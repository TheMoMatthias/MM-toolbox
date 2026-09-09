namespace SessionRestore.Core.Transcripts;

/// <summary>What kind of thing one block of a conversation is.</summary>
/// <remarks>
/// 🔴 EVERYTHING THAT IS NOT A user OR assistant RECORD USED TO BE DROPPED, and
/// a great deal happens in those records: a compact writes a system record, a
/// hook writes an attachment, an inbound message arrives as a queue operation.
/// None of it reached the pane, so the operator compacted a session and watched
/// nothing happen. Each of these kinds exists because something real was
/// invisible without it.
/// </remarks>
public enum BlockKind
{
    /// <summary>The operator's own words.</summary>
    You,

    /// <summary>What claude said.</summary>
    Said,

    /// <summary>Reasoning, folded by default.</summary>
    Thinking,

    /// <summary>A tool call.</summary>
    Tool,

    /// <summary>What a tool answered.</summary>
    Result,

    /// <summary>A question the operator answered, with the answers.</summary>
    Asked,

    /// <summary>A message from another session.</summary>
    MsgIn,

    /// <summary>Something the machine wrote into the transcript.</summary>
    System,

    /// <summary>A hook's own output.</summary>
    Hook,

    /// <summary>A file read or edited, named rather than pasted.</summary>
    File,

    /// <summary>A prompt queued while the session was busy.</summary>
    Queued,

    /// <summary>The conversation was compacted here.</summary>
    Compact,
}

/// <summary>
/// One readable thing out of a transcript: what it is, what it says, and when.
/// </summary>
/// <param name="Kind">What sort of block this is.</param>
/// <param name="Head">Its label - a tool name, a hook name, who sent it.</param>
/// <param name="Body">The text itself, uncut.</param>
/// <param name="Meta">A summary the renderer may use instead of the body.</param>
/// <param name="When">The record's timestamp, in local time.</param>
/// <remarks>
/// 🔴 THE FULL ARGUMENT REACHES THE RENDERER. An earlier version compressed the
/// path and cut at 150 characters HERE, so the command was already destroyed
/// before anything could choose to show it - a reported truncation survived
/// every fix made in the pane, because the pane never had the rest of it.
/// Deciding how much to show is the renderer's job; this one's is to carry it.
/// <see cref="Meta"/> holds the one-line form for callers that want a summary.
/// </remarks>
public sealed record TranscriptBlock(
    BlockKind Kind,
    string Head,
    string Body,
    string Meta,
    DateTimeOffset? When);
