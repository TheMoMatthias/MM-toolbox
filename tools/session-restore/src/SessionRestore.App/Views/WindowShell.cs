using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using SessionRestore.App.Services;
using SessionRestore.App.ViewModels;
using SessionRestore.Core;
using SessionRestore.Core.Config;
using SessionRestore.Core.Rows;

namespace SessionRestore.App.Views;

/// <summary>
/// The handlers that change only what the window SHOWS. Plan item 4.2, first
/// tranche.
/// </summary>
/// <remarks>
/// 🔴 NOTHING HERE CAN ACT ON A SESSION, AND THAT IS STRUCTURAL. This class has no
/// reference to the launcher, the console writer or the registry writer, and the
/// handler check reads the App assembly's own metadata to prove the App does not
/// either. The handlers that launch, type, end or save come later, behind a seam
/// whose only implementation reaches the replica console.
///
/// Ported from the chrome buttons, <c>Invoke-ColumnFold</c> / <c>Update-Columns</c>
/// / <c>Update-Strip</c>, the sort label, the 90 ms search timer,
/// <c>Set-Surface</c> and <c>Step-Zoom</c>.
/// </remarks>
public sealed class WindowShell
{
    /// <summary><c>$SR_ZoomSteps</c>.</summary>
    public static readonly int[] ZoomSteps = [80, 90, 100, 110, 125, 150];

    /// <summary><c>$SR_RailStripWidth</c> and <c>$SR_StripWidth</c>.</summary>
    public const double RailStripWidth = 26.0;

    public const double ListStripWidth = 44.0;

    private readonly SessionsWindow _w;
    private readonly SessionsVm _vm;
    private readonly IPreferences _prefs;
    private readonly DispatcherTimer _search;
    private double _railWidth = 208.0;
    private double _listWidth = 336.0;
    private string _foldApplied = string.Empty;

    public WindowShell(SessionsWindow window, SessionsVm vm, IPreferences prefs, ConfigFile? config = null)
    {
        _w = window ?? throw new ArgumentNullException(nameof(window));
        _vm = vm ?? throw new ArgumentNullException(nameof(vm));
        _prefs = prefs ?? throw new ArgumentNullException(nameof(prefs));

        // Absent from the config means AUTO, not open: a fresh install keeps the
        // adaptive columns, and only a deliberate press pins one.
        if (config is not null)
        {
            FoldRail = config.IsSet("foldProjects") ? config.GetBool("foldProjects") : null;
            FoldList = config.IsSet("foldSessions") ? config.GetBool("foldSessions") : null;
            Zoom = config.IsSet("zoom") ? config.GetInt("zoom") : 100;
        }

        Rail = new RailVm(vm, key => _w.TryFindResource(key) as Brush,
            config is not null && config.IsSet("railBandsShut") ? config.GetString("railBandsShut").Split(',') : null);
        if (config?.Raw("autoTickLaneBudgets") is System.Text.Json.Nodes.JsonObject budgets)
        {
            var map = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (var kv in budgets)
            {
                if (kv.Value is System.Text.Json.Nodes.JsonValue jv && jv.TryGetValue<int>(out var n))
                {
                    map[kv.Key] = n;
                }
            }

            Rail.AutoTickBudgets = map;
        }

        if (config is not null && config.IsSet("shelveSuggestDays"))
        {
            Rail.ShelveSuggestDays = config.GetInt("shelveSuggestDays");
        }

        _search = new DispatcherTimer(DispatcherPriority.Input, _w.Dispatcher) { Interval = Cadences.Debounce };
        _search.Tick += (_, _) =>
        {
            _search.Stop();
            _vm.Search = _w.Search.Text;
            _vm.ListSearch = _w.ListSearch.Text;

            // 🔴 BOTH PANES: the header box narrows the rail as well as the list.
            Rail.Query = _w.Search.Text;
            Rail.ProjectQuery = _w.RailSearch.Text;
            RebuildRail();
        };
    }

    /// <summary>Null means the column follows the window's width.</summary>
    public bool? FoldRail { get; private set; }

    public bool? FoldList { get; private set; }

    public int Zoom { get; private set; } = 100;

    /// <summary>The projects rail's view model.</summary>
    public RailVm Rail { get; }

