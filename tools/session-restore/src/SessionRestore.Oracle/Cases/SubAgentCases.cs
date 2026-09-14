using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Sessions;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 2.5b - the sub-agent readers and what is running now.
/// </summary>
/// <remarks>
/// 🔑 THEY ANSWER "WHAT IS RUNNING", NOT "WHAT DOES THE TRANSCRIPT SAY", which
/// is why they sit in 2.5 with the agent map rather than in 2.3 with the parser
/// - even though they read a transcript to do it.
/// </remarks>
public static class SubAgentCases
{
    /// <summary>How many conversations the live-task comparison covers.</summary>
    /// <remarks>
    /// 🪤 SCOPED, AND FOR A DIFFERENT REASON THAN THE BLOCK CASES. Get-SRLiveTasks
    /// reads a **24 MB** tail, sized so that 356 of 373 transcripts on this
    /// machine are read WHOLE - which is right for the one conversation a window
    /// is showing and absurd over all 546 at once.
    /// </remarks>
    public const int LiveTaskSample = 25;

    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Agents(), true, "every sub-agent of every conversation, and what it is");
        yield return (LastLines(), true, "the last thing each sub-agent said");
        yield return (Live(), true, $"what is still running, over {LiveTaskSample} conversations");
        yield return (TaskShapes(), true, "every way a launch, an id and a finish can be written");
        yield return (Row(), true, "the sub-agent row's name, tag, age and tooltip, against Build-Sessions' own block");
    }

    // ------------------------------------------------------- the row it draws

    /// <param name="Kind">The task kind: a teammate is <c>in_process_teammate</c>.</param>
    private sealed record RowSpec(string Name, string Label, string Kind, string Description, string AgentType, bool Live, bool HasTranscript, int AgeSeconds);

    private static readonly RowSpec[] RowSpecs =
    [
        new("a-task-still-working", "scout", "task", "sweep the callers", "general-purpose", true, true, 30),
        new("a-task-that-finished", "scout", "task", "sweep the callers", "general-purpose", false, true, 7200),
        new("a-teammate-still-working", "I7", "in_process_teammate", "hold the interface", "general-purpose", true, true, 5),
        new("a-teammate-that-finished", "I7", "in_process_teammate", "hold the interface", "general-purpose", false, true, 90000),

        // 🪤 45 OF 374 ON THIS MACHINE ARE METADATA AND NO TRANSCRIPT. A real
        // state, and drawing it like an empty conversation reads as a broken
        // reader rather than as an agent that left nothing.
        new("no-transcript", "ghost", "task", "look around", "explorer", false, false, 400),
        new("no-transcript-and-working", "ghost", "task", "look around", "explorer", true, false, 10),

        // With no description the row falls back to the agent's TYPE, and the
        // tooltip says so in words instead.
        new("no-description", "scout", "task", "", "general-purpose", false, true, 300),
        new("no-description-and-no-type", "scout", "task", "", "", false, true, 300),
        new("no-description-no-transcript", "ghost", "in_process_teammate", "", "explorer", false, false, 300),

        // The ages, at the boundaries Get-AgeLabel turns over.
        new("age-under-90-seconds", "scout", "task", "x", "general-purpose", true, true, 89),
        new("age-at-90-seconds", "scout", "task", "x", "general-purpose", false, true, 90),
        new("age-an-hour", "scout", "task", "x", "general-purpose", false, true, 3600),
        new("age-a-day", "scout", "task", "x", "general-purpose", false, true, 86400),
        new("age-in-the-future", "scout", "task", "x", "general-purpose", true, true, -60),
    ];

    /// <summary>
    /// 🔴 THE ROW IS INLINE IN Build-Sessions, so it is SPLICED rather than
    /// copied: the tag and tooltip are built in one block and the drawn fields
    /// are entries in the hashtable literal beneath it. Both regions are cut out
    /// of the shipped file by their own lines.
    /// </summary>
    private static OracleCase Row() => new(
        "agents/row",
        "what a sub-agent row says, over every combination of kind, state and transcript",
        RowScript(),
        _ =>
        {
            var rows = new JsonArray();
            var now = DateTime.Now;
            foreach (var s in RowSpecs)
            {
                var agent = new SubAgent(
                    Id: "a1",
                    Label: s.Label,
                    AgentType: s.AgentType,
                    Description: s.Description,
                    TaskKind: s.Kind,
                    Model: string.Empty,
                    Team: string.Empty,
                    ToolUseId: string.Empty,
                    Path: string.Empty,
                    HasTranscript: s.HasTranscript,
                    Bytes: 0,
                    When: new DateTimeOffset(now.AddSeconds(-s.AgeSeconds)));
                var t = Core.Rows.AgentRow.Of(agent, s.Live, now.Ticks);
                rows.Add(new JsonObject
                {
                    ["n"] = s.Name,
                    ["name"] = t.Name,
                    ["desc"] = t.Description,
                    ["tag"] = t.Tag,
                    ["age"] = t.Age,
                    ["opacity"] = t.Opacity,
                    ["tip"] = t.Tip,
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        });

    private static string RowScript()
    {
        var sb = new System.Text.StringBuilder();
        var inv = System.Globalization.CultureInfo.InvariantCulture;

        sb.Append("""
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        foreach ($fn in @('Get-AgeLabel', 'Get-AgeTicks')) {
            $a = $winSrc.IndexOf("function $fn")
            if ($a -lt 0) { throw "could not find $fn" }
            Invoke-Expression $winSrc.Substring($a, $winSrc.IndexOf("`n}", $a) - $a + 2)
        }

        # The tag and the tooltip, then the fields the row draws.
        $fromA = $winSrc.IndexOf('                $tag = $(if ($sa.IsTeammate)')
        $toA = $winSrc.IndexOf('                $items.Add([PSCustomObject]@{', $fromA)
        $fromB = $winSrc.IndexOf('                    SubName = $sa.Label', $toA)
        $toB = $winSrc.IndexOf("`n", $winSrc.IndexOf('                    SubTip = $tip', $fromB))
        if ($fromA -lt 0 -or $toA -lt 0 -or $fromB -lt 0 -or $toB -lt 0) { throw 'could not find the sub-agent row block' }
        $regionA = $winSrc.Substring($fromA, $toA - $fromA)
        $regionB = $winSrc.Substring($fromB, $toB - $fromB)

        $now = Get-Date
        $specs = @(

        """);

        foreach (var s in RowSpecs)
        {
            sb.Append(inv, $"    @{{ n = '{s.Name}'; label = {PsText.Literal(s.Label)}; kind = '{s.Kind}'; ");
            sb.Append(inv, $"desc = {PsText.Literal(s.Description)}; type = {PsText.Literal(s.AgentType)}; ");
            sb.Append(inv, $"live = ${s.Live.ToString().ToLowerInvariant()}; has = ${s.HasTranscript.ToString().ToLowerInvariant()}; ");
            sb.Append(inv, $"age = {s.AgeSeconds} }},\n");
        }

        sb.Append("""
            $null)
        $rows = @()
        foreach ($s in $specs) {
            if (-not $s) { continue }
            $sa = [PSCustomObject]@{
                Id            = 'a1'
                Label         = $s.label
                Description   = $s.desc
                AgentType     = $s.type
                IsTeammate    = ($s.kind -eq 'in_process_teammate')
                Live          = $s.live
                HasTranscript = $s.has
                When          = $now.AddSeconds(-$s.age)
            }
            Invoke-Expression $regionA
            $h = Invoke-Expression ('@{' + $regionB + '}')
            $rows += [ordered]@{
                n = "$($s.n)"; name = "$($h.SubName)"; desc = "$($h.SubDesc)"
                tag = "$tag"; age = "$($h.SubAge)"
                opacity = [double]$h.SubOpacity; tip = "$($h.SubTip)"
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 4)

        """);

        return sb.ToString();
    }

    // ------------------------------------------------- what is running: shapes

    /// <summary>
    /// 🔴 THE LIVE CASE PROVES THE PATHS TODAY'S MACHINE HAPPENS TO REACH, and on
    /// most runs nothing at all is running - so it can be green over an empty
    /// answer twice a day. The defect it eventually caught (an Agent writes
    /// <c>run_in_background</c> as the STRING "true", so a kind test dropped every
    /// background agent) only showed because one conversation happened to have an
    /// agent out at that moment. These shapes are the same rules, written down, so
    /// the next one does not need a coincidence.
    /// </summary>
    private sealed record TaskShape(string Name, string[] Lines);

    private static string Use(string id, string name, string bg, string cmd) =>
        new JsonObject
        {
            ["type"] = "assistant",
            ["timestamp"] = "2026-09-13T08:00:00.000Z",
            ["message"] = new JsonObject
            {
                ["role"] = "assistant",
                ["content"] = new JsonArray
                {
                    new JsonObject
                    {
                        ["type"] = "tool_use",
                        ["id"] = id,
                        ["name"] = name,
                        ["input"] = Input(bg, name, cmd),
                    },
                },
            },
        }.ToJsonString();

    /// <summary>The flag spelled the way the shape asks for: a bare word is JSON, anything else a string.</summary>
    private static JsonObject Input(string bg, string name, string cmd)
    {
        var input = new JsonObject { ["description"] = "what it was asked to do" };
        if (string.Equals(name, "Bash", StringComparison.Ordinal))
        {
            input["command"] = cmd;
        }
        else
        {
            input["subagent_type"] = cmd;
        }

        if (bg.Length > 0)
        {
            input["run_in_background"] = bg switch
            {
                "true" => JsonValue.Create(true),
                "false" => JsonValue.Create(false),
                "0" => JsonValue.Create(0),
                "1" => JsonValue.Create(1),
                "null" => null,
                _ => JsonValue.Create(bg.Trim('\'')),
            };
        }

        return input;
    }

    private static string Result(string useId, string text) =>
        new JsonObject
        {
            ["type"] = "user",
            ["timestamp"] = "2026-09-13T08:00:01.000Z",
            ["message"] = new JsonObject
            {
                ["role"] = "user",
                ["content"] = new JsonArray
                {
                    new JsonObject
                    {
                        ["type"] = "tool_result",
                        ["tool_use_id"] = useId,
                        ["content"] = new JsonArray
                        {
                            new JsonObject { ["type"] = "text", ["text"] = text },
                        },
                    },
                },
            },
        }.ToJsonString();

    private static string ResultString(string useId, string text) =>
        new JsonObject
        {
            ["type"] = "user",
            ["timestamp"] = "2026-09-13T08:00:01.000Z",
            ["message"] = new JsonObject
            {
                ["role"] = "user",
                ["content"] = new JsonArray
                {
                    new JsonObject
                    {
                        ["type"] = "tool_result",
                        ["tool_use_id"] = useId,
                        ["content"] = text,
                    },
                },
            },
        }.ToJsonString();

    private static string Ended(string id) =>
        new JsonObject
        {
            ["type"] = "user",
            ["timestamp"] = "2026-09-13T08:00:02.000Z",
            ["message"] = new JsonObject
            {
                ["role"] = "user",
                ["content"] = "<task-notification>\n<task-id>" + id + "</task-id>\ndone\n</task-notification>",
            },
        }.ToJsonString();

    private const string AgentSaid = "Async agent launched successfully.\nagentId: a1b2c3d4 (internal ID)";

    private static readonly TaskShape[] RunShapes =
    [
        // 🔴 THE ONE THAT WAS WRONG. Both are launches; only the spelling differs.
        new("bash-flag-is-a-boolean", [Use("u1", "Bash", "true", "sleep 5"), Result("u1", "running in background with ID: bd9l0w3g5")]),
        new("agent-flag-is-a-string", [Use("u1", "Agent", "'true'", "general-purpose"), Result("u1", AgentSaid)]),

        // 🪤 AND "false" AS A STRING IS TRUE IN POWERSHELL. It reads like a bug
        // and is what the shipped tool does - the point of the case is that both
        // sides say the same wrong-looking thing.
        new("the-string-false-is-truthy", [Use("u1", "Agent", "'false'", "general-purpose"), Result("u1", AgentSaid)]),
        new("the-boolean-false-is-not", [Use("u1", "Bash", "false", "sleep 5"), Result("u1", "running in background with ID: nope")]),
        new("zero-is-not", [Use("u1", "Bash", "0", "sleep 5"), Result("u1", "running in background with ID: nope")]),
        new("one-is", [Use("u1", "Bash", "1", "sleep 5"), Result("u1", "running in background with ID: one")]),
        new("an-empty-string-is-not", [Use("u1", "Bash", "''", "sleep 5"), Result("u1", "running in background with ID: nope")]),
        new("null-is-not", [Use("u1", "Bash", "null", "sleep 5"), Result("u1", "running in background with ID: nope")]),
        new("absent-is-not", [Use("u1", "Bash", string.Empty, "sleep 5"), Result("u1", "running in background with ID: nope")]),

        // The launch names the kind, not the flag.
        new("task-counts-as-an-agent", [Use("u1", "Task", "'true'", "explorer"), Result("u1", AgentSaid)]),
        new("another-tool-never-counts", [Use("u1", "Read", "true", "x"), Result("u1", "background with ID: nope")]),

        // 🪤 EACH KIND HANDS ITS ID BACK IN ITS OWN WORDS, and a result that
        // names the OTHER kind's phrasing is not a launch this can track.
        new("an-agent-that-says-shell-is-dropped", [Use("u1", "Agent", "'true'", "general-purpose"), Result("u1", "background with ID: bd9l0w3g5")]),
        new("a-shell-that-says-agent-is-dropped", [Use("u1", "Bash", "true", "sleep 5"), Result("u1", AgentSaid)]),
        new("a-launch-with-no-result-is-not-open", [Use("u1", "Bash", "true", "sleep 5")]),

        // The result content arrives as a bare string as well as as blocks.
        new("a-string-result-body", [Use("u1", "Bash", "true", "sleep 5"), ResultString("u1", "background with ID: strbody")]),

        // Finishing.
        new("a-finished-shell-is-gone",
        [
            Use("u1", "Bash", "true", "sleep 5"), Result("u1", "background with ID: gone"), Ended("gone"),
        ]),
        new("a-finish-for-something-else-changes-nothing",
        [
            Use("u1", "Bash", "true", "sleep 5"), Result("u1", "background with ID: kept"), Ended("other"),
        ]),
        new("relaunched-after-finishing",
        [
            Use("u1", "Bash", "true", "a"), Result("u1", "background with ID: x"), Ended("x"),
            Use("u2", "Bash", "true", "b"), Result("u2", "background with ID: x"),
        ]),
        new("two-at-once-keep-their-order",
        [
            Use("u1", "Bash", "true", "first"), Result("u1", "background with ID: aaa"),
            Use("u2", "Agent", "'true'", "general-purpose"), Result("u2", AgentSaid),
        ]),
        new("empty-file", []),
    ];

    private static OracleCase TaskShapes() => new(
        "subagents/task-shapes",
        "every way a background launch, its id and its finish can be written",
        // 🔴 PLAIN STRING EXPRESSIONS, NOT BASE64 - the antivirus's script scan
        // refuses a decode-and-write and the case never runs. See PsText.Literal.
        "$dir = Join-Path ([IO.Path]::GetTempPath()) ('sr-tasks-ps-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))\n"
        + "$null = New-Item -ItemType Directory -Path $dir\n"
        + "try {\n"
        + "    $shapes = @(\n"
        + string.Concat(RunShapes.Select(s =>
            "        @{ n = '" + s.Name + "'; l = @(" + string.Join(", ", s.Lines.Select(PsText.Literal)) + ") },\n"))
        + "        $null)\n"
        + "    $rows = New-Object System.Collections.Generic.List[object]\n"
        + "    foreach ($s in $shapes) {\n"
        + "        if (-not $s) { continue }\n"
        + "        $p = Join-Path $dir ($s.n + '.jsonl')\n"
        + "        $text = $(if (@($s.l).Count) { (@($s.l) -join \"`n\") + \"`n\" } else { '' })\n"
        + "        [IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding $false))\n"
        + "        $t = Get-SRLiveTasks -JsonlPath $p\n"
        + "        $t = @($t)\n"
        + "        $rows.Add([ordered]@{\n"
        + "            n     = $s.n\n"
        + "            count = $t.Count\n"
        + "            ids   = (($t | ForEach-Object { \"$($_.Shell)\" }) -join ',')\n"
        + "            kinds = (($t | ForEach-Object { \"$($_.Kind)\" }) -join ',')\n"
        + "            cmds  = (($t | ForEach-Object { \"$($_.Command)\" }) -join '|')\n"
        + "            descs = (($t | ForEach-Object { \"$($_.Desc)\" }) -join '|')\n"
        + "        })\n"
        + "    }\n"
        + "    (@{ rows = $rows.ToArray() } | ConvertTo-Json -Compress -Depth 5)\n"
        + "} finally {\n"
        + "    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue\n"
        + "}\n",
        _ =>
        {
            // 🪤 EACH SIDE WRITES ITS OWN COPY AND DELETES IT IN ITS OWN FINALLY.
            // The PowerShell runs first, so a shared fixture would have to outlive
            // a PowerShell that may fail - and leak whenever it did.
            var dir = Path.Combine(Path.GetTempPath(), "sr-tasks-cs-" + Guid.NewGuid().ToString("N")[..8]);
            Directory.CreateDirectory(dir);
            try
            {
                var rows = new JsonArray();
                foreach (var s in RunShapes)
                {
                    var p = Path.Combine(dir, s.Name + ".jsonl");
                    var text = s.Lines.Length == 0 ? string.Empty : string.Join("\n", s.Lines) + "\n";
                    File.WriteAllBytes(p, System.Text.Encoding.UTF8.GetBytes(text));
                    var t = LiveTasks.Read(p);
                    rows.Add(new JsonObject
                    {
                        ["n"] = s.Name,
                        ["count"] = t.Count,
                        ["ids"] = string.Join(",", t.Select(x => x.Id)),
                        ["kinds"] = string.Join(",", t.Select(x => x.Kind)),
                        ["cmds"] = string.Join("|", t.Select(x => x.Command)),
                        ["descs"] = string.Join("|", t.Select(x => x.Description)),
                    });
                }

                return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
            }
            finally
            {
                try
                {
                    Directory.Delete(dir, recursive: true);
                }
                catch (IOException)
                {
                }
            }
        });

    /// <summary>
    /// 🔴 EVERY CONVERSATION, because a sub-agent list is cheap: it reads a
    /// directory of small meta files and stats one transcript each. Nothing here
    /// parses a conversation.
    /// </summary>
    private static OracleCase Agents() => new(
        "subagents/list",
        "every sub-agent beside every conversation, with what it is and whether it is going",
        """
        $reg = Get-SRRegistry
        $rows = @()
        foreach ($d in @($reg.directories)) {
            foreach ($s in @($d.sessions)) {
                $p = "$($s.jsonl)"
                if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
                # ASSIGN FIRST, WRAP SECOND - Get-SRSubAgents returns an array
                # and @() around the CALL would give one element holding it.
                $a = Get-SRSubAgents -JsonlPath $p
                $a = @($a)
                if (-not $a.Count) { continue }
                foreach ($x in $a) {
                    $rows += [ordered]@{
                        of       = "$($s.sessionId)"
                        id       = "$($x.Id)"
                        label    = "$($x.Label)"
                        type     = "$($x.AgentType)"
                        desc     = "$($x.Description)"
                        kind     = "$($x.TaskKind)"
                        model    = "$($x.Model)"
                        team     = "$($x.Team)"
                        toolUse  = "$($x.ToolUseId)"
                        has      = [bool]$x.HasTranscript
                        bytes    = [long]$x.Bytes
                        when     = $(if ($x.When) { ([datetime]$x.When).ToUniversalTime().Ticks } else { $null })
                        teammate = [bool]$x.IsTeammate
                    }
                }
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 6)
        """,
        psOut =>
        {
            // 🪤 `Live` IS DELIBERATELY NOT COMPARED. It is a clock reading - "was
            // this written to in the last three minutes" - so the two sides
            // evaluate it seconds apart and an agent right on the boundary
            // legitimately differs. Everything it is COMPUTED FROM is compared
            // instead: HasTranscript and the transcript's mtime.
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var byId = PathsById();

            // The PowerShell emits one row per sub-agent, so walk the distinct
            // parents in first-seen order and emit this side's list for each.
            var parents = new List<string>();
            foreach (var a in asked)
            {
                var of = a?["of"]?.GetValue<string>() ?? string.Empty;
                if (!parents.Contains(of, StringComparer.Ordinal))
                {
                    parents.Add(of);
                }
            }

            var rows = new JsonArray();
            foreach (var of in parents)
            {
                if (!byId.TryGetValue(of, out var path))
                {
                    rows.Add(new JsonObject { ["of"] = of, ["id"] = "(no such conversation here)" });
                    continue;
                }

                foreach (var x in SubAgents.List(path))
                {
                    rows.Add(new JsonObject
                    {
                        ["of"] = of,
                        ["id"] = x.Id,
                        ["label"] = x.Label,
                        ["type"] = x.AgentType,
                        ["desc"] = x.Description,
                        ["kind"] = x.TaskKind,
                        ["model"] = x.Model,
                        ["team"] = x.Team,
                        ["toolUse"] = x.ToolUseId,
                        ["has"] = x.HasTranscript,
                        ["bytes"] = x.Bytes,
                        ["when"] = x.When.UtcTicks,
                        ["teammate"] = x.IsTeammate,
                    });
                    AgentsSeen++;
                }
            }

            if (AgentsSeen == 0)
            {
                rows.Add(new JsonObject
                {
                    ["of"] = "(nothing)",
                    ["id"] = "NOTHING WAS COMPARED - no conversation on this machine has a sub-agent",
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        });

    /// <summary>The one line each sub-agent's own transcript ends on.</summary>
    private static OracleCase LastLines() => new(
        "subagents/last-line",
        "the newest thing each sub-agent said, or the last tool it reached for",
        """
        $reg = Get-SRRegistry
        $rows = @()
        $n = 0
        foreach ($d in @($reg.directories)) {
            foreach ($s in @($d.sessions)) {
                if ($n -ge 400) { break }
                $p = "$($s.jsonl)"
                if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
                $a = Get-SRSubAgents -JsonlPath $p
                $a = @($a | Where-Object { $_.HasTranscript })
                foreach ($x in $a) {
                    if ($n -ge 400) { break }
                    # The id the reader takes is the stem WITHOUT its agent- prefix.
                    $aid = "$($x.Id)" -replace '^agent-', ''
                    $rows += [ordered]@{
                        of   = "$($s.sessionId)"
                        id   = "$($x.Id)"
                        aid  = $aid
                        said = "$(Get-SRAgentLastLine -JsonlPath $p -AgentId $aid)"
                    }
                    $n++
                }
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 5)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var byId = PathsById();
            var rows = new JsonArray();

            foreach (var a in asked)
            {
                var of = a?["of"]?.GetValue<string>() ?? string.Empty;
                var id = a?["id"]?.GetValue<string>() ?? string.Empty;
                var aid = a?["aid"]?.GetValue<string>() ?? string.Empty;

                // The parent and the agent id are the QUESTION - which agent are
                // we asking about. The answer is read from the file here.
                rows.Add(new JsonObject
                {
                    ["of"] = of,
                    ["id"] = id,
                    ["aid"] = aid,
                    ["said"] = byId.TryGetValue(of, out var path)
                        ? SubAgents.LastLine(path, aid)
                        : "(no such conversation here)",
                });
                LastLinesSeen++;
            }

            if (LastLinesSeen == 0)
            {
                rows.Add(new JsonObject { ["said"] = "NOTHING WAS COMPARED - no sub-agent has a transcript" });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        });

    /// <summary>
    /// 🔴 THE ONE THAT ANSWERS "WHAT IS RUNNING". Pinned to the file length the
    /// PowerShell read, because a conversation grows while it is being read and
    /// a launch that arrives between the two sides is a real difference about
    /// nothing.
    /// </summary>
    private static OracleCase Live() => new(
        "subagents/live-tasks",
        "every background shell and agent launched and not yet finished",
        $$"""
        $reg = Get-SRRegistry
        $all = @()
        foreach ($d in @($reg.directories)) {
            foreach ($s in @($d.sessions)) {
                $p = "$($s.jsonl)"
                if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
                $all += [PSCustomObject]@{ Id = "$($s.sessionId)"; P = $p; A = $s.lastActive }
            }
        }
        $pick = @($all | Sort-Object -Property @{ E = { [datetime]$_.A } } -Descending | Select-Object -First {{LiveTaskSample}})
        $rows = @()
        foreach ($x in $pick) {
            # 🪤 THE LENGTH BEFORE THE READ, never after.
            $len = $(try { (Get-Item -LiteralPath $x.P).Length } catch { -1 })
            $t = Get-SRLiveTasks -JsonlPath $x.P
            $t = @($t)
            $rows += [ordered]@{
                of    = $x.Id
                len   = $len
                n     = $t.Count
                ids   = (($t | ForEach-Object { "$($_.Shell)" }) -join ',')
                kinds = (($t | ForEach-Object { "$($_.Kind)" }) -join ',')
                cmds  = (($t | ForEach-Object { "$($_.Command)" }) -join [string][char]1)
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 5)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var byId = PathsById();
            var rows = new JsonArray();

            foreach (var a in asked)
            {
                var of = a?["of"]?.GetValue<string>() ?? string.Empty;
                var askedLen = a?["len"]?.GetValue<long>() ?? -1;

                // 🔴 A MARKER GOES IN EVERY FIELD THE OTHER SIDE EMITTED, not
                // just the first two. A partly-marked row reports its remaining
                // fields as "present in PowerShell, missing in C#", and those
                // lines carry nothing an allowance can match on - so this case
                // went red intermittently, whenever a conversation happened to be
                // written to mid-run AND had a task in it. Exactly the mistake
                // the launch cases had already been fixed for.
                if (!byId.TryGetValue(of, out var path))
                {
                    rows.Add(Moving.Mark(a, "of", "(no such conversation here)"));
                    continue;
                }

                var now = Length(path);
                if (askedLen >= 0 && now != askedLen)
                {
                    rows.Add(Moving.Mark(a, "of", "(grew between the two reads)"));
                    continue;
                }

                var t = LiveTasks.Read(path);
                if (Length(path) != askedLen)
                {
                    rows.Add(Moving.Mark(a, "of", "(grew between the two reads)"));
                    continue;
                }

                rows.Add(new JsonObject
                {
                    ["of"] = of,
                    ["len"] = now,
                    ["n"] = t.Count,
                    ["ids"] = string.Join(",", t.Select(x => x.Id)),
                    ["kinds"] = string.Join(",", t.Select(x => x.Kind)),
                    ["cmds"] = string.Join("", t.Select(x => x.Command)),
                });
                LiveTasksSeen++;
            }

            // 🔴 AND FAIL IF NOTHING WAS COMPARED. A run where every
            // conversation grew would otherwise agree about nothing at all and
            // print green. This row matches no allowance on purpose.
            if (LiveTasksSeen == 0)
            {
                rows.Add(new JsonObject { ["of"] = "(nothing was compared)", ["n"] = -3 });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        })
    {
        // 🪤 THE C# VALUE OF THIS ONE DIFFERENCE IS THE MARKER - see Moving.
        Tolerate = d => Moving.IsMarked(d, "(grew between the two reads)"),
        ToleranceReason = "the conversation was written to between the two reads - a growing file, not a differing reader",
    };

    /// <summary>How many sub-agents, last lines and conversations were compared.</summary>
    public static int AgentsSeen { get; private set; }

    public static int LastLinesSeen { get; private set; }

    public static int LiveTasksSeen { get; private set; }

    public static string Coverage() => string.Format(System.Globalization.CultureInfo.InvariantCulture,
        "{0} sub-agent(s), {1} last line(s), {2} conversation(s) for what is running",
        AgentsSeen, LastLinesSeen, LiveTasksSeen);

    private static long Length(string path)
    {
        try
        {
            return new FileInfo(path).Length;
        }
        catch (IOException)
        {
            return -1;
        }
    }

    private static Dictionary<string, string> PathsById() =>
        Core.Registry.SessionRegistry.Read().AllSessions
            .Where(s => !string.IsNullOrEmpty(s.Jsonl))
            .GroupBy(s => s.SessionId, StringComparer.Ordinal)
            .ToDictionary(g => g.Key, g => g.First().Jsonl!, StringComparer.Ordinal);
}
