using System.Globalization;
using SessionRestore.Core.Rows;
using SessionRestore.Core.Sessions;

namespace SessionRestore.Core.Acting;

/// <summary>What a sheet asks before something irreversible happens.</summary>
/// <param name="Title">The heading.</param>
/// <param name="Body">What will happen, in the operator's terms.</param>
/// <param name="Verb">The word on the button that goes ahead.</param>
public readonly record struct Confirm(string Title, string Body, string Verb);

/// <summary>
/// Closing a conversation and opening it again - as a decision, not as an act.
/// </summary>
/// <remarks>
/// 🔴 A FAILED KILL MUST NOT BECOME A SECOND SESSION. The shipped window
/// swallowed the failure and launched anyway, so a process that refused to die
/// left the OLD conversation running while a NEW one opened on the same
/// transcript - two claude processes holding one file, which is the exact state
/// the hidden-session path says must never happen ("the second would resume a
/// session the first is still writing"). A relaunch that cannot close is not a
/// relaunch, and saying so beats silently corrupting a conversation.
///
/// 🪤 THE PID CHECK IS NOT HERE, AND CANNOT BE. "Is this pid still the claude
/// that owns the conversation" is a question about the machine right now, not a
/// value - so it lives with the implementation, behind the same kind of guard
/// as <see cref="Console.ConsoleTarget.ForSession"/>. What is here is every
/// decision that can be answered without touching anything.
/// </remarks>
public static class Relaunch
{
    /// <summary>The command line of the shell a launch starts a conversation from.</summary>
    /// <remarks>
    /// 🪤 A `-like` PATTERN, matched the way PowerShell matches it. The boot
    /// shell is the parent that has to go with the conversation; anything else
    /// with that pid is somebody else's process.
    /// </remarks>
    public const string BootShellPattern = "*.state*boot-*";

    /// <summary>Why this conversation cannot be closed and reopened, or empty.</summary>
    public static string Refusal(AgentStatus? agent, string title)
    {
        if (agent is null || agent.Pid == 0)
        {
            return string.Empty;
        }

        return string.Equals(agent.Status, "busy", StringComparison.OrdinalIgnoreCase)
            ? string.Format(CultureInfo.InvariantCulture,
                "'{0}' is mid-turn - closing it now would lose the reply it is writing", title)
            : string.Empty;
    }

    /// <summary>What to say when the process would not die - and it was NOT reopened.</summary>
    public static string WouldNotClose(string title) =>
        string.Format(CultureInfo.InvariantCulture,
            "'{0}' would not close, so it has NOT been reopened - it is still running", title);

    /// <summary>
    /// The tab to close: the name the probe gave it, or the conversation's title.
    /// </summary>
    /// <remarks>
    /// 🪤 A TITLE ONLY IDENTIFIES A DEAD TAB while it still carries the name it
    /// was launched with, which is why this runs between the kill and the
    /// relaunch rather than after it.
    /// </remarks>
    public static string TabName(AgentStatus? agent, string title)
    {
        var named = agent?.Name ?? string.Empty;
        return named.Length > 0 ? named : title;
    }

    /// <summary>Is this the boot shell that belongs to a conversation?</summary>
    public static bool IsBootShell(string? processName, string? commandLine) =>
        string.Equals(processName, "powershell.exe", StringComparison.OrdinalIgnoreCase)
        && SearchMatch.Like(commandLine ?? string.Empty, BootShellPattern) == true;

    /// <summary>What the pane's Relaunch button asks before doing it.</summary>
    /// <remarks>
    /// 🔑 A CONVERSATION THAT IS NOT RUNNING IS NOT BEING RELAUNCHED, it is
    /// being opened - so the sheet says so, and the button says Open. The two
    /// are one control because the answer to "what does this row need" differs
    /// only in whether something is holding it.
    /// </remarks>
    public static Confirm PaneAsk(AgentStatus? agent, string title) =>
        agent is null || agent.Pid == 0
            ? new Confirm(
                "Open this conversation",
                string.Format(CultureInfo.InvariantCulture, "'{0}' is not running.", title),
                "Open")
            : new Confirm(
                "Relaunch this conversation",
                string.Format(CultureInfo.InvariantCulture,
                    "'{0}' will be CLOSED and opened again. Anything it has written is on disk; a turn in progress is not.",
                    title),
                "Relaunch");

    /// <summary>What the manager's right-click Relaunch asks. Shorter: that surface has no pane to explain it.</summary>
    public static Confirm ManagerAsk(string title) =>
        new("Relaunch this conversation",
            string.Format(CultureInfo.InvariantCulture, "'{0}' will be CLOSED and opened again.", title),
            "Relaunch");
}
