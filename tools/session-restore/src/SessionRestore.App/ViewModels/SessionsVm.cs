using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Data;
using SessionRestore.Core.Registry;
using SessionRestore.Core.Rows;
using SessionRestore.Core.Sessions;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.App.ViewModels;

/// <summary>How the sessions column is ordered.</summary>
public enum SessionSort
{
    Recent,
    Name,
    Band,
}

/// <summary>
/// The sessions column. Plan item 3.2, and the item this rebuild is justified by.
/// </summary>
/// <remarks>
/// 🔴 THE ROWS ARE BOUND ONCE AND A GESTURE NEVER REBUILDS THEM. Measured on the
/// PowerShell: a search keystroke cost **512 ms median** with a real frame, and
/// 81% of it was constructing and drawing 32 rows. The fix is not a faster
/// rebuild - it is not rebuilding. Sort, filter and search are an
/// <see cref="ICollectionView"/> over an <see cref="ObservableCollection{T}"/>
/// that changes only when the MODEL changes.
///
/// 🪤 <c>Refresh()</c> IS THE WHOLE GESTURE, AND IT IS DELIBERATELY NOT
/// DEFERRED. Moving work off the keystroke onto a timer makes the bench green
/// while the operator's wait is unchanged - the measurement has to run to the
/// PRESENTED FRAME, and a deferral just moves which frame that is.
/// </remarks>
public sealed class SessionsVm : INotifyPropertyChanged
{
    private readonly ObservableCollection<ConversationVm> _rows = [];
    private readonly Dictionary<string, ConversationVm> _byId = new(StringComparer.OrdinalIgnoreCase);

    private string _search = string.Empty;
    private string _project = string.Empty;
    private SessionSort _sort = SessionSort.Recent;
    private bool _onlyLive;

    public SessionsVm()
    {
        // 🔴 THE PREDICATE NEVER CHANGES AFTER THIS LINE. It reads one bool off
        // the row, and the ROW is what a gesture updates - so the view raises Add
        // and Remove for what moved instead of Reset for everything.
        var view = new ListCollectionView(_rows)
        {
            Filter = o => o is ConversationVm r && r.Matches,
        };

        // 🪤 IsLiveFiltering IS NOT ENOUGH ON ITS OWN. Without the property
        // NAMED in LiveFilteringProperties the view has nothing to watch, stays
        // silent when Matches changes, and the column quietly stops updating -
        // which looks like a filter that does not work rather than like a missing
        // registration.
        view.IsLiveFiltering = true;
        view.LiveFilteringProperties.Add(nameof(ConversationVm.Matches));
        view.IsLiveSorting = true;

        View = view;
        _view = view;
        ApplySort();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>What the column binds to. Never replaced.</summary>
    public ICollectionView View { get; }

    private readonly ListCollectionView _view;

    /// <summary>Every conversation on the surface, ordered as the model gave them.</summary>
    public IReadOnlyList<ConversationVm> Rows => _rows;

    /// <summary>
    /// 🔑 THE SEARCH BOX. One keystroke is a predicate over 434 items in native
    /// code, not 32 object constructions in an interpreter.
    /// </summary>
    public string Search
    {
        get => _search;
        set
        {
            // 🪤 LOWER-CASED ONCE PER KEYSTROKE, not once per row per keystroke.
            // The haystack is already lower-case; doing the needle here as well
            // is 434 fewer allocations per character typed.
            if (Set(ref _search, value ?? string.Empty))
            {
                _needle = _search.Trim().ToLowerInvariant();
                Reselect();
            }
        }
    }

    /// <summary>The rail's filter: one project, or all of them.</summary>
    public string Project
    {
        get => _project;
        set
        {
            if (Set(ref _project, value ?? string.Empty))
            {
                Reselect();
            }
        }
    }

    public bool OnlyLive
    {
        get => _onlyLive;
        set
        {
            if (Set(ref _onlyLive, value))
            {
                Reselect();
            }
        }
    }

    public SessionSort Sort
    {
        get => _sort;
        set
        {
            if (Set(ref _sort, value))
            {
                ApplySort();
            }
        }
    }

    private string _needle = string.Empty;

    /// <summary>
    /// Brings the rows into line with the model.
    /// </summary>
    /// <remarks>
    /// 🔴 IT ADDS, REMOVES AND UPDATES - IT DOES NOT REPLACE. Clearing and
    /// refilling the collection is a rebuild wearing a different hat: WPF drops
    /// every container and makes them again, which is the cost this class exists
    /// to remove. A conversation that was already there keeps its row object, its
    /// container and its selection.
    ///
    /// 🪤 AND THE SELECTION IS WHY IT MATTERS BEYOND SPEED. A row replaced
    /// mid-read takes the reading pane's selection with it - see the surface
    /// predicate's own note about a conversation vanishing from under the pane.
    /// </remarks>
    public void Sync(
        IEnumerable<(string Id, RegistrySession Session, RegistryDirectory Directory)> model,
        IReadOnlyDictionary<string, AgentStatus>? agents = null,
        IReadOnlyDictionary<string, SaidResult>? said = null,
        long nowTicks = 0)
    {
        ArgumentNullException.ThrowIfNull(model);
        if (nowTicks <= 0)
        {
            nowTicks = DateTime.Now.Ticks;
        }

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (id, session, directory) in model)
        {
            seen.Add(id);
            agents?.TryGetValue(id, out var agent);
            var a = agents is not null && agents.TryGetValue(id, out var av) ? av : null;
            var s = said is not null && said.TryGetValue(id, out var sv) ? sv : null;

            if (_byId.TryGetValue(id, out var row))
            {
                row.Refresh(a, s, nowTicks);
                continue;
            }

            row = new ConversationVm(id, session, directory);
            row.Refresh(a, s, nowTicks);
            _byId[id] = row;
            _rows.Add(row);
        }

        for (var i = _rows.Count - 1; i >= 0; i--)
        {
            if (!seen.Contains(_rows[i].Id))
            {
                _byId.Remove(_rows[i].Id);
                _rows.RemoveAt(i);
            }
        }

        Reselect();
    }

