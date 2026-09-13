using System.Globalization;
using System.Text.RegularExpressions;

namespace SessionRestore.Core.Console;

/// <summary>
/// What a session says about itself on its own screen. Ported from
/// <c>Read-SRScreenVitals</c>.
/// </summary>
/// <remarks>
/// 🔴 -1 AND "" MEAN "THE SCREEN DID NOT SAY", which is not zero. The Saw flags
/// say which figures the screen actually printed: a silent status line is a true
/// zero for shells (a session with none prints none) but "ask the transcript" for
/// sub-agents, which the line does not always name.
/// </remarks>
public sealed record ScreenVitals
{
    public int Shells { get; init; }

    public int Agents { get; init; }

    public bool Ok { get; init; }

    public bool SawShells { get; init; }

    public bool SawAgents { get; init; }

    public string Effort { get; init; } = string.Empty;

    public bool SawEffort { get; init; }

    public int TurnSecs { get; init; } = -1;

    public bool TurnDone { get; init; }

    public bool SawTurn { get; init; }

    public int CtxTokens { get; init; } = -1;

    public int CtxWindow { get; init; } = -1;

    public bool SawCtx { get; init; }

    public bool Compacting { get; init; }

    public int CompactPct { get; init; } = -1;

    public int CompactSecs { get; init; } = -1;

    private static readonly Regex ShellCount = new(@"(\d+)\s+shells?\b", RegexOptions.CultureInvariant);
    private static readonly Regex AgentCount = new(@"(\d+)\s+(?:sub-?)?agents?\b", RegexOptions.CultureInvariant);
    private static readonly Regex Timeout = new(@"(?i)\btimeout\b", RegexOptions.CultureInvariant);
    private static readonly Regex TurnDoneClock = new(@"(?i)\bfor\s+(?:(\d+)h\s+)?(?:(\d+)m\s+)?(\d+)s\b[^\n]*?\bdone\b", RegexOptions.CultureInvariant);
    private static readonly Regex TurnRunningClock = new("…" + @"\s*\((?:(\d+)h\s+)?(?:(\d+)m\s+)?(\d+)s\b", RegexOptions.CultureInvariant);
    private static readonly Regex EffortWord = new(@"(?i)\bwith\s+(\w+)\s+effort\b", RegexOptions.CultureInvariant);
    private static readonly Regex CompactMarker = new(@"(?i)\bcompacting\s+conversation\b", RegexOptions.CultureInvariant);
    private static readonly Regex CompactClock = new(@"\((?:(\d+)h\s+)?(?:(\d+)m\s+)?(\d+)s\)", RegexOptions.CultureInvariant);
    private static readonly Regex CompactPercent = new(@"(\d{1,3})\s*%", RegexOptions.CultureInvariant);
    private static readonly Regex ContextBar = new(@"(?m)^\s*Model:.*?\]\s*([\d.,]+)\s*([kKmM]?)\s*/\s*([\d.,]+)\s*([kKmM]?)", RegexOptions.CultureInvariant);

