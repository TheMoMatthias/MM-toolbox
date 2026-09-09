using System.Globalization;
using System.Text.Json;
using SessionRestore.Core.Registry;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 2.2 - the registry read, against the operator's real 1 MB file.
/// </summary>
/// <remarks>
/// 🔑 DATES ARE COMPARED AS UTC TICKS, NEVER AS TEXT. PowerShell 5.1's
/// ConvertFrom-Json turns an ISO-8601 string into a [DateTime], and
/// ConvertTo-Json writes it back with trailing zeros dropped - so
/// "…01.5109300+02:00" returns as "…01.51093+02:00". That is a formatting
/// difference and nothing else, and a harness that reported 558 of them would be
/// switched off by the second run. A tick count has one spelling.
/// </remarks>
public static class RegistryCases
{
    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Shape(), true, "the same version, scan time and counts");
        yield return (Directories(), true, "every project, its flags and its conversation count");
        yield return (Sessions(), true, "every conversation, every field, all 558 of them");
    }

    private static OracleCase Shape() => new(
        "registry/shape",
        "the file's own header and the size of what is in it",
        """
        $r = Get-SRRegistry
        $sessions = 0
        foreach ($d in @($r.directories)) { $sessions += @($d.sessions).Count }
        $rej = 0
        if ($r.PSObject.Properties['rejected'] -and $r.rejected) {
            $rej = @($r.rejected.PSObject.Properties).Count
        }
        (@{
            version     = [int]$r.version
            lastScan    = $(if ($r.lastScan) { ([datetime]$r.lastScan).ToUniversalTime().Ticks } else { $null })
            directories = @($r.directories).Count
            sessions    = $sessions
            rejected    = $rej
        } | ConvertTo-Json -Compress)
        """,
        () =>
        {
            var r = SessionRegistry.Read();
            return JsonSerializer.Serialize(new
            {
                version = r.Version,
                lastScan = r.LastScan?.UtcTicks,
                directories = r.Directories.Count,
                sessions = r.AllSessions.Count(),
                rejected = r.Rejected?.Count ?? 0,
            }, Compact);
        });

    private static OracleCase Directories() => new(
        "registry/directories",
        "every project, with the flags that decide whether it is scanned at all",
        """
        $r = Get-SRRegistry
        $rows = @()
        foreach ($d in @($r.directories)) {
            $rows += [ordered]@{
                path      = "$($d.path)"
                enabled   = [bool]$d.enabled
                missing   = [bool]$d.missing
                firstSeen = $(if ($d.firstSeen) { ([datetime]$d.firstSeen).ToUniversalTime().Ticks } else { $null })
                sessions  = @($d.sessions).Count
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 6)
        """,
        () =>
        {
            var r = SessionRegistry.Read();
            var rows = r.Directories.Select(d => new
            {
                path = d.Path,
                enabled = d.Enabled,
                missing = d.Missing,
                firstSeen = d.FirstSeen?.UtcTicks,
                sessions = d.Sessions.Count,
            }).ToArray();
            return JsonSerializer.Serialize(new { rows }, Compact);
        });

    /// <summary>
    /// The one that actually proves the reader: every conversation, every field.
    /// </summary>
    /// <remarks>
    /// 🔴 THE TICK AND THE PIN ARE THE TWO FIELDS WORTH BEING LOUD ABOUT.
    /// `enabled` decides what reopens at the next logon and `pinned` decides what
    /// survives the registry window - reading either one wrongly is how a
    /// conversation quietly stops coming back.
    /// </remarks>
    private static OracleCase Sessions() => new(
        "registry/sessions",
        "every conversation and every field the registry keeps about it",
        """
        $r = Get-SRRegistry
        $rows = @()
        foreach ($d in @($r.directories)) {
            foreach ($s in @($d.sessions)) {
                $rows += [ordered]@{
                    id         = "$($s.sessionId)"
                    title      = "$($s.title)"
                    enabled    = [bool]$s.enabled
                    pinned     = [bool]$s.pinned
                    gone       = [bool]$s.gone
                    lane       = "$($s.lane)"
                    cwd        = "$($s.cwd)"
                    stamp      = "$($s.stamp)"
                    worktree   = $(if ($null -eq $s.worktree) { $null } else { "$($s.worktree)" })
                    jsonl      = $(if ($null -eq $s.jsonl) { $null } else { "$($s.jsonl)" })
                    autoTitle  = $(if ($null -eq $s.autoTitle) { $null } else { "$($s.autoTitle)" })
                    lastActive = $(if ($s.lastActive) { ([datetime]$s.lastActive).ToUniversalTime().Ticks } else { $null })
                    firstSeen  = $(if ($s.firstSeen) { ([datetime]$s.firstSeen).ToUniversalTime().Ticks } else { $null })
                }
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 6)
        """,
        () =>
        {
            var r = SessionRegistry.Read();
            var rows = r.Directories.SelectMany(d => d.Sessions).Select(s => new
            {
                id = s.SessionId,
                title = s.Title,
                enabled = s.Enabled,
                pinned = s.Pinned,
                gone = s.Gone,
                lane = s.Lane,
                cwd = s.Cwd,
                stamp = s.Stamp,
                worktree = s.Worktree,
                jsonl = s.Jsonl,
                autoTitle = s.AutoTitle,
                lastActive = s.LastActive?.UtcTicks,
                firstSeen = s.FirstSeen?.UtcTicks,
            }).ToArray();
            return JsonSerializer.Serialize(new { rows }, Compact);
        });

    /// <summary>How many conversations the comparison actually covered.</summary>
    public static string Covered()
    {
        var r = SessionRegistry.Read();
        return string.Format(CultureInfo.InvariantCulture,
            "{0} conversations across {1} projects", r.AllSessions.Count(), r.Directories.Count);
    }
}
