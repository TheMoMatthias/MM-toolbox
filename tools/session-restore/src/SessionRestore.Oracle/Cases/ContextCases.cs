using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 4.1 (2b-2) - the transcript's own account of the context:
/// the model, token count and window <c>Get-SRSessionVitals</c> reports.
/// </summary>
public static class ContextCases
{
    private const int LiveSample = 60;

    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Shapes(), true, "model, tokens and window, on transcripts built for every rule");
        yield return (Live(), true, $"model, tokens and window, over the {LiveSample} newest conversations");
    }

    public static int LiveCompared { get; private set; }

    private static string Assistant(string model, string usage) =>
        "{\"type\":\"assistant\",\"message\":{\"model\":\"" + model + "\",\"usage\":" + usage + ",\"content\":[]}}";

    private sealed record Shape(string Name, string[] Lines, int MaxTail = 0);

    private static readonly Shape[] Shapes_ =
    [
        new("last-usage-wins",
        [
            Assistant("claude-opus-5", "{\"input_tokens\":100,\"cache_read_input_tokens\":50,\"cache_creation_input_tokens\":0}"),
            Assistant("claude-opus-5", "{\"input_tokens\":1000,\"cache_read_input_tokens\":20000,\"cache_creation_input_tokens\":300}"),
        ]),
        new("a-zero-total-keeps-the-previous",
        [
            Assistant("claude-opus-5", "{\"input_tokens\":7000}"),
            Assistant("claude-opus-5", "{\"input_tokens\":0,\"output_tokens\":9}"),
        ]),
        new("synthetic-model-is-not-a-model",
        [
            Assistant("claude-opus-5", "{\"input_tokens\":10}"),
            Assistant("<synthetic>", "{\"input_tokens\":20}"),
            Assistant("<SYNTHETIC>", "{\"input_tokens\":30}"),
        ]),
        new("a-1m-model-is-a-1m-window", [Assistant("claude-opus-5[1m]", "{\"input_tokens\":5}")]),
        new("past-200k-is-a-1m-window", [Assistant("claude-sonnet-5", "{\"input_tokens\":200001}")]),
        new("exactly-200k-is-not", [Assistant("claude-sonnet-5", "{\"input_tokens\":200000}")]),
        new("string-and-fractional-figures",
            [Assistant("m", "{\"input_tokens\":\"123\",\"cache_read_input_tokens\":12.5,\"cache_creation_input_tokens\":13.5}")]),
        new("member-names-any-case",
            ["{\"type\":\"assistant\",\"MESSAGE\":{\"Model\":\"upper\",\"Usage\":{\"INPUT_TOKENS\":42}}}"]),
        new("messages-that-are-not-objects",
        [
            "{\"type\":\"user\",\"message\":null}",
            "{\"type\":\"user\",\"message\":\"a plain string\"}",
            "{\"type\":\"system\"}",
            Assistant("kept", "5"),
        ]),
        new("noise-lines",
        [
            "not json",
            "   " + Assistant("indented", "{\"input_tokens\":11}") + "\r",
            "{\"type\":\"assistant\",\"message\":{\"model\":\"broken\"",
            "[1,2,3]",
        ]),
        new("an-overflowing-sum-widens",
            [Assistant("m", "{\"input_tokens\":2000000000,\"cache_read_input_tokens\":2000000000,\"cache_creation_input_tokens\":2000000000}")]),
        new("a-figure-that-is-an-object-throws", [Assistant("m", "{\"input_tokens\":{\"n\":1}}")]),
        new("no-record-at-all", ["plain", "text"]),
        new("empty-file", []),
        // 🪤 THE MODEL IS ONLY ON THE RECORD OUTSIDE THE TAIL. The first version
        // gave both records a model, and the last one wins - so reading the whole
        // file and reading the tail gave the same answer, and a break that dropped
        // the tail limit stayed green.
        new("a-tail-that-starts-mid-record",
        [
            Assistant("early-outside-the-tail", "{\"input_tokens\":999}"),
            "{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":3}}}",
        ],
        MaxTail: 90),
    ];

    private const string RowFunction = """
        function ConvertTo-SRContextRow($name, $path, $tail) {
            try {
                $v = $(if ($tail -gt 0) { Get-SRSessionVitals -JsonlPath $path -NoDiff -MaxTailBytes $tail } else { Get-SRSessionVitals -JsonlPath $path -NoDiff })
            } catch { return [ordered]@{ name = "$name"; threw = $true } }
            return [ordered]@{ name = "$name"; threw = $false; ok = [bool]$v.Ok; model = "$($v.Model)"; tokens = [string]$v.Tokens; window = [string]$v.Window }
        }
        """;

    private static JsonObject Row(string name, string path, int tail)
    {
        ContextUse v;
        try
        {
            v = tail > 0 ? ContextUse.Read(path, tail) : ContextUse.Read(path);
        }
        catch (Exception ex) when (ex is FormatException or OverflowException)
        {
            return new JsonObject { ["name"] = name, ["threw"] = true };
        }

        return new JsonObject
        {
            ["name"] = name,
            ["threw"] = false,
            ["ok"] = v.Ok,
            ["model"] = v.Model,
            ["tokens"] = v.Tokens.ToString(CultureInfo.InvariantCulture),
            ["window"] = v.Window.ToString(CultureInfo.InvariantCulture),
        };
    }

    private static byte[] Bytes(Shape s) =>
        s.Lines.Length == 0 ? [] : Encoding.UTF8.GetBytes(string.Join("\n", s.Lines) + "\n");

    private static OracleCase Shapes()
    {
        var spec = new StringBuilder();
        foreach (var s in Shapes_)
        {
            spec.Append(CultureInfo.InvariantCulture, $"@{{ n = '{s.Name}'; t = {s.MaxTail}; l = @(");
            spec.Append(string.Join(", ", s.Lines.Select(PsText.Literal)));
            spec.Append(") },\n");
        }

        return new OracleCase(
            "context/shapes",
            "model, tokens and window, on transcripts built for every rule",
            RowFunction + "\n$shapes = @(\n" + spec + "$null)\n" + """
            $dir = Join-Path ([IO.Path]::GetTempPath()) ('sr-ctx-ps-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Path $dir
            try {
                $rows = @()
                foreach ($s in $shapes) {
                    if (-not $s) { continue }
                    $p = Join-Path $dir ($s.n + '.jsonl')
                    $text = $(if (@($s.l).Count) { (@($s.l) -join "`n") + "`n" } else { '' })
                    [IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding $false))
                    $rows += ConvertTo-SRContextRow $s.n $p $s.t
                }
                (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 4)
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
            """,
            _ =>
            {
                var dir = Path.Combine(Path.GetTempPath(), "sr-ctx-cs-" + Guid.NewGuid().ToString("N")[..8]);
                Directory.CreateDirectory(dir);
                try
                {
                    var rows = new JsonArray();
                    foreach (var s in Shapes_)
                    {
                        var p = Path.Combine(dir, s.Name + ".jsonl");
                        File.WriteAllBytes(p, Bytes(s));
                        rows.Add(Row(s.Name, p, s.MaxTail));
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
            });
    }

    private const string Grew = "(it was written to between the two reads)";

    private static OracleCase Live() => new(
        "context/live",
        "model, tokens and window, over the newest conversations",
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
        $rows = @()
        foreach ($x in $pick) {
            $len = $(try { (Get-Item -LiteralPath $x.P).Length } catch { -1 })
            $row = ConvertTo-SRContextRow $x.Id $x.P 0
            $row['len'] = $len
            $rows += $row
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 4)
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
                    // Not the grown marker: a conversation this side cannot find
                    // is a real difference and must not be forgiven as one.
                    rows.Add(Moving.Mark(a, "name", "(no such conversation here)"));
                    continue;
                }

                if (askedLen < 0 || Length(path) != askedLen)
                {
                    rows.Add(Moving.Mark(a, "name", Grew));
                    continue;
                }

                var row = Row(id, path, 0);
                if (Length(path) != askedLen)
                {
                    rows.Add(Moving.Mark(a, "name", Grew));
                    continue;
                }

                row["len"] = askedLen;
                rows.Add(row);
                LiveCompared++;
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
