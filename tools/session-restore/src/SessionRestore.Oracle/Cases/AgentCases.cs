using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Sessions;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 2.5a - what claude says about its own sessions.
/// </summary>
/// <remarks>
/// 🔑 THE SAME MOVING-TARGET PROBLEM AS A SCREEN, MILDER. A session goes from
/// busy to idle while this runs. So the PowerShell asks TWICE and only sessions
/// whose every field was identical across both reads are compared - one that
/// changed its mind mid-run is a fact about the session, not about either
/// reader.
/// </remarks>
public static class AgentCases
{
    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Map(), true, "every session claude reports, and what it says about it");
    }

    private static OracleCase Map() => new(
        "agents/map",
        "the agent map - status, what it waits for, pid, kind, name, cwd and start",
        """
        function Get-SRAgentSnapshot {
            $m = Get-SRAgentStatus -Refresh
            $o = [ordered]@{}
            foreach ($k in @($m.Keys | Sort-Object)) {
                $v = $m[$k]
                $o[$k] = [ordered]@{
                    status     = "$($v.Status)"
                    waitingFor = "$($v.WaitingFor)"
                    needs      = [bool]$v.Needs
                    pid        = [int]$v.Pid
                    kind       = "$($v.Kind)"
                    name       = "$($v.Name)"
                    cwd        = "$($v.Cwd)"
                    startedAt  = $(if ($v.StartedAt) { ([datetime]$v.StartedAt).ToUniversalTime().Ticks } else { $null })
                }
            }
            return $o
        }
        $a = Get-SRAgentSnapshot
        Start-Sleep -Milliseconds 700
        $b = Get-SRAgentSnapshot

        # Only what did not change its mind between the two asks.
        $rows = [ordered]@{}
        foreach ($k in @($b.Keys)) {
            if (-not $a.Contains($k)) { continue }
            $sa = ($a[$k] | ConvertTo-Json -Compress -Depth 4)
            $sb = ($b[$k] | ConvertTo-Json -Compress -Depth 4)
            if ($sa -ne $sb) { continue }
            $rows[$k] = $b[$k]
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 5)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsObject() ?? [];
            var mine = AgentMap.Read(refresh: true);

            var rows = new JsonObject();
            foreach (var kv in asked)
            {
                if (!mine.TryGetValue(kv.Key, out var v))
                {
                    // Saying so beats leaving the key out: an absence would
                    // read as agreement about a session this side never saw.
                    rows[kv.Key] = new JsonObject { ["status"] = "(not reported here)" };
                    continue;
                }

                rows[kv.Key] = new JsonObject
                {
                    ["status"] = v.Status,
                    ["waitingFor"] = v.WaitingFor,
                    ["needs"] = v.Needs,
                    ["pid"] = v.Pid,
                    ["kind"] = v.Kind,
                    ["name"] = v.Name,
                    ["cwd"] = v.Cwd,
                    ["startedAt"] = v.StartedAt?.UtcTicks,
                };
                Compared++;
            }

            // 🔴 A CHECK THAT CANNOT TELL MUST NOT PRINT GREEN. If claude was
            // unreachable, both sides would hand back nothing and this would
            // pass having established nothing at all.
            if (Compared == 0)
            {
                rows["(nothing)"] = new JsonObject
                {
                    ["status"] = "NOTHING WAS COMPARED - claude reported no stable session, so this run proved nothing",
                };
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        });

    /// <summary>How many sessions were actually held to a comparison.</summary>
    public static int Compared { get; private set; }
}
