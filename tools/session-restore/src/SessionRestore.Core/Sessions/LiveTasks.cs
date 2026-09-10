using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.Core.Sessions;

/// <summary>A background shell or sub-agent that was launched and has not ended.</summary>
public sealed record LiveTask(
    string Id,
    string Kind,
    string Command,
    string Description,
    DateTimeOffset? At,
    string ToolUseId)
{
    public bool IsShell => string.Equals(Kind, "shell", StringComparison.Ordinal);
}

/// <summary>
/// What is running right now - by name, not by count.
/// </summary>
/// <remarks>
/// 🔴 THE COUNT AND THE IDENTITY CAME FROM DIFFERENT PLACES, AND ONLY THE COUNT
/// EXISTED. The row's mark is a number off the session's status line; the pane's
/// shell block is a tool_use that happens to be inside the transcript tail. So
/// the mark could say "2 shells" while the pane showed none - reported as "I
/// cannot see a current running shell other than the icon indicating there is
/// something". This is the missing list.
///
/// 🪤 THE TASKS DIRECTORY IS NOT THE ANSWER, AND IT IS THE OBVIOUS WRONG ONE.
/// Every shell that has EVER run leaves its <c>.output</c> there - 1.475 of them
/// on this machine, almost none live. A file on disk is a receipt, not a
/// heartbeat, and listing that directory is the same mistake that once put 374
/// dead sub-agents on screen.
///
/// 🪤 NEITHER IS AN OPEN-TOOL-CALL TRACKER. It opens on a tool_use and closes on
/// the matching tool_result, which is right for an agent and exactly wrong for a
/// shell: measured, 52 of 52 background bashes got their tool_result IMMEDIATELY
/// - that is where the id is handed back - while the shell carried on running.
///
/// 🔑 WHAT ACTUALLY MARKS THE END IS A task-notification, which Claude Code
/// writes when the task stops, carrying its id. So the rule is exact and needs
/// no heuristic, no mtime guess and no freshness window:
/// <code>running = launched, and no task-notification for that id since.</code>
/// Verified against a finished conversation: 114 launches, 129 notifications,
/// 0 left open - the right answer for a session no longer running.
/// </remarks>
public static partial class LiveTasks
{
    /// <summary>
    /// How much of a transcript to read: 24 MB.
    /// </summary>
    /// <remarks>
    /// 🔴 NOT THE 512 KB THIS FIRST SHIPPED WITH, AND THAT NUMBER WAS NOT A
    /// CONSERVATIVE GUESS - IT WAS A BROKEN TEST. A shell running for an hour was
    /// LAUNCHED an hour ago, so a tail sized for "recent activity" is exactly the
    /// wrong shape: the longer a shell runs - precisely when you want to see it -
    /// the further back its only launch record sits. On the largest transcript
    /// here (112 MB) a 512 KB tail covers 0,5% and the last launch was 988 KB
    /// from the end, outside it. The first version passed its test by returning 0
    /// from a window containing no launches at all, in either direction.
    ///
    /// 🔑 SIZED FROM THE DISTRIBUTION, not from caution: of 373 transcripts the
    /// median is 0,4 MB and p90 is 8 MB, so at 24 MB, 356 of 373 are read WHOLE.
    /// The cost is bounded by the pre-filter, not by this.
    /// </remarks>
    public const int DefaultMaxTailBytes = 25_165_824;

    [GeneratedRegex(@"background with ID:\s*([A-Za-z0-9_-]+)")]
    private static partial Regex ShellLaunched();

    [GeneratedRegex(@"agentId:\s*([A-Za-z0-9_-]+)")]
    private static partial Regex AgentLaunched();

    [GeneratedRegex(@"<task-id>\s*([A-Za-z0-9_-]+)\s*</task-id>")]
    private static partial Regex TaskEnded();

