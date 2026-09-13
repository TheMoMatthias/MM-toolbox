using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Rows;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 4.1 (2b) - the queue mark on a session row: <c>Get-SRQueue</c>,
/// <c>Test-SRQueueFresh</c>, and the per-row block in <c>Build-Sessions</c>.
/// </summary>
/// <remarks>
/// 🔴 LIVE DATA REACHES ALMOST NONE OF THIS. A queue is a handful of records in a
/// few conversations, and on most runs nothing is waiting at all - so a green over
/// the live transcripts would prove the empty path. Each rule gets a synthetic
/// shape, spelled once here and written by BOTH sides from the same bytes.
///
/// 🪤 EACH SIDE WRITES ITS OWN COPY AND DELETES IT IN ITS OWN FINALLY. The
/// PowerShell runs first and the C# second, so one shared fixture would have to
/// outlive a PowerShell that may fail - and leak whenever it did.
/// </remarks>
public static class QueueCases
{
    private const int LiveSample = 60;

    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (ReadShapes(), true, "every queue rule, on transcripts built to reach it");
        yield return (ReadLive(), true, $"what is queued, over the {LiveSample} newest conversations");
        yield return (Fresh(), true, "whether a queue is still current, at every boundary");
        yield return (Mark(), true, "the row's mark and its tooltip, against Build-Sessions' own block");
    }

    /// <summary>How many live conversations held still and were compared, and how many had anything queued.</summary>
    public static int LiveCompared { get; private set; }

    public static int LiveWithQueue { get; private set; }

    public static string Coverage() => string.Format(CultureInfo.InvariantCulture,
        "{0} conversation(s) compared, {1} with anything queued", LiveCompared, LiveWithQueue);

    // ------------------------------------------------------------------ shapes

    private sealed record Shape(string Name, string[] Lines, int MaxTail = 0);

    private static string Rec(string op, string? content, string? ts = "2026-09-13T08:00:00.000Z", string type = "queue-operation")
    {
        var o = new JsonObject { ["type"] = type, ["operation"] = op };
        if (ts is not null)
        {
            o["timestamp"] = ts;
        }

        if (content is not null)
        {
            o["content"] = content;
        }

        return o.ToJsonString();
    }

    private static readonly Shape[] Shapes =
    [
        new("remove-matches-one", [Rec("enqueue", "first"), Rec("enqueue", "second"), Rec("remove", "first")]),
        new("hop-chain-is-not-part-of-the-key",
        [
            Rec("enqueue", "<cross-session-message from=\"a\" hop-chain=\"x,y\">hi</cross-session-message>"),
            Rec("remove", "<cross-session-message from=\"a\">hi</cross-session-message>"),
        ]),
        new("remove-matching-nothing-is-ignored", [Rec("enqueue", "kept"), Rec("remove", "never queued")]),
        new("remove-is-case-insensitive", [Rec("enqueue", "Hello There"), Rec("remove", "hello there")]),
        new("pop-all", [Rec("enqueue", "a"), Rec("enqueue", "b"), Rec("popAll", null), Rec("enqueue", "c")]),
        new("dequeue-takes-the-front", [Rec("dequeue", null), Rec("enqueue", "a"), Rec("enqueue", "b"), Rec("dequeue", null)]),
        new("operation-and-type-case", [Rec("Enqueue", "upper op"), Rec("ENQUEUE", "shout", type: "Queue-Operation")]),
        new("blank-content-is-not-queued", [Rec("enqueue", "   "), Rec("enqueue", "\r\n"), Rec("enqueue", "real")]),
        new("ansi-is-removed", [Rec("enqueue", "\u001b[31mred\u001b[0m words")]),
        new("mine-and-machine",
        [
            Rec("enqueue", "<task-notification>done</task-notification>"),
            Rec("enqueue", "   <system-reminder>x</system-reminder>"),
            Rec("enqueue", "please also check the logs\nsecond line"),
            Rec("enqueue", "## a heading\n\n- the point"),
        ]),
        new("timestamps", [Rec("enqueue", "no time", ts: null), Rec("enqueue", "bad time", ts: "not a date"), Rec("enqueue", "local", ts: "2026-09-13T10:00:00")]),
        new("noise-lines",
        [
            "\uFEFF" + Rec("enqueue", "after a bom"),
            "   \t" + Rec("enqueue", "after spaces"),
            "{\"type\":\"queue-operation\",\"operation\":\"enqueue\",\"content\":\"broken",
            "not json at all \"queue-operation\"",
            "{\"type\":\"user\",\"message\":\"mentions \\\"queue-operation\\\" in passing\"}",
            Rec("enqueue", "crlf ended") + "\r",
        ]),
        new("a-tail-that-starts-mid-record",
        [
            Rec("enqueue", new string('x', 300)),
            Rec("enqueue", "inside the tail"),
        ],
        MaxTail: 180),
        new("empty-file", []),
    ];

    private static byte[] Bytes(Shape s) =>
        s.Lines.Length == 0 ? [] : Encoding.UTF8.GetBytes(string.Join("\n", s.Lines) + "\n");

    private static OracleCase ReadShapes()
    {
        // 🔴 PLAIN STRING EXPRESSIONS, NOT BASE64. The first version shipped each
        // fixture as a base64 blob that PowerShell decoded and wrote to disk -
        // which is a dropper's shape, and the antivirus's script scan refused the
        // whole case before it ran. Every character outside printable ASCII is
        // spelled as [char]0xNNNN, so the bytes are exact and nothing is encoded.
        var spec = new StringBuilder();
        foreach (var s in Shapes)
        {
            spec.Append(CultureInfo.InvariantCulture, $"@{{ n = '{s.Name}'; t = {s.MaxTail}; l = @(");
            spec.Append(string.Join(", ", s.Lines.Select(PsText.Literal)));
            spec.Append(") },\n");
        }

        return new OracleCase(
            "queue/read-shapes",
            "every queue rule, on transcripts built to reach it",
            RowFunction + "\n" + """
            $dir = Join-Path ([IO.Path]::GetTempPath()) ('sr-queue-ps-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Path $dir
            try {
                $shapes = @(
            """ + spec + """
                    $null)
                $rows = New-Object System.Collections.Generic.List[object]
                foreach ($s in $shapes) {
                    if (-not $s) { continue }
                    $p = Join-Path $dir ($s.n + '.jsonl')
                    $text = $(if (@($s.l).Count) { (@($s.l) -join "`n") + "`n" } else { '' })
                    [IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding $false))
                    $v = $(if ($s.t -gt 0) { Get-SRQueue -JsonlPath $p -MaxTailBytes $s.t } else { Get-SRQueue -JsonlPath $p })
                    $rows.Add((ConvertTo-SRQueueRow $s.n $v))
                }
                (@{ rows = $rows.ToArray() } | ConvertTo-Json -Compress -Depth 5)
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
            """,
            _ =>
            {
                var dir = Path.Combine(Path.GetTempPath(), "sr-queue-cs-" + Guid.NewGuid().ToString("N")[..8]);
                Directory.CreateDirectory(dir);
                try
                {
                    var rows = new JsonArray();
                    foreach (var s in Shapes)
                    {
                        var p = Path.Combine(dir, s.Name + ".jsonl");
                        File.WriteAllBytes(p, Bytes(s));
                        rows.Add(Row(s.Name, Waiting.Read(p, s.MaxTail)));
                    }

                    return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
                }
                finally
                {
                    try
                    {
                        Directory.Delete(dir, recursive: true);
                    }
                    catch (IOException) { }
                }
            })
        ;
    }

    // -------------------------------------------------------------------- live

    private static OracleCase ReadLive() => new(
        "queue/read-live",
        "what is queued, over the newest conversations",
        RowFunction + "\n" + $$"""
        $reg = Get-SRRegistry
        $all = @()
        foreach ($d in @($reg.directories)) {
            foreach ($s in @($d.sessions)) {
                $p = "$($s.jsonl)"
                if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
                $all += [PSCustomObject]@{ Id = "$($s.sessionId)"; P = $p; A = $s.lastActive }
            }
        }
        $pick = @($all | Sort-Object -Property @{ E = { [datetime]$_.A } } -Descending | Select-Object -First {{LiveSample}})
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($x in $pick) {
            # 🪤 THE LENGTH BEFORE THE READ. See Moving.
            $len = $(try { (Get-Item -LiteralPath $x.P).Length } catch { -1 })
            $v = Get-SRQueue -JsonlPath $x.P
            $row = ConvertTo-SRQueueRow $x.Id $v
            $row['len'] = $len
            $row['wrote'] = $(if ($v.LastWrite -eq [datetime]::MinValue) { 'unknown' } else { "$(([datetime]$v.LastWrite).ToUniversalTime().Ticks)" })
            $rows.Add($row)
        }
        (@{ rows = $rows.ToArray() } | ConvertTo-Json -Compress -Depth 5)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var byId = Core.Registry.SessionRegistry.Read().AllSessions
                .Where(s => !string.IsNullOrEmpty(s.Jsonl))
                .GroupBy(s => s.SessionId, StringComparer.Ordinal)
                .ToDictionary(g => g.Key, g => g.First().Jsonl!, StringComparer.Ordinal);

            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var id = a?["name"]?.GetValue<string>() ?? string.Empty;
                var askedLen = a?["len"]?.GetValue<long>() ?? -1;
                if (!byId.TryGetValue(id, out var path))
                {
                    rows.Add(Moving.Mark(a, "name", "(no such conversation here)"));
                    continue;
                }

                if (askedLen < 0 || Length(path) != askedLen)
                {
                    rows.Add(Moving.Mark(a, "name", Grew));
                    continue;
                }

                var v = Waiting.Read(path);
                if (Length(path) != askedLen)
                {
                    rows.Add(Moving.Mark(a, "name", Grew));
                    continue;
                }

                var row = Row(id, v);
                row["len"] = askedLen;
                row["wrote"] = v.LastWrite == DateTime.MinValue
                    ? "unknown"
                    : v.LastWrite.ToUniversalTime().Ticks.ToString(CultureInfo.InvariantCulture);
                rows.Add(row);
                LiveCompared++;
                if (v.Count > 0)
                {
                    LiveWithQueue++;
                }
            }

            if (LiveCompared == 0)
            {
                rows.Add(new JsonObject { ["name"] = "(nothing was compared)" });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        })
    {
        Tolerate = d => Moving.IsMarked(d, Grew),
        ToleranceReason = "the conversation was written to between the two reads - a growing file, not a differing reader",
    };

    private const string Grew = "(it was written to between the two reads)";

    // ----------------------------------------------------- one row, both sides

    /// <summary>
    /// The PowerShell's half of <see cref="Row"/>. 🔑 Every field is answered
    /// from the returned object, and the text is hashed rather than compared
    /// raw, so a long queued message is one line in a difference, not a page.
    /// </summary>
    private const string RowFunction = """
        function ConvertTo-SRQueueRow($name, $v) {
            $sep = [string][char]1
            $texts = (@($v.Items) | ForEach-Object { "$($_.Text)" }) -join $sep
            $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($texts))).Replace('-', '')
            return [ordered]@{
                name    = "$name"
                ok      = [bool]$v.Ok
                count   = [int]$v.Count
                mine    = [int]$v.Mine
                machine = [int]$v.Machine
                first   = (@($v.Items) | ForEach-Object { "$($_.First)" }) -join $sep
                at      = (@($v.Items) | ForEach-Object { if ($_.At) { "$(([datetime]$_.At).ToUniversalTime().Ticks)" } else { '-' } }) -join $sep
                isMine  = (@($v.Items) | ForEach-Object { if ($_.Mine) { '1' } else { '0' } }) -join $sep
                textSha = $sha
            }
        }
        """;

    private static JsonObject Row(string name, QueueState v)
    {
        const string sep = "\u0001";
        var texts = string.Join(sep, v.Items.Select(i => i.Text));
        return new JsonObject
        {
            ["name"] = name,
            ["ok"] = v.Ok,
            ["count"] = v.Count,
            ["mine"] = v.Mine,
            ["machine"] = v.Machine,
            ["first"] = string.Join(sep, v.Items.Select(i => i.First)),
            ["at"] = string.Join(sep, v.Items.Select(i => i.At is { } at
                ? at.ToUniversalTime().Ticks.ToString(CultureInfo.InvariantCulture)
                : "-")),
            ["isMine"] = string.Join(sep, v.Items.Select(i => i.Mine ? "1" : "0")),
            ["textSha"] = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(texts))),
        };
    }

    // ------------------------------------------------------ fresh, and the mark

    /// <summary>A queue spelled for both sides: whose, and how many minutes old (null = undated).</summary>
    private sealed record Item(bool Mine, string Text, double? AgeMinutes);

    private sealed record QueueSpec(string Name, Item[] Items);

    // 🔑 AGES SIT MID-BUCKET, NOT ON A BOUNDARY, for the mark only: the shipped
    // tooltip reads its OWN clock inside Get-AgeTicks, a few milliseconds after
    // the one this case hands both sides. The FRESH shapes sit on the boundaries
    // on purpose, because there both sides are given the same now.
    private static readonly QueueSpec[] Specs =
    [
        new("empty", []),
        new("undated-only", [new(true, "no date", null)]),
        new("mine-young", [new(true, "yours, 10m20s", 10.34)]),
        new("mine-stale", [new(true, "yours, 2h", 120.5)]),
        new("mine-exactly-an-hour", [new(true, "yours, 60m", 60.0)]),
        new("machine-young", [new(false, "<task-notification>1m</task-notification>", 1.0)]),
        new("machine-exactly-two-minutes", [new(false, "<task-notification>2m</task-notification>", 2.0)]),
        new("machine-stale-but-yours-young", [new(false, "<x>9m</x>", 9.0), new(true, "yours, 30m", 30.4)]),
        new("machine-stale-only", [new(false, "<x>9m</x>", 9.0), new(false, "<y>20m</y>", 20.0)]),
        new("stale-dated-plus-undated", [new(true, "old", 300.0), new(true, "no date", null)]),
        new("two-of-yours-behind-machine", [new(false, "<x>now</x>", 0.5), new(true, "first of yours\nmore", 5.3), new(true, "second", null)]),
        new("yours-undated-first", [new(true, "## undated heading", null), new(true, "dated", 3.4)]),
    ];

    private static string SpecJson()
    {
        var arr = new JsonArray();
        foreach (var s in Specs)
        {
            var items = new JsonArray();
            foreach (var i in s.Items)
            {
                items.Add(new JsonObject { ["mine"] = i.Mine, ["text"] = i.Text, ["age"] = i.AgeMinutes });
            }

            arr.Add(new JsonObject { ["name"] = s.Name, ["items"] = items });
        }

        return arr.ToJsonString(Compact).Replace("'", "''", StringComparison.Ordinal);
    }

    private static QueueState Build(QueueSpec s, DateTime now)
    {
        var items = s.Items
            .Select(i => new QueuedMessage(i.Text, LastSaid.FirstLine(i.Text),
                i.AgeMinutes is { } m ? now.AddMinutes(-m) : null, i.Mine))
            .ToList();
        return new QueueState(items, items.Count(i => i.Mine), items.Count(i => !i.Mine), true, now);
    }

    /// <summary>The same queue, built in PowerShell from the same spec, against one captured now.</summary>
    private static string PsBuild() => $$"""
        $specs = '{{SpecJson()}}' | ConvertFrom-Json
        $now = Get-Date
        function New-SRSpecQueue($s, $now) {
            $items = @()
            foreach ($i in @($s.items)) {
                if ($null -eq $i) { continue }
                $at = $(if ($null -ne $i.age) { $now.AddMinutes(-[double]$i.age) } else { $null })
                $items += [PSCustomObject]@{ Text = "$($i.text)"; First = (Get-SRFirstLine "$($i.text)"); At = $at; Mine = [bool]$i.mine }
            }
            return [PSCustomObject]@{
                Items = $items; Count = $items.Count
                Mine = @($items | Where-Object { $_.Mine }).Count
                Machine = @($items | Where-Object { -not $_.Mine }).Count
                Ok = $true; LastWrite = $now
            }
        }
        """;

    private const string SpliceWindow = """
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        foreach ($fn in @('Test-SRQueueFresh', 'Get-AgeLabel', 'Get-AgeTicks')) {
            $a = $winSrc.IndexOf("function $fn")
            if ($a -lt 0) { throw "could not find $fn in sessions-window.ps1" }
            $b = $winSrc.IndexOf("`n}", $a)
            Invoke-Expression $winSrc.Substring($a, $b - $a + 2)
        }
        """;

    private static OracleCase Fresh() => new(
        "queue/fresh",
        "whether a queue is still current, at every boundary",
        SpliceWindow + "\n" + PsBuild() + "\n" + """

        $rows = @()
        foreach ($s in @($specs)) {
            $rec = New-SRSpecQueue $s $now
            $rows += [ordered]@{
                name = "$($s.name)"
                single = [bool](Test-SRQueueFresh -Rec $rec -Now $now -MaxHours 1.0)
                split  = [bool](Test-SRQueueFresh -Rec $rec -Now $now -MaxHours 1.0 -MachineMins 2.0)
            }
        }
        (@{ now = $now.Ticks; rows = $rows } | ConvertTo-Json -Compress -Depth 4)
        """,
        psOut =>
        {
            var o = JsonNode.Parse(psOut);
            var now = new DateTime(o?["now"]?.GetValue<long>() ?? 0, DateTimeKind.Local);
            var rows = new JsonArray();
            foreach (var s in Specs)
            {
                var rec = Build(s, now);
                rows.Add(new JsonObject
                {
                    ["name"] = s.Name,
                    ["single"] = Waiting.Fresh(rec, now, 1.0),
                    ["split"] = Waiting.Fresh(rec, now, 1.0, 2.0),
                });
            }

            return new JsonObject { ["now"] = now.Ticks, ["rows"] = rows }.ToJsonString(Compact);
        });

    /// <summary>
    /// 🔴 THE MARK IS COMPARED AGAINST BUILD-SESSIONS' OWN BLOCK, spliced out of
    /// the window by its first and last lines - not against a copy of it. The
    /// block is inline in the row loop, so there is no function to call; a copy
    /// here would be a test of what I believe it does.
    /// </summary>
    private static OracleCase Mark() => new(
        "queue/mark",
        "the row's mark and its tooltip, against Build-Sessions' own block",
        SpliceWindow + "\n" + PsBuild() + "\n" + """

        $from = $winSrc.IndexOf('            $qRec = $r.Q')
        if ($from -lt 0) { throw 'could not find the queue block in Build-Sessions' }
        $to = $winSrc.IndexOf('            $items.Add([PSCustomObject]@{', $from)
        if ($to -lt 0) { throw 'could not find the end of the queue block' }
        $block = $winSrc.Substring($from, $to - $from)
        $V_Show = 'Visible'; $V_Hide = 'Collapsed'; $qGrey = 'grey'; $qAmber = 'amber'
        $SR_QueueStaleHours = 1.0; $SR_QueueMachineStaleMins = 2.0
        $rows = @()
        foreach ($s in @($specs)) {
            $r = [PSCustomObject]@{ Q = (New-SRSpecQueue $s $now) }
            $nowDate = $now
            Invoke-Expression $block
            $rows += [ordered]@{ name = "$($s.name)"; vis = "$qVis"; text = "$qTxt"; tip = "$qTip"; brush = "$qBrush" }
        }
        (@{ now = $now.Ticks; rows = $rows } | ConvertTo-Json -Compress -Depth 4)
        """,
        psOut =>
        {
            var o = JsonNode.Parse(psOut);
            var now = new DateTime(o?["now"]?.GetValue<long>() ?? 0, DateTimeKind.Local);
            var rows = new JsonArray();
            foreach (var s in Specs)
            {
                var m = QueueMark.Of(Build(s, now), now);
                rows.Add(new JsonObject
                {
                    ["name"] = s.Name,
                    ["vis"] = m.Visible ? "Visible" : "Collapsed",
                    ["text"] = m.Text,
                    ["tip"] = m.Tip,
                    ["brush"] = m.Mine ? "amber" : "grey",
                });
            }

            return new JsonObject { ["now"] = now.Ticks, ["rows"] = rows }.ToJsonString(Compact);
        });

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
}