    /// <summary>Wires every handler this tranche owns and applies the starting state.</summary>
    public void Attach()
    {
        _w.WinMin.Click += (_, _) => _w.WindowState = WindowState.Minimized;
        _w.WinMax.Click += (_, _) =>
            _w.WindowState = _w.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
        _w.StateChanged += (_, _) => UpdateMaxGlyph();
        _w.WinClose.Click += (_, _) => _w.Close();

        _w.ListSort.MouseLeftButtonDown += (_, e) =>
        {
            _vm.CycleSort();
            _w.ListSort.Text = _vm.SortLabel;
            e.Handled = true;
        };

        // 🔴 ONE TIMER FOR BOTH BOXES, restarted on every keystroke - a debounce,
        // not a deferral: it coalesces a burst of typing into one filter.
        _w.Search.TextChanged += (_, _) => Restart();
        _w.ListSearch.TextChanged += (_, _) => Restart();

        _w.RailFold.MouseLeftButtonUp += (_, _) => ToggleFold(rail: true);
        _w.RailOpen.MouseLeftButtonUp += (_, _) => ToggleFold(rail: true);
        _w.ListFold.MouseLeftButtonUp += (_, _) => ToggleFold(rail: false);
        _w.ListOpen.MouseLeftButtonUp += (_, _) => ToggleFold(rail: false);
        _w.SizeChanged += (_, _) => UpdateColumns();

        _w.ModeWork.Checked += (_, _) => SetSurface(manage: false);
        _w.ModeManage.Checked += (_, _) => SetSurface(manage: true);

        _w.PaneZoom.Click += (_, _) => StepZoom();

        // ---- the rail
        _w.RailSearch.TextChanged += (_, _) => Restart();
        _w.RailSort.MouseLeftButtonDown += (_, e) =>
        {
            Rail.CycleSort();
            RebuildRail();
            e.Handled = true;
        };
        _w.RailOnlyLive.MouseLeftButtonDown += (_, e) =>
        {
            Rail.OnlyLive = !Rail.OnlyLive;
            RebuildRail();
            e.Handled = true;
        };
        _w.RailShelved.MouseLeftButtonDown += (_, e) =>
        {
            Rail.ShowShelved = !Rail.ShowShelved;
            RebuildRail();
            Status(Rail.ShowShelved
                ? string.Format(CultureInfo.InvariantCulture, "showing the {0} shelved project(s) - right-click one to put it back for good", Rail.Shelved)
                : "shelved projects put away again");
            e.Handled = true;
        };
        _w.RailClear.MouseLeftButtonUp += (_, _) =>
        {
            Rail.ClearPick();
            _vm.Project = string.Empty;
            RebuildRail();
        };

        // A heading FOLDS its band; it is never a pick.
        _w.RailList.PreviewMouseLeftButtonDown += (_, e) =>
        {
            if (Clicked(e.OriginalSource as DependencyObject) is not { IsBand: true } band)
            {
                return;
            }

            Rail.ToggleBand(band.BandKey);
            _prefs.Remember("railBandsShut", Rail.ShutList);
            RebuildRail();
            var lower = band.BandLabel.ToLowerInvariant();
            Status(Rail.IsShut(band.BandKey)
                ? string.Format(CultureInfo.InvariantCulture, "{0} folded away - click the heading again to show those {1} project(s)", lower, band.BandCount)
                : string.Format(CultureInfo.InvariantCulture, "showing the {0} project(s) in {1}", band.BandCount, lower));
            e.Handled = true;
        };

        // 🔴 A HEADING IS NOT A PROJECT: its path is empty, and letting it through
        // would filter the sessions column to nothing with no tile lit to say why.
        _w.RailList.SelectionChanged += (_, _) =>
        {
            if (_w.RailList.SelectedItem is not RailItemVm { IsBand: false } tile)
            {
                return;
            }

            Rail.TogglePick(tile.Path);
            _vm.Project = Rail.Pick ?? string.Empty;
            RebuildRail();
        };

        _w.SessionList.ItemsSource = _vm.View;
        _w.RailList.ItemsSource = Rail.Items;
        RebuildRail();
        _w.ListSort.Text = _vm.SortLabel;
        Typefaces.Scale(_w, Zoom);
        _w.PaneZoom.Content = ZoomLabel(Zoom);
        UpdateMaxGlyph();
        UpdateColumns();
    }

    private void Restart()
    {
        _search.Stop();
        _search.Start();
    }

    // ------------------------------------------------------------------ chrome

