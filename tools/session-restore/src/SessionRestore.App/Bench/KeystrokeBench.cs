using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.ComponentModel;
using System.Windows.Threading;
using SessionRestore.App.ViewModels;
using SessionRestore.App.Views;
using SessionRestore.Core.Registry;

namespace SessionRestore.App.Bench;

/// <summary>
/// Plan item 3.2 - does a keystroke land under 16 ms with a real frame?
/// </summary>
/// <remarks>
/// 🔴 THIS IS THE ITEM THE WHOLE REBUILD IS JUSTIFIED BY, so it is measured with
/// the technique <c>tests/render-driver.ps1</c> already uses on this machine
/// rather than a new one:
///
/// 🔑 **THE WINDOW IS SHOWN, OFF THE DESKTOP AT -32000, UNFOCUSABLE AND NOT
/// HIT-TESTABLE.** Showing it is what gives it a PresentationSource, and without
/// one WPF composes no frames at all - which is asserted below, because a bench
/// that has quietly gone headless reports beautiful numbers.
///
/// 🔑 **DRAINING TO ContextIdle IS WHAT MAKES THIS A RENDER NUMBER.** The
/// dispatcher processes Render and Loaded ABOVE ContextIdle, so a call that
/// returns from a ContextIdle invoke has been behind the layout and the draw for
/// that frame. A Background drain returns before the frame is composed and gives
/// a headless number with extra steps.
///
/// 🪤 THE FIRST VERSION OF THIS WAITED ON <c>CompositionTarget.Rendering</c> with
/// the window NEVER SHOWN - so nothing ever composed, all 180 samples hit their
/// two-second guard, and the run took over ten minutes to produce no measurement
/// at all. A bench that reports its own timeout as a reading is worse than no
/// bench.
///
/// 🔴 IT IS READ-ONLY AGAINST LIVE DATA: the registry, and nothing else. No
/// transcripts, no console, no <c>claude agents</c>, no writer reachable from
/// here, and the window cannot be typed into.
/// </remarks>
public static class KeystrokeBench
{
    /// <summary>60 fps. The number the whole plan is written against.</summary>
    public const double FrameMs = 16.7;

    public sealed record Gesture(string Name, double Median, double Min, double Worst, int Drawn)
    {
        public bool Inside => Median <= FrameMs;
    }

    public sealed record BenchRun(
        IReadOnlyList<Gesture> Gestures, int Rows, bool RealFrames, string Note, string Host,
        bool Animating = false)
    {
        /// <summary>WPF binding failures seen while this host drew its rows.</summary>
        public IReadOnlyList<string> BindingErrors { get; init; } = [];

        /// <summary>
        /// What the SAME apparatus costs over code this rebuild cannot have
        /// changed.
        /// </summary>
        /// <remarks>
        /// 🔴 A RED BENCHMARK IS THE MACHINE THREE TIMES OUT OF FOUR, and this
        /// repo has the scar: every absolute figure carried into Phase 4 was
        /// taken at 35-99% CPU with about thirty live conversations, one
        /// worst-case reading 684 ms, and none of them could be believed
        /// afterwards. A number with no control beside it cannot be compared to
        /// a number taken on another day, which is the only thing a benchmark
        /// is for.
        ///
        /// 🔑 TWO CONTROLS, BECAUSE THERE ARE TWO WAYS TO BE SLOW. The spin is
        /// pure arithmetic - it moves when the CPU is contended and for no other
        /// reason. The idle frame is a dispatcher round-trip with NOTHING
        /// changed: WPF's own floor on this machine, through the very drain
        /// every gesture below is measured with. A gesture that grew while both
        /// held still is the diff; one that grew in step with them is the
        /// afternoon.
        /// </remarks>
        public Control Floor { get; init; } = new(0, 0);
    }

    /// <param name="SpinMs">A fixed arithmetic loop. Pure CPU contention.</param>
    /// <param name="IdleFrameMs">A drain to ContextIdle with nothing changed.</param>
    public sealed record Control(double SpinMs, double IdleFrameMs);

    /// <summary>
    /// Collects every data-binding failure WPF reports while it is attached.
    /// </summary>
    /// <remarks>
    /// 🔴 A BINDING TO A PROPERTY THAT IS NOT THERE FAILS SILENTLY - a line in a
    /// trace nobody reads, and the target keeps its default. For a Visibility
    /// that default is VISIBLE, so a misspelt `AgentVis` would draw the amber
    /// sub-agent dot on every row and nothing would say why. The port of the
    /// row template is exactly where that happens, so the bench counts them.
    /// </remarks>
    internal sealed class BindingErrorTrap : System.Diagnostics.TraceListener
    {
        public List<string> Seen { get; } = [];

        public override void Write(string? message) { }

        public override void WriteLine(string? message)
        {
            if (message is not null && Seen.Count < 20)
            {
                Seen.Add(message);
            }
        }
    }

