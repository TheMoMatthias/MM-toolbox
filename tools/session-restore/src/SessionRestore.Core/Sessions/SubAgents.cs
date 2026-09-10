using System.Text.Json;
using System.Text.RegularExpressions;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.Core.Sessions;

/// <summary>One sub-agent: a real conversation of its own, on disk.</summary>
public sealed record SubAgent(
    string Id,
    string Label,
    string AgentType,
    string Description,
    string TaskKind,
    string Model,
    string Team,
    string ToolUseId,
    string Path,
    bool HasTranscript,
    long Bytes,
    DateTimeOffset When)
{
    /// <summary>
    /// A peer working alongside the session, as opposed to a one-shot it
    /// dispatched. Different things, and a row should say which.
    /// </summary>
    public bool IsTeammate => string.Equals(TaskKind, "in_process_teammate", StringComparison.Ordinal);

    /// <summary>
    /// Still going, on the evidence of its own file.
    /// </summary>
    /// <remarks>
    /// 🔴 A SUB-AGENT HAS NO PROCESS OF ITS OWN - it runs inside its parent, so
    /// <c>claude agents --json</c> cannot be asked about it and there is no pid
    /// to check. What a running one does do is WRITE, and a finished one stops
    /// writing permanently, so a recently touched transcript is the only
    /// evidence there is.
    ///
    /// 🪤 AND AN AGENT WITH NO TRANSCRIPT CAN NEVER BE LIVE: there is nothing
    /// writing. 45 of the 374 on this machine are exactly that - metadata and no
    /// transcript - which is a real state and must not look like a file that
    /// failed to load.
    /// </remarks>
    public bool IsLive(DateTimeOffset? now = null) =>
        HasTranscript
        && ((now ?? DateTimeOffset.Now) - When).TotalSeconds < SubAgents.LiveSeconds;
}

/// <summary>
/// The sub-agents beside a conversation.
/// </summary>
/// <remarks>
/// 🔑 THEY LIVE BESIDE THE PARENT, NOT INSIDE IT:
/// <c>&lt;project&gt;\&lt;session-id&gt;\subagents\agent-&lt;name&gt;-&lt;hash&gt;.jsonl</c>
/// plus a <c>.meta.json</c> alongside. The transcript uses the SAME record shape
/// as a top-level conversation, which is the whole reason this is a reader and
/// not a parser - <see cref="TranscriptBlocks"/> reads one unchanged.
///
/// Measured 2026-08-31 across every project on this machine: 374 sub-agents, 329
/// with a transcript, of which 257 are teammates and 117 are Task agents. So
/// this is not a teammates-only feature.
/// </remarks>
public static partial class SubAgents
{
    /// <summary>
    /// How long since its last write a sub-agent still counts as running.
    /// </summary>
    /// <remarks>
    /// Generous on purpose: an agent thinking for a minute writes nothing, and a
    /// threshold tight enough to catch that would flicker. Three minutes
    /// tolerates a long pause and still excludes anything that finished.
    /// </remarks>
    public const int LiveSeconds = 180;

    /// <summary>Where a conversation's sub-agents live, or empty.</summary>
    public static string Directory(string? jsonlPath)
    {
        if (string.IsNullOrEmpty(jsonlPath))
        {
            return string.Empty;
        }

        var dir = System.IO.Path.GetDirectoryName(jsonlPath);
        var stem = System.IO.Path.GetFileNameWithoutExtension(jsonlPath);
        if (string.IsNullOrEmpty(dir) || string.IsNullOrEmpty(stem))
        {
            return string.Empty;
        }

        return System.IO.Path.Combine(dir, stem, "subagents");
    }

    /// <summary>Every sub-agent of this conversation, newest first.</summary>
    public static List<SubAgent> List(string? jsonlPath)
    {
        var outp = new List<SubAgent>();
        var dir = Directory(jsonlPath);
        if (dir.Length == 0 || !System.IO.Directory.Exists(dir))
        {
            return outp;
        }

        string[] metas;
        try
        {
            metas = System.IO.Directory.GetFiles(dir, "*.meta.json");
        }
        catch (IOException)
        {
            return outp;
        }
        catch (UnauthorizedAccessException)
        {
            return outp;
        }

        foreach (var metaPath in metas)
        {
            var stem = System.IO.Path.GetFileName(metaPath);
            stem = stem[..^".meta.json".Length];

            // 🪤 A META THAT WILL NOT PARSE IS STILL A SUB-AGENT THAT RAN. Name
            // it from the file and carry on - dropping it would under-report the
            // very thing this exists to surface.
            var meta = ReadMeta(metaPath);

            var transcript = System.IO.Path.Combine(dir, stem + ".jsonl");
            var has = File.Exists(transcript);
            var bytes = 0L;
            DateTimeOffset when;
            try
            {
                when = new FileInfo(metaPath).LastWriteTime;
            }
            catch (IOException)
            {
                when = DateTimeOffset.Now;
            }

            if (has)
            {
                try
                {
                    var fi = new FileInfo(transcript);
                    bytes = fi.Length;

                    // 🪤 THE TRANSCRIPT'S MTIME, NOT THE META'S. The meta is
                    // written once at spawn and never touched again, so ordering
                    // by it would put a finished agent above one still writing.
                    when = fi.LastWriteTime;
                }
                catch (IOException)
                {
                    // Keep the meta's time.
                }
            }

            // A Task sub-agent has an agentType and NO name; a teammate has both
            // and they are usually the same. The file stem is the last resort and
            // always says something, because it carries the agent's own id.
            var label = meta.Name;
            if (label.Length == 0)
            {
                label = meta.AgentType;
            }

            if (label.Length == 0)
            {
                label = AgentPrefix().Replace(stem, string.Empty);
            }

            outp.Add(new SubAgent(
                Id: stem,
                Label: label,
                AgentType: meta.AgentType,
                Description: meta.Description,
                TaskKind: meta.TaskKind,
                Model: meta.Model,
                Team: meta.Team,
                ToolUseId: meta.ToolUseId,
                Path: transcript,
                HasTranscript: has,
                Bytes: bytes,
                When: when));
        }

        // Newest first, matching every other list in this tool.
        outp.Sort((a, b) => b.When.CompareTo(a.When));
        return outp;
    }

