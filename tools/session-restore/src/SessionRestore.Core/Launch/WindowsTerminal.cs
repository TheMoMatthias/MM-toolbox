namespace SessionRestore.Core.Launch;

/// <summary>Where <c>wt.exe</c> is. Read only - finding it starts nothing.</summary>
/// <remarks>
/// 🪤 A PATH LOOKUP ALONE IS NOT ENOUGH, and it failed here once already.
/// Windows Terminal ships as a WindowsApps execution alias - a reparse point
/// that is often absent from a child shell's PATH and from the thinner PATH a
/// scheduled task inherits. So the probe falls through to the two well-known
/// alias locations and finally to the installed package itself.
/// </remarks>
public static class WindowsTerminal
{
    /// <summary>The full path, or null if Windows Terminal is not installed.</summary>
    public static string? Resolve()
    {
        var onPath = FindOnPath("wt.exe");
        if (onPath is not null)
        {
            return onPath;
        }

        foreach (var c in new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Microsoft", "WindowsApps", "wt.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "WindowsApps", "wt.exe"),
        })
        {
            if (File.Exists(c))
            {
                return c;
            }
        }

        var apps = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsApps");
        try
        {
            // Newest package by name, which is how the versioned folder sorts.
            var pkg = Directory.EnumerateDirectories(apps, "Microsoft.WindowsTerminal*")
                .OrderByDescending(Path.GetFileName, StringComparer.Ordinal)
                .FirstOrDefault();
            if (pkg is not null)
            {
                var exe = Path.Combine(pkg, "wt.exe");
                if (File.Exists(exe))
                {
                    return exe;
                }
            }
        }
        catch (UnauthorizedAccessException) { }
        catch (DirectoryNotFoundException) { }
        catch (IOException) { }

        return null;
    }

    private static string? FindOnPath(string exe)
    {
        var path = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrEmpty(path))
        {
            return null;
        }

        foreach (var dir in path.Split(Path.PathSeparator))
        {
            if (dir.Length == 0)
            {
                continue;
            }

            string full;
            try
            {
                full = Path.Combine(dir.Trim('"'), exe);
            }
            catch (ArgumentException)
            {
                continue; // a malformed PATH entry is not a reason to stop looking
            }

            if (File.Exists(full))
            {
                return full;
            }
        }

        return null;
    }
}
