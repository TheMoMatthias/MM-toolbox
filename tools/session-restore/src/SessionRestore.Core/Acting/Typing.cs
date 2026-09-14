using System.Globalization;
using SessionRestore.Core.Sessions;

namespace SessionRestore.Core.Acting;

/// <summary>Whether the send box accepts typing, and what it says while you do.</summary>
/// <param name="Blocker">Why nothing may be typed. Empty means the box is live.</param>
/// <param name="Note">Something worth saying that does NOT stop you typing.</param>
public readonly record struct TypingState(string Blocker, string Note)
{
    /// <summary>The box is enabled exactly when nothing blocks it.</summary>
    public bool CanType => Blocker.Length == 0;
}

/// <summary>
/// The state of the box you type a message into.
/// </summary>
/// <remarks>
/// 🔴 BUSY IS NOT A BLOCKER, and the shipped window carries the reason: it used
/// to disable the box outright - "wait for it to stop before typing" - so a
/// second message could not be written while the first was being worked on. But
/// claude ACCEPTS typed input mid-turn and QUEUES it, which is what the terminal
/// does, and refusing made the tool less capable than the thing it is a window
/// onto. Reported as: writing multiple messages subsequently and queueing them
/// up is not working.
///
/// 🪤 THE ONE CASE STILL REFUSED IS A MENU. A session sitting on a question
/// reads keystrokes as menu input, so text typed here would PICK AN OPTION
/// rather than queue behind one. The question panel is the way to answer that.
/// </remarks>
public static class Typing
{
    /// <param name="haveSession">Whether a conversation - not a sub-agent - is selected.</param>
    /// <param name="agent">What the probe says about the process holding it.</param>
    /// <param name="onAMenu">Whether it is sitting on a question the window has seen.</param>
    /// <param name="queued">How many messages are already waiting for it.</param>
    public static TypingState Of(bool haveSession, AgentStatus? agent, bool onAMenu, int queued)
    {
        if (!haveSession)
        {
            return new TypingState("nothing is selected", string.Empty);
        }

        if (agent is null || agent.Pid == 0)
        {
            return new TypingState("this conversation is not running, so there is nothing to type into", string.Empty);
        }

        // 🪤 AN EMPTY KIND IS NOT A BACKGROUND AGENT. The shipped test is
        // `$r.A.Kind -and $r.A.Kind -ne 'interactive'` - a probe that said
        // nothing about the kind leaves the box LIVE, and a port that dropped
        // the first half would refuse to type into it.
        if (agent.Kind.Length > 0
            && !string.Equals(agent.Kind, "interactive", StringComparison.OrdinalIgnoreCase))
        {
            return new TypingState("a background agent has no console to type into", string.Empty);
        }

        if (onAMenu)
        {
            return new TypingState("it is waiting on a question - answer it in the panel above", string.Empty);
        }

        if (!string.Equals(agent.Status, "busy", StringComparison.OrdinalIgnoreCase))
        {
            return new TypingState(string.Empty, string.Empty);
        }

        // 🪤 AND IT SAYS WHERE IT WILL LAND. "queued behind it" is true and
        // useless when four things are already waiting: the question the
        // operator actually has is whether this is the next thing read or the
        // fifth.
        return new TypingState(
            string.Empty,
            queued > 0
                ? string.Format(CultureInfo.InvariantCulture,
                    "it is mid-turn - what you type joins the queue at position {0}", queued + 1)
                : "it is mid-turn - what you type will be queued behind it");
    }
}