    /// <summary>The caption glyph and tooltip for a window state.</summary>
    public static (string Glyph, string Tip) MaxGlyph(WindowState state) =>
        state == WindowState.Maximized ? ("\uE923", "Restore down") : ("\uE922", "Maximise");

    private void UpdateMaxGlyph()
    {
        var (glyph, tip) = MaxGlyph(_w.WindowState);
        _w.WinMax.Content = glyph;
        _w.WinMax.ToolTip = tip;
    }

    // ----------------------------------------------------------------- columns

    /// <summary>
    /// Whether each column is folded: a pinned choice, or the width breakpoints.
    /// </summary>
    /// <remarks>Projects fold under 1180 px, sessions under 900 - <c>Get-ColumnFold</c>.</remarks>
    public static (bool Rail, bool List) Folds(bool? pinnedRail, bool? pinnedList, double width) =>
        (pinnedRail ?? (width > 0 && width < 1180), pinnedList ?? (width > 0 && width < 900));

    private (bool Rail, bool List) CurrentFolds()
    {
        var width = _w.ActualWidth > 0 ? _w.ActualWidth : _w.Width;
        return Folds(FoldRail, FoldList, width);
    }

    private void ToggleFold(bool rail)
    {
        var s = CurrentFolds();
        if (rail)
        {
            FoldRail = !s.Rail;
            _prefs.Remember("foldProjects", FoldRail.Value);
        }
        else
        {
            FoldList = !s.List;
            _prefs.Remember("foldSessions", FoldList.Value);
        }

        UpdateColumns();
    }

    /// <summary>
    /// Applies the folds.
    /// </summary>
    /// <remarks>
    /// 🔑 A WIDTH IS REMEMBERED WHILE ITS COLUMN IS OPEN, so reopening puts back
    /// what the splitter was dragged to rather than the default. And a resize that
    /// changes neither fold changes nothing - the applied key short-circuits.
    /// </remarks>
    private void UpdateColumns()
    {
        var s = CurrentFolds();
        if (_w.RailPane.Visibility == Visibility.Visible && _w.RailCol.Width.Value > 0)
        {
            _railWidth = _w.RailCol.Width.Value;
        }

        if (_w.ListPane.Visibility == Visibility.Visible && _w.ListCol.Width.Value > 0)
        {
            _listWidth = _w.ListCol.Width.Value;
        }

        var key = (s.Rail ? "1" : "0") + (s.List ? "1" : "0");
        if (key == _foldApplied)
        {
            return;
        }

        _foldApplied = key;
        Show(_w.RailStrip, s.Rail);
        Show(_w.RailPane, !s.Rail);
        Show(_w.RailSplit, !s.Rail);
        _w.RailCol.Width = new GridLength(s.Rail ? RailStripWidth : _railWidth);

        Show(_w.ListStrip, s.List);
        Show(_w.ListPane, !s.List);
        Show(_w.ListSplit, !s.List);
        _w.ListCol.Width = new GridLength(s.List ? ListStripWidth : _listWidth);
        if (s.List)
        {
            UpdateStrip();
        }
    }

    private static void Show(UIElement e, bool visible) =>
        e.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>One mark on the collapsed sessions strip.</summary>
    public sealed record StripItem(string Id, string Band, Brush? Accent, string Tip);

    /// <summary>
    /// What the collapsed sessions column still says: who needs you, and who is working.
    /// </summary>
    /// <remarks>
    /// 🔴 NOT COLLAPSED TO NOTHING. This window's whole job is saying which
    /// conversation is waiting on you, and with the list hidden the strip is the
    /// only place left to say it.
    /// </remarks>
    public IReadOnlyList<StripItem> StripItems()
    {
        var needs = _w.TryFindResource("AccNeeds") as Brush;
        var working = _w.TryFindResource("AccWorking") as Brush;
        var items = new List<StripItem>();
        foreach (var band in new[] { Bands.Needs, Bands.Open, Bands.Working })
        {
            var rows = _vm.Rows.Where(r => r.Band == band && Surface.Shows(r.Live, r.Warm, r.Id, _vm.SelectedId, null));
            rows = _vm.Sort switch
            {
                SessionSort.Name => rows.OrderBy(r => r.SortTitle, StringComparer.CurrentCulture),
                SessionSort.Project => rows.OrderBy(r => r.SortProject, StringComparer.CurrentCulture)
                                           .ThenBy(r => r.SortTitle, StringComparer.CurrentCulture),
                _ => rows.OrderByDescending(r => r.LastActiveTicks),
            };

            foreach (var r in rows)
            {
                var needsYou = band == Bands.Needs;
                items.Add(new StripItem(r.Id, band, needsYou ? needs : working,
                    string.Format(CultureInfo.InvariantCulture, "{0} - {1}. Click to open it.", r.Title,
                        needsYou ? "waiting on you" : "working")));
            }
        }

        return items;
    }

