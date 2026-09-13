using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace SessionRestore.Core.Registry;

/// <summary>
/// One conversation, as the registry records it.
/// </summary>
/// <remarks>
/// 🔴 <see cref="Extra"/> IS NOT OPTIONAL AND IT IS NOT TIDINESS. A registry
/// written by a newer build carries fields this one has never heard of, and a
/// model that drops them turns the next save into a silent delete of somebody's
/// data. A registry-overwrite bug in this repo's history cost 210 conversations;
/// this is one of the things standing between here and a repeat.
/// </remarks>
public sealed class RegistrySession
{
    [JsonPropertyName("sessionId")] public string SessionId { get; set; } = string.Empty;

    [JsonPropertyName("title")] public string Title { get; set; } = string.Empty;

    /// <summary>The tick: does this conversation come back at the next logon?</summary>
    [JsonPropertyName("enabled")] public bool Enabled { get; set; }

    /// <summary>Pinned conversations survive the registry window.</summary>
    [JsonPropertyName("pinned")] public bool Pinned { get; set; }

    /// <summary>Its transcript is no longer on disk.</summary>
    [JsonPropertyName("gone")] public bool Gone { get; set; }

    [JsonPropertyName("lastActive")] public DateTimeOffset? LastActive { get; set; }

    [JsonPropertyName("firstSeen")] public DateTimeOffset? FirstSeen { get; set; }

    /// <summary>Cheap identity for the transcript: "&lt;ticks&gt;:&lt;length&gt;".</summary>
    /// <remarks>
    /// 🪤 LENGTH AND MTIME CAN COLLIDE. It is fine as a "has this changed?" hint
    /// and must never be the thing a WRITE is guarded on - see the ledger.
    /// </remarks>
    [JsonPropertyName("stamp")] public string Stamp { get; set; } = string.Empty;

    [JsonPropertyName("cwd")] public string Cwd { get; set; } = string.Empty;

    /// <summary>"main" for the repo's own tree, else the worktree name.</summary>
    [JsonPropertyName("lane")] public string Lane { get; set; } = string.Empty;

    [JsonPropertyName("worktree")] public string? Worktree { get; set; }

    [JsonPropertyName("jsonl")] public string? Jsonl { get; set; }

    /// <summary>The title the tool guessed, as opposed to one the operator set.</summary>
    [JsonPropertyName("autoTitle")] public string? AutoTitle { get; set; }

    [JsonExtensionData] public IDictionary<string, JsonElement>? Extra { get; set; }
}

/// <summary>One project directory and the conversations under it.</summary>
public sealed class RegistryDirectory
{
    [JsonPropertyName("path")] public string Path { get; set; } = string.Empty;

    private bool _enabled;

    [JsonPropertyName("enabled")]
    public bool Enabled
    {
        get => _enabled;
        set
        {
            _enabled = value;
            EnabledPresent = true;
        }
    }

    /// <summary>
    /// Whether the file said <c>enabled</c> at all.
    /// </summary>
    /// <remarks>
    /// 🪤 ABSENT IS NOT FALSE. <c>Test-SRProjectRestoreOff</c> reads a project as
    /// restoring nothing only when the field is PRESENT and false; a directory
    /// written before the field existed restores as normal. A plain bool cannot
    /// tell the two apart, and would have labelled such a project "no logon".
    /// Not serialised - the writer still writes <see cref="Enabled"/> as before.
    /// </remarks>
    [JsonIgnore]
    public bool EnabledPresent { get; private set; }

    [JsonPropertyName("missing")] public bool Missing { get; set; }

    [JsonPropertyName("firstSeen")] public DateTimeOffset? FirstSeen { get; set; }

    [JsonPropertyName("sessions")] public List<RegistrySession> Sessions { get; set; } = [];

    [JsonExtensionData] public IDictionary<string, JsonElement>? Extra { get; set; }

    /// <summary><c>Test-SRProjectShelved</c>: a <c>shelved</c> field that is truthy.</summary>
    [JsonIgnore]
    public bool Shelved =>
        Extra is not null
        && Extra.TryGetValue("shelved", out var v)
        && v.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.String => (v.GetString() ?? string.Empty).Length > 0,
            JsonValueKind.Number => v.GetDecimal() != 0,
            JsonValueKind.Object => true,
            JsonValueKind.Array => v.GetArrayLength() > 0,
            _ => false,
        };
}

