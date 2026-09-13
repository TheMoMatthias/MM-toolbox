using System.Globalization;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.Core.Rows;

/// <summary>
/// What the sweep filed for one session off its own screen.
/// </summary>
/// <param name="Agents">-1 when the status line did not name sub-agents - "ask the transcript", not "none".</param>
/// <param name="At">When it was read, local time. Past <see cref="RowDecor.ScreenTtlSeconds"/> it is not evidence.</param>
public sealed record RowScreen(
    int Shells, int Agents, int CtxTokens, int CtxWindow,
    bool Compacting, int CompactPct, int CompactSecs, DateTime At);

/// <summary>The transcript's context reading for one session, as the warm pass cached it.</summary>
/// <param name="Jsonl">The transcript it was read from - a row that moved to another one cannot use it.</param>
public sealed record CachedContext(long Tokens, int Window, string Jsonl, DateTime At);

/// <summary>The context bar's hue.</summary>
public enum ContextHue
{
    Ok,
    Warn,
    Bad,

    /// <summary>A compact is running and the bar is its progress, not a reading.</summary>
    Compacting,
}

/// <summary>
/// The second line and the right-hand marks of a session row: what it said, the
/// context bar, and the sub-agent and shell marks. Ported from the row loop of
/// <c>Build-Sessions</c>, with <c>Get-SRRowCtx</c>, <c>Get-CtxBrush</c> and
/// <c>Get-SRCompactText</c>.
/// </summary>
public sealed record RowDecor(
    string Said,
    bool CtxVisible, double CtxWidth, ContextHue CtxHue, string CtxTip,
    bool AgentVisible, string AgentText,
    bool ShellVisible, string ShellText)
{
    /// <summary><c>$SR_RowScreenTTL</c>.</summary>
    public const int ScreenTtlSeconds = 45;

    /// <summary><c>$SR_VitalsTTL</c>.</summary>
    public const int ContextTtlSeconds = 20;

    /// <summary><c>$SR_CtxWarnTokens</c> and <c>$SR_CtxBadTokens</c>.</summary>
    /// <remarks>
    /// 🔴 ABSOLUTE, NOT FRACTIONS OF THE WINDOW. 85% of 200k is 170k and fine;
    /// 85% of 1M is 850k and nearly out. The colour answers "how many tokens".
    /// </remarks>
    public const long WarnTokens = 200000;

    public const long BadTokens = 600000;

    /// <summary><c>$SR_CompactCells</c>.</summary>
    public const int CompactCells = 10;

    public static ContextHue HueFor(long tokens) =>
        tokens > BadTokens ? ContextHue.Bad : tokens > WarnTokens ? ContextHue.Warn : ContextHue.Ok;

    /// <summary>
    /// How a compact's progress is worded, on the row and in the pane header.
    /// </summary>
    /// <remarks>
    /// 🪤 NO PER CENT IS NOT NOUGHT PER CENT. The number appears a beat after the
    /// marker; until then this says "compacting" and nothing else.
    /// </remarks>
    public static string CompactText(int pct, int secs, bool bar = false)
    {
        var inv = CultureInfo.InvariantCulture;
        var t = "compacting";
        if (bar)
        {
            var n = pct >= 0 ? (int)Math.Round(CompactCells * (Math.Min(100, pct) / 100.0), MidpointRounding.ToEven) : 0;
            t += "  " + new string('█', n) + new string('░', CompactCells - n);
        }

        if (pct >= 0)
        {
            t += string.Format(inv, "  {0}%", Math.Min(100, pct));
        }

        if (secs > 0)
        {
            t += secs >= 60
                ? string.Format(inv, "  {0}m {1}s", (int)Math.Floor(secs / 60.0), secs % 60)
                : string.Format(inv, "  {0}s", secs);
        }

        return t;
    }

    /// <summary>
    /// The context bar's two numbers: the screen's while it is fresh, the transcript's otherwise.
    /// </summary>
    /// <remarks>
    /// 🔴 A WINDOW THE SESSION PRINTED OUTRANKS THE DERIVED ONE, wherever one has
    /// ever been seen - <paramref name="windowSeen"/> - because the transcript
    /// reads a 1M conversation under 200k as 200k.
    /// </remarks>
    public static (long Tokens, int Window) Context(RowScreen? screen, CachedContext? cached, string? rowJsonl, int? windowSeen, DateTime now)
    {
        if (screen is not null && screen.CtxWindow > 0)
        {
            return (screen.CtxTokens, screen.CtxWindow);
        }

        if (cached is null
            || !string.Equals(cached.Jsonl, rowJsonl ?? string.Empty, StringComparison.OrdinalIgnoreCase)
            || (now - cached.At).TotalSeconds > ContextTtlSeconds
            || cached.Tokens <= 0)
        {
            return (0, 0);
        }

        var win = windowSeen is > 0 ? windowSeen.Value : cached.Window;
        return win <= 0 ? (0, 0) : (cached.Tokens, win);
    }

    /// <summary>Everything the row draws beside its name and under it.</summary>
    /// <param name="screenFiled">The sweep's last reading, however old - the TTL is applied here.</param>
    /// <param name="liveSubAgents">Sub-agents whose transcripts are still being written.</param>
    public static RowDecor Of(
        string? said, string? detail, RowScreen? screenFiled, int liveSubAgents,
        CachedContext? cached, string? rowJsonl, int? windowSeen, DateTime now)
    {
        var scr = screenFiled is not null && (now - screenFiled.At).TotalSeconds <= ScreenTtlSeconds ? screenFiled : null;

        var text = Headline.Of(said, detail);

        // 🔴 WHAT IT IS DOING BEATS WHAT IT LAST SAID: a compact writes nothing to
        // the transcript until it lands, so the row would otherwise show a line
        // from before it started and read as a session that had stopped.
        var compacting = scr is not null && scr.Compacting;
        if (compacting)
        {
            text = CompactText(scr!.CompactPct, scr.CompactSecs);
        }

        var shells = scr?.Shells ?? 0;
        var compactFrac = compacting && scr!.CompactPct >= 0 ? Math.Min(1.0, scr.CompactPct / 100.0) : 0.0;
        var agents = scr is not null && scr.Agents >= 0 ? scr.Agents : liveSubAgents;

        var (tok, win) = Context(scr, cached, rowJsonl, windowSeen, now);
        var frac = win > 0 ? (double)tok / win : 0.0;
        var inv = CultureInfo.InvariantCulture;

        return new RowDecor(
            text,
            CtxVisible: compacting || win > 0,
            CtxWidth: compacting ? Math.Max(2.0, 34.0 * compactFrac) : Math.Max(2.0, 34.0 * Math.Min(1.0, frac)),
            CtxHue: compacting ? ContextHue.Compacting : HueFor(tok),
            CtxTip: compacting
                ? "How far through compacting this conversation is"
                : "How much of its context window this conversation has used",
            AgentVisible: agents > 0,
            AgentText: agents > 1 ? agents.ToString(inv) : string.Empty,
            ShellVisible: shells > 0,
            ShellText: shells > 1 ? shells.ToString(inv) : string.Empty);
    }
}
