using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.ComponentModel;
using System.Windows.Threading;
using SessionRestore.App.ViewModels;
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
        IReadOnlyList<Gesture> Gestures, int Rows, bool RealFrames, string Note);

    public static BenchRun Run(int repeats = 20)
    {
        var model = Model();
        var vm = new SessionsVm();
        vm.Sync(model);

        var list = new ListBox
        {
            ItemsSource = vm.View,
            DisplayMemberPath = nameof(ConversationVm.Title),
            IsHitTestVisible = false,
        };

        // 🔴 GROUPING TURNS WPF VIRTUALIZATION OFF UNLESS THIS IS SET, and that
        // is not a tuning knob - it is the difference between realising ~30
        // containers and realising all 428. Adding the band grouping without it
        // took `clear the search` from 13 ms to 87. It is opt-in for backwards
        // compatibility, and it is the single least discoverable line in the
        // whole view layer.
        VirtualizingPanel.SetIsVirtualizingWhenGrouping(list, true);
        var window = new Window
        {
            Content = list,
            Width = 460,
            Height = 940,
            WindowStartupLocation = WindowStartupLocation.Manual,
            Left = -32000,
            Top = -32000,
            ShowInTaskbar = false,
            ShowActivated = false,
        };

        window.Show();
        try
        {
            Drain(window);

            // 🔴 A GATE THAT CANNOT TELL MUST NOT PRINT GREEN. With no
            // PresentationSource this is the headless path, and every number
            // below is meaningless rather than merely optimistic - so the run
            // says so, and the caller fails on it.
            var real = PresentationSource.FromVisual(window) is not null;

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

            return new BenchRun(
                gestures,
                vm.Rows.Count,
                real,
                real
                    ? "the window is shown and has a real PresentationSource - these are render numbers"
                    : "the window has NO PresentationSource, so this is the headless path - every number above is suspect");
        }
        finally
        {
            window.Close();
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

    /// <summary>The bench's own report, so a run says what it measured.</summary>
    public static string Report(BenchRun run)
    {
        ArgumentNullException.ThrowIfNull(run);
        var sb = new System.Text.StringBuilder();
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"  plan item 3.2 - a gesture with a real frame on the end. 60 fps is {FrameMs} ms.");
        sb.AppendLine(CultureInfo.InvariantCulture, $"  {run.Rows} conversation(s) bound.");
        sb.AppendLine(CultureInfo.InvariantCulture, $"  {run.Note}");
        sb.AppendLine(
            "  it does NOT ask `claude agents`, so every row is non-live here - "
            + "which is why only-live filters to nothing.");
        sb.AppendLine();
        sb.AppendLine(CultureInfo.InvariantCulture,
            $"  {"gesture",-24}{"median",9}{"min",9}{"worst",9}{"drawn",8}");
        foreach (var g in run.Gestures)
        {
            sb.AppendLine(CultureInfo.InvariantCulture,
                $"  {g.Name,-24}{g.Median,9:F2}{g.Min,9:F2}{g.Worst,9:F2}{g.Drawn,8}   {(g.Inside ? "ok" : "OVER")}");
        }

        return sb.ToString();
    }
}
