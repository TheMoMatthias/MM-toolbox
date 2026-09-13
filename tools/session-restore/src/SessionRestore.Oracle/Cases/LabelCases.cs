using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Rows;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 4.2 - what each project is called: <c>Update-ProjectLabels</c> and
/// <c>Get-ProjectLabel</c>, spliced from the window.
/// </summary>
/// <remarks>
/// 🔴 LIVE DATA HAS FEW CLASHES, so the registry's own projects are compared AND a
/// set built to clash: two levels deep, four levels deep, past four, case
/// variants of one path, and both slash directions.
/// </remarks>
public static class LabelCases
{
    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Labels("labels/live", live: true), true, "every project in the registry, and the label it shows");
        yield return (Labels("labels/shapes", live: false), true, "labels for projects built to clash at every depth");
    }

    private static readonly string[] Shapes =
    [
        @"C:\work\api\src",
        @"C:\work\web\src",
        @"C:\a\x\y\z\app",
        @"C:\b\x\y\z\app",
        @"C:\c\q\r\s\t\deep",
        @"C:\d\q\r\s\t\deep",
        @"C:\Tools\Case",
        @"c:\tools\case",
        @"C:\one\Src",
        "D:/forward/slashes/src",
        @"C:\solo\",
        @"\\server\share\proj",
        @"C:\other\proj",
        @"C:\",
        @"\",
        @"E:/",
    ];

    // Asked of every label set: a path it was built with, and one it was not.
    private static readonly string[] Probes = [@"C:\TOOLS\CASE", @"C:\never\seen\thing"];

    private static OracleCase Labels(string name, bool live)
    {
        var sb = new StringBuilder();
        foreach (var p in Shapes)
        {
            sb.Append(PsText.Literal(p)).Append(",\n");
        }

        var probes = string.Join(", ", Probes.Select(PsText.Literal));

        return new OracleCase(
            name,
            live ? "every project in the registry, and the label it shows" : "labels for projects built to clash",
            """
            $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
            foreach ($fn in @('Update-ProjectLabels', 'Get-ProjectLabel')) {
                $a = $winSrc.IndexOf("function $fn")
                if ($a -lt 0) { throw "could not find $fn in sessions-window.ps1" }
                $b = $winSrc.IndexOf("`n}", $a)
                Invoke-Expression $winSrc.Substring($a, $b - $a + 2)
            }
            $script:accentOrder = @(); $script:accentCache = @{}
            """ + "\n" + (live
                ? "$paths = @(@((Get-SRRegistry).directories) | ForEach-Object { \"$($_.path)\" })\n"
                : "$paths = @(\n" + sb + "$null) | Where-Object { $null -ne $_ }\n")
            + "$probes = @(" + probes + ")\n" + """
            $script:dirs = @($paths | ForEach-Object { [PSCustomObject]@{ path = $_ } })
            Update-ProjectLabels
            $rows = @()
            foreach ($p in @($paths) + @($probes)) { $rows += [ordered]@{ path = "$p"; label = "$(Get-ProjectLabel $p)" } }
            (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 4)
            """,
            psOut =>
            {
                // The paths are the question; each side labels them itself.
                var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
                var all = asked.Select(a => a?["path"]?.GetValue<string>() ?? string.Empty).ToList();
                var built = all.Take(all.Count - Probes.Length).ToList();
                var labels = ProjectLabels.For(built);
                var rows = new JsonArray();
                foreach (var p in all)
                {
                    rows.Add(new JsonObject { ["path"] = p, ["label"] = labels.Of(p) });
                }

                if (built.Count == 0)
                {
                    rows.Add(new JsonObject { ["path"] = "(no project was labelled)" });
                }

                return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
            });
    }
}
