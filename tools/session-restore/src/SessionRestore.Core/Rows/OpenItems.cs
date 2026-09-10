using System.Text.RegularExpressions;

namespace SessionRestore.Core.Rows;

/// <summary>
/// Did the last thing a conversation said leave anything open? Plan item 2.6.
/// </summary>
/// <remarks>
/// 🔑 IT READS THE WHOLE LAST MESSAGE, NOT THE HEADLINE. Measured over 26 live
/// conversations: the one-line <c>Said</c> the column draws matched NONE of these
/// shapes and the full message matched four. The text was always there - the
/// record threw it away, and the band was decided on what was left.
///
/// 🪤 AND <c>Full</c> IS EMPTY UNTIL A PROBE HAS READ IT, exactly as
/// <c>Said</c> is. So an unread conversation degrades to plain "finished" rather
/// than to a wrong answer.
/// </remarks>
public static class OpenItems
{
    /// <summary>One rule, and the words it puts on the tooltip.</summary>
    public sealed record Rule(string Name, Regex Pattern);

    // 🔴 THE ORDER IS THE ANSWER for the tooltip: the FIRST rule that fires is
    // the reason reported, so a message that both ends on a question and names a
    // next step is described as the question. Ported in the PowerShell's order.
    //
    // 🪤 SINGLELINE AND MULTILINE ARE PER-RULE AND THEY ARE NOT THE SAME THING.
    // PowerShell spells them inline - `(?s)` makes `.` match a newline, `(?m)`
    // makes `^` and `$` match at every line - and getting one wrong turns a rule
    // that fires on a trailing question mark into one that fires on any question
    // mark anywhere.
    private static readonly Rule[] All =
    [
        new("ends on a question", new Regex(@"\?\s*$", RegexOptions.Singleline | RegexOptions.Compiled)),
        new("an unticked box", new Regex(@"^\s*[-*]\s*\[\s\]", RegexOptions.Multiline | RegexOptions.Compiled)),
        new("names something open", new Regex(
            @"\b(still (open|outstanding|to do)|remains? (open|outstanding)|not (yet )?(started|done|finished|landed)|still (missing|blocked)|blocked on|open (question|item|decision)s?|left to do|next step|to be done|needs? (your|a) (decision|answer|call|look))\b",
            RegexOptions.IgnoreCase | RegexOptions.Compiled)),
        new("hands a decision back", new Regex(
            @"\b(let me know|tell me (if|whether|which|what)|shall i\b|should i\b|would you like|do you want|your call|up to you|say the word|if you.{0,3}d (rather|prefer))",
            RegexOptions.IgnoreCase | RegexOptions.Compiled)),
        new("a heading for it", new Regex(
            @"^\s{0,3}#{0,4}\s*(DECISIONS?|OPEN|OUTSTANDING|TODO|NEXT|STILL OPEN|REMAINING)\b\s*[:\-]",
            RegexOptions.IgnoreCase | RegexOptions.Multiline | RegexOptions.Compiled)),
    ];

    public static bool Any(string? text) => Reason(text).Length > 0;

    /// <summary>Which rule fired, for the tooltip and for the suite. Empty when none did.</summary>
    public static string Reason(string? text)
    {
        var t = text ?? string.Empty;
        if (t.Trim().Length == 0)
        {
            return string.Empty;
        }

        foreach (var r in All)
        {
            if (r.Pattern.IsMatch(t))
            {
                return r.Name;
            }
        }

        return string.Empty;
    }
}
