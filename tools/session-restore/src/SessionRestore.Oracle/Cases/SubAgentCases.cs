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
    }

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
            $t = Get-SRLiveTasks -JsonlPath $x.P
            $t = @($t)
            $len = $(try { (Get-Item -LiteralPath $x.P).Length } catch { -1 })
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

                if (!byId.TryGetValue(of, out var path))
                {
                    rows.Add(new JsonObject { ["of"] = of, ["len"] = -1, ["n"] = -1 });
                    continue;
                }

                var now = Length(path);
                if (askedLen >= 0 && now != askedLen)
                {
                    rows.Add(new JsonObject { ["of"] = of, ["len"] = -2, ["n"] = -2 });
                    continue;
                }

                var t = LiveTasks.Read(path);
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

            if (LiveTasksSeen == 0)
            {
                rows.Add(new JsonObject { ["of"] = "(nothing)", ["n"] = -3 });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        })
    {
        Tolerate = d => d.EndsWith("C# \"-2\"", StringComparison.Ordinal),
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
