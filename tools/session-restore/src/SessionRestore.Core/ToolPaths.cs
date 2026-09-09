namespace SessionRestore.Core;

/// <summary>
/// Where the tool's files are. The first piece of domain, because everything
/// else needs it and because getting it wrong is silent.
/// </summary>
/// <remarks>
/// 🔴 THE REGISTRY AND THE CONFIG ARE LIVE OPERATOR FILES. `sessions-registry.json`
/// is the state of every conversation across every repo, and a registry-overwrite
/// bug in this repo's history cost 210 conversations. Nothing in Core writes
/// either of them until the guarded writer exists (plan item 2.7); until then
/// these are read paths and the absence of a writer is the guard.
///
/// 🪤 THE ROOT IS FOUND BY LOOKING FOR A FILE, NOT BY COUNTING "..". A relative
/// hop is correct for exactly one output layout and wrong the first time
/// anything moves - and it fails by resolving to a plausible directory that
/// simply has no data in it, which reads as "no conversations" rather than as
/// an error.
/// </remarks>
public static class ToolPaths
{
    private const string Marker = "lib";
    private const string MarkerFile = "_common.ps1";

    private static readonly Lazy<string> LazyRoot = new(Locate);

    /// <summary>The folder holding <c>lib\</c>, <c>Sessions.bat</c> and the registry.</summary>
    public static string Root => LazyRoot.Value;

    public static string Lib => Path.Combine(Root, "lib");

    /// <summary>Scratch this tool owns: logs, spliced harnesses, temporary state.</summary>
    public static string State => Path.Combine(Root, ".state");

    /// <summary>🔴 LIVE. Every conversation, its project and its tick.</summary>
    public static string Registry => Path.Combine(Root, "sessions-registry.json");

    /// <summary>🔴 LIVE. The operator's own settings.</summary>
    public static string Config => Path.Combine(Root, "session-restore.config.json");

    public static string Log => Path.Combine(State, "restore.log");

    /// <summary>Where claude keeps the transcripts. Read only, always.</summary>
    public static string Transcripts => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "projects");

    private static string Locate()
    {
        // From the build output (bin/Debug/net8.0-windows) the root is five up;
        // from a published dist/ it is two. Walking until the marker is found
        // covers both without either being written down.
        var dir = AppContext.BaseDirectory;
        for (var i = 0; i < 12; i++)
        {
            if (string.IsNullOrEmpty(dir))
            {
                break;
            }

            if (File.Exists(Path.Combine(dir, Marker, MarkerFile)))
            {
                return dir;
            }

            var parent = Path.GetDirectoryName(dir.TrimEnd(Path.DirectorySeparatorChar));
            if (string.Equals(parent, dir, StringComparison.OrdinalIgnoreCase))
            {
                break;
            }

            dir = parent;
        }

        throw new DirectoryNotFoundException(
            $"Could not find the session-restore root above '{AppContext.BaseDirectory}'. " +
            $"Looked for '{Marker}\\{MarkerFile}' in each parent.");
    }
}
