using System.Text.RegularExpressions;

namespace SessionRestore.Core.Console;

/// <summary>
/// Whether the screen in front of a conversation is a MENU it is waiting on.
/// </summary>
/// <remarks>
/// 🔴 THIS IS THE SECOND OF THE TWO THINGS THAT BLOCK AN IMPLEMENTATION THAT
/// CAN ACT. A session sitting on a menu reads keystrokes as MENU INPUT, so a
/// sentence typed at it PICKS AN OPTION instead of queueing behind the turn.
/// The send box refused on <c>onAMenu: false</c> while nothing in the rebuild
/// could type, which was honest and is not honest any more the moment something
/// can.
///
/// 🔑 IT IS A VALUE READ OFF TEXT, WHICH IS WHY IT CAN BE PORTED NOW. The
/// shipped tool asks the same question in two places - the band, through
/// <c>Set-AskSeen</c>, and the send refusal in <c>Send-SRSessionInput</c> - and
/// deliberately routes both through ONE function so they cannot answer it
/// differently, which is exactly what they were doing. Ported as one function
/// here for the same reason.
///
/// 🪤 IT CANNOT REUSE THE QUESTION-CHROME TEST, WHICH IS THE OBVIOUS THING TO
/// DO. That helper's box-drawing arm matches the menu's own free-text editor
/// row - <c>round-single-fresh</c> draws a rule between option 4 and option 5 -
/// so "no chrome below the last option" rejects all seven captured real menus.
/// Only the three status-line patterns in <see cref="IsPromptLine"/> are safe.
/// </remarks>
public static class LiveMenu
{
    /// <summary>The highlight claude draws beside the option the cursor is on.</summary>
    public const char Cursor = '❯';

    /// <summary>
    /// One numbered option row: an optional cursor, one or two digits, a dot,
    /// and something that is not blank after it.
    /// </summary>
    private static readonly Regex Option = new(
        @"^\s*(" + Cursor + @")?\s*(\d{1,2})\.\s+(\S.*)$",
        RegexOptions.CultureInvariant);

    /// <remarks>
    /// 🔴 THESE ARE CASE-INSENSITIVE BECAUSE POWERSHELL'S <c>-match</c> IS, and
    /// the shipped line is written with it. A port that used the .NET default
    /// would answer differently on a screen that said <c>model:</c>, and the
    /// difference would show up as a session the window thought was on a menu
    /// when it was sitting at its own prompt.
    /// </remarks>
    private static readonly Regex[] PromptLines =
    [
        new(@"^Model:\s", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant),
        new(@"\bshift\+tab to cycle\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant),
        new(@"^\?\s+for shortcuts", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant),
    ];

    /// <summary>
    /// Is this the status line claude draws under its own input box?
    /// </summary>
    /// <remarks>
    /// 🔑 WHAT IS LEFT IS STRUCTURE, AND IT IS EXACT. The prompt's status line
    /// only ever appears when the session is showing its input box, and a
    /// session showing its input box is not showing a menu. Scored over 13
    /// fixtures: the old cursor gate was wrong on 3, the sweep's option-count
    /// test on 2, this on none.
    /// </remarks>
    public static bool IsPromptLine(string? line)
    {
        var t = (line ?? string.Empty).Trim();
        if (t.Length == 0)
        {
            return false;
        }

        foreach (var re in PromptLines)
        {
            if (re.IsMatch(t))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// Which line the live menu's first option is on, or -1 when the screen
    /// holds no menu.
    /// </summary>
    /// <remarks>
    /// 🔴 IT HAS TO RESTART, AND NOT RESTARTING IS THE BUG IT EXISTS TO FIX.
    /// The parser used to lock onto the first run of consecutive numbers on the
    /// screen and never reconsider, so an ordinary numbered list in scrollback
    /// ABOVE a live menu captured the parse - and it went on absorbing later
    /// lines whose number continued the count, welding three lines of prose to
    /// the menu's last two rows as one option list.
    ///
    /// 🔑 THE LAST SURVIVING RUN WINS. A run is disqualified the moment a prompt
    /// status line appears below it, because everything above the input box is
    /// scrollback by definition. What is left at the end is the run nothing has
    /// been drawn under - which is the menu, if there is one.
    ///
    /// 🪤 A NUMBERED LINE THAT IS NEITHER A 1 NOR THE NEXT IN THE RUN IS
    /// SKIPPED, NOT A RESET. Only a prompt line resets. Ported exactly: a screen
    /// with "1. a", "7. b", "2. c" leaves the run alive at length 2.
    /// </remarks>
    public static int Start(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return -1;
        }

        var lines = text.Split('\n');
        var runStart = -1;
        var runCount = 0;

        for (var i = 0; i < lines.Length; i++)
        {
            var m = Option.Match(lines[i]);
            if (m.Success)
            {
                var n = int.Parse(m.Groups[2].Value, System.Globalization.CultureInfo.InvariantCulture);

                // A '1.' always starts a new run, whatever was being counted before.
                if (n == 1)
                {
                    runStart = i;
                    runCount = 1;
                }
                else if (runCount > 0 && n == runCount + 1)
                {
                    runCount++;
                }

                continue;
            }

            if (IsPromptLine(lines[i]))
            {
                runStart = -1;
                runCount = 0;
            }
        }

        // One numbered line is a paragraph, not a menu - the same floor the
        // parser itself keeps.
        return runCount < 2 ? -1 : runStart;
    }

    /// <summary>Is a live menu on this screen at all?</summary>
    public static bool IsOn(string? text) => Start(text) >= 0;
}
