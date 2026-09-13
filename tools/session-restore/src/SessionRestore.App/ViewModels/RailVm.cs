using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Media;
using SessionRestore.Core.Rows;

namespace SessionRestore.App.ViewModels;

/// <summary>One line of the rail: an age-band heading or a project tile.</summary>
/// <remarks>
/// 🔑 ONE SHAPE FOR BOTH, AS THE SHIPPED TEMPLATE WANTS. The rail's heading is a
/// clickable ITEM - it folds its band - not a group header, so heading and tile go
/// through one template and each carries the other's properties switched off.
/// Unlike the sessions column, that is the design here rather than a workaround.
/// </remarks>
public sealed class RailItemVm
{
    public required string Id { get; init; }

    public bool IsBand { get; init; }

    public string BandKey { get; init; } = string.Empty;

    public string Path { get; init; } = string.Empty;

    public Visibility BandVis => IsBand ? Visibility.Visible : Visibility.Collapsed;

    public Visibility RowVis => IsBand ? Visibility.Collapsed : Visibility.Visible;

    public string BandLabel { get; init; } = string.Empty;

    public int BandCount { get; init; }

    public string BandCaret { get; init; } = string.Empty;

    public string Label { get; init; } = string.Empty;

    public int Count { get; init; }

    public string State { get; init; } = string.Empty;

    public string? Tip { get; init; }

    public Brush? Accent { get; init; }

    public double AccentOpacity { get; init; }

    public Visibility NeedsVis { get; init; } = Visibility.Collapsed;

    public Brush? PickBg { get; init; }

    public Brush? PickEdge { get; init; }

    public Brush? Fg { get; init; }

    /// <summary>What the drawn state is, for the keyed sync: a tile whose signature is unchanged is left alone.</summary>
    public required string Sig { get; init; }
}

/// <summary>
/// The projects rail. Plan item 4.2b. The rules are <see cref="Rail"/>, oracle-checked
/// against <c>Build-Rail</c>; this holds the rail's view state and patches the list.
/// </summary>
public sealed class RailVm
{
    private readonly SessionsVm _sessions;
    private readonly Func<string, Brush?> _resource;
    private readonly HashSet<string> _shut = new(StringComparer.Ordinal);

    public RailVm(SessionsVm sessions, Func<string, Brush?> resource, IEnumerable<string>? shut = null)
    {
        _sessions = sessions ?? throw new ArgumentNullException(nameof(sessions));
        _resource = resource ?? throw new ArgumentNullException(nameof(resource));
        foreach (var k in shut ?? [])
        {
            var kk = k.Trim().ToLowerInvariant();
            if (kk.Length > 0)
            {
                _shut.Add(kk);
            }
        }
    }

    /// <summary>
    /// 🔑 PATCHED, NOT REPLACED - the fix the sessions column got, for the same
    /// reason: handing the list a new collection re-realises every tile.
    /// </summary>
    public ObservableCollection<RailItemVm> Items { get; } = [];

    public string Query { get; set; } = string.Empty;

    public string ProjectQuery { get; set; } = string.Empty;

    public string Sort { get; private set; } = "recent";

    public bool OnlyLive { get; set; }

    public bool ShowShelved { get; set; }

    public string? Pick { get; private set; }

    public int Shelved { get; private set; }

    public (string Text, string Tip)? ShelvedControl { get; private set; }

    public (string Text, string Tip)? SuggestControl { get; private set; }

    /// <summary>The band keys folded shut, in band order - what a fold asks to be remembered.</summary>
    public string ShutList => string.Join(",", Rail.BandsInOrder.Select(b => b.Key).Where(_shut.Contains));

    /// <summary>
    /// Autotick budgets by lane key (<c>leaf/*</c>) and the suggestion days, from the config. Read-only.
    /// </summary>
    public IReadOnlyDictionary<string, int> AutoTickBudgets { get; set; } = new Dictionary<string, int>();

    public int? ShelveSuggestDays { get; set; }

    public void CycleSort()
    {
        var at = Array.IndexOf(Rail.Sorts, Sort);
        Sort = Rail.Sorts[(at + 1) % Rail.Sorts.Length];
    }

    public void ToggleBand(string key)
    {
        var k = key.ToLowerInvariant();
        if (!_shut.Remove(k))
        {
            _shut.Add(k);
        }
    }

    public bool IsShut(string key) => _shut.Contains(key.ToLowerInvariant());

    /// <summary>A tile click: picks the project, or unpicks it when it was the pick.</summary>
    public void TogglePick(string path) =>
        Pick = Pick is not null && string.Equals(Pick, path, StringComparison.OrdinalIgnoreCase) ? null : path;

