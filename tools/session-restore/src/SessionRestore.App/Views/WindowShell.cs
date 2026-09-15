using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using SessionRestore.App.Services;
using SessionRestore.App.ViewModels;
using SessionRestore.Core;
using SessionRestore.Core.Acting;
using SessionRestore.Core.Config;
using SessionRestore.Core.Rows;
using SessionRestore.Core.Sessions;

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
    private readonly IActs _acts;
    private readonly IConfirms _confirms;
    private readonly DispatcherTimer _search;
    private double _railWidth = 208.0;
    private double _listWidth = 336.0;
    private string _foldApplied = string.Empty;

    /// <param name="acts">
    /// 🔴 THE ONLY WAY ANYTHING HERE REACHES A CONVERSATION, and it has no
    /// default on purpose. A parameter that quietly supplied one would be the
    /// line along which a real implementation gets wired by accident; every
    /// caller says which it means.
    /// </param>
    /// <param name="confirms">The sheet in front of anything that cannot be taken back.</param>
    public WindowShell(
        SessionsWindow window,
        SessionsVm vm,
        IPreferences prefs,
        IActs acts,
        IConfirms confirms,
        ConfigFile? config = null)
    {
        _w = window ?? throw new ArgumentNullException(nameof(window));
        _vm = vm ?? throw new ArgumentNullException(nameof(vm));
        _prefs = prefs ?? throw new ArgumentNullException(nameof(prefs));
        _acts = acts ?? throw new ArgumentNullException(nameof(acts));
        _confirms = confirms ?? throw new ArgumentNullException(nameof(confirms));

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

        _w.SessionList.SelectionChanged += (_, _) => Select(_w.SessionList.SelectedItem);

        // ---- the acting handlers. Every one of them goes through the seam.
        _w.PaneStop.Click += (_, _) => Stop();
        _w.PaneCompact.Click += (_, _) => Compact();
        _w.PaneGoTo.Click += (_, _) => GoTo();
        _w.PaneRelaunch.Click += (_, _) => RelaunchSelected();
        _w.SendBtn.Click += (_, _) => Send();

        // 🪤 SELECT IT, DO NOT RE-OPEN THE COLUMN. Un-folding here would undo
        // the thing the operator just asked for the moment they used it - and
        // the column does not need to be visible to work: the rows are bound
        // either way, so selecting one runs the usual handler and puts the
        // conversation in the pane.
        //
        // 🪤 AND IT SELECTS THE ROW RATHER THAN REBUILDING THE COLUMN TO REACH
        // IT. The shipped handler used to call Build-Sessions purely so the
        // rebind would restore the selection - a correct route, audited at
        // 164 ms with 114 of it inside that one call.
        _w.StripList.PreviewMouseLeftButtonUp += (_, e) =>
        {
            if (StripClicked(e.OriginalSource as DependencyObject) is not { } id)
            {
                return;
            }

            var row = _vm.Rows.FirstOrDefault(r => string.Equals(r.Id, id, StringComparison.OrdinalIgnoreCase));
            if (row is not null)
            {
                _w.SessionList.SelectedItem = row;
            }

            UpdateStrip();
        };

        // 🪤 PreviewMouseLeftButtonDown, NOT a click and NOT SelectionChanged.
        // A ListBoxItem marks button-down HANDLED when it selects - the same trap
        // that stopped the session manager ticking anything at all - and
        // selecting a heading is meaningless, so SelectionChanged has already
        // stepped past it by the time it runs.
        _w.SessionList.PreviewMouseLeftButtonDown += (_, e) =>
        {
            if (BandClicked(e.OriginalSource as DependencyObject) is not { } band)
            {
                return;
            }

            var picked = _vm.PickBand(band);
            Status(
                picked is null
                    ? "showing every conversation again"
                    : string.Format(
                        CultureInfo.InvariantCulture,
                        "showing only {0} - click the heading again for all of them",
                        picked.ToLowerInvariant()),
                Tone.Info);
            e.Handled = true;
        };

        // 🔑 SO THE HEADINGS CAN SEE THE PICK. A group header's DataContext is
        // its own CollectionViewGroup; the column's is what the two converters
        // reach through to find which band is pressed.
        _w.SessionList.DataContext = _vm;
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

    // --------------------------------------------------------------- selection

    /// <summary>
    /// Opens a row in the reading pane: its header, and its sub-agents under it.
    /// </summary>
    /// <remarks>
    /// 🔴 THE HEADER AND THE AGENT ROWS ONLY. Everything the shipped handler
    /// does after this point reads files and spawns a process - the document, the
    /// vitals strip, the pending question, the console probe - and none of it
    /// exists yet. What is here is the half that is a few string assignments and
    /// is always safe to redo.
    ///
    /// 🪤 SELECTING A SUB-AGENT KEEPS ITS PARENT EXPANDED. Passing the agent's
    /// own id as the parent would take the agent rows away on the next pass -
    /// including the one that was just selected - and the list would fight the
    /// click.
    /// </remarks>
    public void Select(object? item)
    {
        switch (item)
        {
            case AgentRowVm agent:
                _vm.SelectedId = agent.Id;
                ShowAgents(agent.Parent, agent.Agent.Id);
                Head(PaneHeader.OfAgent(agent.Agent, agent.Parent.Title));
                break;

            case ConversationVm row:
                _vm.SelectedId = row.Id;
                ShowAgents(row);
                Head(PaneHeader.OfSession(row.Title, row.Band, row.Detail, row.ProjectLabel, row.Busy));
                break;

            default:
                break;
        }
    }

    /// <summary>
    /// The agent rows under one conversation: what is actually running, plus the
    /// one being read.
    /// </summary>
    /// <remarks>
    /// 🔴 ONLY WHAT IS ACTUALLY RUNNING, and the port got this wrong first. It
    /// listed every sub-agent the conversation had EVER spawned - 24 of them on
    /// the first conversation rendered, all finished - which is the exact
    /// complaint the shipped window carries a note about: the operator reported
    /// seeing sub-agent sessions with none deployed, twice. The column answers
    /// "what is happening now", and a row for an agent that finished last week
    /// is not an answer to that. Found by LOOKING at the render; every check was
    /// green.
    ///
    /// 🪤 THE ONE BEING READ STAYS, even once it goes quiet. An agent has
    /// usually just stopped writing by the time you open it, and filtering
    /// before that check would delete the row under the cursor on the next pass.
    ///
    /// 🔴 READ-ONLY, AND A DIRECTORY LISTING RATHER THAN A PARSE. Listing a
    /// conversation's agents stats a handful of small meta files beside the
    /// transcript; nothing here opens the conversation itself. That is what makes
    /// it affordable on a click.
    /// </remarks>
    /// <param name="keepId">The sub-agent being read, which is shown whether or not it is still going.</param>
    private void ShowAgents(ConversationVm row, string? keepId = null)
    {
        var all = SubAgents.List(row.Session.Jsonl);
        var now = DateTimeOffset.Now;

        // 🪤 ONE DEFINITION OF LIVE, DECIDED HERE AND HANDED DOWN. The row's tag
        // and the amber count on the parent both mean "still writing"; asking the
        // agent twice, a moment apart, is how the two come to disagree.
        var liveIds = all.Where(a => a.IsLive(now)).Select(a => a.Id).ToHashSet(StringComparer.Ordinal);
        var show = all.Where(a => liveIds.Contains(a.Id)).ToList();
        if (!string.IsNullOrEmpty(keepId) && !liveIds.Contains(keepId))
        {
            var picked = all.Find(a => string.Equals(a.Id, keepId, StringComparison.Ordinal));
            if (picked is not null)
            {
                show.Add(picked);
            }
        }

        _vm.SetAgents(row.Id, show, liveIds);
    }

    // ----------------------------------------------------------------- acting

    /// <summary>The conversation the pane is holding, or null - an agent is not one.</summary>
    private ConversationVm? Selected() =>
        _w.SessionList.SelectedItem switch
        {
            ConversationVm row => row,
            AgentRowVm agent => agent.Parent,
            _ => null,
        };

    /// <summary>
    /// 🔑 STOPPING A TURN IS NOT CONFIRMED, and that is deliberate rather than
    /// an omission. It is the recoverable half of the pair beside it - the
    /// session stays open, the transcript keeps everything written so far, and
    /// pressing it by mistake costs the rest of one turn. A sheet in front of a
    /// gesture whose whole point is "stop, now" would be asking the operator to
    /// watch it keep going while they read.
    /// </summary>
    private void Stop()
    {
        var row = Selected();
        var why = Interrupt.Blocker(row is not null, Agent(row));
        if (why.Length > 0)
        {
            Status(why, Tone.Warn);
            return;
        }

        var r = _acts.Carry(new ActRequest(Act.Interrupt, row!.Id, row.Title, "esc"));
        Status(r.Done ? "interrupting..." : r.Said, r.Done ? Tone.Info : Tone.Bad);
    }

    /// <summary>
    /// 🔑 NOT CONFIRMED EITHER: compacting summarises and carries on, so a stray
    /// press costs a summary rather than any work. The status line says what was
    /// sent, which is the trace that matters if one was not meant.
    ///
    /// 🪤 IT IS TEXT, NOT A MENU KEY. A slash command goes the same way as
    /// anything typed; pretending otherwise is how a keystroke lands in whatever
    /// happens to be highlighted.
    /// </summary>
    private void Compact()
    {
        var row = Selected();
        if (row is null)
        {
            Status("pick a conversation first", Tone.Bad);
            return;
        }

        if (Agent(row) is null)
        {
            Status("that conversation is not running, so there is nothing to compact", Tone.Bad);
            return;
        }

        Status("compacting...", Tone.Info);
        var r = _acts.Carry(new ActRequest(Act.Send, row.Id, row.Title, "/compact"));
        Status(r.Done ? "sent /compact" : r.Said, r.Done ? Tone.Ok : Tone.Bad);
    }

    private void GoTo()
    {
        var row = Selected();
        if (row is null)
        {
            Status("select a conversation first", Tone.Warn);
            return;
        }

        if (Agent(row) is null)
        {
            Status("that conversation is not running - there is no terminal to go to", Tone.Warn);
            return;
        }

        Status("finding its tab...", Tone.Info);
        var r = _acts.Carry(new ActRequest(Act.GoTo, row.Id, row.Title, string.Empty));
        Status(
            r.Done ? string.Format(CultureInfo.InvariantCulture, "went to {0}", _w.PaneName.Text) : r.Said,
            r.Done ? Tone.Ok : Tone.Warn);
    }

    /// <summary>
    /// 🔴 THE SHEET COMES FIRST, ALWAYS. A relaunch loses the turn AND the
    /// process, so the act is never requested unless a confirmation was asked
    /// for and answered - which is a thing a check can assert, and does.
    ///
    /// 🔑 A CONVERSATION THAT IS NOT RUNNING IS BEING OPENED, NOT RELAUNCHED,
    /// and the sheet and the button both say so.
    /// </summary>
    private void RelaunchSelected()
    {
        var row = Selected();
        if (row is null)
        {
            Status("select a conversation first", Tone.Warn);
            return;
        }

        var agent = Agent(row);
        var why = Relaunch.Refusal(agent, row.Title);
        if (why.Length > 0)
        {
            Status(why, Tone.Warn);
            return;
        }

        var ask = Relaunch.PaneAsk(agent, row.Title);
        if (!_confirms.Ask(ask))
        {
            Status("nothing relaunched", Tone.Info);
            return;
        }

        var what = agent is null ? Act.Open : Act.Relaunch;
        var r = _acts.Carry(new ActRequest(what, row.Id, row.Title, ask.Verb));
        if (!r.Done)
        {
            Status(r.Said, Tone.Bad);
        }
    }

    private void Send()
    {
        var row = Selected();

        // 🔴 THE MENU TEST IS NOT WIRED YET, AND IT IS THE ONE REFUSAL THAT
        // MATTERS MOST. A session sitting on a question reads keystrokes as MENU
        // INPUT, so text typed here would PICK AN OPTION rather than queue behind
        // one - and what knows a conversation is on a menu is the screen probe,
        // which the background pass has not ported. Passing false is honest while
        // nothing can act; it must be wired before anything can.
        var state = Typing.Of(row is not null, Agent(row), onAMenu: false, row?.Queued ?? 0);
        if (!state.CanType)
        {
            Status(state.Blocker, Tone.Warn);
            return;
        }

        var text = _w.SendBox.Text.Trim();
        if (text.Length == 0)
        {
            return;
        }

        Status("typing it in...", Tone.Info);
        var r = _acts.Carry(new ActRequest(Act.Send, row!.Id, row.Title, text));
        if (!r.Done)
        {
            Status(r.Said, Tone.Bad);
        }
    }

    /// <summary>
    /// The band heading under a click, or null when the click was not on one.
    /// </summary>
    /// <remarks>
    /// 🪤 IT WALKS UP LOOKING FOR A DATA CONTEXT, NOT FOR A CONTROL TYPE. The
    /// heading is a Border inside a GroupItem inside the panel, and which of
    /// those the mouse reports depends on where in the heading it landed - on
    /// the accent bar, on the label, or on the padding between them. What every
    /// one of them shares is the CollectionViewGroup behind it.
    /// </remarks>
    private static string? BandClicked(DependencyObject? from)
    {
        for (var d = from; d is not null; d = VisualTreeHelper.GetParent(d))
        {
            // A row reached first means the click was on a conversation, not on
            // a heading - stop, rather than walking past it to the group above.
            if (d is ListBoxItem)
            {
                return null;
            }

            if (d is FrameworkElement { DataContext: CollectionViewGroup g })
            {
                return g.Name as string;
            }
        }

        return null;
    }

    /// <summary>What is holding a conversation, or null when nothing is.</summary>
    /// <remarks>
    /// 🪤 A ROW KNOWS IT IS LIVE; IT DOES NOT KEEP THE PROBE'S ANSWER. Until the
    /// background pass is ported there is nothing here to hand the decisions, so
    /// this is the one place that says so - and every acting decision reads it,
    /// rather than each inventing its own idea of "running".
    /// </remarks>
    private static AgentStatus? Agent(ConversationVm? row) => row?.Agent;

    private void Head(PaneHead h)
    {
        _w.PaneName.Text = h.Name;
        _w.PaneState.Text = h.State;
        _w.PaneStateDot.Background = _w.TryFindResource(PaneAccent(h.Accent)) as Brush;
        Pulse(h.Pulse);
    }

    /// <summary>The window resource for a header accent.</summary>
    /// <remarks>
    /// 🪤 AN UNKNOWN BAND IS <c>AccIdle</c>, WHICH IS NOT THE QUIET ACCENT - the
    /// shipped line falls back to AccIdle when the band table has no row, and
    /// "quiet" IS a row in it. Two different answers; the oracle has a spec for
    /// each.
    /// </remarks>
    public static string PaneAccent(string accent) => accent switch
    {
        PaneHeader.Ask => "HueAsk",
        Bands.Needs => "AccNeeds",
        Bands.Open => "AccOpen",
        Bands.Working => "AccWorking",
        Bands.Done => "AccDone",
        Bands.Idle => "AccIdle",
        Bands.Quiet => "AccQuiet",
        _ => "AccIdle",
    };

    /// <summary>
    /// 🔑 A DOT THAT BREATHES WHILE IT IS ACTUALLY THINKING, and stops dead
    /// otherwise. A permanent animation would be decoration, and this window has
    /// none.
    /// </summary>
    private void Pulse(bool on)
    {
        if (on)
        {
            var a = new DoubleAnimation(1.0, 0.35, new Duration(TimeSpan.FromSeconds(0.9)))
            {
                AutoReverse = true,
                RepeatBehavior = RepeatBehavior.Forever,
            };
            _w.PaneStateDot.BeginAnimation(UIElement.OpacityProperty, a);
            return;
        }

        // 🪤 CLEARED, NOT SET TO 1. An animation left running holds the property
        // hostage: a later assignment is ignored and the dot keeps breathing on a
        // conversation that has stopped.
        _w.PaneStateDot.BeginAnimation(UIElement.OpacityProperty, null);
        _w.PaneStateDot.Opacity = 1.0;
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

    /// <summary>The id of the strip mark under a click, walking up from whatever was hit.</summary>
    /// <remarks>
    /// 🪤 THE ORIGINAL SOURCE IS THE SHAPE, NOT THE ITEM. A mark is a Border
    /// inside a container, so the click lands several levels below the thing
    /// that carries the row - walking up is what finds it.
    /// </remarks>
    public static string? StripClicked(DependencyObject? from)
    {
        while (from is not null)
        {
            if (from is FrameworkElement { DataContext: StripItem s })
            {
                return s.Id;
            }

            from = System.Windows.Media.VisualTreeHelper.GetParent(from);
        }

        return null;
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

    /// <summary>How loudly the status line says it. <c>Set-Status</c>'s four kinds.</summary>
    public enum Tone
    {
        Info,
        Ok,
        Warn,
        Bad,
    }

    private void Status(string text, Tone tone = Tone.Info)
    {
        _w.Status.Text = text;
        _w.Status.Foreground = _w.TryFindResource(tone switch
        {
            Tone.Bad => "AccNeeds",
            Tone.Ok => "AccDone",
            Tone.Warn => "TextHigh",
            _ => "TextMid",
        }) as Brush;
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
