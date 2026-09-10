using System.Globalization;
using System.Text.Json.Nodes;
using SessionRestore.Core;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 3.4 - the cadences, checked against the window that still ships.
/// </summary>
/// <remarks>
/// 🔑 THIS IS A DRIFT CHECK RATHER THAN A PORT CHECK, and it is the only kind
/// available: the timers are created at window scope in a file the oracle must
/// not load, so what both sides can answer is "what interval does this timer
/// have". The PowerShell reads its own source; the C# reports its table. A timer
/// changed in the window and not in `Cadences` goes red.
///
/// 🪤 IT MATTERS MORE THAN IT LOOKS. These numbers are the whole of how live the
/// tool feels, and every one was chosen against a measurement - so the failure
/// this catches is not a crash, it is a rebuild that quietly feels different from
/// the tool it replaces, in a way nobody can point at.
/// </remarks>
public static class CadenceCases
{
    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Intervals(), true, "every timer's interval, against the shipped window's source");
    }

    private static OracleCase Intervals() => new(
        "loops/cadences",
        "the eleven timers and what they are set to",
        """
        $src = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))

        # The three intervals that are named constants rather than literals.
        $named = @{}
        foreach ($n in @('FastSeconds', 'LiveSeconds', 'AskPollFastMs')) {
            $m = [regex]::Match($src, '\$script:' + $n + '\s*=\s*(\d+)')
            if ($m.Success) { $named[$n] = [double]$m.Groups[1].Value }
        }

        $rows = New-Object System.Collections.Generic.List[object]
        # 🪤 THE FIRST *RESOLVABLE* ASSIGNMENT PER TIMER, not the first one in
        # the file. askTimer's interval is re-set at runtime from a conditional -
        # `$(if ($slow ...))` - and that assignment appears EARLIER in the source
        # than the one that creates it. Taking the first textual match reported
        # "could not resolve: $(if ($slow" for a timer whose cadence is a plain
        # constant twelve thousand lines further down.
        $seen = @{}
        foreach ($m in [regex]::Matches($src, '\$script:(\w+Timer)\.Interval\s*=\s*\[TimeSpan\]::From(\w+)\(([^)]*)\)')) {
            $name = $m.Groups[1].Value
            if ($seen.ContainsKey($name)) { continue }
            $unit = $m.Groups[2].Value
            $arg  = $m.Groups[3].Value.Trim()
            $v = $null
            if ($arg -match '^\d+(\.\d+)?$') { $v = [double]$arg }
            else {
                foreach ($k in $named.Keys) { if ($arg -like ('*' + $k + '*')) { $v = $named[$k] } }
            }
            if ($null -eq $v) { continue }
            $seen[$name] = $true
            $ms = switch ($unit) {
                'Milliseconds' { $v }
                'Seconds'      { $v * 1000 }
                'Minutes'      { $v * 60000 }
                default        { -1 }
            }
            $rows.Add([ordered]@{ name = $name; ms = [string][int]$ms })
        }
        (@{ rows = ($rows.ToArray() | Sort-Object { $_.name }) } | ConvertTo-Json -Compress -Depth 4)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var name = a?["name"]?.GetValue<string>() ?? string.Empty;
                rows.Add(new JsonObject
                {
                    ["name"] = name,
                    // 🔴 A TIMER THIS SIDE HAS NEVER HEARD OF IS A DIFFERENCE, not
                    // an absence. It means the window grew a cadence the rebuild
                    // does not have, which is exactly the drift this exists for.
                    ["ms"] = Cadences.ByTimerName.TryGetValue(name, out var t)
                        ? ((int)t.TotalMilliseconds).ToString(CultureInfo.InvariantCulture)
                        : "(no cadence of that name in the rebuild)",
                });
            }

            // 🔴 AND FAIL IF NOTHING WAS COMPARED - a regex that stopped matching
            // would otherwise agree about an empty list.
            if (rows.Count == 0)
            {
                rows.Add(new JsonObject { ["name"] = "(no timers were found in the window's source)" });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString();
        });
}
