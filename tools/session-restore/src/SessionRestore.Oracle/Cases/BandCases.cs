using System.Globalization;
using System.Text.Json.Nodes;
using SessionRestore.Core.Registry;
using SessionRestore.Core.Rows;
using SessionRestore.Core.Sessions;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 2.6 - bands and titles.
/// </summary>
/// <remarks>
/// 🔑 THE BAND IS WHAT THE OPERATOR ACTUALLY READS. Four words decide the whole
/// board - needs, working, done/open, quiet - and getting one wrong does not
/// look like a bug, it looks like his own list of work being wrong about itself.
/// So this is compared over every conversation in the registry, and the shapes
/// live data cannot produce are supplied.
///
/// 🪤 AND THE LESSON FROM 2.5c APPLIES DIRECTLY. A green over live data proves
/// only the branches live data reaches - so `bands/shapes` exists alongside
/// `bands/live`, and every branch of Get-Band was seen to go red through it.
/// [[feedback-written-is-not-working]]
/// </remarks>
public static class BandCases
{
    /// <summary>How many conversations the band comparison covered.</summary>
    public static int Rows { get; private set; }

    /// <summary>How many of those were in each band, for the coverage line.</summary>
    public static string Spread { get; private set; } = string.Empty;

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (TitleCase(), true, "what every conversation is called, and its lane and age");
        yield return (Ages(), true, "how an age reads, at every boundary");
        yield return (OpenItemCase(), true, "whether a message left something open, over what was really said");
        yield return (Live(), true, "the band every conversation is in, over the whole registry");
        yield return (Shapes(), true, "every band the window can reach, including the ones nothing is in");
        yield return (Rail(), true, "the rail's age bands");
        yield return (OnSurface(), true, "which conversations the work surface shows, selection included");
    }

    public static string Coverage() =>
        Rows.ToString(CultureInfo.InvariantCulture) + " conversations banded" +
        (Spread.Length > 0 ? " - " + Spread : string.Empty);

    // ---------------------------------------------------------------------

    private static OracleCase TitleCase() => new(
        "bands/titles",
        "the name on the row, whether it was derived, and the lane beside it",
        """
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        foreach ($fn in @('Get-Title', 'Get-LaneLabel', 'Get-AgeLabel', 'Get-AgeTicks')) {
            $a = $winSrc.IndexOf("function $fn")
            if ($a -lt 0) { throw "could not find $fn in sessions-window.ps1" }
            $b = $winSrc.IndexOf("`n}", $a)
            if ($b -lt 0) { throw "could not find the end of $fn" }
            Invoke-Expression $winSrc.Substring($a, $b - $a + 2)
        }
        $reg = Get-SRRegistry
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($d in @($reg.directories)) {
            foreach ($s in @($d.sessions)) {
                $t = Get-Title $s $d
                $r = [PSCustomObject]@{ S = $s; D = $d }
                $at = 0L
                try { $at = ([datetime]$s.lastActive).Ticks } catch { }
                $rows.Add([ordered]@{
                    id      = "$($s.sessionId)"
                    text    = "$($t.Text)"
                    derived = [bool]$t.Derived
                    lane    = "$(Get-LaneLabel $r $t.Text)"
                    at      = [string]$at
                })
            }
        }
        (@{ rows = $rows.ToArray() } | ConvertTo-Json -Compress -Depth 5)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var pairs = Pairs();
            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var id = a?["id"]?.GetValue<string>() ?? string.Empty;
                if (!pairs.TryGetValue(id, out var p))
                {
                    rows.Add(new JsonObject { ["id"] = id, ["text"] = "(not on this side)" });
                    continue;
                }

                var t = Titles.Of(p.Session, p.Directory);
                rows.Add(new JsonObject
                {
                    ["id"] = id,
                    ["text"] = t.Text,
                    ["derived"] = t.Derived,
                    ["lane"] = Titles.LaneLabel(p.Session, t.Text),
                    ["at"] = (p.Session.LastActive?.LocalDateTime.Ticks ?? 0L)
                        .ToString(CultureInfo.InvariantCulture),
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString();
        });

    /// <summary>
    /// 🔑 THE BOUNDARIES, NOT A SAMPLE. Every one of these is one tick either
    /// side of a threshold - the places an age label changes - because a label
    /// that is right in the middle of each band and wrong at every edge reads as
    /// correct all day and then disagrees with the fingerprint that decides
    /// whether to repaint.
    /// </summary>
    private static OracleCase Ages() => new(
        "bands/ages",
        "an age at every boundary, and one tick either side of each",
        """
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        $a = $winSrc.IndexOf("function Get-AgeLabel")
        $b = $winSrc.IndexOf("`n}", $a)
        Invoke-Expression $winSrc.Substring($a, $b - $a + 2)
        $secs = @(0, 1, 2, 89, 90, 91, 3599, 3600, 3601, 86399, 86400, 86401,
                  120, 3660, 90000, 604800, 2592000, 31536000)
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($s in $secs) {
            foreach ($off in @(-1, 0, 1)) {
                $d = ([long]$s * 10000000) + $off
                $rows.Add([ordered]@{ d = [string]$d; label = "$(Get-AgeLabel $d)" })
            }
        }
        $rows.Add([ordered]@{ d = '-5000'; label = "$(Get-AgeLabel -5000)" })
        (@{ rows = $rows.ToArray() } | ConvertTo-Json -Compress -Depth 4)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var d = long.Parse(a?["d"]?.GetValue<string>() ?? "0", CultureInfo.InvariantCulture);
                rows.Add(new JsonObject
                {
                    ["d"] = d.ToString(CultureInfo.InvariantCulture),
                    ["label"] = Titles.AgeLabel(d),
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString();
        });

    /// <summary>
    /// 🔑 OVER WHAT WAS REALLY SAID, PLUS WHAT THE RULES WERE WRITTEN FOR. The
    /// live half reads the last full message of every conversation with one - the
    /// only text that can show a rule firing where it should not. The shapes half
    /// carries one example per rule, because a rule nothing in the registry
    /// happens to match is an untested rule.
    /// </summary>
    private static OracleCase OpenItemCase() => new(
        "bands/open-items",
        "did the last message leave something open - every rule, and every live message",
        "$texts = New-Object System.Collections.Generic.List[string]\n"
        + Shapes(OpenTexts)
        + """
        $reg = Get-SRRegistry
        foreach ($d in @($reg.directories)) {
            foreach ($s in @($d.sessions)) {
                $p = "$($s.jsonl)"
                if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
                $sd = $null
                try { $sd = Get-SRLastSaid -JsonlPath $p } catch { }
                if (-not $sd) { continue }
                $f = "$($sd.Full)"
                if ($f.Trim()) { $texts.Add($f) }
            }
        }
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($t in $texts) {
            $rows.Add([ordered]@{
                len    = [int]$t.Length
                sha    = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($t))).Replace('-','').ToLower())
                any    = [bool](Test-SROpenItems -Text $t)
                reason = "$(Get-SROpenItemReason -Text $t)"
            })
        }
        (@{ rows = $rows.ToArray() } | ConvertTo-Json -Compress -Depth 4)
        """,
        psOut =>
        {
            // 🪤 THE TEXTS ARE IDENTIFIED BY HASH, NOT SENT. A last message runs
            // to kilobytes and there are hundreds of them; shipping them through
            // the pipe twice was what made an earlier case take minutes. This
            // side reads the same transcripts itself and matches on the digest,
            // so a text that differs is a difference in the READER - which is
            // 2.3a's case, not this one - and shows up as a missing row rather
            // than as a wrong verdict.
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var byHash = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var t in OpenTexts)
            {
                byHash[Sha(t)] = t;
            }

            foreach (var s in SessionRegistry.Read().AllSessions)
            {
                var p = s.Jsonl;
                if (string.IsNullOrEmpty(p) || !File.Exists(p))
                {
                    continue;
                }

                var full = LastSaid.Read(p).Full;
                if (full.Trim().Length > 0)
                {
                    byHash[Sha(full)] = full;
                }
            }

            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var sha = a?["sha"]?.GetValue<string>() ?? string.Empty;
                if (!byHash.TryGetValue(sha, out var text))
                {
                    // 🔴 ONE MARKER PER FIELD, so a message that changed between
                    // the two reads is forgiven as a whole row rather than
                    // leaving fields the allowance cannot match on.
                    rows.Add(new JsonObject
                    {
                        ["len"] = "(this side read different text)",
                        ["sha"] = sha,
                        ["any"] = "(this side read different text)",
                        ["reason"] = "(this side read different text)",
                    });
                    continue;
                }

                rows.Add(new JsonObject
                {
                    ["len"] = text.Length,
                    ["sha"] = sha,
                    ["any"] = OpenItems.Any(text),
                    ["reason"] = OpenItems.Reason(text),
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString();
        })
    {
        Tolerate = d => Diffs(d).All(x => x.Contains("this side read different text", StringComparison.Ordinal)),
        ToleranceReason = "a conversation said something new between the two reads, so its last message is not the one that was judged",
    };

    // ---------------------------------------------------------------------
    // The band itself.
    // ---------------------------------------------------------------------

    /// <summary>
    /// The window's own <c>Get-Band</c>, spliced out and run over the whole
    /// registry.
    /// </summary>
    /// <remarks>
    /// 🪤 <c>Resolve-SRSessionState</c> IS CALLED WITH <c>-Conv $null</c>, and
    /// that is not a simplification - it is what the window does. Update-Model
    /// passes no transcript state at all, so the corroboration test reduces to
    /// "is there a pid", and the transcript reader is not on the band path.
    /// Porting the Conv branch would have been porting a caller that does not
    /// exist.
    /// </remarks>
    private static OracleCase Live() => new(
        "bands/live",
        "the band every conversation is in - the window's own Get-Band",
        BandPreamble + """

        $rows = New-Object System.Collections.Generic.List[object]
        $said = New-Object System.Collections.Generic.List[object]
        foreach ($r in $script:model) {
            $rows.Add([ordered]@{ id = "$($r.Id)"; band = "$(Get-Band $r)" })
            $sd = $r.Said
            $said.Add([ordered]@{
                id      = "$($r.Id)"
                has     = [bool]$sd
                pending = $(if ($sd) { "$($sd.Pending)" } else { '' })
                saidLen = $(if ($sd) { [int]("$($sd.Said)".Trim().Length) } else { 0 })
                fullSha = $(if ($sd -and "$($sd.Full)".Trim()) {
                    ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("$($sd.Full)"))).Replace('-','').ToLower())
                } else { '' })
            })
        }
        (@{ rows = $rows.ToArray(); agents = $agents; said = $said.ToArray() } | ConvertTo-Json -Compress -Depth 6)
        """,
        psOut =>
        {
            var doc = JsonNode.Parse(psOut);
            var agents = AgentsFrom(doc);
            var said = SaidFrom(doc);

            var rows = new JsonArray();
            var spread = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var a in doc?["rows"]?.AsArray() ?? [])
            {
                var id = a?["id"]?.GetValue<string>() ?? string.Empty;
                var conv = SessionState.Of(agents.GetValueOrDefault(id));
                var band = Bands.Of(conv, said.GetValueOrDefault(id));
                spread[band] = spread.GetValueOrDefault(band) + 1;
                rows.Add(new JsonObject { ["id"] = id, ["band"] = band });
            }

            Rows = rows.Count;
            Spread = string.Join(", ", spread.OrderByDescending(k => k.Value)
                .Select(k => k.Value.ToString(CultureInfo.InvariantCulture) + " " + k.Key));

            return new JsonObject
            {
                ["rows"] = rows,
                ["agents"] = AgentsBack(doc, agents),
                ["said"] = SaidBack(doc, said),
            }.ToJsonString();
        })
    {
        Tolerate = d => Diffs(d).All(x => x.Contains("this side read different text", StringComparison.Ordinal)),
        ToleranceReason = "a conversation said something new between the two reads",
    };

    /// <summary>
    /// Every band, including the ones nothing on the machine is in.
    /// </summary>
    /// <remarks>
    /// 🔴 THIS IS THE CASE THAT CAN GO RED. `bands/live` walks every
    /// conversation and almost all of them are quiet - a band reached by three
    /// different routes - so most of Get-Band is unexercised by it. The agent
    /// statuses here are the question, spelled the same way on both sides.
    /// </remarks>
    private static OracleCase Shapes() => new(
        "bands/shapes",
        "every route into every band, from a synthetic agent report",
        BandShapesPreamble,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var k = a?["k"]?.GetValue<string>() ?? string.Empty;
                var sh = BandShapes.FirstOrDefault(x => string.Equals(x.K, k, StringComparison.Ordinal));
                if (sh.K is null)
                {
                    rows.Add(new JsonObject { ["k"] = k, ["band"] = "(no such shape here)" });
                    continue;
                }

                var agent = sh.Status is null
                    ? null
                    : new AgentStatus("id", sh.Status, sh.WaitingFor, sh.Needs, sh.Pid, "interactive", "n", string.Empty, sh.Started);
                var conv = SessionState.Of(agent);
                var said = sh.SaidText is null
                    ? null
                    : new SaidResult(sh.SaidText, sh.Pending, string.Empty, DateTimeOffset.UnixEpoch, sh.FullText ?? sh.SaidText);

                rows.Add(new JsonObject
                {
                    ["k"] = k,
                    ["state"] = conv.State,
                    ["needs"] = conv.Needs,
                    ["stuck"] = conv.Stuck,
                    ["stale"] = conv.Stale,
                    ["band"] = Bands.Of(conv, said, sh.AskSeen),
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString();
        });

    private static OracleCase Rail() => new(
        "bands/rail",
        "the rail's four age bands, at each cut and either side of it",
        """
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        foreach ($fn in @('Get-RailBandCuts', 'Get-RailBandKey')) {
            $a = $winSrc.IndexOf("function $fn")
            $b = $winSrc.IndexOf("`n}", $a)
            Invoke-Expression $winSrc.Substring($a, $b - $a + 2)
        }
        $cuts = Get-RailBandCuts
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($c in @($cuts.Today, $cuts.Week, $cuts.Month)) {
            foreach ($off in @(-1, 0, 1)) {
                $rows.Add([ordered]@{ at = [string]([long]$c + $off); key = "$(Get-RailBandKey ([long]$c + $off) $cuts)" })
            }
        }
        $rows.Add([ordered]@{ at = '0'; key = "$(Get-RailBandKey 0 $cuts)" })
        (@{ today = [string]$cuts.Today; week = [string]$cuts.Week; month = [string]$cuts.Month
           rows = $rows.ToArray() } | ConvertTo-Json -Compress -Depth 4)
        """,
        psOut =>
        {
            var doc = JsonNode.Parse(psOut);
            var cuts = RailCuts.At();
            var rows = new JsonArray();
            foreach (var a in doc?["rows"]?.AsArray() ?? [])
            {
                var at = long.Parse(a?["at"]?.GetValue<string>() ?? "0", CultureInfo.InvariantCulture);
                rows.Add(new JsonObject
                {
                    ["at"] = at.ToString(CultureInfo.InvariantCulture),
                    ["key"] = cuts.KeyFor(at),
                });
            }

            return new JsonObject
            {
                ["today"] = cuts.Today.ToString(CultureInfo.InvariantCulture),
                ["week"] = cuts.Week.ToString(CultureInfo.InvariantCulture),
                ["month"] = cuts.Month.ToString(CultureInfo.InvariantCulture),
                ["rows"] = rows,
            }.ToJsonString();
        })
    {
        // 🪤 THE CUTS ARE MIDNIGHT-RELATIVE AND THE TWO SIDES READ THEM SECONDS
        // APART, so a run that straddles midnight legitimately disagrees about
        // every one of them. Forgiven only as a whole - a single key differing
        // while the cuts match is a real defect.
        Tolerate = d => Diffs(d).Any(x => x.Contains("$.today", StringComparison.Ordinal)),
        ToleranceReason = "the comparison straddled midnight, so the two sides computed different cuts",
    };


    /// <summary>
    /// 🔴 WHAT YOU ARE READING STAYS ON SCREEN, and this is the predicate that
    /// promises it. A conversation drops off once it stops being live and its
    /// last activity passes 24 hours - and the refresh runs every six seconds, so
    /// without the selection clause it could vanish from under the reading pane
    /// mid-read and the rebuild would select a DIFFERENT conversation in its
    /// place. Compared with a selection set, without one, and with one that is
    /// not on the surface by any other route.
    /// </summary>
    private static OracleCase OnSurface() => new(
        "bands/on-surface",
        "live, warm, and pinned-because-selected - over every conversation, twice",
        """
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        foreach ($fn in @('Test-Warm', 'Test-OnSurface')) {
            $a = $winSrc.IndexOf("function $fn")
            if ($a -lt 0) { throw "could not find $fn" }
            $b = $winSrc.IndexOf("`n}", $a)
            Invoke-Expression $winSrc.Substring($a, $b - $a + 2)
        }
        $agentMap = Get-SRAgentStatus -Refresh
        $reg = Get-SRRegistry
        $model = New-Object System.Collections.Generic.List[object]
        foreach ($d in @($reg.directories)) {
            foreach ($s in @($d.sessions)) {
                $id = "$($s.sessionId)".ToLower()
                $model.Add([PSCustomObject]@{ Id = $id; S = $s; D = $d; A = $agentMap[$id]; Live = [bool]$agentMap[$id]; Warm = $null })
            }
        }
        # The coldest conversation NOTHING IS RUNNING, so the selection clause is
        # the only thing that could put it on the surface.
        # 🪤 `-not $r.Live` IS THE WHOLE POINT OF THIS PICK, and leaving it out
        # made the case unable to fail: the coldest conversation on this machine
        # is LIVE - a running session whose registry lastActive was never
        # updated - so Test-OnSurface returned on its first line and the clause
        # under test was never reached. A deliberate break to it stayed green.
        $coldest = ''; $best = [long]::MaxValue
        foreach ($r in $model) {
            if ($r.Live) { continue }
            $t = 0L
            try { $t = ([datetime]$r.S.lastActive).Ticks } catch { }
            if ($t -gt 0 -and $t -lt $best) { $best = $t; $coldest = "$($r.Id)" }
        }
        if (-not $coldest) { throw 'no conversation is both cold and not running, so the selection clause cannot be exercised' }
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($sel in @('', "$coldest")) {
            $script:selId = $(if ($sel) { $sel } else { $null })
            foreach ($r in $model) {
                # 🪤 Warm IS THE SAME QUESTION DECIDED ONCE, and the window sets
                # it on the row. Both arms are compared: without it (a bare
                # session object, which re-parses the date) and with it, which is
                # the path the painted row takes.
                $r.Warm = $null
                $bare = [bool](Test-OnSurface $r)
                $r.Warm = [bool](Test-Warm $r.S)
                $painted = [bool](Test-OnSurface $r)
                $rows.Add([ordered]@{
                    sel = "$sel"; id = "$($r.Id)"; live = [bool]$r.Live
                    warm = [bool]$r.Warm; bare = $bare; painted = $painted
                })
            }
        }
        $script:selId = $null
        (@{ coldest = "$coldest"; rows = $rows.ToArray() } | ConvertTo-Json -Compress -Depth 5)
        """,
        psOut =>
        {
            var doc = JsonNode.Parse(psOut);
            var coldest = doc?["coldest"]?.GetValue<string>() ?? string.Empty;
            var byId = new Dictionary<string, RegistrySession>(StringComparer.OrdinalIgnoreCase);
            foreach (var s in SessionRegistry.Read().AllSessions)
            {
                byId[s.SessionId.ToLowerInvariant()] = s;
            }

            var rows = new JsonArray();
            foreach (var a in doc?["rows"]?.AsArray() ?? [])
            {
                var id = a?["id"]?.GetValue<string>() ?? string.Empty;
                var sel = a?["sel"]?.GetValue<string>() ?? string.Empty;
                // 🔑 `live` IS THE QUESTION - "does claude report this one" -
                // and case 2.5a compares that on its own. Everything else on the
                // row is computed here.
                var live = a?["live"]?.GetValue<bool>() ?? false;
                byId.TryGetValue(id, out var session);
                var warm = Titles.Warm(session);
                var selected = sel.Length > 0 ? sel : null;

                rows.Add(new JsonObject
                {
                    ["sel"] = sel,
                    ["id"] = id,
                    ["live"] = live,
                    ["warm"] = warm,
                    ["bare"] = Surface.Shows(live, null, id, selected, session),
                    ["painted"] = Surface.Shows(live, warm, id, selected, session),
                });
            }

            return new JsonObject { ["coldest"] = coldest, ["rows"] = rows }.ToJsonString();
        })
    {
        // 🪤 THE 24-HOUR EDGE MOVES WHILE THIS RUNS. A conversation whose
        // lastActive is within a second of the cut-off legitimately answers warm
        // on one side and cold on the other. Forgiven only where `warm` itself is
        // the field that differs - a surface verdict differing while warm agrees
        // is a real defect.
        Tolerate = d => Diffs(d).All(x => x.Contains(".warm", StringComparison.Ordinal)),
        ToleranceReason = "a conversation sat within a second of the 24-hour cut-off and the two sides read the clock apart",
    };

    // ---------------------------------------------------------------------

    private const string BandPreamble = """
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        $want = @('Test-SROpenDismissed', 'Get-SRRestingBand', 'Get-Band')
        foreach ($fn in $want) {
            $a = $winSrc.IndexOf("function $fn")
            if ($a -lt 0) { throw "could not find $fn in sessions-window.ps1" }
            $b = $winSrc.IndexOf("`n}", $a)
            if ($b -lt 0) { throw "could not find the end of $fn" }
            Invoke-Expression $winSrc.Substring($a, $b - $a + 2)
        }
        foreach ($fn in $want) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { throw "$fn did not define" }
        }
        # The window's own two module-scope values these read.
        $script:HandbackMinChars = 40
        $script:askSeen = @{}
        $script:openDismissed = @{}

        $agentMap = Get-SRAgentStatus -Refresh
        $script:model = New-Object System.Collections.Generic.List[object]
        $reg = Get-SRRegistry
        foreach ($d in @($reg.directories)) {
            if ($d.missing) { continue }
            foreach ($s in @($d.sessions)) {
                if ($s.gone) { continue }
                $id = "$($s.sessionId)".ToLower()
                $a = $agentMap[$id]
                # 🪤 -Conv $null IS WHAT UPDATE-MODEL PASSES. Not a shortcut - the
                # transcript reader is not on the band path at all.
                $cv = Resolve-SRSessionState -Agent $a -Conv $null
                $sd = $null
                $p = "$($s.jsonl)"
                if ($p -and (Test-Path -LiteralPath $p)) { try { $sd = Get-SRLastSaid -JsonlPath $p } catch { } }
                $script:model.Add([PSCustomObject]@{ Id = $id; S = $s; D = $d; A = $a; Conv = $cv; Said = $sd })
            }
        }
        $agents = New-Object System.Collections.Generic.List[object]
        foreach ($r in $script:model) {
            if (-not $r.A) { continue }
            $agents.Add([ordered]@{
                id = "$($r.Id)"; status = "$($r.A.Status)"; waitingFor = "$($r.A.WaitingFor)"
                needs = [bool]$r.A.Needs; agentPid = [int]$r.A.Pid
                started = $(if ($r.A.StartedAt) { [string]([datetime]$r.A.StartedAt).Ticks } else { '' })
            })
        }
        $agents = $agents.ToArray()
        """;

    /// <summary>
    /// The synthetic band shapes. 🔑 Spelled once, in PowerShell, and mirrored by
    /// <see cref="BandShapes"/> - the two lists are the same question asked of
    /// both sides.
    /// </summary>
    private const string BandShapesPreamble = """
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        foreach ($fn in @('Test-SROpenDismissed', 'Get-SRRestingBand', 'Get-Band')) {
            $a = $winSrc.IndexOf("function $fn")
            $b = $winSrc.IndexOf("`n}", $a)
            Invoke-Expression $winSrc.Substring($a, $b - $a + 2)
        }
        $script:HandbackMinChars = 40
        $script:askSeen = @{}
        $script:openDismissed = @{}
        $long = 'x' * 60
        $open = 'I have done the first part. Shall I do the second one as well?'
        $shapes = @(
            @{ k='nothing';      st=$null;        wf=''; nd=$false; pid=0;   sd=$null;  fl=$null; ask=$false }
            @{ k='busy';         st='busy';       wf=''; nd=$false; pid=100; sd=$null;  fl=$null; ask=$false }
            @{ k='waiting';      st='waiting';    wf='input needed'; nd=$true; pid=100; sd=$null; fl=$null; ask=$false }
            @{ k='dialog';       st='waiting';    wf='DIALOG OPEN';  nd=$true; pid=100; sd=$null; fl=$null; ask=$false }
            @{ k='blocked-live';  st='blocked';   wf=''; nd=$true;  pid=100; sd=$null;  fl=$null; ask=$false }
            @{ k='blocked-stuck'; st='blocked';   wf=''; nd=$true;  pid=0;   sd=$null;  fl=$null; ask=$false }
            @{ k='idle-nosaid';  st='idle';       wf=''; nd=$false; pid=100; sd=$null;  fl=$null; ask=$false }
            @{ k='idle-short';   st='idle';       wf=''; nd=$false; pid=100; sd='too short'; fl='too short'; ask=$false }
            @{ k='idle-pending'; st='idle';       wf=''; nd=$false; pid=100; sd=$long; fl=$long;  ask=$false; pd='Bash' }
            @{ k='idle-done';    st='idle';       wf=''; nd=$false; pid=100; sd=$long; fl=$long;  ask=$false }
            @{ k='idle-open';    st='idle';       wf=''; nd=$false; pid=100; sd=$long; fl=$open;  ask=$false }
            @{ k='idle-ask-seen'; st='idle';      wf=''; nd=$false; pid=100; sd=$long; fl=$long;  ask=$true }
            @{ k='busy-ask-seen'; st='busy';      wf=''; nd=$false; pid=100; sd=$null;  fl=$null; ask=$true }
            @{ k='stuck-ask-seen'; st='blocked';  wf=''; nd=$true;  pid=0;   sd=$null;  fl=$null; ask=$true }
            @{ k='unknown';      st='reticulating'; wf=''; nd=$false; pid=100; sd=$null; fl=$null; ask=$false }
            # 🔴 THE ONLY ROUTE THAT TESTS THE QUIET EXCLUSION. A stuck row
            # returns quiet from Get-Band's FIRST line, before the askSeen
            # override is reached, so it proves nothing about it. An unrecognised
            # status reaches the switch, falls through to quiet, and THEN meets
            # the override - which must not promote it.
            @{ k='unknown-ask-seen'; st='reticulating'; wf=''; nd=$false; pid=100; sd=$null; fl=$null; ask=$true }
        )
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($sh in $shapes) {
            $ag = $null
            if ($sh.st) {
                $ag = [PSCustomObject]@{
                    Status = $sh.st; WaitingFor = $sh.wf; Needs = [bool]$sh.nd; Pid = [int]$sh.pid
                    StartedAt = $null
                }
            }
            $cv = Resolve-SRSessionState -Agent $ag -Conv $null
            $sd = $null
            if ($null -ne $sh.sd) {
                $sd = [PSCustomObject]@{
                    Said = "$($sh.sd)"; Pending = "$($sh.pd)"; Full = "$($sh.fl)"
                    At = ([datetime]'1970-01-01T00:00:00Z')
                }
            }
            $r = [PSCustomObject]@{ Id = "$($sh.k)"; Conv = $cv; Said = $sd }
            $script:askSeen = @{}
            if ($sh.ask) { $script:askSeen["$($sh.k)"] = $true }
            $rows.Add([ordered]@{
                k     = "$($sh.k)"
                state = "$($cv.State)"
                needs = [bool]$cv.Needs
                stuck = [bool]$cv.Stuck
                stale = [bool]$cv.Stale
                band  = "$(Get-Band $r)"
            })
        }
        (@{ rows = $rows.ToArray() } | ConvertTo-Json -Compress -Depth 5)
        """;

    private static readonly (string K, string? Status, string WaitingFor, bool Needs, int Pid,
        string? SaidText, string? FullText, string Pending, bool AskSeen, DateTimeOffset? Started)[] BandShapes =
    [
        ("nothing", null, "", false, 0, null, null, "", false, null),
        ("busy", "busy", "", false, 100, null, null, "", false, null),
        ("waiting", "waiting", "input needed", true, 100, null, null, "", false, null),
        ("dialog", "waiting", "DIALOG OPEN", true, 100, null, null, "", false, null),
        ("blocked-live", "blocked", "", true, 100, null, null, "", false, null),
        ("blocked-stuck", "blocked", "", true, 0, null, null, "", false, null),
        ("idle-nosaid", "idle", "", false, 100, null, null, "", false, null),
        ("idle-short", "idle", "", false, 100, "too short", "too short", "", false, null),
        ("idle-pending", "idle", "", false, 100, Long, Long, "Bash", false, null),
        ("idle-done", "idle", "", false, 100, Long, Long, "", false, null),
        ("idle-open", "idle", "", false, 100, Long, OpenText, "", false, null),
        ("idle-ask-seen", "idle", "", false, 100, Long, Long, "", true, null),
        ("busy-ask-seen", "busy", "", false, 100, null, null, "", true, null),
        ("stuck-ask-seen", "blocked", "", true, 0, null, null, "", true, null),
        ("unknown", "reticulating", "", false, 100, null, null, "", false, null),
        ("unknown-ask-seen", "reticulating", "", false, 100, null, null, "", true, null),
    ];

    private const string Long = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    private const string OpenText = "I have done the first part. Shall I do the second one as well?";

    /// <summary>One example per open-item rule, plus the shapes that must NOT fire.</summary>
    private static readonly string[] OpenTexts =
    [
        "Everything is finished and there is nothing left.",
        "I rebuilt the index. Did that cover what you wanted?",
        "Remaining:\n- [ ] wire up the second reader\n- [x] the first one",
        "The parser is done; the writer is still outstanding.",
        "I have not yet started the migration.",
        "That is blocked on the credentials being rotated.",
        "Two open questions before I carry on.",
        "Let me know which of the two you prefer.",
        "Shall I go ahead and delete the old table?",
        "Would you like me to keep the backup?",
        "It is up to you whether the cap stays.",
        "If you'd rather I stopped, say the word.",
        "## OPEN: the cutover date",
        "NEXT: hand this to the reviewer",
        "   #### Decisions: which store wins",
        "A question mark in the middle? Then more text after it.",
        "- [x] all boxes ticked",
        "",
        "   ",
    ];

    private static string Shapes(IEnumerable<string> texts)
    {
        var sb = new System.Text.StringBuilder();
        foreach (var t in texts)
        {
            sb.Append("$texts.Add('")
              .Append(t.Replace("'", "''", StringComparison.Ordinal).Replace("\n", "' + [char]10 + '", StringComparison.Ordinal))
              .AppendLine("')");
        }

        return sb.ToString();
    }

    private static string Sha(string s) =>
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(
            System.Text.Encoding.UTF8.GetBytes(s))).ToLowerInvariant();

    private static Dictionary<string, AgentStatus> AgentsFrom(JsonNode? doc)
    {
        var map = new Dictionary<string, AgentStatus>(StringComparer.OrdinalIgnoreCase);
        foreach (var a in doc?["agents"]?.AsArray() ?? [])
        {
            var id = a?["id"]?.GetValue<string>() ?? string.Empty;
            if (id.Length == 0)
            {
                continue;
            }

            var startedTicks = a?["started"]?.GetValue<string>() ?? string.Empty;
            DateTimeOffset? started = startedTicks.Length > 0
                ? new DateTimeOffset(new DateTime(long.Parse(startedTicks, CultureInfo.InvariantCulture), DateTimeKind.Local))
                : null;

            map[id] = new AgentStatus(
                id,
                a?["status"]?.GetValue<string>() ?? string.Empty,
                a?["waitingFor"]?.GetValue<string>() ?? string.Empty,
                a?["needs"]?.GetValue<bool>() ?? false,
                a?["agentPid"]?.GetValue<int>() ?? 0,
                "interactive",
                string.Empty,
                string.Empty,
                started);
        }

        return map;
    }

    private static JsonArray AgentsBack(JsonNode? doc, Dictionary<string, AgentStatus> agents)
    {
        var back = new JsonArray();
        foreach (var a in doc?["agents"]?.AsArray() ?? [])
        {
            var id = a?["id"]?.GetValue<string>() ?? string.Empty;
            if (!agents.TryGetValue(id, out var got))
            {
                back.Add(new JsonObject { ["id"] = "(not parsed here) " + id });
                continue;
            }

            back.Add(new JsonObject
            {
                ["id"] = got.SessionId,
                ["status"] = got.Status,
                ["waitingFor"] = got.WaitingFor,
                ["needs"] = got.Needs,
                ["agentPid"] = got.Pid,
                ["started"] = got.StartedAt is null
                    ? string.Empty
                    : got.StartedAt.Value.LocalDateTime.Ticks.ToString(CultureInfo.InvariantCulture),
            });
        }

        return back;
    }

    /// <summary>
    /// This side reads every last-said itself; the PowerShell's digest is only
    /// used to line the rows up and to say when the text moved underneath.
    /// </summary>
    private static Dictionary<string, SaidResult> SaidFrom(JsonNode? doc)
    {
        var byId = new Dictionary<string, SaidResult>(StringComparer.OrdinalIgnoreCase);
        var jsonl = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var s in SessionRegistry.Read().AllSessions)
        {
            jsonl[s.SessionId.ToLowerInvariant()] = s.Jsonl ?? string.Empty;
        }

        foreach (var a in doc?["said"]?.AsArray() ?? [])
        {
            var id = a?["id"]?.GetValue<string>() ?? string.Empty;
            if (!jsonl.TryGetValue(id, out var p) || string.IsNullOrEmpty(p) || !File.Exists(p))
            {
                continue;
            }

            byId[id] = LastSaid.Read(p);
        }

        return byId;
    }

    private static JsonArray SaidBack(JsonNode? doc, Dictionary<string, SaidResult> said)
    {
        var back = new JsonArray();
        foreach (var a in doc?["said"]?.AsArray() ?? [])
        {
            var id = a?["id"]?.GetValue<string>() ?? string.Empty;
            var got = said.GetValueOrDefault(id);
            var psSha = a?["fullSha"]?.GetValue<string>() ?? string.Empty;
            var mySha = got is not null && got.Full.Trim().Length > 0 ? Sha(got.Full) : string.Empty;

            if (!string.Equals(psSha, mySha, StringComparison.Ordinal))
            {
                back.Add(new JsonObject
                {
                    ["id"] = id,
                    ["has"] = "(this side read different text)",
                    ["pending"] = "(this side read different text)",
                    ["saidLen"] = "(this side read different text)",
                    ["fullSha"] = "(this side read different text)",
                });
                continue;
            }

            back.Add(new JsonObject
            {
                ["id"] = id,
                ["has"] = got is not null,
                ["pending"] = got?.Pending ?? string.Empty,
                ["saidLen"] = (got?.Said ?? string.Empty).Trim().Length,
                ["fullSha"] = mySha,
            });
        }

        return back;
    }

    /// <summary>Every conversation with the project it sits under, by id.</summary>
    private static Dictionary<string, (RegistrySession Session, RegistryDirectory Directory)> Pairs()
    {
        var map = new Dictionary<string, (RegistrySession, RegistryDirectory)>(StringComparer.OrdinalIgnoreCase);
        foreach (var d in SessionRegistry.Read().Directories)
        {
            foreach (var s in d.Sessions)
            {
                map[s.SessionId] = (s, d);
            }
        }

        return map;
    }

    private static IEnumerable<string> Diffs(string d) =>
        (d ?? string.Empty).Split('\n').Select(x => x.Trim()).Where(x => x.Length > 0);
}
