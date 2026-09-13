using SessionRestore.Core.Rows;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.App.ViewModels;

/// <summary>
/// What the background readers filed for one conversation beyond its registry
/// row, its agent report and its last words.
/// </summary>
/// <param name="Queue">What is waiting behind its turn.</param>
/// <param name="Screen">The sweep's last reading of its own screen, however old - the row applies the TTL.</param>
/// <param name="LiveSubAgents">Sub-agents whose transcripts are still being written.</param>
/// <param name="Context">The transcript's context reading, as the warm pass cached it.</param>
/// <param name="WindowSeen">A context window the session has ever PRINTED - it outranks the derived one.</param>
public sealed record RowExtras(
    QueueState? Queue,
    RowScreen? Screen,
    int LiveSubAgents,
    CachedContext? Context,
    int? WindowSeen);
