using SessionRestore.Core.Sessions;

namespace SessionRestore.Core.Rows;

/// <summary>Everything a sub-agent row draws, as values.</summary>
/// <param name="Name">The agent's label - the only thing on the row in the text hue.</param>
/// <param name="Description">What it was asked to do, or failing that its type.</param>
/// <param name="Tag">kind, state, and whether it left a transcript, joined with the wide dash.</param>
/// <param name="Age">When it last wrote, as the list writes every other age.</param>
/// <param name="Opacity">Dimmed to 0,55 when there is no transcript behind it.</param>
/// <param name="Tip">The hover line: label, description, and the missing-transcript note.</param>
public readonly record struct AgentRowText(
    string Name,
    string Description,
    string Tag,
    string Age,
    double Opacity,
    string Tip);

/// <summary>
/// The sub-agent row, built from the agent alone.
/// </summary>
/// <remarks>
/// 🔑 A SUB-AGENT IS A CONVERSATION, and its row says the three things a
/// session row does not: what kind of mind it is, whether it is still working,
/// and whether it left anything to read. Everything else a session row carries -
/// the accent bar, the unread dot, the context gauge - is deliberately absent,
/// because the column is scanned for what needs you and a sub-agent never does.
///
/// 🪤 TWO COUNTS THAT ARE BOTH RIGHT LIVE NEARBY, and confusing them is the
/// easiest mistake here. The amber dot on the PARENT counts agents that are out
/// RIGHT NOW. These rows are every agent the conversation has ever spawned that
/// is still running, plus the one being read - see the row loop. This type
/// decides neither; it is handed the agent and says how it reads.
/// </remarks>
public static class AgentRow
{
    /// <summary>Dimmed, not hidden: it still says what it was asked to do.</summary>
    /// <remarks>
    /// 45 of 374 sub-agents on this machine have metadata and no transcript.
    /// That is a real state, and drawing them like an empty conversation would
    /// read as a broken reader rather than as an agent that left nothing.
    /// </remarks>
    public const double NoTranscriptOpacity = 0.55;

    /// <summary>The separator between the parts of the tag and the tip.</summary>
    /// <remarks>
    /// 🪤 TWO SPACES, A HYPHEN, TWO SPACES - not an en dash and not one space.
    /// The shipped row builds it by concatenation, and a tag is compared against
    /// the shipped one character for character.
    /// </remarks>
    private const string Gap = "  -  ";

    /// <param name="agent">The sub-agent, as the reader found it on disk.</param>
    /// <param name="live">
    /// Whether it is still writing. Passed in rather than asked of the agent, so
    /// the row and the count on the parent can only ever use ONE definition -
    /// the row loop already holds the live set and filtering twice would drift.
    /// </param>
    /// <param name="nowTicks">Now, for the age. 0 reads the clock.</param>
    public static AgentRowText Of(SubAgent agent, bool live, long nowTicks = 0)
    {
        ArgumentNullException.ThrowIfNull(agent);

        var tag = agent.IsTeammate ? "teammate" : "task";
        var tip = string.Format(
            System.Globalization.CultureInfo.InvariantCulture,
            "{0} - {1}",
            agent.Label,
            string.IsNullOrEmpty(agent.Description) ? "no description recorded" : agent.Description);

        tag += live ? Gap + "working" : Gap + "finished";

        if (!agent.HasTranscript)
        {
            tag += Gap + "no transcript";
            tip += " (this agent left no transcript on disk)";
        }

        return new AgentRowText(
            agent.Label,
            string.IsNullOrEmpty(agent.Description) ? agent.AgentType : agent.Description,
            tag,
            Titles.AgeOf(agent.When.Ticks, nowTicks),
            agent.HasTranscript ? 1.0 : NoTranscriptOpacity,
            tip);
    }
}
