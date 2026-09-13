using System.Text;
using System.Text.RegularExpressions;

namespace SessionRestore.Core.Rows;

/// <summary>
/// What the two search boxes match, and how. Ported from <c>Update-Model</c>'s
/// haystack and <c>Build-Sessions</c>' filter.
/// </summary>
/// <remarks>
/// 🔴 IT IS <c>-like "*query*"</c>, NOT A SUBSTRING TEST. So <c>*</c>, <c>?</c> and
/// <c>[ab]</c> typed into a search box are wildcards, a backtick escapes the next
/// character, and an unclosed <c>[</c> is an invalid pattern that THROWS - which in
/// the shipped window aborts that rebuild and leaves the list as it was. A port
/// that used <c>Contains</c> agreed on every query without those characters and on
/// none with them.
/// </remarks>
public static class SearchMatch
{
    /// <summary>The header search box's haystack, lower-cased once when the model changes.</summary>
    /// <remarks>
    /// 🪤 THE PROJECT LABEL, NOT THE CWD. The first port searched title, id, path
    /// and cwd; the shipped one searches title, auto-title, path, id and the
    /// project's disambiguated label - so "web / src" found nothing.
    /// </remarks>
    public static string Haystack(string title, string? autoTitle, string? path, string id, string label) =>
        string.Join(" ", title, autoTitle ?? string.Empty, path ?? string.Empty, id, label).ToLowerInvariant();

    /// <summary>
    /// The sessions column's own box: title and auto-title only.
    /// </summary>
    /// <remarks>
    /// Deliberately NOT the project path - narrowing projects is the rail's box,
    /// and matching both here would make a project name typed into this box
    /// silently do the rail's job.
    /// </remarks>
    public static string ListHaystack(string title, string? autoTitle) =>
        (title + " " + (autoTitle ?? string.Empty)).ToLowerInvariant();

    /// <summary>A compiled <c>-like "*needle*"</c>, or null when PowerShell would throw on it.</summary>
    public static Regex? Pattern(string needle)
    {
        ArgumentNullException.ThrowIfNull(needle);
        var sb = new StringBuilder("^.*");
        for (var i = 0; i < needle.Length; i++)
        {
            var ch = needle[i];
            if (ch == '`' && i + 1 < needle.Length)
            {
                sb.Append(Regex.Escape(needle[++i].ToString()));
            }
            else if (ch == '*')
            {
                sb.Append(".*");
            }
            else if (ch == '?')
            {
                sb.Append('.');
            }
            else if (ch == '[')
            {
                var close = needle.IndexOf(']', i + 1);
                if (close < 0)
                {
                    return null;
                }

                sb.Append('[');
                for (var j = i + 1; j < close; j++)
                {
                    var c = needle[j];
                    if (c == '`' && j + 1 < close)
                    {
                        c = needle[++j];
                        sb.Append(Regex.Escape(c.ToString()));
                    }
                    else if (c == '-' && j > i + 1 && j + 1 < close)
                    {
                        sb.Append('-');
                    }
                    else
                    {
                        sb.Append(c is '\\' or ']' or '^' or '-' or '[' ? "\\" + c : c.ToString());
                    }
                }

                sb.Append(']');
                i = close;
            }
            else
            {
                sb.Append(Regex.Escape(ch.ToString()));
            }
        }

        sb.Append(".*$");
        return new Regex(sb.ToString(), RegexOptions.IgnoreCase | RegexOptions.Singleline | RegexOptions.CultureInvariant);
    }

    /// <summary>PowerShell's <c>$hay -like "*$needle*"</c>; null when it would throw.</summary>
    public static bool? Like(string hay, string needle) =>
        Pattern(needle) is { } rx ? rx.IsMatch(hay ?? string.Empty) : null;
}