    /// <summary>
    /// 🔑 THE REAL WINDOW, AND THE PLACEHOLDER BESIDE IT IN THE SAME RUN.
    /// </summary>
    /// <remarks>
    /// Plan item 4.1 is what 3.5's two carried measurements waited for: the
    /// placeholder had no row template and no GroupStyle, so it could not say
    /// what the real column costs. Both run here, one after the other, because
    /// every speed claim in this repo made against a number from a DIFFERENT run
    /// has since been withdrawn.
    /// </remarks>
    /// <summary>
    /// The placeholder, the ported window, and the ported window WITH THE PULSE
    /// RUNNING - plan item 4.5's done-when.
    /// </summary>
    /// <remarks>
    /// 🔑 THE THIRD RUN IS THE POINT OF THE OTHER TWO. A figure taken on a still
    /// window says what a gesture costs when nothing is happening, which is not
    /// when the operator makes them: the dot breathes on every conversation that
    /// is mid-turn, and mid-turn is exactly when he is looking.
    /// </remarks>
    public static IReadOnlyList<BenchRun> RunBoth(int repeats = 20) =>
    [
        Run(repeats, realWindow: false),
        Run(repeats, realWindow: true),
        Run(repeats, realWindow: true, animating: true),
    ];

    public static BenchRun Run(int repeats = 20, bool realWindow = true, bool animating = false)
    {
        var model = Model();
        var vm = new SessionsVm();
        vm.Sync(model);

        Window window;
        if (realWindow)
        {
            // The ported window, with its own SessionList, row template and band
            // header. No data context, no handler - only the column is bound.
            var w = new SessionsWindow();
            w.SessionList.ItemsSource = vm.View;
            w.SessionList.IsHitTestVisible = false;
            window = w;
        }
        else
        {
            var list = new ListBox
            {
                ItemsSource = vm.View,
                DisplayMemberPath = nameof(ConversationVm.Title),
                IsHitTestVisible = false,
            };

            // 🔴 GROUPING TURNS WPF VIRTUALIZATION OFF UNLESS THIS IS SET, and
            // that is not a tuning knob - it is the difference between realising
            // ~30 containers and realising all 428. Adding the band grouping
            // without it took `clear the search` from 13 ms to 87.
            VirtualizingPanel.SetIsVirtualizingWhenGrouping(list, true);
            window = new Window { Content = list, Width = 460, Height = 940 };
        }

        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -32000;
        window.Top = -32000;
        window.ShowInTaskbar = false;
        window.ShowActivated = false;

        var trap = new BindingErrorTrap();
        PresentationTraceSources.Refresh();
        PresentationTraceSources.DataBindingSource.Switch.Level = SourceLevels.Error;
        PresentationTraceSources.DataBindingSource.Listeners.Add(trap);

        window.Show();
        try
        {
            Drain(window);

            // 🔴 A GATE THAT CANNOT TELL MUST NOT PRINT GREEN. With no
            // PresentationSource this is the headless path, and every number
            // below is meaningless rather than merely optimistic - so the run
            // says so, and the caller fails on it.
            var real = PresentationSource.FromVisual(window) is not null;

            // 🔴 PLAN ITEM 4.5'S DONE-WHEN: no gesture exceeds a frame while an
            // animation is RUNNING. A pulse is a composition-thread animation
            // and is supposed to cost the UI thread nothing - "supposed to" is
            // not a measurement, and this window's one animation repeats for
            // ever on every mid-turn conversation, so it is running during most
            // of the gestures the operator makes.
            //
            // 🪤 ON THE WINDOW ITSELF, NOT ON A ROW. A row's container is
            // recycled by the virtualizing panel, so an animation started on one
            // is thrown away the moment it scrolls - which would measure nothing
            // and look like a pass.
            if (animating)
            {
                window.BeginAnimation(UIElement.OpacityProperty, Views.WindowShell.Breath());
            }

            // 🔑 BEFORE THE GESTURES AND AFTER THEM, and the WORSE of the two
            // is reported. A control taken only at the start describes a machine
            // that was quiet for one moment; the pair says whether it stayed
            // that way for the run the figures came out of.
            var floorBefore = Floor(window);

            var projects = Projects(model);
            var gestures = new List<Gesture>
            {
                Measure(window, "search keystroke", repeats,
                    before: _ => vm.Search = string.Empty,
                    gesture: i => vm.Search = Needle(i), view: vm.View),

                // 🔴 THE PRECONDITION IS SET UNTIMED. The first version put
                // `Search = "algo"` INSIDE the timed region, so "clear the
                // search" was two gestures and a drain and reported 30 ms for
                // one of them. A bench that times its own setup is measuring
                // itself.
                Measure(window, "clear the search", repeats,
                    before: _ => vm.Search = "algo",
                    gesture: _ => vm.Search = string.Empty, view: vm.View),

                Measure(window, "pick a project", repeats,
                    before: _ => vm.Project = string.Empty,
                    gesture: i => vm.Project = projects.Count == 0 ? string.Empty : projects[i % projects.Count], view: vm.View),

                Measure(window, "clear the project", repeats,
                    before: _ => vm.Project = projects.Count == 0 ? string.Empty : projects[0],
                    gesture: _ => vm.Project = string.Empty, view: vm.View),

                Measure(window, "cycle the sort", repeats,
                    before: null,
                    gesture: i => vm.Sort = (SessionSort)(i % 3), view: vm.View),

                Measure(window, "only-live on and off", repeats,
                    before: null,
                    gesture: i => vm.OnlyLive = i % 2 == 0, view: vm.View),
            };

            var floorAfter = Floor(window);
            var floor = new Control(
                Math.Max(floorBefore.SpinMs, floorAfter.SpinMs),
                Math.Max(floorBefore.IdleFrameMs, floorAfter.IdleFrameMs));

            return new BenchRun(
                gestures,
                vm.Items.Count,
                real,
                real
                    ? "the window is shown and has a real PresentationSource - these are render numbers"
                    : "the window has NO PresentationSource, so this is the headless path - every number above is suspect",
                realWindow
                    ? "the PORTED window: its SessionList, row template and band header"
                    : "a placeholder ListBox: titles only, no GroupStyle",
                animating)
            {
                BindingErrors = trap.Seen.ToList(),
                Floor = floor,
            };
        }
        finally
        {
            // 🪤 CLEARED BEFORE THE WINDOW CLOSES. An animation left running on
            // a window holds it, and a bench that leaked one would keep the
            // process alive after its report was written.
            window.BeginAnimation(UIElement.OpacityProperty, null);
            window.Close();
            PresentationTraceSources.DataBindingSource.Listeners.Remove(trap);
        }
    }

