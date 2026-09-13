using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Console;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 4.1 (2b-2) - <c>Read-SRScreenVitals</c>: what a session prints about
/// itself. Feeds the row's shell and sub-agent marks, the context bar, and the
/// compact progress.
/// </summary>
/// <remarks>
/// 🔴 THE SHAPES CASE CARRIES THE WEIGHT. On a quiet machine the live screens show
/// no shell, no compact and one or two context bars, so a green over them proves
/// the empty paths. Every branch of the parser gets a screen spelled for it here.
///
/// 🪤 THE LIVE CASE HANDS THE C# THE POWERSHELL'S SCREEN TEXT. That is the
/// QUESTION, not the answer - the parse is computed on each side - and it is the
/// only way to compare readers of a screen that redraws between two reads.
/// </remarks>
public static class VitalsCases
{
    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Shapes(), true, "every figure a screen can print, including the misreads it refuses");
        yield return (Live(), true, "what each live session's own screen says about it");
    }

    /// <summary>How many live screens were parsed by both.</summary>
    public static int LiveCompared { get; private set; }

    private const string StatusAuto = "⏵⏵ auto mode on · 1 shell · ← for agents · 1 feedback draft";

    private static readonly (string Name, string Screen)[] Screens =
    [
        ("empty", string.Empty),
        ("status-one-shell", "> hello\n\n" + StatusAuto + "\n"),
        ("status-paused-counts", "text\n⏸ plan mode on · 2 shells · 3 agents\n"),
        ("sub-agent-spellings", "x\n⏵⏵ on · 1 subagent\ny\n"),
        ("sub-hyphen-agents", "x\n⏵⏵ on · 4 sub-agents\n"),
        ("prose-is-not-the-status-line", "we launched 2100 shells and 7 agents today\n" + "⏵⏵ auto mode on\n"),
        ("absurd-count-refused", "⏵⏵ on · 150 shells · 120 agents\n"),
        ("status-above-the-last-six", "⏵⏵ on · 5 shells\n1\n2\n3\n4\n5\n6\n"),
        ("status-within-the-last-six-with-blanks", "⏵⏵ on · 5 shells\n\n1\n\n2\n3\n4\n5\n"),
        ("capital-shells-is-not-a-count", "⏵⏵ on · 2 Shells\n"),
        ("turn-done", "✻ Cooked for 3m 9s · done 9:03 PM\n"),
        ("turn-done-hours", "✻ Pondered for 1h 2m 3s · done 11:00 AM\n"),
        ("turn-running", "✢ Deciphering… (32s · ↓ 1.7k tokens · thinking with xhigh effort)\n"),
        ("turn-running-then-done-last-wins", "✢ Deciphering… (1m 2s)\n✻ Cooked for 3m 9s · done 9:03 PM\n"),
        ("tool-timer-is-not-the-turn", "⎿  Running… (2s · timeout 5m)\n  Running… (7s) Timeout\n"),
        ("effort-in-the-banner", "Opus 5 (1M context) with High effort · Claude Max\n"),
        ("compacting-with-bar", "* Compacting conversation… (1m 37s)\n  ████░░ 66%\n"),
        ("compacting-no-percent-yet", "* Compacting conversation… (5s)\n\nModel: Opus | [█░] 804k/1.0M (80%)\n"),
        ("compacting-percent-too-far-below", "Compacting conversation (2h 0m 1s)\nx\ny\n  50%\n"),
        ("compacting-percent-out-of-range", "compacting CONVERSATION\n  150%\n  40%\n"),
        ("context-bar", "Model: Opus 5 | [████░░] 638k/1.0M (64%) | ⎇ main | (+0,-0)\n"),
        ("context-decimal-k", "  Model: Opus | [█] 123.5k / 200k (61%)\n"),
        ("context-thousands-separator", "Model: x | [█] 1,234/200k\n"),
        ("context-over-window-refused", "Model: x | [█] 900k/200k\n"),
        ("context-zero", "Model: x | [] 0/200k\n"),
        ("context-lowercase-model-is-not-the-bar", "model: x | [█] 10k/200k\n"),
        ("context-garbled-number", "Model: x | [█] 1.2.3k/200k\n"),
        ("crlf-screen", "text\r\n⏵⏵ on · 3 shells\r\n✻ Cooked for 4s · done 1:00 PM\r\n"),
        ("everything-at-once",
            "Opus 5 with max effort\nModel: Opus 5 | [█░] 200k/1.0M (20%)\n✢ Thinking… (2m 5s)\n* Compacting conversation… (9s)\n 12%\n"
            + StatusAuto + "\n"),
        ("an-int-overflow-throws-on-both-sides", "✻ Cooked for 99999999999s · done\n"),
    ];

    /// <summary>The PowerShell's half of <see cref="Row"/>.</summary>
    private const string RowFunction = """
        function ConvertTo-SRVitalsRow($name, $text) {
            try { $v = Read-SRScreenVitals -ScreenText $text } catch { return [ordered]@{ name = "$name"; threw = $true } }
            return [ordered]@{
                name = "$name"; threw = $false
                shells = [int]$v.Shells; agents = [int]$v.Agents; ok = [bool]$v.Ok
                sawShells = [bool]$v.SawShells; sawAgents = [bool]$v.SawAgents
                effort = "$($v.Effort)"; sawEffort = [bool]$v.SawEffort
                turnSecs = [long]$v.TurnSecs; turnDone = [bool]$v.TurnDone; sawTurn = [bool]$v.SawTurn
                ctxTokens = [long]$v.CtxTokens; ctxWindow = [long]$v.CtxWindow; sawCtx = [bool]$v.SawCtx
                compacting = [bool]$v.Compacting; compactPct = [int]$v.CompactPct; compactSecs = [long]$v.CompactSecs
            }
        }
        """;

    private static JsonObject Row(string name, string text)
    {
        ScreenVitals v;
        try
        {
            v = ScreenVitals.Read(text);
        }
        catch (OverflowException)
        {
            return new JsonObject { ["name"] = name, ["threw"] = true };
        }

        return new JsonObject
        {
            ["name"] = name,
            ["threw"] = false,
            ["shells"] = v.Shells,
            ["agents"] = v.Agents,
            ["ok"] = v.Ok,
            ["sawShells"] = v.SawShells,
            ["sawAgents"] = v.SawAgents,
            ["effort"] = v.Effort,
            ["sawEffort"] = v.SawEffort,
            ["turnSecs"] = v.TurnSecs,
            ["turnDone"] = v.TurnDone,
            ["sawTurn"] = v.SawTurn,
            ["ctxTokens"] = v.CtxTokens,
            ["ctxWindow"] = v.CtxWindow,
            ["sawCtx"] = v.SawCtx,
            ["compacting"] = v.Compacting,
            ["compactPct"] = v.CompactPct,
            ["compactSecs"] = v.CompactSecs,
        };
    }

    private static OracleCase Shapes()
    {
        var spec = new StringBuilder();
        foreach (var (name, screen) in Screens)
        {
            spec.Append(CultureInfo.InvariantCulture, $"@{{ n = '{name}'; s = {PsText.Literal(screen)} }},\n");
        }

        return new OracleCase(
            "vitals/shapes",
            "every figure a screen can print, including the misreads it refuses",
            RowFunction + "\n$screens = @(\n" + spec + "$null)\n" + """
            $rows = @()
            foreach ($x in $screens) {
                if (-not $x) { continue }
                $rows += ConvertTo-SRVitalsRow $x.n $x.s
            }
            (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 4)
            """,
            _ =>
            {
                var rows = new JsonArray();
                foreach (var (name, screen) in Screens)
                {
                    rows.Add(Row(name, screen));
                }

                return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
            });
    }

    private static OracleCase Live() => new(
        "vitals/live",
        "what each live session's own screen says about it",
        RowFunction + "\n" + """
        $procs = @(Get-Process -Name claude -ErrorAction SilentlyContinue |
            Where-Object { "$($_.Path)" -notlike '*\WindowsApps\*' } |
            Select-Object -First 30)
        $rows = @()
        foreach ($p in $procs) {
            $text = $null
            try { $text = Get-SRScreenText -ProcessId $p.Id } catch { $text = $null }
            if ($null -eq $text) { continue }
            $row = ConvertTo-SRVitalsRow ("pid " + $p.Id) $text
            $row['screen'] = "$text"
            $rows += $row
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 4)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var name = a?["name"]?.GetValue<string>() ?? string.Empty;
                var screen = a?["screen"]?.GetValue<string>() ?? string.Empty;
                var row = Row(name, screen);
                row["screen"] = screen;
                rows.Add(row);
                LiveCompared++;
            }

            // 🔴 AND FAIL IF NOTHING WAS COMPARED - no readable session means the
            // parse was never run on a real screen at all.
            if (LiveCompared == 0)
            {
                rows.Add(new JsonObject { ["name"] = "(no live screen could be read)" });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        });
}
