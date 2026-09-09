using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace SessionRestore.Core.Config;

/// <summary>
/// The operator's <c>session-restore.config.json</c>: what is in it, what the
/// tool uses when it is not, and how to change one value without losing the rest.
/// </summary>
/// <remarks>
/// 🔴 THIS FILE IS HAND-EDITED AND LIVE. It carries the operator's own prose in
/// <c>_README</c> and in <c>//</c>-prefixed keys, and settings this build has
/// never heard of may be in it from a newer or older version. Every write is a
/// read-modify-write that keeps everything it did not come to change.
///
/// 🪤 A VALUE THE TOOL CANNOT USE IS NOT AN ERROR, IT IS THE DEFAULT. A
/// hand-edited file will contain a misspelled choice or an out-of-range number
/// sooner or later, and refusing to start over one setting is worse than
/// ignoring it - the PowerShell takes the same position and says so.
/// </remarks>
public sealed class ConfigFile
{
    private readonly JsonObject _root;

    private ConfigFile(JsonObject root, string path)
    {
        _root = root;
        Path = path;
    }

    public string Path { get; }

    /// <summary>Keys in the file that are prose rather than settings.</summary>
    /// <remarks>
    /// 🪤 ORDINAL, AND THE POWERSHELL CARRIES THE SAME NOTE FOR THE SAME REASON:
    /// a culture-sensitive StartsWith answers True for pairs sharing no
    /// characters at all - measured in this window with ("· x").StartsWith("⏵").
    /// </remarks>
    public static bool IsComment(string key) =>
        string.IsNullOrEmpty(key)
        || key.StartsWith('_')
        || key.StartsWith('/');

    /// <summary>Every key actually present in the file, in file order.</summary>
    public IEnumerable<string> Keys => _root.Select(kv => kv.Key);

    /// <summary>Keys present in the file that this build has no setting for.</summary>
    /// <remarks>Not a problem to be fixed: a config written by a newer build, or
    /// a key retired by this one. They are preserved on every write.</remarks>
    public IEnumerable<string> UnknownKeys =>
        _root.Select(kv => kv.Key)
             .Where(k => !IsComment(k) && SettingsCatalog.Find(k) is null);

    public static ConfigFile Read(string? path = null)
    {
        var p = path ?? ToolPaths.Config;
        if (!File.Exists(p))
        {
            // A missing config is every default, not a failure. That is how a
            // fresh machine starts, and how "delete the file to get the defaults
            // back" - which the PowerShell tells the operator - has to behave.
            return new ConfigFile([], p);
        }

        var text = File.ReadAllText(p);
        JsonNode? node;
        try
        {
            node = JsonNode.Parse(text, documentOptions: new JsonDocumentOptions
            {
                CommentHandling = JsonCommentHandling.Skip,
                AllowTrailingCommas = true,
            });
        }
        catch (JsonException ex)
        {
            // 🪤 SAY WHAT TO DO ABOUT IT. The PowerShell learned this the hard
            // way: ConvertFrom-Json's own message names a character offset and
            // no file, and this is the one of the two data files that gets
            // hand-edited, so it is the likelier to be broken.
            throw new InvalidDataException(
                $"config is unreadable ({p}): {ex.Message}. " +
                "Fix the JSON, or delete the file to get the defaults back.", ex);
        }

        return new ConfigFile(node as JsonObject ?? [], p);
    }

    /// <summary>The value as it is written in the file, or null if absent.</summary>
    public JsonNode? Raw(string key) => _root.TryGetPropertyValue(key, out var v) ? v : null;

    /// <summary>Is this key actually set in the file?</summary>
    public bool IsSet(string key) => Raw(key) is not null;

    public bool GetBool(string key) => Get(key, SettingKind.Toggle) is bool b && b;

    public int GetInt(string key) => Get(key, SettingKind.Number) is int n ? n : 0;

    public string GetString(string key) => Get(key, SettingKind.Text) as string ?? string.Empty;

    /// <summary>A flags setting as its parts, in the order written.</summary>
    public IReadOnlyList<string> GetFlags(string key)
    {
        var s = Get(key, SettingKind.Flags) as string ?? string.Empty;
        return s.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    }

    /// <summary>A list setting, empty when unset.</summary>
    public IReadOnlyList<string> GetList(string key)
    {
        if (Raw(key) is JsonArray a)
        {
            return a.Where(x => x is not null).Select(x => x!.ToString()).ToList();
        }

        return [];
    }

    /// <summary>
    /// The effective value: what the file says if the tool can use it, and the
    /// catalogue's default otherwise.
    /// </summary>
    public object? Get(string key, SettingKind? expect = null)
    {
        var def = SettingsCatalog.Find(key);
        var raw = Raw(key);
        var kind = expect ?? def?.Kind ?? SettingKind.Text;

        var value = Coerce(raw, kind);
        if (value is not null && (def is null || def.Accepts(value)))
        {
            return value;
        }

        return def?.Default;
    }

    private static object? Coerce(JsonNode? raw, SettingKind kind)
    {
        if (raw is null)
        {
            return null;
        }

        try
        {
            switch (kind)
            {
                case SettingKind.Toggle:
                    return raw.GetValue<bool>();

                case SettingKind.Number:
                    // 🪤 A NUMBER MAY ARRIVE AS A STRING. The file is hand-edited
                    // and "30" is what a person types; the PowerShell casts and
                    // does not care, so refusing here would change behaviour for
                    // a config that works today.
                    if (raw.GetValueKind() == JsonValueKind.String)
                    {
                        return int.TryParse(raw.GetValue<string>(), NumberStyles.Integer,
                            CultureInfo.InvariantCulture, out var parsed) ? parsed : null;
                    }

                    return raw.GetValue<int>();

                case SettingKind.List:
                case SettingKind.Map:
                    return raw;

                default:
                    return raw.GetValueKind() == JsonValueKind.String
                        ? raw.GetValue<string>()
                        : raw.ToJsonString().Trim('"');
            }
        }
        catch (FormatException) { return null; }
        catch (InvalidOperationException) { return null; }
    }

    /// <summary>
    /// The file with <paramref name="changes"/> applied - everything else, prose
    /// and unknown keys included, kept exactly as it was.
    /// </summary>
    public string Render(IReadOnlyDictionary<string, object?> changes)
    {
        ArgumentNullException.ThrowIfNull(changes);

        var copy = _root.DeepClone().AsObject();
        foreach (var (k, v) in changes)
        {
            copy[k] = v is null ? null : JsonSerializer.SerializeToNode(v);
        }

        return copy.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true,
            // The file holds Windows paths in excludePatterns; escaping them
            // beyond what JSON requires makes it unreadable to the person who
            // hand-edits it.
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        }) + Environment.NewLine;
    }
}
