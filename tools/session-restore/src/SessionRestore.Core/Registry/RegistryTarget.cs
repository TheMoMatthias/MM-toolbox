namespace SessionRestore.Core.Registry;

/// <summary>
/// A file the registry writer is allowed to write. Plan item 2.7.
/// </summary>
/// <remarks>
/// 🔴 THE GUARD IS A TYPE, AND THE OPERATOR'S OWN REGISTRY CANNOT BE NAMED BY
/// ONE. A registry-overwrite bug in this repo's history cost **210
/// conversations**, and the rebuild's protection so far has been that no writer
/// existed at all. Now that one does, the protection has to be something better
/// than remembering: <see cref="ForCopy"/> is the ONLY way to obtain a target,
/// and it refuses the live registry and the live config by name.
///
/// 🔑 THERE IS DELIBERATELY NO <c>Live()</c> FACTORY, NOT EVEN AN INTERNAL ONE.
/// An internal one would be reachable from the test assembly, and "a test that
/// CAN reach live state WILL destroy it" is written down in this repo because it
/// already happened. Phase 6 adds exactly one factory, in the one place that
/// swaps the tools over, and it will be the only line that can ever address the
/// real file.
///
/// 🪤 THE COMPARISON IS ON THE FULL PATH, not the string handed in. <c>.\..\</c>,
/// a short name, a trailing separator and a different case all name the same
/// file, and a guard that compared the text would wave every one of them
/// through.
/// </remarks>
public sealed class RegistryTarget
{
    private RegistryTarget(string path) => Path = path;

    /// <summary>The file to write. Never the operator's own.</summary>
    public string Path { get; }

    /// <summary>
    /// A registry file that is not the live one.
    /// </summary>
    /// <param name="refusal">Empty when a target was returned; otherwise the
    /// reason, in words the operator could read.</param>
    /// <returns>Null when the path is a live operator file.</returns>
    public static RegistryTarget? ForCopy(string path, out string refusal)
    {
        ArgumentNullException.ThrowIfNull(path);

        string full;
        try
        {
            full = System.IO.Path.GetFullPath(path);
        }
        catch (ArgumentException ex)
        {
            refusal = "that is not a usable path: " + ex.Message;
            return null;
        }
        catch (NotSupportedException ex)
        {
            refusal = "that is not a usable path: " + ex.Message;
            return null;
        }
        catch (PathTooLongException ex)
        {
            refusal = "that path is too long: " + ex.Message;
            return null;
        }

        foreach (var (live, what) in new[]
        {
            (ToolPaths.Registry, "the operator's live registry"),
            (ToolPaths.Config, "the operator's live config"),
        })
        {
            if (Same(full, live))
            {
                refusal = "refusing to write " + what + " (" + live
                    + "). Nothing outside the cutover step may address it; write a copy and compare.";
                return null;
            }
        }

        if (System.IO.Path.GetDirectoryName(full) is null)
        {
            refusal = "a registry needs a directory to sit in, and that path has none: " + full;
            return null;
        }

        refusal = string.Empty;
        return new RegistryTarget(full);
    }

    private static bool Same(string a, string b)
    {
        try
        {
            return string.Equals(
                System.IO.Path.GetFullPath(a),
                System.IO.Path.GetFullPath(b),
                StringComparison.OrdinalIgnoreCase);
        }
        catch (ArgumentException)
        {
            return false;
        }
    }
}