    /// <summary>
    /// The newest thing one sub-agent said, as one line.
    /// </summary>
    /// <remarks>
    /// 🔑 WALKED BACKWARDS FOR THE NEWEST THING WORTH SHOWING. An agent's tail is
    /// mostly tool traffic; what answers "what is it doing" is the last thing it
    /// SAID, and failing that the last tool it reached for.
    ///
    /// 🔒 THE ID IS PATTERN-CHECKED BEFORE IT REACHES A PATH. It arrives from a
    /// transcript, which is data this tool does not write - and it is about to
    /// become a filename. A id of "..\..\something" is the difference between
    /// reading a sub-agent and reading whatever the caller was pointed at.
    /// </remarks>
    public static string LastLine(string? jsonlPath, string? agentId, int maxTailBytes = 65_536)
    {
        if (string.IsNullOrEmpty(jsonlPath) || string.IsNullOrEmpty(agentId)
            || !SafeAgentId().IsMatch(agentId))
        {
            return string.Empty;
        }

        var dir = Directory(jsonlPath);
        if (dir.Length == 0 || !System.IO.Directory.Exists(dir))
        {
            return string.Empty;
        }

        var file = System.IO.Path.Combine(dir, "agent-" + agentId + ".jsonl");
        if (!File.Exists(file))
        {
            return string.Empty;
        }

        var lines = TranscriptTail.WholeRecords(TranscriptTail.Read(file, maxTailBytes));
        for (var i = lines.Count - 1; i >= 0; i--)
        {
            JsonElement r;
            try
            {
                using var doc = JsonDocument.Parse(lines[i]);
                r = doc.RootElement.Clone();
            }
            catch (JsonException)
            {
                continue;
            }

            if (!r.TryGetProperty("type", out var t) || t.ValueKind != JsonValueKind.String
                || !string.Equals(t.GetString(), "assistant", StringComparison.Ordinal))
            {
                continue;
            }

            if (!r.TryGetProperty("message", out var m) || m.ValueKind != JsonValueKind.Object
                || !m.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            foreach (var b in content.EnumerateArray())
            {
                if (b.ValueKind != JsonValueKind.Object
                    || !b.TryGetProperty("type", out var bt) || bt.ValueKind != JsonValueKind.String)
                {
                    continue;
                }

                var kind = bt.GetString();
                if (string.Equals(kind, "text", StringComparison.Ordinal))
                {
                    var s = b.TryGetProperty("text", out var tv) && tv.ValueKind == JsonValueKind.String
                        ? tv.GetString() ?? string.Empty
                        : string.Empty;
                    if (!string.IsNullOrWhiteSpace(s))
                    {
                        foreach (var line in s.Trim().Split('\n'))
                        {
                            if (!string.IsNullOrWhiteSpace(line))
                            {
                                return line.Trim();
                            }
                        }
                    }
                }
                else if (string.Equals(kind, "tool_use", StringComparison.Ordinal))
                {
                    var n = b.TryGetProperty("name", out var nv) && nv.ValueKind == JsonValueKind.String
                        ? nv.GetString() ?? string.Empty
                        : string.Empty;
                    return "- " + n;
                }
            }
        }

        return string.Empty;
    }

    private sealed record Meta(
        string Name, string AgentType, string Description,
        string TaskKind, string Model, string Team, string ToolUseId)
    {
        public static Meta Empty { get; } = new(
            string.Empty, string.Empty, string.Empty,
            string.Empty, string.Empty, string.Empty, string.Empty);
    }

    private static Meta ReadMeta(string path)
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            var e = doc.RootElement;
            if (e.ValueKind != JsonValueKind.Object)
            {
                return Meta.Empty;
            }

            return new Meta(
                Str(e, "name"), Str(e, "agentType"), Str(e, "description"),
                Str(e, "taskKind"), Str(e, "model"), Str(e, "teamName"), Str(e, "toolUseId"));
        }
        catch (JsonException)
        {
            return Meta.Empty;
        }
        catch (IOException)
        {
            return Meta.Empty;
        }
    }

    private static string Str(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? string.Empty
            : string.Empty;

    [GeneratedRegex(@"^agent-")]
    private static partial Regex AgentPrefix();

    [GeneratedRegex(@"^[A-Za-z0-9_-]{1,64}$")]
    private static partial Regex SafeAgentId();
}
