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
/// <remarks>
/// 🔴 RECENT, NAME, PROJECT - the shipped cycle. The first port had BAND as the
/// third, which the window never offered: bands are always the grouping, never a
/// sort, and "by project" was missing entirely.
/// </remarks>
public enum SessionSort
{
    Recent,
    Name,
    Project,
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
    private readonly ObservableCollection<IListRow> _rows = [];
    private readonly Dictionary<string, ConversationVm> _byId = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// The agent rows currently in the column, by the conversation they belong to.
    /// </summary>
    /// <remarks>
    /// 🔴 ONE PARENT AT A TIME, in practice - the rows exist only under the
    /// conversation being read - but this is keyed rather than a single field
    /// so that dropping them cannot depend on remembering which parent they had.
    /// A stale key here is an agent row under a conversation nobody selected.
    /// </remarks>
    private readonly Dictionary<string, List<AgentRowVm>> _agentRows = new(StringComparer.OrdinalIgnoreCase);

    private string _search = string.Empty;
    private string _project = string.Empty;
    private SessionSort _sort = SessionSort.Recent;
    private bool _onlyLive;
    private string _selectedId = string.Empty;
    private string _listSearch = string.Empty;
    private System.Text.RegularExpressions.Regex? _needleRx;
    private System.Text.RegularExpressions.Regex? _listRx;

