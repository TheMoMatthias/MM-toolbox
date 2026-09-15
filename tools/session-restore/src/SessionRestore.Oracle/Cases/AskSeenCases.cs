using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Sessions;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 4.4's groundwork - the record that lets a screen's answer survive
/// a recompute.
/// </summary>
/// <remarks>
/// 🔴 THIS IS WHAT STOPPED A CONVERSATION FLIPPING BETWEEN NEEDS YOU AND
/// WORKING EVERY FEW SECONDS. The quiet check reads a screen, sees a menu, and
/// used to write the band directly - but the band is DERIVED, and every
/// recompute reached for the agent probe's answer instead. The probe says
/// "working" for a session sitting on a menu, so the two took turns.
///
/// 🔑 WHAT IS COMPARED IS THE RETURN VALUE AS WELL AS THE SET, and the return
/// value is the point: it says whether the flag MOVED, and the poll rebands only
/// when it did. A port that always returned true would put the whole model on a
/// 400 ms cadence; one that always returned false would leave a session asking
/// and the board not saying so.
/// </remarks>
public static class AskSeenCases
{
    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Sequence(), true, "Set-AskSeen over a sequence of polls, its answer and its set");
    }

    /// <param name="Id">Which conversation. Empty is a real input - a poll over whatever the probe last reported.</param>
    private static readonly (string Id, bool Asking)[] Steps =
    [
        ("", true),          // nothing to record, and not an error
        ("a", false),        // never seen: clearing changes nothing
        ("a", true),         // first sighting
        ("a", true),         // still there: no change, so no reband
        ("b", true),
        ("a", false),        // its menu went away
        ("a", false),        // and again: no change
        ("A", true),         // 🪤 THE SAME CONVERSATION, SHOUTED. PowerShell's
                             // hashtable is case-insensitive by default, so this
                             // is 'a' and not a second row.
        ("a", false),
        ("b", false),
        ("", false),
    ];

    private static OracleCase Sequence() => new(
        "agents/ask-seen",
        "Set-AskSeen's answer and its set, over a sequence of polls",
        Script(),
        _ =>
        {
            var set = new AskSeenSet();
            var rows = new JsonArray();
            foreach (var (id, asking) in Steps)
            {
                var moved = set.Set(id, asking);
                rows.Add(new JsonObject
                {
                    ["id"] = id,
                    ["asking"] = asking,
                    ["moved"] = moved,
                    ["count"] = set.Count,
                    ["flagged"] = string.Join(",", set.Ids.OrderBy(x => x, StringComparer.OrdinalIgnoreCase)),
                });
            }

            Steps_ = Steps.Length;
            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        });

    private static string Script()
    {
        var sb = new StringBuilder();
        sb.Append("""
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        $a = $winSrc.IndexOf('function Set-AskSeen')
        if ($a -lt 0) { throw 'could not find Set-AskSeen' }
        Invoke-Expression $winSrc.Substring($a, $winSrc.IndexOf("`n}", $a) - $a + 2)

        $script:askSeen = @{}
        $rows = @()
        $steps = @(
        """);

        foreach (var (id, asking) in Steps)
        {
            sb.Append("            @{ id='").Append(id).Append("'; ask=$")
              .Append(asking ? "true" : "false").Append(" }\n");
        }

        sb.Append("""
        )
        foreach ($s in $steps) {
            $moved = [bool](Set-AskSeen -Id $s.id -Asking ([bool]$s.ask))
            $rows += [ordered]@{
                id      = $s.id
                asking  = [bool]$s.ask
                moved   = $moved
                count   = $script:askSeen.Count
                flagged = ((@($script:askSeen.Keys) | Sort-Object) -join ',')
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 5)
        """);

        return sb.ToString();
    }

    private static int Steps_ { get; set; }

    public static string Coverage() => string.Format(CultureInfo.InvariantCulture,
        "{0} poll(s) compared, answer and set", Steps_);
}