    /// <summary>Everything launched in this conversation that has not reported back.</summary>
    public static List<LiveTask> Read(string? jsonlPath, int maxTailBytes = DefaultMaxTailBytes)
    {
        var open = new Dictionary<string, LiveTask>(StringComparer.Ordinal);
        var order = new List<string>();
        if (string.IsNullOrEmpty(jsonlPath) || !File.Exists(jsonlPath))
        {
            return [];
        }

        var text = TranscriptTail.Read(jsonlPath, maxTailBytes);

        // tool_use id -> what it was asked to do, until its result names the id.
        var pending = new Dictionary<string, Pending>(StringComparer.Ordinal);

        foreach (var raw in text.Split('\n'))
        {
            // 🔑 THE PRE-FILTER IS WHAT MAKES A 24 MB WINDOW AFFORDABLE. Parsing
            // every line of a big transcript is the whole cost of this, and all
            // three records it cares about carry a distinctive literal. A
            // substring test is orders of magnitude cheaper than a parse, and on
            // a transcript with a hundred background shells it leaves a few
            // hundred lines to parse instead of a few hundred thousand.
            if (!raw.Contains("run_in_background", StringComparison.Ordinal)
                && !raw.Contains("background with ID:", StringComparison.Ordinal)
                && !raw.Contains("agentId:", StringComparison.Ordinal)
                && !raw.Contains("<task-notification>", StringComparison.Ordinal))
            {
                continue;
            }

            // 🪤 THE BOM IS NOT WHITESPACE. Trim leaves it, so a StartsWith('{')
            // test is FALSE on the first line of any file written with one and
            // the record is skipped in silence. Caught by a negative control that
            // rewrote a fixture through a StreamWriter: the first line happened
            // to be a shell's LAUNCH, and this reported one running shell instead
            // of two. A dropped record looks exactly like a correct answer.
            var line = raw.Trim('﻿', ' ', '\t', '\r', '\n');
            if (!line.StartsWith('{'))
            {
                continue;
            }

            JsonElement r;
            try
            {
                using var doc = JsonDocument.Parse(line);
                r = doc.RootElement.Clone();
            }
            catch (JsonException)
            {
                continue;
            }

            // A completion arrives as a queue-operation record or as the user
            // record the same notification becomes once it comes off the queue,
            // so the whole line is searched rather than one field.
            if (line.Contains("<task-notification>", StringComparison.Ordinal))
            {
                foreach (Match m in TaskEnded().Matches(line))
                {
                    var id = m.Groups[1].Value;
                    if (open.Remove(id))
                    {
                        order.Remove(id);
                    }
                }
            }

            if (!r.TryGetProperty("message", out var msg) || msg.ValueKind != JsonValueKind.Object
                || !msg.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            var when = Timestamp(r);
            foreach (var b in content.EnumerateArray())
            {
                if (b.ValueKind != JsonValueKind.Object
                    || !b.TryGetProperty("type", out var bt) || bt.ValueKind != JsonValueKind.String)
                {
                    continue;
                }

                switch (bt.GetString())
                {
                    case "tool_use":
                        NoteLaunch(b, when, pending);
                        break;

                    case "tool_result":
                        NoteId(b, pending, open, order);
                        break;

                    default:
                        break;
                }
            }
        }

        return order.Select(id => open[id]).ToList();
    }

    private sealed record Pending(string Kind, string Command, string Description, DateTimeOffset? At);

    private static void NoteLaunch(JsonElement b, DateTimeOffset? when, Dictionary<string, Pending> pending)
    {
        var name = Str(b, "name");
        if (!b.TryGetProperty("input", out var input) || input.ValueKind != JsonValueKind.Object)
        {
            return;
        }

        if (!input.TryGetProperty("run_in_background", out var bg) || bg.ValueKind != JsonValueKind.True)
        {
            return;
        }

        // 🪤 BOTH KINDS CARRY run_in_background, so the NAME is what tells them
        // apart, not the flag. An Agent launch that fell into the shell branch
        // would be listed as a background command with an empty command line.
        var isShell = string.Equals(name, "Bash", StringComparison.Ordinal);
        var isAgent = string.Equals(name, "Agent", StringComparison.Ordinal)
                      || string.Equals(name, "Task", StringComparison.Ordinal);
        if (!isShell && !isAgent)
        {
            return;
        }

        pending[Str(b, "id")] = new Pending(
            Kind: isShell ? "shell" : "agent",
            Command: isShell ? Str(input, "command") : Str(input, "subagent_type"),
            Description: Str(input, "description"),
            At: when);
    }

    private static void NoteId(
        JsonElement b,
        Dictionary<string, Pending> pending,
        Dictionary<string, LiveTask> open,
        List<string> order)
    {
        var uid = Str(b, "tool_use_id");
        if (uid.Length == 0 || !pending.TryGetValue(uid, out var info))
        {
            return;
        }

        var text = string.Empty;
        if (b.TryGetProperty("content", out var c))
        {
            if (c.ValueKind == JsonValueKind.String)
            {
                text = c.GetString() ?? string.Empty;
            }
            else if (c.ValueKind == JsonValueKind.Array)
            {
                text = string.Join("\n", c.EnumerateArray()
                    .Where(x => x.ValueKind == JsonValueKind.Object)
                    .Select(x => Str(x, "text")));
            }
        }

        // Each kind hands its id back in its own words: a shell says "background
        // with ID: <id>", an agent says "agentId: <id>". That id is what the
        // completion notification will name, and for an agent it is also the
        // name of its own transcript on disk.
        var hit = string.Equals(info.Kind, "agent", StringComparison.Ordinal)
            ? AgentLaunched().Match(text)
            : ShellLaunched().Match(text);

        pending.Remove(uid);
        if (!hit.Success)
        {
            return;
        }

        var id = hit.Groups[1].Value;
        if (!open.ContainsKey(id))
        {
            order.Add(id);
        }

        open[id] = new LiveTask(id, info.Kind, info.Command, info.Description, info.At, uid);
    }

    private static DateTimeOffset? Timestamp(JsonElement r)
    {
        var ts = Str(r, "timestamp");
        if (ts.Length == 0)
        {
            return null;
        }

        return DateTimeOffset.TryParse(ts, CultureInfo.InvariantCulture,
            DateTimeStyles.AdjustToUniversal, out var when) ? when : null;
    }

    private static string Str(JsonElement e, string name) =>
        e.ValueKind == JsonValueKind.Object
        && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? string.Empty
            : string.Empty;
}
