using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Config;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 2.1 - the config layer, checked against the operator's real file.
/// </summary>
public static class ConfigCases
{
    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Keys(), true, "every key in the file is seen, in the same order");
        yield return (Effective(), true, "every setting resolves to the same value the tool uses");
        yield return (Untouched(), true, "rendering with no changes alters nothing in the file");
    }

    /// <summary>
    /// 🔴 THE FILE HOLDS MORE THAN SETTINGS. `_README` is the operator's own
    /// prose and `//panelScanMaxAgeSeconds` is a key he commented out by hand. A
    /// reader that quietly drops what it does not recognise turns the next write
    /// into a delete.
    /// </summary>
    private static OracleCase Keys() => new(
        "config/keys",
        "the reader must see every key in the file, prose and commented-out ones included",
        """
        $raw = [System.IO.File]::ReadAllText($SR_ConfigPath) | ConvertFrom-Json
        (@{ keys = @($raw.PSObject.Properties.Name) } | ConvertTo-Json -Compress -Depth 4)
        """,
        () =>
        {
            var cfg = ConfigFile.Read();
            return JsonSerializer.Serialize(new { keys = cfg.Keys.ToArray() }, Compact);
        });

    /// <summary>
    /// The one that matters: for every setting the PowerShell resolves, does the
    /// C# resolve the same thing?
    /// </summary>
    /// <remarks>
    /// 🔑 THE KEY LIST COMES FROM THE POWERSHELL, and that is the question
    /// rather than the answer. Get-SRConfig applies Get-SRConfigRead's defaults,
    /// so the properties it ends up with are exactly "the keys the old tool has
    /// an opinion about" - four settings (lineSpacing, terminalColour,
    /// yourGround, yourInk) are defaulted elsewhere in the PowerShell and would
    /// otherwise register as differences that are really the three-tables
    /// problem this rebuild is collapsing.
    /// </remarks>
    private static OracleCase Effective() => new(
        "config/effective",
        "every setting the old tool resolves must resolve to the same value here",
        """
        $cfg = Get-SRConfig
        $out = [ordered]@{}
        foreach ($p in @($cfg.PSObject.Properties)) {
            if ($p.Name.StartsWith('_', [System.StringComparison]::Ordinal)) { continue }
            if ($p.Name.StartsWith('/', [System.StringComparison]::Ordinal)) { continue }
            $out[$p.Name] = $p.Value
        }
        ($out | ConvertTo-Json -Compress -Depth 8)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut) as JsonObject ?? [];
            var cfg = ConfigFile.Read();
            var mine = new JsonObject();
            foreach (var kv in asked)
            {
                var v = cfg.Get(kv.Key);
                mine[kv.Key] = v switch
                {
                    null => null,
                    JsonNode n => n.DeepClone(),
                    _ => JsonSerializer.SerializeToNode(v),
                };
            }

            return mine.ToJsonString(Compact);
        });

    /// <summary>
    /// 🔴 AN UNTOUCHED SETTING MUST NEVER BE WRITTEN. The file goes on saying
    /// nothing about a setting until there is something to say - which is what
    /// keeps a default free to change later without silently overriding what the
    /// operator never chose.
    /// </summary>
    /// <remarks>
    /// 🪤 THIS COMPARES AGAINST THE FILE, NOT AGAINST A WRITE. Nothing here
    /// touches session-restore.config.json: the C# renders what it WOULD write
    /// and the keys are compared. The live file is read-only to this whole
    /// project until plan item 2.7.
    /// </remarks>
    private static OracleCase Untouched() => new(
        "config/untouched-writes-nothing",
        "rendering with no changes must keep every key, and add none",
        """
        $raw = [System.IO.File]::ReadAllText($SR_ConfigPath) | ConvertFrom-Json
        (@{ keys = @($raw.PSObject.Properties.Name | Sort-Object) } | ConvertTo-Json -Compress -Depth 4)
        """,
        () =>
        {
            var cfg = ConfigFile.Read();
            var rendered = cfg.Render(new Dictionary<string, object?>());
            var back = JsonNode.Parse(rendered) as JsonObject ?? [];
            return JsonSerializer.Serialize(
                new { keys = back.Select(k => k.Key).Order(StringComparer.Ordinal).ToArray() }, Compact);
        });
}
