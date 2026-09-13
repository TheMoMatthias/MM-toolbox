using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Rows;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 4.2 - what the two search boxes match, against the three shipped
/// lines that decide it: the haystack in <c>Update-Model</c> and both filters in
/// <c>Build-Sessions</c>.
/// </summary>
/// <remarks>
/// 🔴 THE LINES ARE SPLICED BY THEIR OWN TEXT, not retyped: the haystack assignment,
/// and the condition of each <c>-notlike</c>. A change to what the window searches
/// goes red here instead of making the rebuild quietly search something else.
/// </remarks>
public static class SearchCases
{
    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Filter(), true, "both search boxes, wildcards and invalid patterns included, against the window's own lines");
    }

    private sealed record Row(string Title, string? Auto, string Path, string Id, string Label);

    private static readonly Row[] Rows =
    [
        new("REFACTOR-LOOP", "refactor the loop", @"C:\work\api\src", "2641f7fc-1313", "api / src"),
        new("jobradar", null, @"D:\Jobs\radar", "aa11bb22", "radar"),
        new("Plan [draft] v2", "a*b?c", @"C:\x\web\src", "ffee0011", "web / src"),
    ];

    private static readonly string[] Needles =
    [
        "", "loop", "LOOP", "api / src", "web / src", "2641", "radar", "d:\\jobs",
        "ref*loop", "r?dar", "[jr]obradar", "`[draft`]", "a`*b", "[draft", "x[", "draft]",
        "refactor the", "cwd-only-text", " ",
    ];

    private static OracleCase Filter()
    {
        var rows = new StringBuilder();
        foreach (var r in Rows)
        {
            rows.Append("[PSCustomObject]@{ t = ").Append(PsText.Literal(r.Title))
                .Append("; auto = ").Append(r.Auto is null ? "$null" : PsText.Literal(r.Auto))
                .Append("; path = ").Append(PsText.Literal(r.Path))
                .Append("; id = ").Append(PsText.Literal(r.Id))
                .Append("; label = ").Append(PsText.Literal(r.Label)).Append(" },\n");
        }

        var needles = string.Join(",\n", Needles.Select(PsText.Literal));

        return new OracleCase(
            "search/filter",
            "both search boxes, against the window's own lines",
            """
            $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
            function Get-SRLine($marker) {
                $a = $winSrc.IndexOf($marker)
                if ($a -lt 0) { throw "could not find: $marker" }
                # The whole LINE the marker is on - a marker can sit mid-line.
                $a = $winSrc.LastIndexOf("`n", $a) + 1
                $b = $winSrc.IndexOf("`n", $a)
                return $winSrc.Substring($a, $b - $a).Trim()
            }
            $hayLine = Get-SRLine '$r.Hay     = '
            # The CONDITION of each filter: the text between 'if (' and ') { continue }'.
            $qLine  = Get-SRLine 'if ($q -and "$($r.Hay)" -notlike'
            $qlLine = Get-SRLine "-notlike `"*`$ql*`""
            $qCond  = $qLine.Substring(4, $qLine.LastIndexOf(') { continue }') - 4)
            $qlCond = $qlLine.Substring(4, $qlLine.LastIndexOf(') { continue }') - 4)
            $rows = @(
            """ + "\n" + rows + "$null) | Where-Object { $_ }\n$needles = @(\n" + needles + "\n)\n" + """
            $out = @()
            foreach ($x in $rows) {
                $r = [PSCustomObject]@{ Hay = ''; Id = $x.id; S = [PSCustomObject]@{ autoTitle = $x.auto }; D = [PSCustomObject]@{ path = $x.path } }
                $t = $x.t; $pl = $x.label
                Invoke-Expression $hayLine
                foreach ($n in $needles) {
                    $q = "$n".Trim().ToLower(); $ql = $q
                    $hide = try { [string][bool](Invoke-Expression $qCond) } catch { 'threw' }
                    $hideL = try { [string][bool](Invoke-Expression $qlCond) } catch { 'threw' }
                    $out += [ordered]@{ hay = "$($r.Hay)"; needle = "$n"; hides = $hide; hidesInList = $hideL }
                }
            }
            (@{ rows = $out } | ConvertTo-Json -Compress -Depth 4)
            """,
            _ =>
            {
                var rowsOut = new JsonArray();
                foreach (var r in Rows)
                {
                    var hay = SearchMatch.Haystack(r.Title, r.Auto, r.Path, r.Id, r.Label);
                    var list = SearchMatch.ListHaystack(r.Title, r.Auto);
                    foreach (var n in Needles)
                    {
                        var q = n.Trim().ToLowerInvariant();
                        rowsOut.Add(new JsonObject
                        {
                            ["hay"] = hay,
                            ["needle"] = n,
                            ["hides"] = Hides(hay, q),
                            ["hidesInList"] = Hides(list, q),
                        });
                    }
                }

                return new JsonObject { ["rows"] = rowsOut }.ToJsonString(Compact);
            });
    }

    /// <summary>The filter's condition: an empty query hides nothing; an invalid one throws.</summary>
    private static string Hides(string hay, string q)
    {
        if (q.Length == 0)
        {
            return "False";
        }

        return SearchMatch.Like(hay, q) switch
        {
            null => "threw",
            true => "False",
            false => "True",
        };
    }
}
