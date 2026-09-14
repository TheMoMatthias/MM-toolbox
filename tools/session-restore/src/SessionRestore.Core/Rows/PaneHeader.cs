using SessionRestore.Core.Sessions;

namespace SessionRestore.Core.Rows;

/// <summary>What the reading pane's header says about what is open.</summary>
/// <param name="Name">The title, large.</param>
/// <param name="Accent">A band key for the dot's colour, or <see cref="PaneHeader.Ask"/>.</param>
/// <param name="State">The one line under it, parts joined by the wide bar.</param>
/// <param name="Pulse">Whether the dot breathes - true only while a turn is actually being written.</param>
public readonly record struct PaneHead(string Name, string Accent, string State, bool Pulse);

/// <summary>
/// The header of the reading pane, for a conversation or for a sub-agent.
/// </summary>
/// <remarks>
/// 🔴 A SUB-AGENT GETS ITS OWN SHAPE, NOT A CONVERSATION'S WITH BLANKS. Every
/// live thing on a session header is meaningless for an agent: it has no
/// process, so nothing can be typed into it, it cannot be waiting on a
/// question, and there is no console to read. The shipped window learned this
/// the hard way - running the session path against an agent spawned a screen
/// probe for a pid that does not exist and put the PARENT's pending question
/// over the agent's transcript.
/// </remarks>
public static class PaneHeader
{
    /// <summary>The dot's colour for a sub-agent: the agent hue, not a band.</summary>
    /// <remarks>
    /// An agent is never in a band - bands are about what a SESSION is doing -
    /// so this is a key of its own rather than a band it does not have.
    /// </remarks>
    public const string Ask = "ask";

    /// <summary>What the header says when no process is holding the conversation.</summary>
    public const string NoProcess = "no process is holding it";

    /// <summary>The separator between the parts of the state line.</summary>
    /// <remarks>
    /// 🪤 THREE SPACES, A BAR, THREE SPACES. The shipped header builds it with
    /// a format string, and the line is compared against it character for
    /// character.
    /// </remarks>
    public const string Bar = "   |   ";

    /// <param name="title">The conversation's title, as the row draws it.</param>
    /// <param name="band">Its band key. An unknown one leaves the label empty, as the shipped one does.</param>
    /// <param name="detail">What the process is doing, from the agent map. Empty means nothing is holding it.</param>
    /// <param name="projectLabel">The project's disambiguated label.</param>
    /// <param name="busy">Whether it is mid-turn.</param>
    public static PaneHead OfSession(string? title, string? band, string? detail, string? projectLabel, bool busy)
    {
        var def = Bands.Ordered.FirstOrDefault(b => string.Equals(b.Key, band, StringComparison.Ordinal));

        // 🔑 A DOT THAT BREATHES WHILE IT IS ACTUALLY THINKING, and only then.
        // The header said WORKING in text, which is a state you have to read;
        // on a surface whose whole job is telling you what is alive, "right
        // now" is the one thing worth animating. A permanent animation would be
        // decoration, and this window has none.
        return new PaneHead(
            title ?? string.Empty,
            band ?? Bands.Quiet,
            string.Join(Bar, def?.Label ?? string.Empty, Empty(detail) ? NoProcess : detail!, projectLabel ?? string.Empty),
            busy);
    }

    /// <param name="agent">The sub-agent being read.</param>
    /// <param name="parentTitle">The conversation it works for, or empty if that could not be read.</param>
    public static PaneHead OfAgent(SubAgent agent, string? parentTitle)
    {
        ArgumentNullException.ThrowIfNull(agent);

        var bits = new List<string> { agent.IsTeammate ? "teammate" : "task sub-agent" };
        if (!Empty(parentTitle))
        {
            bits.Add("working for " + parentTitle);
        }

        if (!Empty(agent.Description))
        {
            bits.Add(agent.Description);
        }

        return new PaneHead(agent.Label, Ask, string.Join(Bar, bits), false);
    }

    private static bool Empty(string? s) => string.IsNullOrEmpty(s);
}
