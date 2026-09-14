using SessionRestore.Core.Sessions;

namespace SessionRestore.Core.Acting;

/// <summary>
/// Whether Escape may be pressed in a conversation, and why not.
/// </summary>
/// <remarks>
/// 🔴 NOTHING IN THIS NAMESPACE ACTS. Every type here turns an act into a
/// VALUE - a refusal, a note, the name of a tab - so the decision can be
/// compared against the shipped window without anything being performed. That
/// split is what made the dangerous paths verifiable in Phase 2, and it is the
/// same move: <c>Get-SRLaunchCommandLine</c> was cut out of
/// <c>Start-SRSession</c>, and <c>Get-SRSaveRefusal</c> out of the fenced
/// <c>Save-SRRegistry</c>.
///
/// 🔑 THE INTERRUPT IS THE RECOVERABLE HALF OF A PAIR, and that is why the
/// shipped window confirms nothing here: stopping a turn leaves the session open
/// and the transcript keeps everything written so far, so pressing it by mistake
/// costs the rest of one turn. Relaunch, which loses the turn AND the process,
/// does confirm.
/// </remarks>
public static class Interrupt
{
    /// <summary>Why Escape cannot be sent, or empty when it can.</summary>
    /// <param name="haveRow">Whether anything is selected at all.</param>
    /// <param name="agent">What the probe says about the process holding it.</param>
    public static string Blocker(bool haveRow, AgentStatus? agent)
    {
        if (!haveRow)
        {
            return "nothing is selected";
        }

        if (agent is null || agent.Pid == 0)
        {
            return "this conversation is not running, so there is nothing to interrupt";
        }

        // 🪤 CASE-INSENSITIVE, because PowerShell's -ne is. A probe that
        // answered "Interactive" would fall through to the background-agent
        // refusal in a port that compared ordinally.
        if (!string.Equals(agent.Kind, "interactive", StringComparison.OrdinalIgnoreCase))
        {
            return "that is a background agent - it has no console to press Esc in";
        }

        if (!string.Equals(agent.Status, "busy", StringComparison.OrdinalIgnoreCase))
        {
            return "it is not mid-turn - there is nothing running to interrupt, and Esc at its prompt would clear what you have typed";
        }

        return string.Empty;
    }
}
