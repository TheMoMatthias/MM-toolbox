using System.Text;

namespace SessionRestore.Core.Transcripts;

/// <summary>Where a conversation's transcript is.</summary>
/// <remarks>
/// 🔴 THE RECORDED PATH MUST ACTUALLY BELONG TO THIS SESSION. Trusting it on
/// existence alone would let a stale registry row vouch for somebody else's
/// transcript, and the caller would then launch <c>--resume &lt;id&gt;</c> having
/// verified the wrong file - a guard that passes and a resume that fails. So the
/// filename has to be the session id before the recorded path is believed;
/// otherwise the canonical location is computed from scratch.
/// </remarks>
public static class TranscriptPath
{
    public static string For(string dir, string sessionId, string? recorded)
    {
        ArgumentNullException.ThrowIfNull(dir);
        ArgumentNullException.ThrowIfNull(sessionId);

        if (!string.IsNullOrEmpty(recorded)
            && string.Equals(Path.GetFileNameWithoutExtension(recorded), sessionId, StringComparison.OrdinalIgnoreCase)
            && Exists(recorded))
        {
            return recorded;
        }

        return Path.Combine(ToolPaths.Transcripts, Slug(dir), sessionId + ".jsonl");
    }

    /// <summary>PowerShell's <c>Test-Path</c>: a file OR a directory.</summary>
    public static bool Exists(string path) =>
        path.Length > 0 && (File.Exists(path) || Directory.Exists(path));

    /// <summary>
    /// claude's own folder naming: every character that is not a letter or a
    /// digit becomes a dash. Not a hash and not an escape - which is why two
    /// different directories CAN collide here, and why the session id is still
    /// part of the filename.
    /// </summary>
    private static string Slug(string dir)
    {
        var sb = new StringBuilder(dir.Length);
        foreach (var c in dir)
        {
            sb.Append(char.IsAsciiLetterOrDigit(c) ? c : '-');
        }

        return sb.ToString();
    }
}