    /// <summary>Every conversation on the surface, read from the registry.</summary>
    public static List<(string Id, RegistrySession S, RegistryDirectory D)> Model()
    {
        var reg = SessionRegistry.Read();
        var model = new List<(string, RegistrySession, RegistryDirectory)>();
        foreach (var d in reg.Directories)
        {
            if (d.Missing)
            {
                continue;
            }

            foreach (var s in d.Sessions)
            {
                if (!s.Gone)
                {
                    model.Add((s.SessionId.ToLowerInvariant(), s, d));
                }
            }
        }

        return model;
    }

    /// <summary>
    /// 🪤 A REAL TYPING SEQUENCE, not one repeated string. A filter that narrows
    /// to nothing is the cheap case; the expensive one is a single character that
    /// keeps most of the list - which is also the first thing anybody types.
    /// </summary>
    private static string Needle(int i) => (i % 6) switch
    {
        0 => "a",
        1 => "al",
        2 => "alg",
        3 => "algo",
        4 => "s",
        _ => "se",
    };

    /// <summary>
    /// 🪤 DISTINCT PROJECTS, NOT model[i].D.Path. Consecutive conversations
    /// usually share a directory, so indexing the model handed the same path
    /// twice running - the setter saw no change, did nothing, and the bench
    /// reported **0,01 ms** for a gesture that never happened. A no-op is not a
    /// fast gesture.
    /// </summary>
    private static List<string> Projects(
        IReadOnlyList<(string Id, RegistrySession S, RegistryDirectory D)> model)
    {
        var seen = new List<string>();
        foreach (var m in model)
        {
            if (!seen.Contains(m.D.Path, StringComparer.OrdinalIgnoreCase))
            {
                seen.Add(m.D.Path);
            }
        }

        return seen;
    }

    /// <summary>
    /// 🔴 EVERY GESTURE REPORTS HOW MANY ROWS IT LEFT ON SCREEN, because a
    /// filter that narrows to NOTHING is the cheap case and would otherwise read
    /// as a fast one. `drawn` next to the milliseconds is what tells a reader
    /// whether the number is about work or about the absence of it.
    /// </summary>
    private static Gesture Measure(
        Window w, string name, int repeats, Action<int>? before, Action<int> gesture, ICollectionView view)
    {
        // One untimed pass: the first of anything pays for a template, a
        // container pool and a JIT, none of which the operator pays twice.
        before?.Invoke(0);
        Drain(w);
        gesture(0);
        Drain(w);

        var taken = new List<double>(repeats);
        for (var i = 1; i <= repeats; i++)
        {
            // 🔴 THE PRECONDITION IS OUTSIDE THE CLOCK, and drained, so what
            // is timed is one gesture from a settled window - which is what the
            // operator actually does.
            if (before is not null)
            {
                before(i);
                Drain(w);
            }

            var sw = Stopwatch.StartNew();
            gesture(i);
            Drain(w);
            sw.Stop();
            taken.Add(sw.Elapsed.TotalMilliseconds);
        }

        taken.Sort();
        return new Gesture(name, taken[taken.Count / 2], taken[0], taken[^1], view.Cast<object>().Count());
    }