    /// <summary>
    /// Re-decides which rows pass, and lets live filtering move the ones that
    /// changed.
    /// </summary>
    /// <remarks>
    /// 🔴 THIS IS O(n) BOOLEAN WRITES AND DELIBERATELY SO. It touches all 428
    /// rows, but the ones whose answer is unchanged raise nothing - and typing
    /// narrows, so most rows keep their answer. What it replaces is a Reset,
    /// which costs a container rebuild for every row on screen whether anything
    /// moved or not.
    ///
    /// 🪤 DeferRefresh AROUND THE WHOLE PASS, or the view reacts to each row
    /// in turn and re-sorts between them.
    /// </remarks>
    private void Reselect()
    {
        using (_view.DeferRefresh())
        {
            foreach (var r in _rows)
            {
                r.Matches = Passes(r);
            }
        }
    }

    /// <summary>
    /// 🔑 THE PREDICATE IS THE GESTURE. Everything it reads is a field that was
    /// computed when the model changed, so this is string and boolean work over
    /// 434 items - no file, no clock, no allocation per row.
    /// </summary>
    private bool Passes(ConversationVm r)
    {
        if (_onlyLive && !r.Live)
        {
            return false;
        }

        if (_project.Length > 0
            && !string.Equals(r.ProjectPath, _project, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return _needle.Length == 0
            || r.SearchText.Contains(_needle, StringComparison.Ordinal);
    }

    /// <summary>
    /// 🪤 SortDescriptions ARE REPLACED IN ONE DEFERRED BLOCK. Assigning them one
    /// at a time makes the view re-sort on each, so a two-key order costs two
    /// full sorts and briefly shows a wrong one.
    /// </summary>
    private void ApplySort()
    {
        using (_view.DeferRefresh())
        {
            View.SortDescriptions.Clear();
            switch (_sort)
            {
                case SessionSort.Name:
                    View.SortDescriptions.Add(new SortDescription(nameof(ConversationVm.Title), ListSortDirection.Ascending));
                    break;
                case SessionSort.Band:
                    View.SortDescriptions.Add(new SortDescription(nameof(ConversationVm.Band), ListSortDirection.Ascending));
                    View.SortDescriptions.Add(new SortDescription(nameof(ConversationVm.LastActiveTicks), ListSortDirection.Descending));
                    break;
                default:
                    View.SortDescriptions.Add(new SortDescription(nameof(ConversationVm.LastActiveTicks), ListSortDirection.Descending));
                    break;
            }
        }
    }

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        return true;
    }
}