    public void ClearPick() => Pick = null;

    /// <summary>Rebuilds the rail from the column's rows. False when a search holds an invalid pattern and nothing changed.</summary>
    public bool Rebuild(DateTime? now = null)
    {
        var rows = _sessions.Rows;
        var labels = ProjectLabels.For(rows.Select(r => r.Directory.Path).Distinct(StringComparer.OrdinalIgnoreCase));
        var order = ProjectAccent.Order(rows.Select(r => r.Directory.Path));
        var railRows = rows.Select(r => new RailRow(
            r.Directory.Path, r.LastActiveTicks, r.Band, r.Live, r.Session, r.Directory,
            r.SearchText, (labels.Of(r.Directory.Path) + " " + r.Directory.Path).ToLowerInvariant())).ToList();

        var clock = now ?? DateTime.Now;
        var suggest = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var names = new List<string>();
        foreach (var dir in rows.Select(r => r.Directory).Distinct())
        {
            var running = rows.Any(r => ReferenceEquals(r.Directory, dir) && r.Live);
            var why = ShelveSuggestion.For(dir, ShelveSuggestDays, running, clock);
            if (why.Length > 0 && !suggest.ContainsKey(dir.Path))
            {
                suggest[dir.Path] = why;
                names.Add(labels.Of(dir.Path));
            }
        }

        var built = Rail.Build(
            railRows, new RailView(Query, ProjectQuery, Sort, OnlyLive, ShowShelved, _shut, Pick),
            labels, order, RailCuts.At(clock),
            path => AutoTickBudgets.TryGetValue(Titles.PathLeaf(path) + "/*", out var n) && n == 0,
            suggest);
        if (built is null)
        {
            return false;
        }

        Shelved = built.Shelved;
        ShelvedControl = Rail.ShelvedControl(built.Shelved, ShowShelved);
        SuggestControl = Rail.SuggestControl(names);
        Patch(built.Items.Select(ToVm).ToList());
        return true;
    }

    private RailItemVm ToVm(object item)
    {
        if (item is RailHead h)
        {
            return new RailItemVm
            {
                Id = "band:" + h.Key, IsBand = true, BandKey = h.Key, BandLabel = h.Label, BandCount = h.Count,
                BandCaret = h.Caret, Sig = "band|" + h.Label + "|" + h.Count + "|" + h.Caret,
            };
        }

        var t = (RailTile)item;
        var accent = new SolidColorBrush(Color.FromRgb(t.Accent.R, t.Accent.G, t.Accent.B));
        accent.Freeze();
        return new RailItemVm
        {
            Id = "proj:" + t.Path, Path = t.Path, Label = t.Label, Count = t.Count, State = t.State, Tip = t.Tip,
            Accent = accent, AccentOpacity = t.AccentOpacity,
            NeedsVis = t.NeedsVisible ? Visibility.Visible : Visibility.Collapsed,
            PickBg = t.Picked ? _resource("SelBg") : Brushes.Transparent,
            PickEdge = t.Picked ? _resource("EdgeLit") : Brushes.Transparent,
            Fg = _resource(t.Picked ? "TextMax" : "TextHigh"),
            Sig = string.Join("|", t.Label, t.Count, t.State, t.Tip, t.Accent, t.AccentOpacity, t.NeedsVisible, t.Picked),
        };
    }

    /// <summary><c>Sync-SRSessionItems</c>: remove what left, move what moved, replace what changed, insert what is new.</summary>
    private void Patch(List<RailItemVm> want)
    {
        var keep = want.Select(w => w.Id).ToHashSet(StringComparer.Ordinal);
        for (var i = Items.Count - 1; i >= 0; i--)
        {
            if (!keep.Contains(Items[i].Id))
            {
                Items.RemoveAt(i);
            }
        }

        for (var i = 0; i < want.Count; i++)
        {
            var t = want[i];
            if (i >= Items.Count)
            {
                Items.Add(t);
                continue;
            }

            if (Items[i].Id != t.Id)
            {
                var at = -1;
                for (var j = i + 1; j < Items.Count; j++)
                {
                    if (Items[j].Id == t.Id)
                    {
                        at = j;
                        break;
                    }
                }

                if (at >= 0)
                {
                    Items.Move(at, i);
                }
                else
                {
                    Items.Insert(i, t);
                    continue;
                }
            }

            if (Items[i].Sig != t.Sig)
            {
                Items[i] = t;
            }
        }

        while (Items.Count > want.Count)
        {
            Items.RemoveAt(Items.Count - 1);
        }
    }
}
