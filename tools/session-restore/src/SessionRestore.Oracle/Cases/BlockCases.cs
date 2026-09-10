using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 2.3b - <c>Get-SRTranscriptBlocks</c>, the reading model.
/// </summary>
/// <remarks>
/// 🪤 THIS ONE IS SCOPED TO A SAMPLE, DELIBERATELY, and the reason is what the
/// function actually costs: it reads a 2 MB tail per conversation, so running it
/// over all 546 would read the better part of a gigabyte to answer a question
/// about a pane that only ever parses ONE conversation - the selected one. The
/// sample is the most recently active, which is what the surface shows.
/// </remarks>
public static class BlockCases
{
    /// <summary>How many conversations the block comparison covers.</summary>
    public const int Sample = 15;

    /// <summary>
    /// The largest transcript this comparison will look at.
    /// </summary>
    /// <remarks>
    /// 🔴 THE SAMPLE OUTGREW ITSELF. At 40 conversations with no size limit it
    /// covered 474 MB and one 68 MB file, and the PowerShell side stopped
    /// answering inside a five-minute deadline - measured 2026-09-10, having run
    /// in 3,2 s the day before on the same code. Nothing changed but the data:
    /// a day's work made several of the most recent transcripts enormous.
    ///
    /// 🔑 SIZE IS NOT WHERE THE PARSER DIFFERS - VARIETY IS. What the giants
    /// exercise that the others do not is the WIDENING loop, and that is a
    /// deterministic path better proven by a fixture whose newest record is
    /// bigger than the window than by reading 68 MB through PowerShell. The
    /// first-line case already splits this way: fixtures for the awkward shapes,
    /// live data for what is actually there.
    ///
    /// 12 MB is above the p90 of 8 MB, so it keeps almost everything.
    /// </remarks>
    public const long MaxBytes = 12L * 1024 * 1024;

    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Shape(), true, $"the same blocks in the same order, over {Sample} conversations");
        yield return (Detail(), true, $"every field of every block, over {Sample} conversations");
    }

    /// <summary>PowerShell's own name for a block kind.</summary>
    private static string KindName(BlockKind k) => k switch
    {
        BlockKind.You => "you",
        BlockKind.Said => "said",
        BlockKind.Thinking => "thinking",
        BlockKind.Tool => "tool",
        BlockKind.Result => "result",
        BlockKind.Asked => "asked",
        BlockKind.MsgIn => "msgin",
        BlockKind.System => "system",
        BlockKind.Hook => "hook",
        BlockKind.File => "file",
        BlockKind.Queued => "queued",
        BlockKind.Compact => "compact",
        _ => "?",
    };

    private static string PsPickList(int take) => $$"""
        $reg = Get-SRRegistry
        $all = @()
        foreach ($d in @($reg.directories)) {
            foreach ($s in @($d.sessions)) {
                $p = "$($s.jsonl)"
                if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
                $len = $(try { (Get-Item -LiteralPath $p).Length } catch { [long]::MaxValue })
                $all += [PSCustomObject]@{ Id = "$($s.sessionId)"; P = $p; A = $s.lastActive; Bytes = $len }
            }
        }
        $pick = @($all |
            Where-Object { $_.Bytes -le {{MaxBytes}} } |
            Sort-Object -Property @{ E = { [datetime]$_.A } } -Descending |
            Select-Object -First {{take}})
        """;

    /// <summary>
    /// 🔴 THE SEQUENCE IS THE THING. A parser can get every individual block
    /// right and still emit them in the wrong order, or drop one kind entirely -
    /// which is exactly what happened in the PowerShell when system records,
    /// attachments and queue operations were all being discarded. Comparing the
    /// joined kind sequence catches a missing or extra block anywhere in it and
    /// says where.
    /// </summary>
    private static OracleCase Shape() => new(
        "transcript/blocks-shape",
        "the same blocks, of the same kinds, in the same order",
        PsPickList(Sample) + """

        $rows = @()
        foreach ($x in $pick) {
            # ASSIGN FIRST, WRAP SECOND. Get-SRTranscriptBlocks returns a
            # comma-guarded array, so @(...) around the CALL yields ONE element
            # holding the whole array - and PowerShell's member enumeration then
            # makes $b[0].Kind read as every kind at once, which looks like a
            # parser difference and is not.
            $b = Get-SRTranscriptBlocks -JsonlPath $x.P
            $b = @($b)
            $len = 0
            foreach ($y in $b) { $len += "$($y.Body)".Length }
            # 🪤 NOT $len. That name is ALREADY the body-sum accumulator four
            # lines up, so reusing it here overwrote the sum with the FILE SIZE
            # and bodyLen came back as 11.718.403 against the C#'s 13.492 - a
            # difference that looked like a parser disagreeing and was a name
            # collision. Same family as the $ShellId and $args collisions this
            # repo already records: a name that is already taken, in a language
            # that will not warn you.
            $fileLen = 0
            try { $fileLen = (Get-Item -LiteralPath $x.P).Length } catch { $fileLen = -1 }
            $rows += [ordered]@{
                id      = $x.Id
                len     = $fileLen
                n       = $b.Count
                kinds   = (($b | ForEach-Object { "$($_.Kind)" }) -join ',')
                heads   = (($b | ForEach-Object { "$($_.Head)" }) -join ',')
                bodyLen = $len
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 6)
        """,
        Answer((id, path, askedLen) =>
        {
            // 🔴 A TRANSCRIPT GROWS WHILE IT IS BEING READ, and the reading
            // window is a TAIL - so a conversation that gained one record
            // between the two sides gives two correct answers about two
            // different windows. Caught exactly that way: the C# list was the
            // PowerShell's shifted by one, same length, one gained at the end
            // and one lost at the start.
            var now = Length(path);
            if (askedLen >= 0 && now != askedLen)
            {
                return new JsonObject { ["id"] = id, ["len"] = -2, ["n"] = -2 };
            }

            var b = TranscriptBlocks.Read(path);
            return new JsonObject
            {
                ["id"] = id,
                ["len"] = now,
                ["n"] = b.Count,
                ["kinds"] = string.Join(",", b.Select(x => KindName(x.Kind))),
                ["heads"] = string.Join(",", b.Select(x => x.Head)),
                ["bodyLen"] = b.Sum(x => x.Body.Length),
            };
        }))
    {
        Tolerate = d => d.EndsWith("C# \"-2\"", StringComparison.Ordinal),
        ToleranceReason = "the conversation was written to between the two reads - a growing file, not a differing parser",
    };

    /// <summary>
    /// Every field of every block, on a smaller set - so a difference the shape
    /// case reports as "block 14 is a tool not a result" can be read.
    /// </summary>
    private static OracleCase Detail() => new(
        "transcript/blocks-detail",
        "the head, the meta, the timestamp and both ends of every block's body",
        PsPickList(Sample) + """

        $rows = @()
        foreach ($x in $pick) {
            $b = Get-SRTranscriptBlocks -JsonlPath $x.P
            $b = @($b)
            # 🪤 NEVER "$($y.Body)" HERE. That COPIES the body, and a body can be
            # megabytes - so a case doing it once per block over fifteen
            # conversations spent five minutes copying strings and was killed by
            # its own deadline, while blocks-shape did the same reading in 2,2 s
            # because it only ever asked for a Length. Body is already a string;
            # index it in place.
            $fileLen = $(try { (Get-Item -LiteralPath $x.P).Length } catch { -1 })
            foreach ($y in $b) {
                $bl = 0
                if ($null -ne $y.Body) { $bl = $y.Body.Length }
                $rows += [ordered]@{
                    id   = $x.Id
                    len  = $fileLen
                    kind = "$($y.Kind)"
                    head = "$($y.Head)"
                    meta = "$($y.Meta)"
                    when = $(if ($y.When) { ([datetime]$y.When).ToUniversalTime().Ticks } else { $null })
                    blen = $bl
                    head80 = $(if ($bl -gt 80) { $y.Body.Substring(0, 80) } elseif ($bl) { $y.Body } else { '' })
                    tail80 = $(if ($bl -gt 80) { $y.Body.Substring($bl - 80) } elseif ($bl) { $y.Body } else { '' })
                }
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 6)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var byId = PathsById();
            var rows = new JsonArray();

            // The PowerShell emits one row per BLOCK, so the ids repeat. Walk
            // the distinct ids in first-seen order and emit this side's blocks
            // for each - a count difference then shows up as a row count, which
            // is exactly what it is.
            var seen = new List<string>();
            var lenById = new Dictionary<string, long>(StringComparer.Ordinal);
            var rowsById = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var a in asked)
            {
                var id = a?["id"]?.GetValue<string>() ?? string.Empty;
                if (!seen.Contains(id, StringComparer.Ordinal))
                {
                    seen.Add(id);
                    lenById[id] = a?["len"]?.GetValue<long>() ?? -1;
                    rowsById[id] = 0;
                }

                rowsById[id]++;
            }

            foreach (var id in seen)
            {
                if (!byId.TryGetValue(id, out var path))
                {
                    rows.Add(new JsonObject { ["id"] = id, ["len"] = -1, ["kind"] = "(no such conversation here)" });
                    continue;
                }

                // The same pinning the shape case uses: a conversation written to
                // between the two reads gives two correct answers about two
                // different windows.
                var now = Length(path);
                if (lenById[id] >= 0 && now != lenById[id])
                {
                    // 🪤 ONE MARKER PER ROW THE OTHER SIDE EMITTED, so the two
                    // arrays stay the same length and a COUNT difference goes on
                    // meaning what it says. A single marker row made 289 rows
                    // face 290, and the only way to pass would have been a
                    // tolerance for "the counts differ" - which would forgive a
                    // genuine fifty-block disagreement just as happily.
                    //
                    // 🔑 HOW MANY ROWS is part of the QUESTION - which blocks are
                    // we talking about - not part of the answer. What each row
                    // SAYS is this side's own words.
                    for (var k = 0; k < rowsById[id]; k++)
                    {
                        rows.Add(new JsonObject { ["id"] = id, ["len"] = -2, ["kind"] = "(grew)" });
                    }

                    continue;
                }

                foreach (var y in TranscriptBlocks.Read(path))
                {
                    var body = y.Body;
                    rows.Add(new JsonObject
                    {
                        ["id"] = id,
                        ["len"] = now,
                        ["kind"] = KindName(y.Kind),
                        ["head"] = y.Head,
                        ["meta"] = y.Meta,
                        ["when"] = y.When?.UtcTicks,
                        ["blen"] = body.Length,
                        ["head80"] = body.Length > 80 ? body[..80] : body,
                        ["tail80"] = body.Length > 80 ? body[^80..] : body,
                    });
                }
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        })
    {
        // Exactly the marker a grown conversation makes, and nothing else.
        Tolerate = d => d.EndsWith("C# \"-2\"", StringComparison.Ordinal)
                     || d.EndsWith("C# \"(grew)\"", StringComparison.Ordinal),
        ToleranceReason = "the conversation was written to between the two reads - a growing file, not a differing parser",
    };

    private static Dictionary<string, string> PathsById() =>
        Core.Registry.SessionRegistry.Read().AllSessions
            .Where(s => !string.IsNullOrEmpty(s.Jsonl))
            .GroupBy(s => s.SessionId, StringComparer.Ordinal)
            .ToDictionary(g => g.Key, g => g.First().Jsonl!, StringComparer.Ordinal);

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

    private static Func<string, string> Answer(Func<string, string, long, JsonObject> one) =>
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var byId = PathsById();
            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var id = a?["id"]?.GetValue<string>() ?? string.Empty;
                var askedLen = a?["len"]?.GetValue<long>() ?? -1;
                rows.Add(byId.TryGetValue(id, out var path)
                    ? one(id, path, askedLen)
                    : new JsonObject { ["id"] = id, ["n"] = -1 });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        };
}