    private static void Drain(Window w) =>
        w.Dispatcher.Invoke(static () => { }, DispatcherPriority.ContextIdle);

    /// <summary>
    /// What this machine costs, right now, for work the rebuild cannot have
    /// touched.
    /// </summary>
    /// <remarks>
    /// 🪤 THE SPIN HAS TO BE UNOPTIMISABLE. A loop whose result is discarded is
    /// a loop the JIT is entitled to delete, and a control that has been
    /// compiled away reads as a machine that got infinitely fast - which would
    /// make every gesture beside it look correspondingly worse and be blamed on
    /// the diff. The sum is returned, and the caller keeps it.
    ///
    /// 🔑 BOTH ARE MEDIANS OVER NINE. One reading of a contended machine is a
    /// coin toss; the median of nine is what the gestures themselves are
    /// reported as, so the two are comparable.
    /// </remarks>
    private static Control Floor(Window w)
    {
        const int Rounds = 9;

        // One untimed pass, for the JIT, exactly as a gesture gets.
        _ = Spin();
        Drain(w);

        var spins = new List<double>(Rounds);
        var frames = new List<double>(Rounds);
        for (var i = 0; i < Rounds; i++)
        {
            var sw = Stopwatch.StartNew();
            Kept += Spin();
            sw.Stop();
            spins.Add(sw.Elapsed.TotalMilliseconds);

            sw.Restart();
            Drain(w);
            sw.Stop();
            frames.Add(sw.Elapsed.TotalMilliseconds);
        }

        spins.Sort();
        frames.Sort();
        return new Control(spins[Rounds / 2], frames[Rounds / 2]);
    }

    /// <summary>Where the spin's answer goes, so nothing may delete the spin.</summary>
    private static double Kept { get; set; }

    private static double Spin()
    {
        var acc = 0.0;
        for (var i = 1; i <= 4_000_000; i++)
        {
            acc += 1.0 / i;
        }

        return acc;
    }

    /// <summary>The bench's own report, so a run says what it measured.</summary>
    public static string Report(BenchRun run)
    {
        ArgumentNullException.ThrowIfNull(run);
        var sb = new System.Text.StringBuilder();
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"  plan item 3.2 - a gesture with a real frame on the end. 60 fps is {FrameMs} ms.");
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"  host: {run.Host}{(run.Animating ? "   WITH THE PULSE RUNNING" : string.Empty)}");
        sb.AppendLine(CultureInfo.InvariantCulture, $"  {run.Rows} conversation(s) bound.");
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"  {(run.BindingErrors.Count == 0 ? "ok  " : "FAIL")}  {run.BindingErrors.Count} binding error(s) while drawing");
        foreach (var e in run.BindingErrors.Take(5))
        {
            sb.AppendLine(CultureInfo.InvariantCulture, $"        {e}");
        }
        sb.AppendLine(CultureInfo.InvariantCulture, $"  {run.Note}");
        sb.AppendLine(
            "  it does NOT ask `claude agents`, so every row is non-live here - "
            + "which is why only-live filters to nothing.");
        sb.AppendLine();
        // 🔴 THE CONTROL COMES FIRST, BECAUSE IT DECIDES WHETHER THE REST MEANS
        // ANYTHING. Every figure carried out of Phase 3 was taken on a machine
        // at 35-99% CPU and none of them could be compared to anything
        // afterwards. These two are the same apparatus over code the rebuild
        // cannot have touched.
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"  control    spin {run.Floor.SpinMs,7:F2} ms      idle frame {run.Floor.IdleFrameMs,7:F2} ms      (worse of before and after)");
        sb.AppendLine(
            "             a gesture that grew while these held still is the code; "
            + "one that grew with them is the machine.");
        sb.AppendLine();
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"  {"gesture",-24}{"median",9}{"min",9}{"worst",9}{"drawn",8}{"x idle",9}");
        foreach (var g in run.Gestures)
        {
            // In units of this machine's own empty frame, so the figure can be
            // set beside one taken on another day or another machine.
            var x = run.Floor.IdleFrameMs > 0.0001
                ? (g.Median / run.Floor.IdleFrameMs).ToString("F1", CultureInfo.InvariantCulture)
                : "-";
            sb.AppendLine(CultureInfo.InvariantCulture,
                $"  {g.Name,-24}{g.Median,9:F2}{g.Min,9:F2}{g.Worst,9:F2}{g.Drawn,8}{x,9}   {(g.Inside ? "ok" : "OVER")}");
        }

        return sb.ToString();
    }
}
