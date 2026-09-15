using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 4.4, first tranche - the turns the reading pane draws.
/// </summary>
/// <remarks>
/// 🔑 THIS IS THE WHOLE OF WHAT THE PANE SHOWS, AS A VALUE. The shipped window
/// builds a FlowDocument straight out of <c>Get-ReadTurns</c>, which is why the
/// document can never be virtualized and why it needs a tail budget at all. A
/// list of turns can be bound to a virtualizing panel instead - and either way
/// the GROUPING is the same rule, which is the half that can be compared before
/// a single pixel is drawn.
///
/// 🔴 TWO CASES, AND THE SECOND IS THE ONE THAT CAN GO RED ON EVERY RULE.
/// The live one runs both sides over real transcripts on this machine; the
/// shaped one is built to reach every merge, every call shape and every cut.
/// The lesson is now three-for-three in this rebuild: real data covers the
/// branches real data happens to walk.
/// </remarks>
public static class TurnCases
{
    private const int Sample = 12;

    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Shapes(), true, "every merge, every call shape and every cut, on blocks written to reach them");
        yield return (Live(), true, $"the same turns over {Sample} real conversations, field for field");
    }

    // ------------------------------------------------------------ the shapes

    /// <param name="Kind">The block kind, in PowerShell's own spelling.</param>
    private sealed record Blk(string Kind, string Head, string Body, string Meta, int Minute);

    /// <summary>
    /// 🔴 EVERY RULE IN <c>Get-ReadTurns</c> HAS A SHAPE HERE. The three merges,
    /// the three special call kinds, the folded line's cut, the shell id read
    /// out of prose, a failed result, a result with no call in front of it, and
    /// a call that never answered.
    /// </summary>
    private static readonly Blk[] Shaped =
    [
        // Two of the operator's messages in a row: one turn, joined with a blank line.
        new("you", "", "first thing I said", "", 1),
        new("you", "  second thing I said  ", "second thing I said", "", 2),

        // A said in between, so the run does not simply continue.
        new("said", "", "what it answered", "", 3),
        new("said", "", "and more of it", "", 4),

        // 🪤 A THINKING BLOCK IS NOT MERGED, even two in a row - only you and
        // said are, and a port that merged on "same kind" would join these.
        new("thinking", "", "reasoning one", "", 5),
        new("thinking", "", "reasoning two", "", 6),

        // Notices: joined head-first, and the FIRST one written the same way.
        new("system", "a hook", "said something", "", 7),
        new("system", "another hook", "said something else", "", 8),
        new("system", "a third", "and again", "", 9),

        // Files: joined body-then-meta.
        new("file", "Read", "C:\\p\\one.cs", "42 lines", 10),
        new("file", "Read", "C:\\p\\two.cs", "7 lines", 11),

        // A run of steps, one of each shape.
        new("tool", "Read", "C:\\p\\three.cs", "", 12),
        new("result", "ok", "  \n\nthe answer's first real line\nand a second\n\n", "", 13),
        new("tool", "Task", "go and look at the callers", "sweep the callers", 14),
        new("result", "ok", "done", "", 15),
        new("tool", "Bash (background)", "npm run watch", "", 16),
        new("result", "ok", "Command running in background with ID: beqvs0dpb.", "", 17),
        new("tool", "SendMessage", "tell the other session", "", 18),
        new("result", "ok", "sent", "", 19),

        // A failed step.
        new("tool", "Edit", "C:\\p\\four.cs", "", 20),
        new("result", "failed", "it did not match", "", 21),

        // 🪤 A CALL THAT NEVER ANSWERED. The turn still carries it, with an
        // empty result - which is what a session interrupted mid-step looks
        // like, and there are plenty of those.
        new("tool", "Grep", "a pattern", "", 22),

        // A said, to close the run.
        new("said", "", "and then it spoke again", "", 23),

        // 🪤 A RESULT WITH NO CALL IN FRONT OF IT. It opens a run of its own and
        // contributes nothing, so the run is empty and no turn is added at all.
        new("result", "ok", "an orphan answer", "", 24),

        new("you", "", "after the orphan", "", 25),

        // The folded line's cut, at exactly the boundary.
        new("tool", "Bash", "echo", "", 26),
        new("result", "ok", "x123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789", "", 27),
        new("tool", "Bash", "echo", "", 28),
        new("result", "ok", "y1234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890", "", 29),

        // 🪤 A BACKGROUNDED BASH WHOSE ANSWER HAS NO ID IN IT. The shell field
        // stays empty rather than picking up whatever the regex last matched.
        new("tool", "Bash (background)", "something", "", 30),
        new("result", "ok", "no identifier in this one at all", "", 31),

        // 🪤 TWO ANSWERS FOR ONE CALL. The FIRST one wins - the shipped line
        // only fills a call whose result is still empty - and no shape reached
        // that rule until a break stayed green on it. A second answer arrives
        // whenever a tool streams, and taking the last would show the tail of a
        // long run instead of what it said.
        new("tool", "Bash", "a streaming one", "", 32),
        new("result", "ok", "the first answer", "", 33),
        new("result", "ok", "a second answer that must be ignored", "", 34),
    ];

    private static OracleCase Shapes() => new(
        "read/turn-shapes",
        "Get-ReadTurns and Get-RunSummary over blocks built to reach every rule",
        ShapeScript(),
        _ =>
        {
            var blocks = Shaped.Select(b => new TranscriptBlock(
                Kind(b.Kind), b.Head, b.Body, b.Meta,
                new DateTimeOffset(2026, 1, 1, 0, b.Minute, 0, TimeSpan.Zero))).ToList();

            Shaped_ = blocks.Count;
            return Emit(ReadTurns.Of(blocks));
        });

    private static string ShapeScript()
    {
        var sb = new StringBuilder();
        sb.Append(Preamble).Append("""

        $blocks = @(
        """);

        foreach (var b in Shaped)
        {
            sb.Append("            [PSCustomObject]@{ Kind = ").Append(PsText.Literal(b.Kind))
              .Append("; Head = ").Append(PsText.Literal(b.Head))
              .Append("; Body = ").Append(PsText.Literal(b.Body))
              .Append("; Meta = ").Append(PsText.Literal(b.Meta))
              .Append("; When = ([datetimeoffset]'2026-01-01T00:")
              .Append(b.Minute.ToString("D2", CultureInfo.InvariantCulture))
              .Append(":00+00:00') }\n");
        }

        sb.Append("""
        )
        (Emit-Turns (Get-ReadTurns $blocks))
        """);

        return sb.ToString();
    }

    // -------------------------------------------------------------- the live

    private static OracleCase Live() => new(
        "read/turns-live",
        $"the turns of {Sample} real conversations, field for field",
        Preamble + BlockCases.PsPickListFor(Sample) + """

        $out = @()
        foreach ($row in $pick) {
            $p = $row.P

            $blocks = @()
            # 🔴 ASSIGN, THEN WRAP. Get-SRTranscriptBlocks ends with a comma
            # guard, so @(...) around the call in ONE step makes a one-element
            # array holding every block - and everything downstream then behaves
            # perfectly on one nonsense turn. This codebase has shipped that bug.
            $got = Get-SRTranscriptBlocks -JsonlPath $p -MaxRecords 60 -MaxTailBytes 2097152
            $blocks = @($got)
            $out += [ordered]@{
                path   = $p
                blocks = @($blocks | ForEach-Object { [ordered]@{
                    kind = "$($_.Kind)"; head = "$($_.Head)"; body = "$($_.Body)"; meta = "$($_.Meta)"
                    when = $(if ($_.When) { ([datetimeoffset]$_.When).ToString('o') } else { '' }) } })
                turns  = (ConvertFrom-Json (Emit-Turns (Get-ReadTurns $blocks))).turns
            }
        }
        (@{ files = $out } | ConvertTo-Json -Compress -Depth 12)
        """,
        psOut =>
        {
            var files = new JsonArray();
            foreach (var f in JsonNode.Parse(psOut)?["files"]?.AsArray() ?? [])
            {
                // 🔑 THE BLOCKS ARE THE QUESTION. They are already compared, field
                // for field, by transcript/blocks-detail; what is being asked here
                // is whether two GROUPERS of the same blocks agree. Reading the
                // transcript again on this side would compare two readers and two
                // groupers at once, and a difference in either would look the same.
                var blocks = new List<TranscriptBlock>();
                foreach (var b in f?["blocks"]?.AsArray() ?? [])
                {
                    var when = b?["when"]?.GetValue<string>() ?? string.Empty;
                    blocks.Add(new TranscriptBlock(
                        Kind(b?["kind"]?.GetValue<string>() ?? string.Empty),
                        b?["head"]?.GetValue<string>() ?? string.Empty,
                        b?["body"]?.GetValue<string>() ?? string.Empty,
                        b?["meta"]?.GetValue<string>() ?? string.Empty,
                        when.Length > 0 ? DateTimeOffset.Parse(when, CultureInfo.InvariantCulture) : null));
                }

                LiveBlocks += blocks.Count;
                var turns = ReadTurns.Of(blocks);
                LiveTurns += turns.Count;
                LiveCalls += turns.Sum(t => t.Calls.Count);

                files.Add(new JsonObject
                {
                    ["path"] = f?["path"]?.GetValue<string>() ?? string.Empty,
                    ["blocks"] = f?["blocks"]?.DeepClone(),
                    ["turns"] = JsonNode.Parse(Emit(turns))?["turns"]?.DeepClone(),
                });
            }

            if (LiveBlocks == 0)
            {
                files.Add(new JsonObject { ["path"] = "NOTHING WAS COMPARED - no transcript had any blocks" });
            }

            return new JsonObject { ["files"] = files }.ToJsonString(Compact);
        });

    // ------------------------------------------------------------- the shared

    /// <summary>
    /// 🪤 ONE EMITTER, SPLICED INTO THE POWERSHELL AND WRITTEN ONCE HERE. Two
    /// hand-kept field lists drift, and a field that only one side prints
    /// arrives as "present in PowerShell, missing in C#" - which every allowance
    /// in this harness is shaped to forgive by accident.
    /// </summary>
    private static string Emit(IReadOnlyList<ReadTurn> turns)
    {
        var arr = new JsonArray();
        foreach (var t in turns)
        {
            var calls = new JsonArray();
            foreach (var c in t.Calls)
            {
                calls.Add(new JsonObject
                {
                    ["name"] = c.Name, ["arg"] = c.Arg, ["res"] = c.Res, ["resFull"] = c.ResFull,
                    ["bad"] = c.Bad, ["desc"] = c.Desc, ["callKind"] = c.CallKind, ["shell"] = c.Shell,
                });
            }

            arr.Add(new JsonObject
            {
                ["kind"] = t.Kind,
                ["head"] = t.Head,
                ["body"] = t.Body,
                ["count"] = t.Count,
                ["when"] = t.When?.ToString("o", CultureInfo.InvariantCulture) ?? string.Empty,
                ["summary"] = string.Equals(t.Kind, "run", StringComparison.Ordinal)
                    ? ReadTurns.Summary(t.Calls)
                    : string.Empty,
                ["calls"] = calls,
            });
        }

        return new JsonObject { ["turns"] = arr }.ToJsonString(Compact);
    }

    private const string Preamble = """
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        foreach ($fn in @('Get-ReadTurns', 'Get-RunSummary')) {
            $a = $winSrc.IndexOf("function $fn")
            if ($a -lt 0) { throw "could not find $fn in sessions-window.ps1" }
            $b = $winSrc.IndexOf("`n}", $a)
            Invoke-Expression $winSrc.Substring($a, $b - $a + 2)
        }

        # The one emitter both sides use, so a field cannot be printed by one
        # side alone and swallowed as "missing" by an allowance.
        function Emit-Turns { param($Turns)
            $arr = @()
            foreach ($t in @($Turns)) {
                $calls = @()
                # 🪤 AND AGAIN: @($null) IS A ONE-ELEMENT ARRAY HOLDING $null,
                # so a turn with no calls iterated once and emitted a call made
                # of empty strings. Twice in one emitter, the same trap.
                foreach ($c in @($t.Calls | Where-Object { $_ })) {
                    $calls += [ordered]@{ name = "$($c.Name)"; arg = "$($c.Arg)"; res = "$($c.Res)"
                                          resFull = "$($c.ResFull)"; bad = [bool]$c.Bad; desc = "$($c.Desc)"
                                          callKind = "$($c.CallKind)"; shell = "$($c.Shell)" }
                }
                $arr += [ordered]@{
                    kind = "$($t.Kind)"; head = "$($t.Head)"; body = "$($t.Body)"
                    count = [int]$(if ($null -eq $t.Count) { 1 } else { $t.Count })
                    when = $(if ($t.When) { ([datetimeoffset]$t.When).ToString('o') } else { '' })
                    # 🪤 @($null).Count IS 1 IN POWERSHELL, so "has it any
                    # calls?" cannot be asked that way: every turn without a
                    # single step reported "1 step     " and the C# reported
                    # nothing, which reads exactly like a broken summary. The
                    # RUN kind is what says a turn carries steps.
                    summary = $(if ("$($t.Kind)" -eq 'run') { Get-RunSummary $t.Calls } else { '' })
                    calls = @($calls)
                }
            }
            return (@{ turns = $arr } | ConvertTo-Json -Compress -Depth 10)
        }
        """;

    private static BlockKind Kind(string name) => name switch
    {
        "you" => BlockKind.You,
        "said" => BlockKind.Said,
        "thinking" => BlockKind.Thinking,
        "tool" => BlockKind.Tool,
        "result" => BlockKind.Result,
        "asked" => BlockKind.Asked,
        "msgin" => BlockKind.MsgIn,
        "system" => BlockKind.System,
        "hook" => BlockKind.Hook,
        "file" => BlockKind.File,
        "queued" => BlockKind.Queued,
        "compact" => BlockKind.Compact,
        _ => BlockKind.Said,
    };

    private static int Shaped_ { get; set; }

    public static int LiveBlocks { get; private set; }

    public static int LiveTurns { get; private set; }

    public static int LiveCalls { get; private set; }

    public static string Coverage() => string.Format(CultureInfo.InvariantCulture,
        "{0} written block(s); {1} real block(s) grouped into {2} turn(s) carrying {3} step(s)",
        Shaped_, LiveBlocks, LiveTurns, LiveCalls);
}
