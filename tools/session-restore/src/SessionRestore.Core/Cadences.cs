namespace SessionRestore.Core;

/// <summary>
/// How often the tool looks at things. Plan item 3.4.
/// </summary>
/// <remarks>
/// 🔑 EVERY ONE OF THESE WAS CHOSEN AGAINST A MEASUREMENT, and that is why they
/// are values in one place rather than literals at eleven call sites. They are
/// the whole of how live the tool feels: too slow and the operator clicks another
/// conversation to find out whether this one is still going; too fast and the
/// window spends its life reading files nobody asked about.
///
/// 🔴 AND THEY ARE COMPARED AGAINST THE SHIPPED WINDOW'S OWN SOURCE. The oracle
/// case `loops/cadences` reads the intervals out of lib\sessions-window.ps1 and
/// diffs them against this table, so a timer changed there and not here shows up
/// as a difference rather than as a rebuild that quietly feels different.
/// </remarks>
public static class Cadences
{
    /// <summary>
    /// The model pass: re-read the registry, re-band every conversation.
    /// </summary>
    /// <remarks>
    /// 🪤 SIX SECONDS IS ALREADY THE FAST ONE, and it was still the thing the
    /// operator felt. Measured 2026-09-08: working->done, idle->working and
    /// ->quiet were reachable at ~17 s and by nothing faster, while
    /// needs->working took 0,1 s. That asymmetry is the whole of "I have to click
    /// a different session to see whether this one is still going" - the two
    /// transitions being watched for were the two on the slowest path.
    /// </remarks>
    public static readonly TimeSpan Fast = TimeSpan.FromSeconds(6);

    /// <summary>
    /// The live probe: ask claude what every session is doing.
    /// </summary>
    /// <remarks>
    /// 🔴 IT IS A SUBPROCESS AND IT IS NOT FREE - <c>claude agents --json</c> was
    /// 295 ms of a 508 ms model refresh, the single dominant cost of the
    /// background pass. Fifteen seconds is what that buys: any faster and the
    /// machine spends a measurable fraction of itself asking.
    /// </remarks>
    public static readonly TimeSpan Live = TimeSpan.FromSeconds(15);

    /// <summary>Following a streamed terminal: one second is a reading pace.</summary>
    public static readonly TimeSpan Follow = TimeSpan.FromSeconds(1);

    /// <summary>Re-measuring a pane after a resize, coalesced.</summary>
    public static readonly TimeSpan Measure = TimeSpan.FromMilliseconds(240);

    /// <summary>
    /// The debounce on a search keystroke and on showing a picked conversation.
    /// </summary>
    /// <remarks>
    /// 🪤 90 ms IS A DEBOUNCE, NOT A DEFERRAL, and the difference matters to the
    /// bench. It coalesces a burst of typing; it does not move work off the
    /// keystroke to make a measurement look better. Anything that only moves the
    /// work makes the bench green while the wait is unchanged.
    /// </remarks>
    public static readonly TimeSpan Debounce = TimeSpan.FromMilliseconds(90);

    /// <summary>Between one launch and the next.</summary>
    /// <remarks>
    /// 🔑 ONE PER TICK RATHER THAN A LOOP. Windows Terminal needs breathing room
    /// between tabs, and a 500 ms sleep per conversation would freeze the window
    /// for nine seconds over seventeen of them.
    /// </remarks>
    public static readonly TimeSpan Launch = TimeSpan.FromMilliseconds(500);

    /// <summary>Typing into a console, character group by character group.</summary>
    public static readonly TimeSpan Write = TimeSpan.FromMilliseconds(30);

    /// <summary>Streaming a console's screen into the pane.</summary>
    public static readonly TimeSpan Cast = TimeSpan.FromMilliseconds(300);

    /// <summary>Polling a screen for a change while something is expected.</summary>
    public static readonly TimeSpan Poll = TimeSpan.FromMilliseconds(200);

    /// <summary>Watching for a question to appear, while one is likely.</summary>
    public static readonly TimeSpan AskPollFast = TimeSpan.FromMilliseconds(400);

    /// <summary>Sending one answer's keystrokes.</summary>
    public static readonly TimeSpan Answer = TimeSpan.FromMilliseconds(50);

    /// <summary>Every cadence by the name the window's timer has.</summary>
    /// <remarks>
    /// 🔑 KEYED BY THE POWERSHELL'S OWN VARIABLE NAME so the drift check can line
    /// the two up without a translation table nobody maintains.
    /// </remarks>
    public static IReadOnlyDictionary<string, TimeSpan> ByTimerName { get; } =
        new Dictionary<string, TimeSpan>(StringComparer.Ordinal)
        {
            ["ansTimer"] = Answer,
            ["followTimer"] = Follow,
            ["measureTimer"] = Measure,
            ["showTimer"] = Debounce,
            ["searchTimer"] = Debounce,
            ["launchTimer"] = Launch,
            ["writeTimer"] = Write,
            ["castTimer"] = Cast,
            ["fastTimer"] = Fast,
            ["liveTimer"] = Live,
            ["pollTimer"] = Poll,
            ["askTimer"] = AskPollFast,
        };
}
