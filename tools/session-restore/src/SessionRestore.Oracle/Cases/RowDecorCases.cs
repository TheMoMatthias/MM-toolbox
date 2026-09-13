using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Rows;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 4.1 (2b-2) - the row's second line and right-hand marks, against the
/// shipped row loop itself.
/// </summary>
/// <remarks>
/// 🔴 BUILD-SESSIONS IS SPLICED, NOT COPIED. The said line, the counts and the
/// context resolution are inline in the row loop, and the bar's four fields are
/// entries in the hashtable literal that builds the row object - so the case cuts
/// both regions out of <c>lib/sessions-window.ps1</c> by their first and last
/// lines and runs them over each spec. A change to the shipped loop that the port
/// does not follow goes red; a copy here would only test what I believe it does.
///
/// 🪤 THE ONE SUBSTITUTION: <c>$Pal</c> holds real WPF brushes built here, and
/// the answer names which one came back. The shipped code casts to
/// <c>[System.Windows.Media.Brush]</c>, so a stand-in string would not survive it.
/// </remarks>
public static class RowDecorCases
{
    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Decor(), true, "said, context bar, sub-agent and shell marks, against Build-Sessions' own lines");
    }

    private sealed record Scr(int Shells, int Agents, int CtxTokens, int CtxWindow, bool Compacting, int Pct, int Secs, int AgeSec);

    private sealed record Vit(long Tokens, int Window, bool SameJsonl, int AgeSec);

    private sealed record Spec(string Name, string? Said, string? Detail, Scr? Screen, int LiveSubs, Vit? Cached, int? WindowSeen);

    private static readonly Spec[] Specs =
    [
        new("nothing-known", null, null, null, 0, null, null),
        new("said-wins-over-detail", "  all   done\n", "idle", null, 0, null, null),
        new("detail-when-nothing-said", "   ", "waiting on you", null, 0, null, null),
        new("screen-context", "x", null, new(0, -1, 150000, 1000000, false, -1, -1, 5), 0, null, null),
        new("screen-context-warn", "x", null, new(0, -1, 250000, 1000000, false, -1, -1, 5), 0, null, null),
        new("screen-context-bad", "x", null, new(0, -1, 700000, 1000000, false, -1, -1, 5), 0, null, null),
        new("screen-at-the-warn-line", "x", null, new(0, -1, 200000, 1000000, false, -1, -1, 5), 0, null, null),
        new("screen-past-its-ttl-falls-back", "x", null, new(3, 2, 150000, 1000000, true, 50, 10, 46), 1, new(90000, 200000, true, 3), null),
        new("screen-exactly-at-its-ttl", "x", null, new(3, 2, 150000, 1000000, false, -1, -1, 45), 0, null, null),
        new("cached-context", "x", null, null, 0, new(90000, 200000, true, 3), null),
        new("cached-with-a-printed-window", "x", null, null, 0, new(90000, 200000, true, 3), 1000000),
        new("cached-for-another-transcript", "x", null, null, 0, new(90000, 200000, false, 3), null),
        new("cached-past-its-ttl", "x", null, null, 0, new(90000, 200000, true, 21), null),
        new("cached-with-no-tokens", "x", null, null, 0, new(0, 200000, true, 3), null),
        new("screen-without-a-window-uses-cached", "x", null, new(1, -1, -1, -1, false, -1, -1, 5), 0, new(90000, 200000, true, 3), null),
        new("over-full-is-capped", "x", null, new(0, -1, 950000, 900000, false, -1, -1, 5), 0, null, null),
        new("compacting-with-percent", "old words", null, new(0, -1, 600000, 1000000, true, 66, 97, 5), 0, null, null),
        new("compacting-before-a-percent", "old words", null, new(0, -1, -1, -1, true, -1, 5, 5), 0, null, null),
        new("compacting-an-hour-in", "old", null, new(0, -1, -1, -1, true, 100, 3725, 5), 0, null, null),
        new("one-agent-one-shell", "x", null, new(1, 1, -1, -1, false, -1, -1, 5), 0, null, null),
        new("counts-past-one", "x", null, new(4, 3, -1, -1, false, -1, -1, 5), 0, null, null),
        new("screen-silent-on-agents-uses-transcript", "x", null, new(0, -1, -1, -1, false, -1, -1, 5), 2, null, null),
        new("screen-says-no-agents-overrides-transcript", "x", null, new(0, 0, -1, -1, false, -1, -1, 5), 2, null, null),
        new("no-screen-uses-transcript-agents", "x", null, null, 1, null, null),
    ];

    private static string PsSpecs()
    {
        var sb = new StringBuilder();
        var inv = CultureInfo.InvariantCulture;
        foreach (var s in Specs)
        {
            sb.Append(inv, $"@{{ n = '{s.Name}'; said = {(s.Said is null ? "$null" : PsText.Literal(s.Said))}; ");
            sb.Append(inv, $"detail = {(s.Detail is null ? "$null" : PsText.Literal(s.Detail))}; subs = {s.LiveSubs}; ");
            sb.Append(inv, $"wt = {(s.WindowSeen is { } w ? w.ToString(inv) : "$null")}; ");
            if (s.Screen is { } c)
            {
                sb.Append(inv, $"scr = @{{ Shells = {c.Shells}; Agents = {c.Agents}; CtxTokens = {c.CtxTokens}; CtxWindow = {c.CtxWindow}; ");
                sb.Append(inv, $"Compacting = ${c.Compacting.ToString().ToLowerInvariant()}; CompactPct = {c.Pct}; CompactSecs = {c.Secs}; Age = {c.AgeSec} }}; ");
            }
            else
            {
                sb.Append("scr = $null; ");
            }

            if (s.Cached is { } v)
            {
                sb.Append(inv, $"vit = @{{ Tokens = {v.Tokens}; Window = {v.Window}; Same = ${v.SameJsonl.ToString().ToLowerInvariant()}; Age = {v.AgeSec} }} }},\n");
            }
            else
            {
                sb.Append("vit = $null },\n");
            }
        }

        return sb.ToString();
    }

    private static OracleCase Decor() => new(
        "row/decorations",
        "said, context bar, sub-agent and shell marks, against Build-Sessions' own lines",
        """
        Add-Type -AssemblyName PresentationCore
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        foreach ($fn in @('Get-SRRowCtx', 'Get-CtxBrush', 'Get-SRCompactText')) {
            $a = $winSrc.IndexOf("function $fn")
            if ($a -lt 0) { throw "could not find $fn in sessions-window.ps1" }
            $b = $winSrc.IndexOf("`n}", $a)
            Invoke-Expression $winSrc.Substring($a, $b - $a + 2)
        }
        $fromA = $winSrc.IndexOf('            $scr = $null')
        # The end marker is found by its ASCII words and backed up to its line: an
        # emoji in a literal sent down the oracle's pipe is one codepage from not matching.
        $toA = $winSrc.IndexOf('WHAT IS QUEUED BEHIND IT.', $fromA)
        if ($toA -ge 0) { $toA = $winSrc.LastIndexOf("`n", $toA) + 1 }
        $fromB = $winSrc.IndexOf('                CtxVis = $(if ($rowCompact', $toA)
        $toB = $winSrc.IndexOf('                SubVis = $V_Hide; SubName = ', $fromB)
        if ($fromA -lt 0 -or $toA -lt 0 -or $fromB -lt 0 -or $toB -lt 0) { throw 'could not find the row regions in Build-Sessions' }
        $regionA = $winSrc.Substring($fromA, $toA - $fromA)
        $regionB = $winSrc.Substring($fromB, $toB - $fromB)

        function New-SRBrush($r) { $x = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb($r, 0, 0)); $x.Freeze(); $x }
        $Pal = @{ Ask = (New-SRBrush 1); Bad = (New-SRBrush 2); Warn = (New-SRBrush 3); Ok = (New-SRBrush 4) }
        $V_Show = 'Visible'; $V_Hide = 'Collapsed'
        $SR_RowScreenTTL = 45; $SR_VitalsTTL = 20; $SR_CtxWarnTokens = 200000; $SR_CtxBadTokens = 600000; $SR_CompactCells = 10
        $now = Get-Date
        $specs = @(
        """ + PsSpecs() + """
        $null)
        $rows = @()
        foreach ($s in $specs) {
            if (-not $s) { continue }
            $r = [PSCustomObject]@{
                Id = 'row'
                Said = $(if ($null -ne $s.said) { [PSCustomObject]@{ Said = $s.said } } else { $null })
                Conv = $(if ($null -ne $s.detail) { [PSCustomObject]@{ Detail = $s.detail } } else { $null })
                S = [PSCustomObject]@{ jsonl = 'C:\t\row.jsonl' }
            }
            $script:rowScreen = @{}
            if ($s.scr) {
                $x = $s.scr
                $script:rowScreen['row'] = @{ At = $now.AddSeconds(-$x.Age); Shells = $x.Shells; Agents = $x.Agents
                    CtxTokens = $x.CtxTokens; CtxWindow = $x.CtxWindow; Compacting = $x.Compacting
                    CompactPct = $x.CompactPct; CompactSecs = $x.CompactSecs }
            }
            $script:vitalsCache = @{}
            if ($s.vit) {
                $script:vitalsCache['row'] = @{ V = [PSCustomObject]@{ Tokens = $s.vit.Tokens; Window = $s.vit.Window }
                    At = $now.AddSeconds(-$s.vit.Age); J = $(if ($s.vit.Same) { 'C:\t\row.jsonl' } else { 'C:\t\other.jsonl' }) }
            }
            $script:ctxWindowTrue = @{}
            if ($null -ne $s.wt) { $script:ctxWindowTrue['row'] = $s.wt }
            $subsAll = @()
            for ($i = 0; $i -lt $s.subs; $i++) { $subsAll += [PSCustomObject]@{ Live = $true } }
            $subsAll += [PSCustomObject]@{ Live = $false }
            $nowDate = $now

            Invoke-Expression $regionA
            $h = Invoke-Expression ('@{' + $regionB + '}')
            $hue = 'none'
            foreach ($k in $Pal.Keys) { if ([object]::ReferenceEquals($h.CtxBrush, $Pal[$k])) { $hue = $k } }
            $rows += [ordered]@{
                name = "$($s.n)"; said = "$saidText"
                ctxVis = "$($h.CtxVis)"; ctxWidth = [string][BitConverter]::DoubleToInt64Bits([double]$h.CtxWidth)
                ctxHue = $hue; ctxTip = "$($h.CtxTip)"
                agentVis = "$($h.AgentVis)"; agentText = "$($h.AgentText)"
                shellVis = "$($h.ShellVis)"; shellText = "$($h.ShellText)"
            }
        }
        (@{ now = $now.Ticks; rows = $rows } | ConvertTo-Json -Compress -Depth 4)
        """,
        psOut =>
        {
            var now = new DateTime(JsonNode.Parse(psOut)?["now"]?.GetValue<long>() ?? 0, DateTimeKind.Local);
            var rows = new JsonArray();
            const string jsonl = "C:\\t\\row.jsonl";
            foreach (var s in Specs)
            {
                var scr = s.Screen is { } c
                    ? new RowScreen(c.Shells, c.Agents, c.CtxTokens, c.CtxWindow, c.Compacting, c.Pct, c.Secs, now.AddSeconds(-c.AgeSec))
                    : null;
                var cached = s.Cached is { } v
                    ? new CachedContext(v.Tokens, v.Window, v.SameJsonl ? jsonl : "C:\\t\\other.jsonl", now.AddSeconds(-v.AgeSec))
                    : null;
                var d = RowDecor.Of(s.Said, s.Detail, scr, s.LiveSubs, cached, jsonl, s.WindowSeen, now);
                rows.Add(new JsonObject
                {
                    ["name"] = s.Name,
                    ["said"] = d.Said,
                    ["ctxVis"] = d.CtxVisible ? "Visible" : "Collapsed",
                    // 🪤 THE BITS, NOT "R". .NET Framework prints a double to 17 digits and
                    // .NET 8 to the shortest that round-trips, so the same 6.8000000000000007
                    // read as a difference that was not one.
                    ["ctxWidth"] = BitConverter.DoubleToInt64Bits(d.CtxWidth).ToString(CultureInfo.InvariantCulture),
                    ["ctxHue"] = d.CtxHue switch
                    {
                        ContextHue.Compacting => "Ask",
                        ContextHue.Bad => "Bad",
                        ContextHue.Warn => "Warn",
                        _ => "Ok",
                    },
                    ["ctxTip"] = d.CtxTip,
                    ["agentVis"] = d.AgentVisible ? "Visible" : "Collapsed",
                    ["agentText"] = d.AgentText,
                    ["shellVis"] = d.ShellVisible ? "Visible" : "Collapsed",
                    ["shellText"] = d.ShellText,
                });
            }

            return new JsonObject { ["now"] = now.Ticks, ["rows"] = rows }.ToJsonString(Compact);
        });
}
