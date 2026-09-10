using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 2.3 - the transcript reader, over every conversation on disk.
/// </summary>
public static class TranscriptCases
{
    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (LastSaidEverywhere(), true, "what every conversation last said, and what it left running");
        yield return (FirstLineRules(), true, "one line out of markdown, on the awkward shapes");
    }

    /// <summary>
    /// 🔴 THE COLUMN THE WHOLE LIST IS FOR. "What did this conversation last
    /// say" is the question the work surface exists to answer, so it is compared
    /// over every transcript on the machine rather than a sample.
    /// </summary>
    /// <remarks>
    /// 🪤 `Full` IS COMPARED BY LENGTH AND BOTH ENDS, NOT WHOLE. It is capped at
    /// 4.000 characters and there are ~550 conversations, so emitting it in full
    /// would put two megabytes through a pipe to prove something its length and
    /// its two ends already prove - and a difference in the middle still moves
    /// the length. Head and tail are there so a difference says WHERE.
    /// </remarks>
    private static OracleCase LastSaidEverywhere() => new(
        "transcript/last-said",
        "every conversation's last words, its pending tool and when it spoke",
        """
        $reg = Get-SRRegistry
        $rows = @()
        foreach ($d in @($reg.directories)) {
            foreach ($s in @($d.sessions)) {
                $p = "$($s.jsonl)"
                if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
                $v = Get-SRLastSaid -JsonlPath $p
                $full = "$($v.Full)"
                # 🔴 THE LENGTH OF THE FILE THAT WAS READ, so the other side can
                # say whether it read the same one. This case had no allowance at
                # all and went red whenever a conversation spoke mid-run - which
                # on this machine means whenever the operator is working.
                $len = $(try { (Get-Item -LiteralPath $p).Length } catch { -1 })
                $rows += [ordered]@{
                    id          = "$($s.sessionId)"
                    len         = [long]$len
                    said        = "$($v.Said)"
                    pending     = "$($v.Pending)"
                    pendingTool = "$($v.PendingTool)"
                    at          = $(if ($v.At) { ([datetime]$v.At).ToUniversalTime().Ticks } else { $null })
                    fullLen     = $full.Length
                    fullHead    = $(if ($full.Length -gt 60) { $full.Substring(0, 60) } else { $full })
                    fullTail    = $(if ($full.Length -gt 60) { $full.Substring($full.Length - 60) } else { $full })
                }
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 6)
        """,
        psOut =>
        {
            // The question is "these conversations" - the ids come from the
            // PowerShell so both sides answer about the same set. The ANSWERS
            // are computed here from the file, never read back out of psOut.
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var byId = Core.Registry.SessionRegistry.Read()
                .AllSessions
                .Where(s => !string.IsNullOrEmpty(s.Jsonl))
                .GroupBy(s => s.SessionId, StringComparer.Ordinal)
                .ToDictionary(g => g.Key, g => g.First().Jsonl!, StringComparer.Ordinal);

            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var id = a?["id"]?.GetValue<string>() ?? string.Empty;
                if (!byId.TryGetValue(id, out var path))
                {
                    // Say so rather than skipping: a row this side cannot even
                    // find is a difference, not an absence.
                    rows.Add(Marked(id, "(no such conversation here)"));
                    continue;
                }

                // 🔴 A CONVERSATION THAT SPOKE BETWEEN THE TWO READS IS NOT A
                // DEFECT, and this case had no way to say so - it went red on
                // $.rows[281].said with two perfectly good last lines from two
                // different moments. The marker goes in EVERY field the other
                // side emitted, or the unmarked ones report "present in
                // PowerShell, missing in C#" and match no allowance.
                var askedLen = a?["len"]?.GetValue<long>() ?? -1;
                var nowLen = Length(path);
                if (askedLen >= 0 && nowLen != askedLen)
                {
                    rows.Add(Marked(id, Grew));
                    continue;
                }

                var v = LastSaid.Read(path);
                var full = v.Full;
                rows.Add(new JsonObject
                {
                    ["id"] = id,
                    ["len"] = nowLen,
                    ["said"] = v.Said,
                    ["pending"] = v.Pending,
                    ["pendingTool"] = v.PendingTool,
                    ["at"] = v.At?.UtcTicks,
                    ["fullLen"] = full.Length,
                    ["fullHead"] = full.Length > 60 ? full[..60] : full,
                    ["fullTail"] = full.Length > 60 ? full[^60..] : full,
                });
                Compared++;
            }

            // 🔴 AND FAIL IF NOTHING WAS COMPARED. A run where every transcript
            // grew would otherwise agree about nothing at all and print green.
            if (Compared == 0)
            {
                rows.Add(new JsonObject { ["id"] = "(nothing was compared)" });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        })
    {
        Tolerate = d => d.Split('\n').Select(x => x.Trim()).Where(x => x.Length > 0)
                         .All(x => x.Contains(Grew, StringComparison.Ordinal)),
        ToleranceReason = "the conversation said something between the two reads - a growing file, not a differing reader",
    };

    /// <summary>How many conversations held still and were really compared.</summary>
    public static int Compared { get; private set; }

    private const string Grew = "(it spoke between the two reads)";

    /// <summary>
    /// A row this side could not answer for, with the reason in every field the
    /// PowerShell emitted.
    /// </summary>
    private static JsonObject Marked(string id, string why) => new()
    {
        ["id"] = id,
        ["len"] = why,
        ["said"] = why,
        ["pending"] = why,
        ["pendingTool"] = why,
        ["at"] = why,
        ["fullLen"] = why,
        ["fullHead"] = why,
        ["fullTail"] = why,
    };

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
        catch (UnauthorizedAccessException)
        {
            return -1;
        }
    }

    /// <summary>
    /// The headline rules, on the shapes that actually break them.
    /// </summary>
    /// <remarks>
    /// 🔑 THESE ARE FIXTURES, NOT LIVE DATA, and deliberately so. The live
    /// comparison above proves the two agree on what is there; this one proves
    /// they agree on the awkward shapes that may not be in any transcript today
    /// - a fenced code block first, a heading, a bullet, an over-long line.
    /// </remarks>
    private static OracleCase FirstLineRules() => new(
        "transcript/first-line",
        "a one-line headline out of markdown, including the shapes with no prose at the top",
        // 🪤 NOT ONE BACKTICK IN HERE, DELIBERATELY. The first version built
        // this PowerShell out of C# string concatenation with backtick-n escapes
        // and came back with 13 fixtures where there are 10 - the escaping was
        // splitting entries, so the difference the oracle reported was about the
        // harness rather than about the code. Single quotes and an explicit
        // newline character have one meaning each.
        """
        $nl    = [string][char]10
        $fence = [string][char]96 + [string][char]96 + [string][char]96
        $cases = @(
            'plain sentence',
            ($nl + $nl + '   leading blanks then text'),
            ($fence + $nl + 'fenced first' + $nl + $fence + $nl + 'after the fence'),
            ('## a heading' + $nl + 'and a line'),
            ('- a bullet' + $nl + 'and a line'),
            ('**bold** and ' + [string][char]96 + 'code' + [string][char]96 + ' inline'),
            '   spaced    out     words   ',
            ('x' * 400),
            '',
            ($nl + $nl + $nl)
        )
        $rows = New-Object System.Collections.Generic.List[string]
        foreach ($c in $cases) { $null = $rows.Add((Get-SRFirstLine "$c")) }
        (@{ rows = $rows.ToArray() } | ConvertTo-Json -Compress -Depth 4)
        """,
        () =>
        {
            string[] cases =
            [
                "plain sentence",
                "\n\n   leading blanks then text",
                "```\nfenced first\n```\nafter the fence",
                "## a heading\nand a line",
                "- a bullet\nand a line",
                "**bold** and `code` inline",
                "   spaced    out     words   ",
                new string('x', 400),
                string.Empty,
                "\n\n\n",
            ];
            // 🪤 JsonArray.Add(string) GOES THROUGH AN IMPLICIT CONVERSION that
            // needs a TypeInfoResolver on the options, and these have none - it
            // throws at serialise time rather than at compile time. Serialising
            // a plain array asks nothing of the options.
            var rows = cases.Select(c => LastSaid.FirstLine(c)).ToArray();
            return JsonSerializer.Serialize(new { rows }, Compact);
        });
}