    private void UpdateStrip()
    {
        var items = StripItems();
        _w.StripList.ItemsSource = items;
        var waiting = items.Count(i => i.Band == Bands.Needs);
        _w.StripCount.Text = waiting > 0 ? waiting.ToString(CultureInfo.InvariantCulture) : "·";
        _w.StripCount.ToolTip = string.Format(CultureInfo.InvariantCulture, "{0} waiting on you, {1} working", waiting, items.Count - waiting);
    }

    // -------------------------------------------------------------------- rail

    /// <summary>Rebuilds the rail and its header controls; an invalid pattern leaves both as they were.</summary>
    public void RebuildRail()
    {
        if (!Rail.Rebuild())
        {
            return;
        }

        _w.RailSort.Text = Rail.Sort;
        _w.RailOnlyLive.Text = Rail.OnlyLive ? "running" : "all";
        _w.RailOnlyLive.Foreground = _w.TryFindResource(Rail.OnlyLive ? "TextMax" : "TextLow") as Brush;
        _w.RailClear.Visibility = Rail.Pick is null ? Visibility.Collapsed : Visibility.Visible;

        if (Rail.ShelvedControl is { } sh)
        {
            _w.RailShelved.Visibility = Visibility.Visible;
            _w.RailShelved.Text = sh.Text;
            _w.RailShelved.ToolTip = sh.Tip;
            _w.RailShelved.Foreground = _w.TryFindResource(Rail.ShowShelved ? "TextMax" : "TextLow") as Brush;
        }
        else
        {
            _w.RailShelved.Visibility = Visibility.Collapsed;
        }

        if (Rail.SuggestControl is { } su)
        {
            _w.RailSuggest.Visibility = Visibility.Visible;
            _w.RailSuggest.Text = su.Text;
            _w.RailSuggest.ToolTip = su.Tip;
        }
        else
        {
            _w.RailSuggest.Visibility = Visibility.Collapsed;
        }
    }

    /// <summary>The rail item under a click, found by walking up to its container.</summary>
    private static RailItemVm? Clicked(DependencyObject? d)
    {
        while (d is not null and not ListBoxItem)
        {
            d = d is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d);
        }

        return (d as ListBoxItem)?.DataContext as RailItemVm;
    }

    private void Status(string text)
    {
        _w.Status.Text = text;
        _w.Status.Foreground = _w.TryFindResource("TextMid") as Brush;
    }

    // ---------------------------------------------------------------- surfaces

    private void SetSurface(bool manage)
    {
        Show(_w.ManageSurface, manage);
        Show(_w.WorkSurface, !manage);
        _w.Status.Text = manage
            ? "Session manager: what comes back at the next logon. The ticks decide - and the two buttons act on exactly that set, now."
            : "Work surface: what each conversation last said, and which of them are waiting on you.";
        _w.Status.Foreground = _w.TryFindResource("TextMid") as Brush;
    }

    // -------------------------------------------------------------------- zoom

    public static string ZoomLabel(int zoom) => string.Format(CultureInfo.InvariantCulture, "Text: {0}%", zoom);

    /// <summary>
    /// The step after the one nearest <paramref name="current"/>, round again.
    /// </summary>
    /// <remarks>🪤 A TIE GOES TO THE LOWER STEP - the shipped loop keeps the first of two equal distances.</remarks>
    public static int NextZoom(int current)
    {
        var i = 0;
        for (var n = 0; n < ZoomSteps.Length; n++)
        {
            if (Math.Abs(ZoomSteps[n] - current) < Math.Abs(ZoomSteps[i] - current))
            {
                i = n;
            }
        }

        return ZoomSteps[(i + 1) % ZoomSteps.Length];
    }

    private void StepZoom()
    {
        Zoom = Math.Max(70, Math.Min(200, NextZoom(Zoom)));
        Typefaces.Scale(_w, Zoom);
        _w.PaneZoom.Content = ZoomLabel(Zoom);
        _prefs.Remember("zoom", Zoom);
    }
}
