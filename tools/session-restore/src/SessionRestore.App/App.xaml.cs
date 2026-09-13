using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using SessionRestore.App.Bench;

namespace SessionRestore.App;

public partial class App : Application
{
    /// <summary>
    /// 🔴 <c>--bench</c> MEASURES; IT NEVER PUTS A WINDOW ON THE DESKTOP. Plan
    /// item 3.2 has to be measured on this machine, against this registry, while
    /// the operator is working - so the bench window is shown at -32000,
    /// unfocusable, not hit-testable, and closed again. Anything else would put a
    /// second Sessions window over his conversations.
    /// </summary>
    protected override void OnStartup(StartupEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);

        // Plan item 4.1: build the ported window with no data and report whether
        // every named control is there. The same off-screen showing as the bench.
        if (Array.Exists(e.Args, a => string.Equals(a, "--surface", StringComparison.OrdinalIgnoreCase)))
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            Dispatcher.BeginInvoke(new Action(RunSurface), DispatcherPriority.ApplicationIdle);
            return;
        }

        // Render the ported sessions column, bound to the registry read-only, to
        // a PNG - so a port can be LOOKED AT rather than inferred from a green.
        var renderAt = Array.FindIndex(e.Args, a => string.Equals(a, "--render", StringComparison.OrdinalIgnoreCase));
        if (renderAt >= 0 && renderAt + 1 < e.Args.Length)
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            var png = e.Args[renderAt + 1];
            Dispatcher.BeginInvoke(new Action(() => RunRender(png)), DispatcherPriority.ApplicationIdle);
            return;
        }

        var wanted = Array.Exists(e.Args, a =>
            string.Equals(a, "--bench", StringComparison.OrdinalIgnoreCase));
        if (!wanted)
        {
            base.OnStartup(e);
            return;
        }

        // 🪤 NO StartupUri, so no MainWindow is created - and ShutdownMode has to
        // be explicit, because the bench window closing would otherwise be the
        // last window and end the process before the report was written.
        ShutdownMode = ShutdownMode.OnExplicitShutdown;

        var repeats = 20;
        var at = Array.FindIndex(e.Args, a =>
            string.Equals(a, "--repeats", StringComparison.OrdinalIgnoreCase));
        if (at >= 0 && at + 1 < e.Args.Length
            && int.TryParse(e.Args[at + 1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var n)
            && n > 0)
        {
            repeats = n;
        }

        // 🪤 THE BENCH CANNOT RUN INSIDE OnStartup. Application.Run has not
        // entered its message loop yet, so a Window.Show() here composes no
        // frames and the first ContextIdle drain never returns - measured twice,
        // both times as a process that sat there until it was killed. Queue it
        // and let the loop start first.
        Dispatcher.BeginInvoke(new Action(() => RunBench(repeats)), DispatcherPriority.ApplicationIdle);
    }

    private void RunRender(string png)
    {
        var code = 0;
        try
        {
            Bench.Snapshot.SessionColumn(png);
        }
#pragma warning disable CA1031 // a render must report a failure, not vanish with it
        catch (Exception ex)
#pragma warning restore CA1031
        {
            code = 1;
            try
            {
                File.WriteAllText(png + ".error.txt", ex.ToString());
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        Shutdown(code);
    }

    private void RunSurface()
    {
        int failures;
        string report;
        try
        {
            var r = SurfaceCheck.Run();
            report = SurfaceCheck.Report(r);
            failures = r.Failures;
        }
#pragma warning disable CA1031 // the check must report a failure, not vanish with it
        catch (Exception ex)
#pragma warning restore CA1031
        {
            report = "the surface check threw: " + ex.GetType().Name + ": " + ex.Message
                     + Environment.NewLine + ex.StackTrace;
            failures = 1000;
        }

        try
        {
            File.WriteAllText(Path.Combine(Path.GetTempPath(), "sr-surface-check.txt"), report);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }

        Shutdown(failures);
    }

    private void RunBench(int repeats)
    {
        var over = 0;
        string report;
        try
        {
            // 🔴 THE STRUCTURAL CLAIM IS CHECKED BEFORE THE NUMBERS ARE READ.
            // "12 ms" is consistent with a fast rebuild as well as with no
            // rebuild, and only one of those still holds at twice the
            // conversations - or keeps the selection.
            var checks = BindingChecks.Run(KeystrokeBench.Model());
            var runs = KeystrokeBench.RunBoth(repeats);
            var run = runs[^1];
            report = BindingChecks.Report(checks);
            foreach (var each in runs)
            {
                report += Environment.NewLine + KeystrokeBench.Report(each);
            }

            // 🔴 A BINDING ERROR FAILS THE RUN. See BindingErrorTrap.
            foreach (var each in runs)
            {
                over += each.BindingErrors.Count * 10;
            }

            foreach (var c in checks)
            {
                if (!c.Passed)
                {
                    over += 10;
                }
            }

            // 🔴 THE EXIT CODE IS THE GATE. 3.2 is not "we measured something",
            // it is "a keystroke lands inside a frame" - so the run FAILS when it
            // does not, and a build script can depend on that without reading
            // prose.
            foreach (var g in run.Gestures)
            {
                if (!g.Inside)
                {
                    over++;
                }
            }

            // 🔴 AND A RUN THAT WAS NOT MEASURING FRAMES FAILS OUTRIGHT, whatever
            // its numbers said. A headless bench reports beautiful figures about
            // nothing, and a gate that cannot tell must not pass.
            if (!run.RealFrames)
            {
                over += 100;
            }
        }
#pragma warning disable CA1031 // the bench must report a failure, not vanish with it
        catch (Exception ex)
#pragma warning restore CA1031
        {
            report = "the bench threw: " + ex.GetType().Name + ": " + ex.Message
                     + Environment.NewLine + ex.StackTrace;
            over = 200;
        }

        // 🪤 THE FILE IS THE CHANNEL, NOT THE CONSOLE. This is a WinExe, so it
        // has no console of its own - Console.Out goes nowhere when it is
        // launched from a shell, which is how the first run appeared to produce
        // no output at all.
        try
        {
            File.WriteAllText(Path.Combine(Path.GetTempPath(), "sr-keystroke-bench.txt"), report);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }

        Shutdown(over);
    }
}