/// <summary>
/// <c>sessions-registry.json</c> - every conversation across every repo, and the
/// tick that decides what comes back at the next logon.
/// </summary>
/// <remarks>
/// 🔴 THIS FILE IS THE TOOL'S ONLY STATE AND IT IS LIVE. Nothing in this class
/// writes it; the guarded writer is plan item 2.7 and is deliberately the last
/// thing built.
/// </remarks>
public sealed class SessionRegistry
{
    /// <summary>The schema this build understands.</summary>
    /// <remarks>
    /// v1 keyed one entry per directory with a single sessionId; v2 gave a
    /// directory a list of sessions; v3 keys a project on the REPO and puts
    /// worktree conversations in a lane beneath it.
    /// </remarks>
    public const int CurrentVersion = 3;

    [JsonPropertyName("version")] public int Version { get; set; } = CurrentVersion;

    [JsonPropertyName("lastScan")] public DateTimeOffset? LastScan { get; set; }

    [JsonPropertyName("directories")] public List<RegistryDirectory> Directories { get; set; } = [];

    /// <summary>
    /// Transcripts looked at and deliberately not tracked, keyed by session id.
    /// </summary>
    /// <remarks>
    /// Kept verbatim rather than modelled: this build has no use for the shape,
    /// and inventing one is how a field gets dropped on the next write.
    /// </remarks>
    [JsonPropertyName("rejected")] public JsonObject? Rejected { get; set; }

    [JsonExtensionData] public IDictionary<string, JsonElement>? Extra { get; set; }

    /// <summary>Every conversation in the file, whatever project it sits under.</summary>
    public IEnumerable<RegistrySession> AllSessions =>
        Directories.SelectMany(d => d.Sessions);

    private static readonly JsonSerializerOptions ReadOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static SessionRegistry Read(string? path = null)
    {
        var p = path ?? ToolPaths.Registry;
        if (!File.Exists(p))
        {
            // An absent registry is an empty one, which is how a fresh machine
            // starts - not an error to report.
            return new SessionRegistry { LastScan = null };
        }

        // 🪤 THE REGISTRY IS WRITTEN WITH A BOM AND THE CONFIG IS NOT. Measured,
        // not assumed: sessions-registry.json starts EF BB BF and
        // session-restore.config.json does not. ReadAllText detects and strips
        // it; JsonNode.Parse on a string that still has one throws. Reading the
        // bytes straight into a parser is the version of this that breaks.
        string text;
        try
        {
            text = File.ReadAllText(p);
        }
        catch (IOException ex)
        {
            // Another window mid-save is an ordinary event, not a corrupt file.
            throw new IOException(
                $"could not read the registry ({p}): {ex.Message}. " +
                "Another session-restore window may be saving; try again.", ex);
        }

        SessionRegistry? reg;
        try
        {
            reg = JsonSerializer.Deserialize<SessionRegistry>(text, ReadOptions);
        }
        catch (JsonException ex)
        {
            throw new InvalidDataException(
                $"registry is unreadable ({p}): {ex.Message}. Delete it to start fresh.", ex);
        }

        reg ??= new SessionRegistry();

        // 🔴 AN OLDER SCHEMA IS REFUSED, NOT MIGRATED - see the note on
        // RequiresMigration. Refusing is safe; a half-ported migration is not.
        return reg;
    }

    /// <summary>
    /// Is this file older than this build understands?
    /// </summary>
    /// <remarks>
    /// 🔴 THE v1 AND v2 MIGRATIONS ARE DELIBERATELY NOT PORTED. They rewrite the
    /// operator's ticks in place - v2 to v3 re-parents every session onto its
    /// repo rather than its working directory - and the only file available to
    /// test them against is already v3, so a port would be code that has never
    /// once run on its own input. That is the exact shape this rebuild is
    /// supposed to avoid.
    ///
    /// The PowerShell still has both migrations and still runs. So the answer
    /// for an old registry is "open the old tool once", not a rewrite nobody has
    /// exercised. Revisit only if a v1 or v2 file actually turns up.
    /// </remarks>
    public bool RequiresMigration => Version < CurrentVersion;

    /// <summary>What to tell the operator when the file is too old for this build.</summary>
    public string MigrationAdvice =>
        $"This registry is version {Version}; this build reads version {CurrentVersion}. " +
        "Open the PowerShell window (Sessions.exe) once - it migrates the file in place, " +
        "keeping every tick - then come back.";
}