    /// <summary>Reads one screen.</summary>
    /// <remarks>
    /// 🪤 A NUMBER TOO BIG FOR AN INT THROWS, as PowerShell's <c>[int]</c> cast
    /// does - an OverflowException rather than a quiet wrong count. The caller
    /// treats a screen it could not read as filing nothing.
    /// </remarks>
    public static ScreenVitals Read(string? screenText)
    {
        var v = new ScreenVitals();
        if (string.IsNullOrEmpty(screenText))
        {
            return v;
        }

        var lines = screenText.Split('\n');

        // 🔴 THE STATUS LINE, NOT THE WHOLE SCREEN: prose saying "2100 shells"
        // was once read as a shell count. The line claude draws for itself
        // begins with U+23F5 or U+23F8 and sits in the last six non-empty lines.
        var tail = lines.Where(l => l.Trim().Length > 0).TakeLast(6);
        var status = string.Join(" ", tail
            .Select(l => l.Trim())
            .Where(t => t.StartsWith('⏵') || t.StartsWith('⏸')));

        if (status.Length > 0)
        {
            var m = ShellCount.Match(status);
            if (m.Success)
            {
                v = v with { Shells = Int(m.Groups[1].Value), Ok = true, SawShells = true };
            }

            m = AgentCount.Match(status);
            if (m.Success)
            {
                v = v with { Agents = Int(m.Groups[1].Value), Ok = true, SawAgents = true };
            }

            // A handful of shells, not thousands - a number this size means the
            // line was misread.
            if (v.Shells > 99)
            {
                v = v with { Shells = 0, SawShells = false };
            }

            if (v.Agents > 99)
            {
                v = v with { Agents = 0, SawAgents = false };
            }
        }

        // THE TURN CLOCK, off the spinner line. The LAST matching line wins.
        // 🪤 A tool's own timer has the same shape: it hangs off the U+23BF elbow
        // and says "timeout", and either excludes it.
        foreach (var ln in lines)
        {
            var t = ln.Trim();
            if (t.Length == 0 || t.StartsWith('⎿') || Timeout.IsMatch(t))
            {
                continue;
            }

            var d = TurnDoneClock.Match(t);
            if (d.Success)
            {
                v = v with { TurnSecs = Clock(d), TurnDone = true, SawTurn = true, Ok = true };
            }

            var r = TurnRunningClock.Match(t);
            if (r.Success)
            {
                v = v with { TurnSecs = Clock(r), TurnDone = false, SawTurn = true, Ok = true };
            }
        }

        var e = EffortWord.Match(screenText);
        if (e.Success)
        {
            v = v with { Effort = e.Groups[1].Value.ToLowerInvariant(), SawEffort = true, Ok = true };
        }

        // A COMPACT PRINTS ITS OWN PROGRESS. 🪤 The per cent is looked for only at
        // or just below the marker: the context bar ends in a per cent too.
        var cIdx = Array.FindIndex(lines, l => CompactMarker.IsMatch(l));
        if (cIdx >= 0)
        {
            v = v with { Compacting = true, Ok = true };
            var cm = CompactClock.Match(lines[cIdx]);
            if (cm.Success)
            {
                v = v with { CompactSecs = Clock(cm) };
            }

            for (var cj = cIdx; cj < Math.Min(lines.Length, cIdx + 3); cj++)
            {
                var cp = CompactPercent.Match(lines[cj]);
                if (cp.Success)
                {
                    var cv = Int(cp.Groups[1].Value);
                    if (cv is >= 0 and <= 100)
                    {
                        v = v with { CompactPct = cv };
                    }

                    break;
                }
            }
        }

        // THE CONTEXT, off the session's own bar: count AND window, both of which
        // the transcript can only guess at.
        var c = ContextBar.Match(screenText);
        if (c.Success)
        {
            var tk = Number(c.Groups[1].Value, c.Groups[2].Value);
            var wn = Number(c.Groups[3].Value, c.Groups[4].Value);
            if (tk >= 0 && wn > 0 && tk <= wn)
            {
                v = v with { CtxTokens = tk, CtxWindow = wn, SawCtx = true, Ok = true };
            }
        }

        return v;
    }

    /// <summary>h, m and s groups to seconds - PowerShell's <c>[int]</c> on each.</summary>
    private static int Clock(Match m) =>
        checked(((m.Groups[1].Success ? Int(m.Groups[1].Value) : 0) * 3600)
                + ((m.Groups[2].Success ? Int(m.Groups[2].Value) : 0) * 60)
                + Int(m.Groups[3].Value));

    /// <summary>PowerShell's <c>[int]"digits"</c>: invariant, and it throws on overflow.</summary>
    private static int Int(string digits) => int.Parse(digits, NumberStyles.Integer, CultureInfo.InvariantCulture);

    /// <summary>
    /// The bar's figures: <c>638k</c>, <c>1.0M</c>, <c>1,234</c>. -1 when it will not parse.
    /// </summary>
    /// <remarks>
    /// 🪤 A SEPARATOR FOLLOWED BY EXACTLY THREE DIGITS IS A THOUSANDS SEPARATOR
    /// and is removed; any other one is the decimal point. Then scaled, and rounded
    /// half to even - PowerShell's <c>[Math]::Round</c>.
    /// </remarks>
    private static int Number(string digits, string unit)
    {
        var d = digits.Replace(',', '.');
        var dot = d.LastIndexOf('.');
        if (dot >= 0 && d.Length - dot - 1 == 3)
        {
            d = d.Remove(dot, 1);
        }

        if (!double.TryParse(d, NumberStyles.Float, CultureInfo.InvariantCulture, out var val))
        {
            return -1;
        }

        var scaled = unit.ToLowerInvariant() switch
        {
            "k" => Math.Round(val * 1000),
            "m" => Math.Round(val * 1000000),
            _ => Math.Round(val),
        };

        return scaled is > int.MaxValue or < int.MinValue
            ? throw new OverflowException("the context bar printed a figure no int can hold")
            : (int)scaled;
    }
}
