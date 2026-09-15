namespace SessionRestore.Core.Acting;

/// <summary>
/// Why a message must not be typed into a conversation - the check that sits
/// BELOW the seam, in front of the keystrokes themselves.
/// </summary>
/// <remarks>
/// 🔴 THIS IS THE ONE THAT PROTECTS THE OPERATOR, AND IT IS NOT THE SEND BOX'S.
/// <see cref="Typing"/> decides what the window SAYS and whether the button is
/// enabled, from what the window has already SEEN. This decides whether the
/// keystrokes are written at all, from a screen read taken at the moment of
/// sending - and the shipped tool made that split deliberately:
///
/// <code>
/// 🪤 BUT THE DIALOG GATE IS NOT THE ANSWER PATH'S GATE ... HERE THERE IS NO
/// DOWNSTREAM CHECK AT ALL: this types the text and submits it, and nothing
/// re-reads the screen in between.
/// </code>
///
/// So the evidence could not be made cheaper and older; it was made cheaper and
/// FRESHER instead. The window's own record is up to ~26 s behind (a 15 s probe
/// that itself takes 11.3 s); a screen read through the held-open reader costs
/// about 9 ms.
///
/// 🔴 AND THE REBUILD NEEDS IT BEFORE IT NEEDS ANYTHING ELSE THAT ACTS. A
/// session sitting on a menu reads keystrokes as MENU INPUT, so a sentence typed
/// at it picks an option instead of queueing. With about thirty live
/// conversations that cannot be relaunched, "the text landed in the menu's
/// editor row" is not a cosmetic failure.
///
/// 🔑 IT IS A VALUE, SO IT CAN BE COMPARED WITHOUT BEING PERFORMED. The shipped
/// ladder is the top of <c>Send-SRSessionInput</c>, whose bottom half writes
/// into a live console; the oracle splices the ladder out by the words in it and
/// never evaluates a line below the cut.
/// </remarks>
public static class SendRefusal
{
    /// <summary><c>$SR_RefuseDialog</c>.</summary>
    public const string Dialog = "a dialog is open in that session - it is waiting on an answer there";

    /// <summary><c>$SR_RefuseMenu</c>.</summary>
    public const string Menu = "that session is showing a menu - the question card is where it wants answering";

    public const string Nothing = "nothing to send";

    public const string NoProcess = "that session has no process to type into (it is a background agent)";

    public const string NotInteractive = "only an interactive session can be typed into";

    /// <summary>
    /// Is this refusal one that forcing would lift?
    /// </summary>
    /// <remarks>
    /// 🪤 CONSTANTS, NOT PROSE MATCHED AT THE CALL SITE. A composer has to tell
    /// "refused, and forcing would be reasonable" from "refused because the
    /// session is gone", and matching on wording would break the moment somebody
    /// improved it.
    ///
    /// 🔴 AND WHOEVER REFUSES DOES NOT OWN THE OFFER. The shipped refusals used
    /// to end "or send anyway to type into the dialog/menu" and NO CALLER PASSED
    /// -Force, so the sentence offered an action that did not exist. Whether
    /// "send anyway" is available depends on who is asking: a composer has the
    /// operator in front of it, while a broadcast queue is acting across
    /// sessions nobody is watching.
    /// </remarks>
    public static bool IsForceable(string? why) =>
        !string.IsNullOrEmpty(why)
        && (string.Equals(why, Dialog, StringComparison.Ordinal)
            || string.Equals(why, Menu, StringComparison.Ordinal));

    /// <summary>The message with its line breaks flattened, as the shipped one sends it.</summary>
    public static string Body(string? text) =>
        (text ?? string.Empty).Replace("\r\n", " ", StringComparison.Ordinal)
                              .Replace("\r", " ", StringComparison.Ordinal)
                              .Replace("\n", " ", StringComparison.Ordinal)
                              .Trim();

    /// <summary>
    /// Why this message must not be typed into this conversation, or empty when
    /// it may be.
    /// </summary>
    /// <param name="text">What is being sent.</param>
    /// <param name="processId">The process the window believes owns it.</param>
    /// <param name="kind">What the probe calls it.</param>
    /// <param name="waitingFor">What the window's record says it is waiting on.</param>
    /// <param name="notClaude">
    /// What a check of the process says, or empty when it is the claude that
    /// owns the session. A pid is reusable, so this is asked before anything is
    /// written into that console.
    /// </param>
    /// <param name="screen">
    /// What is on the screen RIGHT NOW, or null when it could not be read.
    /// 🪤 A FAILED READ IS NOT A MISSING MENU - the reader sometimes comes back
    /// empty about a menu that is plainly still there, so an unreadable screen
    /// refuses nothing and the shipped line says the same by testing the text
    /// for truth before asking about it.
    /// </param>
    /// <param name="force">
    /// The caller has shown the operator what is open and been told to go ahead.
    /// </param>
    public static string Of(
        string? text,
        int processId,
        string? kind,
        string? waitingFor,
        string? notClaude,
        string? screen,
        bool force = false)
    {
        if (Body(text).Length == 0)
        {
            return Nothing;
        }

        if (processId <= 0)
        {
            return NoProcess;
        }

        // 🪤 AN EMPTY KIND IS NOT A BACKGROUND AGENT, and the comparison is
        // case-insensitive because PowerShell's -ne is.
        if (!string.IsNullOrEmpty(kind)
            && !string.Equals(kind, "interactive", StringComparison.OrdinalIgnoreCase))
        {
            return NotInteractive;
        }

        // The window's own record, honoured when it has one. -match, so the word
        // anywhere in it counts, and case-insensitively.
        if (!force
            && (waitingFor ?? string.Empty).Contains("dialog", StringComparison.OrdinalIgnoreCase))
        {
            return Dialog;
        }

        // A pid is reusable. This is asked BEFORE the screen, because a screen
        // belonging to something else is not evidence about anything.
        if (!string.IsNullOrEmpty(notClaude))
        {
            return notClaude;
        }

        if (!force && !string.IsNullOrEmpty(screen) && Console.LiveMenu.IsOn(screen))
        {
            return Menu;
        }

        return string.Empty;
    }
}
