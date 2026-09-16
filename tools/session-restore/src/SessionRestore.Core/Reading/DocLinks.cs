using System.Text.RegularExpressions;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.Core.Reading;

/// <summary>
/// The files this conversation wrote, so that naming one anywhere in it is
/// pressable. <c>Set-SRDocLinks</c> and <c>Get-SRDocLinkRx</c>.
/// </summary>
/// <remarks>
/// 🔑 HARVESTED FROM THE TOOL RECORDS, NOT FROM PATH-SHAPED TEXT. A link points
/// at something a tool actually wrote, rather than at an example in a sentence -
/// which is the difference between a pane that offers you the file it just made
/// and one that underlines every word with a backslash in it.
///
/// 🔴 A READ IS NOT ONE OF THEM. Linking everything a session ever looked at
/// would put a link on half the document and teach the eye to ignore all of
/// them.
/// </remarks>
public static class DocLinks
{
    /// <summary>The tools that CREATE or CHANGE a file.</summary>
    public static readonly string[] FileTools =
        ["write", "edit", "multiedit", "notebookedit", "artifact"];

    /// <summary>How many paths are worth carrying.</summary>
    public const int Max = 400;

    /// <summary>Shorter than this is not a path.</summary>
    public const int MinLength = 3;

    /// <summary>Longer than this is a sentence.</summary>
    public const int MaxLength = 400;

    /// <summary>
    /// Every distinct path this conversation wrote, in the order it first wrote
    /// them.
    /// </summary>
    /// <remarks>
    /// 🪤 NO EXISTENCE CHECK HERE. This runs while the document is being built,
    /// on the gesture made all day, and four hundred stat calls is 40 ms of it.
    /// Whether the file is still there is decided when the link is PRESSED,
    /// which is also when the answer is worth having.
    ///
    /// 🪤 AND THE KEY IS LOWERCASED WHILE THE VALUE IS NOT. Windows paths differ
    /// in case between the record and the prose; what is drawn is what the tool
    /// wrote.
    /// </remarks>
    public static List<string> Paths(IReadOnlyList<ReadTurn>? turns)
    {
        var seen = new Dictionary<string, string>(StringComparer.Ordinal);
        var order = new List<string>();
        if (turns is null)
        {
            return order;
        }

        var n = 0;
        foreach (var t in turns)
        {
            if (!string.Equals(t.Kind, "run", StringComparison.Ordinal))
            {
                continue;
            }

            foreach (var c in t.Calls)
            {
                if (n >= Max)
                {
                    break;
                }

                var nm = c.Name.Trim().ToLowerInvariant();
                if (Array.IndexOf(FileTools, nm) < 0)
                {
                    continue;
                }

                var p = c.Arg.Trim().Trim('"');
                if (p.Length < MinLength || p.Length > MaxLength)
                {
                    continue;
                }

                var k = p.ToLowerInvariant();
                if (!seen.ContainsKey(k))
                {
                    seen[k] = p;
                    order.Add(p);
                    n++;
                }
            }
        }

        return order;
    }

    /// <summary>
    /// One pattern matching any of them, longest first.
    /// </summary>
    /// <remarks>
    /// 🔑 LONGEST FIRST, so a path never matches as the prefix of a longer one
    /// that is also in the set - which would underline half of a name and leave
    /// the rest as prose.
    ///
    /// 🪤 A PATTERN THAT WILL NOT COMPILE IS NO PATTERN. The shipped builder
    /// swallows the failure and returns null rather than taking the document
    /// down, and so does this.
    /// </remarks>
    public static Regex? Rx(IReadOnlyList<string>? paths)
    {
        if (paths is null || paths.Count == 0)
        {
            return null;
        }

        var parts = paths.OrderByDescending(p => p.Length).Select(Regex.Escape);
        try
        {
            return new Regex(string.Join("|", parts), RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        }
        catch (ArgumentException)
        {
            return null;
        }
    }
}