    public SessionsVm()
    {
        // 🔴 THE PREDICATE NEVER CHANGES AFTER THIS LINE. It reads one bool off
        // the row, and the ROW is what a gesture updates - so the view raises Add
        // and Remove for what moved instead of Reset for everything.
        var view = new ListCollectionView(_rows)
        {
            Filter = o => o is IListRow r && r.Matches,
        };

        // 🪤 IsLiveFiltering IS NOT ENOUGH ON ITS OWN. Without the property
        // NAMED in LiveFilteringProperties the view has nothing to watch, stays
        // silent when Matches changes, and the column quietly stops updating -
        // which looks like a filter that does not work rather than like a missing
        // registration.
        view.IsLiveFiltering = true;
        view.LiveFilteringProperties.Add(nameof(ConversationVm.Matches));

        // 🔴 PLAN ITEM 3.3 - THE BANDS ARE A GROUPING, NOT CONSTRUCTED ROWS.
        // The PowerShell builds a heading as a FAKE LIST ITEM carrying every
        // session property present-but-switched-off, because a heading and a row
        // share one DataTemplate and a binding to a property that is not on the
        // object is a silent trace error and an empty cell. That whole class of
        // problem disappears with a real group: the header has its own template
        // and never pretends to be a row.
        //
        // 🪤 AND LIVE GROUPING IS WHAT MAKES IT WORTH HAVING. Without it, a
        // conversation whose band changes on a background refresh does not move
        // until something re-groups - and re-grouping is a Reset, which rebuilds
        // the column. With it, the row moves between two headings and nothing
        // else is touched.
        view.GroupDescriptions.Add(new PropertyGroupDescription(nameof(ConversationVm.BandLabel)));
        view.IsLiveGrouping = true;
        view.LiveGroupingProperties.Add(nameof(ConversationVm.BandLabel));

        // 🔴 IsLiveSorting STAYS ON, AND IT IS LOAD-BEARING. Turning it off was
        // tried as a fix for the 21 ms sort cycle and bought nothing measurable -
        // but it WOULD have cost something real: a conversation whose lastActive
        // moves on a background refresh has to rise to the top of a recent-first
        // list, and with live sorting off it would sit where it was until
        // something else re-sorted. A change that buys nothing and risks that is
        // not a trade, it is a regression waiting for a quiet week.
        view.IsLiveSorting = true;

        View = view;
        _view = view;
        ApplySort();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>What the column binds to. Never replaced.</summary>
    public ICollectionView View { get; }

    private readonly ListCollectionView _view;

    /// <summary>
    /// Every row the column holds - conversations and the agent rows under the
    /// one being read - in the order the model gave them.
    /// </summary>
    /// <remarks>
    /// 🪤 THIS IS THE SOURCE, NOT THE VIEW. A check that watches it for
    /// structural changes is asking whether a gesture REBUILT the column, and
    /// that is a different question from what is on screen - see the three
    /// checks in Phase 3 that each passed while the thing they named was untrue.
    /// </remarks>
    public IReadOnlyList<IListRow> Items => _rows;

    /// <summary>Every conversation on the surface, without the agent rows.</summary>
    public IEnumerable<ConversationVm> Rows => _rows.OfType<ConversationVm>();

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
                _needleRx = _needle.Length > 0 ? SearchMatch.Pattern(_needle) : null;
                Reselect();
            }
        }
    }

    /// <summary>The sessions column's own search box - titles only.</summary>
    public string ListSearch
    {
        get => _listSearch;
        set
        {
            if (Set(ref _listSearch, value ?? string.Empty))
            {
                _listNeedle = _listSearch.Trim().ToLowerInvariant();
                _listRx = _listNeedle.Length > 0 ? SearchMatch.Pattern(_listNeedle) : null;
                Reselect();
            }
        }
    }

    private string _listNeedle = string.Empty;

    /// <summary>What the sort control says: "newest first", "by name", "by project".</summary>
    public string SortLabel => _sort switch
    {
        SessionSort.Name => "by name",
        SessionSort.Project => "by project",
        _ => "newest first",
    };

    /// <summary>The sort control's click: the next of the three, round again.</summary>
    public void CycleSort() => Sort = (SessionSort)(((int)_sort + 1) % 3);

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

    /// <summary>
    /// The conversation the reading pane holds.
    /// </summary>
    /// <remarks>
    /// 🔴 IT IS PART OF THE FILTER, not only of the selection. A conversation
    /// leaves the surface once it is neither live nor warm, and the model pass
    /// runs every six seconds - so without this it could vanish from under the
    /// pane mid-read. See Surface.Shows.
    /// </remarks>
    public string SelectedId
    {
        get => _selectedId;
        set
        {
            if (Set(ref _selectedId, (value ?? string.Empty).ToLowerInvariant()))
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
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(SortLabel)));
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
        long nowTicks = 0,
        IReadOnlyDictionary<string, RowExtras>? extras = null,
        ProjectLabels? labels = null)
    {
        ArgumentNullException.ThrowIfNull(model);
        if (nowTicks <= 0)
        {
            nowTicks = DateTime.Now.Ticks;
        }

        var list = model as IList<(string Id, RegistrySession Session, RegistryDirectory Directory)> ?? model.ToList();

        // Labels are disambiguated against every project the model holds.
        labels ??= ProjectLabels.For(list.Select(m => m.Directory.Path).Distinct(StringComparer.OrdinalIgnoreCase));

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (id, session, directory) in list)
        {
            seen.Add(id);
            var a = agents is not null && agents.TryGetValue(id, out var av) ? av : null;
            var s = said is not null && said.TryGetValue(id, out var sv) ? sv : null;
            var x = extras is not null && extras.TryGetValue(id, out var xv) ? xv : null;

            if (_byId.TryGetValue(id, out var row))
            {
                row.Refresh(a, s, nowTicks, x);
                row.ApplyLabel(labels.Of(directory.Path));
                continue;
            }

            row = new ConversationVm(id, session, directory);
            row.Refresh(a, s, nowTicks, x);
            row.ApplyLabel(labels.Of(directory.Path));
            _byId[id] = row;
            _rows.Add(row);
        }

        // 🔴 THE AGENT ROWS ARE NOT IN `seen` AND MUST NOT BE JUDGED BY IT.
        // Their ids are the agents' own, the model is a list of conversations,
        // and a loop that only asked `seen.Contains` deleted every agent row on
        // the next 2,5 s sweep - the rows appeared on the click and vanished a
        // moment later. They are owned by SetAgents; what happens here is that
        // an agent whose PARENT has gone goes with it.
        for (var i = _rows.Count - 1; i >= 0; i--)
        {
            switch (_rows[i])
            {
                case AgentRowVm agent when !seen.Contains(agent.Parent.Id):
                    agent.Detach();
                    _rows.RemoveAt(i);
                    break;
                case ConversationVm row when !seen.Contains(row.Id):
                    _byId.Remove(row.Id);
                    _rows.RemoveAt(i);
                    break;
                default:
                    break;
            }
        }

        foreach (var key in _agentRows.Keys.Where(k => !seen.Contains(k)).ToList())
        {
            _agentRows.Remove(key);
        }

        Reselect();
    }

    /// <summary>
    /// Puts the sub-agent rows under one conversation, and takes every other
    /// conversation's away.
    /// </summary>
    /// <remarks>
    /// 🔴 UNDER THE SELECTED CONVERSATION ONLY. Rendering every conversation's
    /// agents took the shipped list from 36 rows to 106 in review, on a surface
    /// that had just been asked to get LESS dense, and one conversation on this
    /// machine has 31 agents of its own. The amber dot still says, on every row,
    /// that a session has agents out right now.
    ///
    /// 🪤 IT PATCHES, IT DOES NOT REPLACE. This is called again on every sweep
    /// while a conversation is open, and dropping the rows to re-add them would
    /// rebuild their containers two or three times a second - the exact cost
    /// this whole class exists to remove. A row that is still there keeps its
    /// object and gets new values.
    ///
    /// 🪤 AND THE PARENT MUST STAY OPEN WHILE ONE OF ITS AGENTS IS SELECTED, or
    /// selecting an agent would remove the row that is selected. That is the
    /// caller's business: it passes the parent of the selected agent.
    /// </remarks>
    /// <param name="parentId">The conversation whose agents are shown, or empty for none.</param>
    /// <param name="agents">Its agents, in the order they should read.</param>
    /// <param name="live">Which of them are still writing, by agent id. One definition, from the caller.</param>
    /// <param name="nowTicks">Now, for the ages. 0 reads the clock.</param>
    public void SetAgents(
        string parentId,
        IReadOnlyList<SubAgent> agents,
        IReadOnlySet<string>? live = null,
        long nowTicks = 0)
    {
        ArgumentNullException.ThrowIfNull(agents);
        parentId = (parentId ?? string.Empty).ToLowerInvariant();
        if (nowTicks <= 0)
        {
            nowTicks = DateTime.Now.Ticks;
        }

        // Everything filed under another conversation goes, whatever is passed.
        foreach (var key in _agentRows.Keys.Where(k => !string.Equals(k, parentId, StringComparison.OrdinalIgnoreCase)).ToList())
        {
            Drop(key);
        }

        if (parentId.Length == 0 || !_byId.TryGetValue(parentId, out var parent))
        {
            return;
        }

        var wanted = agents.Select(a => AgentRowVm.IdPrefix + a.Id).ToHashSet(StringComparer.Ordinal);
        if (!_agentRows.TryGetValue(parentId, out var held))
        {
            held = [];
            _agentRows[parentId] = held;
        }

        for (var i = held.Count - 1; i >= 0; i--)
        {
            if (!wanted.Contains(held[i].Id))
            {
                Remove(held[i]);
                held.RemoveAt(i);
            }
        }

        var byId = held.ToDictionary(r => r.Id, StringComparer.Ordinal);
        var at = _rows.IndexOf(parent);
        for (var order = 0; order < agents.Count; order++)
        {
            var a = agents[order];
            var id = AgentRowVm.IdPrefix + a.Id;
            var running = live is not null ? live.Contains(a.Id) : a.IsLive();
            if (byId.TryGetValue(id, out var row))
            {
                row.Refresh(running, nowTicks, order + 1);
                continue;
            }

            row = new AgentRowVm(parent, a, order + 1);
            row.Refresh(running, nowTicks, order + 1);
            row.Matches = parent.Matches;
            held.Add(row);

            // Beside its parent in the source as well as in the view. The sort
            // decides what is on screen; this only keeps the source readable.
            if (at >= 0 && at + held.Count <= _rows.Count)
            {
                _rows.Insert(at + held.Count, row);
            }
            else
            {
                _rows.Add(row);
            }
        }
    }

    private void Drop(string parentId)
    {
        if (!_agentRows.TryGetValue(parentId, out var held))
        {
            return;
        }

        foreach (var row in held)
        {
            Remove(row);
        }

        _agentRows.Remove(parentId);
    }

    private void Remove(AgentRowVm row)
    {
        row.Detach();
        _rows.Remove(row);
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
    ///
    /// 🪤 "ONE RESET WHEN MOST ROWS MOVE" WAS TRIED HERE AND WAS WORSE, which
    /// is worth writing down because it is the obvious idea. Live filtering is
    /// the wrong trade for a whole-list swap in principle - 428 notifications
    /// against one Reset - so the plan was to count the movers and switch. But
    /// the only lever for it is toggling `IsLiveFiltering`, and toggling that
    /// makes the view rebuild its own tracking over every item: a search
    /// keystroke went **2,1 ms -> 25 ms** and clearing the search **10 -> 38 ms**.
    /// Reverted. The whole-list gestures keep their per-row notifications.
    /// </remarks>
    private void Reselect()
    {
        // 🔴 AN INVALID PATTERN CHANGES NOTHING. In the shipped window `-like`
        // throws on an unclosed `[`, the rebuild is abandoned inside its catch, and
        // the list keeps showing what it showed. Filtering to nothing instead would
        // blank the column on the second character of `[draft]`.
        if ((_needle.Length > 0 && _needleRx is null) || (_listNeedle.Length > 0 && _listRx is null))
        {
            return;
        }

        using (_view.DeferRefresh())
        {
            // 🔴 THE CONVERSATIONS FIRST, THEN THEIR AGENTS. An agent row's
            // answer is its parent's answer AND the expansion, so deciding it
            // in one pass over a mixed list would read whatever the parent
            // happened to hold - right for the rows that come after their
            // parent and wrong for any that do not. Two passes cost one extra
            // walk of a list that is already only booleans.
            foreach (var r in _rows)
            {
                if (r is ConversationVm c)
                {
                    c.Matches = Passes(c);
                }
            }

            foreach (var r in _rows)
            {
                if (r is AgentRowVm a)
                {
                    a.Matches = a.Expanded && a.Parent.Matches;
                }
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

        // 🔴 A PICKED PROJECT SHOWS THAT PROJECT, ALL OF IT - and the surface
        // rule is what it replaces, not what it narrows. The shipped column
        // answered a pick on an old project with an EMPTY list, because the
        // 24-hour cut still applied; "expand the further-away projects and
        // continue working on them" cannot mean an empty list. With no pick,
        // the surface rule decides: live, warm, or the one being read.
        //
        // 🪤 THE PORT MISSED THIS UNTIL 4.1 DREW IT. The column showed all 416
        // conversations under NOT RUNNING - every one ever recorded - and no
        // check had asked, because every check was about how rows MOVE.
        if (_project.Length > 0)
        {
            if (!string.Equals(r.ProjectPath, _project, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
        }
        else if (!Surface.Shows(r.Live, r.Warm, r.Id, _selectedId, null))
        {
            return false;
        }

        return (_needleRx is null || _needleRx.IsMatch(r.SearchText))
            && (_listRx is null || _listRx.IsMatch(r.ListSearchText));
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

            // 🔴 THE BAND ORDER SORTS FIRST, ALWAYS, whatever the column is
            // sorted by inside a band. A view forms its groups in the order the
            // items arrive, so this is what puts NEEDS YOU at the top and NOT
            // RUNNING at the bottom - the order is a fact about the board, not a
            // preference the sort control gets to change.
            View.SortDescriptions.Add(
                new SortDescription(nameof(ConversationVm.BandOrder), ListSortDirection.Ascending));

            switch (_sort)
            {
                case SessionSort.Name:
                    View.SortDescriptions.Add(new SortDescription(nameof(ConversationVm.SortTitle), ListSortDirection.Ascending));
                    break;
                case SessionSort.Project:
                    View.SortDescriptions.Add(new SortDescription(nameof(ConversationVm.SortProject), ListSortDirection.Ascending));
                    View.SortDescriptions.Add(new SortDescription(nameof(ConversationVm.SortTitle), ListSortDirection.Ascending));
                    break;
                default:
                    View.SortDescriptions.Add(new SortDescription(nameof(ConversationVm.LastActiveTicks), ListSortDirection.Descending));
                    break;
            }

            // 🔴 LAST, ALWAYS, AND IT IS WHAT KEEPS AN AGENT UNDER ITS OWN
            // CONVERSATION. Every key above is mirrored from the parent onto its
            // agent rows, so the pair ties on all of them and this breaks the tie
            // in favour of the conversation - 0 before 1, 2, 3.
            //
            // 🪤 A STABLE SORT WOULD NOT HAVE BEEN ENOUGH TO RELY ON.
            // ListCollectionView sorts with Array.Sort, which is introsort and
            // NOT stable, so "they were added in the right order" decides
            // nothing once there are more than a few rows.
            View.SortDescriptions.Add(
                new SortDescription(nameof(IListRow.SubOrder), ListSortDirection.Ascending));
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
