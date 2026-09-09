using System.Text.RegularExpressions;

namespace SessionRestore.Core.Transcripts;

/// <summary>Text that came out of a terminal, made fit to read.</summary>
public static partial class TranscriptText
{
    // 🪤 THE ESCAPE AND BELL CHARACTERS ARE SPELLED, NEVER TYPED. A raw
    // ESC byte sitting in a source file is invisible in every editor and
    // every diff, and a literal backspace that got into a regex exactly this
    // way earlier in this rebuild matched nothing at all and looked fine.
    // A \u001B escape says what it is, out loud, to anyone reading it.

    [GeneratedRegex("\u001B\\[[0-9;?]*[ -/]*[@-~]")]
    private static partial Regex AnsiCsi();

    [GeneratedRegex("\u001B\\][^\u0007]*\u0007")]
    private static partial Regex AnsiOsc();

    [GeneratedRegex("[\u0000-\u0008\u000B\u000C\u000E-\u001F]")]
    private static partial Regex AnsiControl();

    /// <summary>
    /// Strips terminal escapes from text that passed through a console.
    /// </summary>
    /// <remarks>
    /// 🪤 TAB AND NEWLINE ARE KEPT. They are layout in a tool result, not control
    /// noise, and stripping them runs a table into one line. That is why the
    /// control class above has holes in it rather than being every byte below
    /// 0x20.
    /// </remarks>
    public static string RemoveAnsi(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return string.Empty;
        }

        var t = AnsiCsi().Replace(text, string.Empty);
        t = AnsiOsc().Replace(t, string.Empty);
        return AnsiControl().Replace(t, string.Empty);
    }

    // 🪤 THE QUOTED FORM HAS TO BE MATCHED FIRST AND SEPARATELY. Every path in
    // this operator's transcripts runs through "Trading Bot" - a directory with
    // a SPACE in it - so an unquoted pattern stops dead at the space, shortens
    // the wrong half, and trims the part that was already common to every line
    // while leaving the tail that says WHICH worktree untouched.
    [GeneratedRegex(@"""([A-Za-z]:[\\/][^""]{24,})""")]
    private static partial Regex PathQuoted();

    [GeneratedRegex(@"(?<![\w""])([A-Za-z]:[\\/][^\s""']{24,})")]
    private static partial Regex PathBare();

    // A drive letter is <letter>: followed by a slash. Nothing here can fire
    // without one, so text that has none is returned untouched.
    [GeneratedRegex(@"[A-Za-z]:[\\/]")]
    private static partial Regex PathAny();

    /// <summary>A long absolute path shortened to its drive and its last three parts.</summary>
    public static string ShortenPath(string path)
    {
        if (string.IsNullOrEmpty(path))
        {
            return path;
        }

        var sep = path.Contains('/', StringComparison.Ordinal) ? "/" : "\\";
        var parts = path.Split('\\', '/').Where(p => p.Length > 0).ToArray();
        if (parts.Length <= 4)
        {
            return path;
        }

        return parts[0] + sep + '…' + sep + string.Join(sep, parts[^3..]);
    }

    /// <summary>Every long path in <paramref name="text"/>, shortened in place.</summary>
    public static string CompressPaths(string? text)
    {
        if (string.IsNullOrEmpty(text) || !PathAny().IsMatch(text))
        {
            return text ?? string.Empty;
        }

        var shortened = PathQuoted().Replace(text, m => "\"" + ShortenPath(m.Groups[1].Value) + "\"");
        return PathBare().Replace(shortened, m => ShortenPath(m.Groups[1].Value));
    }
}
