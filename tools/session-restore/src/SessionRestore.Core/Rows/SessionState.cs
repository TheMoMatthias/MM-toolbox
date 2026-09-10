using System.Globalization;
using SessionRestore.Core.Sessions;

namespace SessionRestore.Core.Rows;

/// <summary>What a conversation is doing, and how much that is worth believing.</summary>
/// <remarks>
/// 🔴 STATE AND STALENESS ARE SEPARATE, and collapsing them was the first
/// version's mistake: anything outside the live window became a single 'idle',
/// which threw away the waiting/working distinction for 110 of 119 conversations
/// - the exact distinction this exists to provide. State is always what the
/// conversation was last doing; <see cref="Stale"/> says whether that is current.
/// A row renders "waiting" and "was waiting" from the same two fields.
/// </remarks>
public sealed record ConvState(
    string State,
    string Detail,
    bool Stale,
    bool Needs,
    bool Stuck,
    DateTimeOffset? StuckSince,
    string Source,
    int Pid);

/// <summary>Plan item 2.6 - resolving what a conversation is doing.</summary>
public static class SessionState
{
    /// <summary>Nothing is running it and nothing was read.</summary>
    public static readonly ConvState Nothing =
        new("unknown", "nothing known", true, false, false, null, "none", 0);

    /// <summary>
    /// What claude says about a session, corroborated.
    /// </summary>
    /// <remarks>
    /// 🔴 A NEEDS CLAIM MUST BE CORROBORATED. <c>claude agents --json</c> keeps
    /// reporting background agents that went <c>blocked</c> and were never
    /// reaped. Measured 2026-08-23: a session in state <c>blocked</c> with
    /// <c>startedAt</c> 33 DAYS earlier, no pid, and no transcript left on disk -
    /// sitting in NEEDS YOU, the band that means ACT ON THIS, while the typing
    /// path refused to touch it for the very reason that made it unactionable.
    /// 🔑 The window knew it could not be acted on and filed it under
    /// act-on-this.
    ///
    /// Corroboration is the weakest true thing: either there is a process to type
    /// into, or there is a transcript that was actually read. NEITHER, and the
    /// claim is a leftover rather than a demand. 🪤 Note a running BACKGROUND
    /// agent reports no pid, so the pid alone would condemn every one of them -
    /// which is why the transcript is the second half of the test rather than an
    /// afterthought.
    /// </remarks>
    /// <param name="readable">Whether a transcript was actually read for this
    /// conversation. 🪤 NOT "whether a reader returned an object" - the
    /// transcript reader answers even when the file is gone (state 'unknown'),
    /// which was true for exactly the case this guard exists to catch. The window
    /// passes no transcript at all here, so this is false in practice and the pid
    /// carries the whole test.</param>
    public static ConvState Of(AgentStatus? agent, bool readable = false)
    {
        if (agent is null)
        {
            return Nothing;
        }

        var backed = agent.Pid > 0 || readable;
        var stuck = agent.Needs && !backed;

        var state = "unknown";
        var detail = agent.Status.Length > 0
            ? "claude reports '" + agent.Status + "'"
            : "running, status unknown";

        switch (agent.Status)
        {
            case "busy":
                state = "working";
                detail = "running";
                break;
            case "blocked":
                state = "waiting";
                detail = "blocked, needs you";
                break;
            case "waiting":
                state = "waiting";
                // 🔑 THE DISTINCTION A TRANSCRIPT CAN NEVER MAKE. A dialog wants
                // a CLICK, not a sentence, and telling those apart is the whole
                // reason this source is better than reading the file.
                detail = agent.WaitingFor.Contains("dialog", StringComparison.OrdinalIgnoreCase)
                    ? "a dialog is open, it wants an answer"
                    : agent.WaitingFor.Length > 0 ? agent.WaitingFor : "waiting for you";
                break;
            case "idle":
                state = "idle";
                detail = "at its prompt, nothing pending";
                break;
            default:
                // An unrecognised status is REPORTED, not silently mapped: claude
                // is free to add one and a guess here would be a lie.
                break;
        }

        if (stuck)
        {
            var since = agent.StartedAt is not null
                ? agent.StartedAt.Value.LocalDateTime.ToString("d MMM", CultureInfo.CurrentCulture)
                : "some time ago";
            detail = "stuck since " + since + " - nothing is running it, and there is no transcript left to read";
        }

        return new ConvState(
            state,
            detail,
            // Stale, deliberately: an unbacked report is the LAST thing that was
            // seen, not something happening now. It needs no new state value -
            // the row already draws a stale state as "was waiting" in the dim
            // brush, and the band sends anything stale to quiet.
            stuck,
            agent.Needs && backed,
            stuck,
            stuck ? agent.StartedAt : null,
            "agent",
            agent.Pid);
    }
}
