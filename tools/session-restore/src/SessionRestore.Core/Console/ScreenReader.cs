using System.Diagnostics;
using System.Globalization;

namespace SessionRestore.Core.Console;

/// <summary>
/// Reads a session's screen by asking the helper, because this process must
/// never attach to a console itself.
/// </summary>
/// <remarks>
/// 🔴 THE PROCESS BOUNDARY IS THE POINT, NOT AN ARTEFACT. Attaching hands the
/// caller somebody else's console; doing that from the window would redefine
/// its own standard handles and Ctrl+C behaviour underneath it. The helper
/// exists so the attaching happens somewhere disposable.
///
/// 🪤 A PROCESS PER READ IS NOT THE END STATE. Measured in the PowerShell:
/// starting the helper is 100 of the 130 ms a read costs, and the reading
/// itself about 30 - which is why the shipped tool holds one helper open on a
/// pipe and talks to it. That server is plan item 2.4b; this is the shape it
/// replaces, kept because it is also the fallback when the pipe is not there.
/// </remarks>
public static class ScreenReader
{
    private static readonly Lazy<string?> Helper = new(Locate);

    /// <summary>Where sr-screen.exe is, or null if it was not built.</summary>
    public static string? HelperPath => Helper.Value;

    private static string? Locate()
    {
        var names = new[] { "sr-screen.exe" };
        var dirs = new List<string> { AppContext.BaseDirectory };

        // A published app has the helper beside it; a dev build has it in the
        // sibling project's output. Both are looked for rather than assumed.
        var here = AppContext.BaseDirectory;
        for (var i = 0; i < 6 && here is not null; i++)
        {
            var candidate = Path.Combine(here, "SessionRestore.Screen", "bin");
            if (Directory.Exists(candidate))
            {
                dirs.AddRange(Directory.GetDirectories(candidate, "*", SearchOption.AllDirectories));
            }

            here = Path.GetDirectoryName(here.TrimEnd(Path.DirectorySeparatorChar));
        }

        foreach (var d in dirs)
        {
            foreach (var n in names)
            {
                var p = Path.Combine(d, n);
                if (File.Exists(p))
                {
                    return p;
                }
            }
        }

        return null;
    }

    /// <summary>
    /// The visible screen of <paramref name="pid"/>, or a string beginning with
    /// '!' saying why not.
    /// </summary>
    public static string Read(uint pid, int back = 0, bool attributes = false, int timeoutMs = 5000)
    {
        var exe = Helper.Value;
        if (exe is null)
        {
            return "!nohelper";
        }

        // 🪤 THE ANSWER FILE LIVES BESIDE THE TOOL'S OWN STATE, not in the OS
        // temp directory. A leaked temp there degrades every later session on
        // this machine, and this path runs several times a second.
        var dir = ToolPaths.State;
        Directory.CreateDirectory(dir);
        var outFile = Path.Combine(dir,
            "screen-" + Guid.NewGuid().ToString("N", CultureInfo.InvariantCulture) + ".txt");

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = exe,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            if (attributes)
            {
                psi.ArgumentList.Add("-attrs");
            }

            if (back > 0)
            {
                psi.ArgumentList.Add("-back");
                psi.ArgumentList.Add(back.ToString(CultureInfo.InvariantCulture));
            }

            psi.ArgumentList.Add(pid.ToString(CultureInfo.InvariantCulture));
            psi.ArgumentList.Add(outFile);

            using var p = Process.Start(psi);
            if (p is null)
            {
                return "!spawn";
            }

            if (!p.WaitForExit(timeoutMs))
            {
                try { p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                return "!timeout";
            }

            return File.Exists(outFile) ? File.ReadAllText(outFile) : "!noanswer";
        }
        catch (IOException ex)
        {
            return "!io " + ex.GetType().Name;
        }
        finally
        {
            try { File.Delete(outFile); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    /// <summary>
    /// Reads twice and returns the text only if it did not move.
    /// </summary>
    /// <remarks>
    /// 🔑 A LIVE SCREEN IS A MOVING TARGET, and that is a fact about the thing
    /// being read rather than about either implementation. Anything comparing
    /// two readers has to be able to say "this one was not standing still" -
    /// otherwise a busy session reads as a defect, every time, and the
    /// comparison gets switched off.
    /// </remarks>
    public static (string Text, bool Stable) ReadStable(uint pid, int gapMs = 220)
    {
        var a = Read(pid);
        Thread.Sleep(gapMs);
        var b = Read(pid);
        return (b, string.Equals(a, b, StringComparison.Ordinal));
    }
}
