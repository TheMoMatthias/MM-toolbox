using System.Text.RegularExpressions;

namespace SessionRestore.Core.Rows;

/// <summary>
/// The second line of a session row: what it last said, as one line.
/// </summary>
/// <remarks>
/// Ported from the row loop in <c>Build-Sessions</c>. What it last SAID wins;
/// with nothing said, the state's own detail stands in, so a row that has not
/// spoken yet still says something about itself.
///
/// 🪤 WHITESPACE IS COLLAPSED, NOT JUST TRIMMED. A reply's first line can carry
/// runs of spaces and tabs from a table or an indented block, and one line of a
/// 336px column cannot afford to spend them.
/// </remarks>
public static class Headline
{
    private static readonly Regex Runs = new(@"\s+", RegexOptions.CultureInvariant);

    /// <summary>The row's second line.</summary>
    /// <param name="said">The last thing the conversation said, or null.</param>
    /// <param name="detail">The state's detail, used when nothing was said.</param>
    public static string Of(string? said, string? detail)
    {
        var s = (said ?? string.Empty).Trim();
        if (s.Length > 0)
        {
            return Runs.Replace(s, " ");
        }

        return detail ?? string.Empty;
    }
}
