using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace SessionRestore.Core.Transcripts;

/// <summary>
/// A conversation's tail, turned into blocks something can read.
/// </summary>
public static partial class TranscriptBlocks
{
    /// <summary>Records, not blocks: one record can carry several content blocks.</summary>
    public const int DefaultMaxRecords = 60;

    /// <summary>The reading window this starts at: 2 MB.</summary>
    public const int DefaultMaxTailBytes = 2_097_152;

    /// <summary>
    /// How far the window may widen when it lands inside a single record: 24 MB.
    /// </summary>
    /// <remarks>
    /// Roughly 25x the largest record ever observed here (916 KB) and still a
    /// bounded read on a 180 MB transcript.
    /// </remarks>
    public const int TailCeiling = 25_165_824;

    /// <summary>How far it may widen looking for actual conversation: 1 MB.</summary>
    public const int TailConvCeiling = 1_048_576;

    /// <summary>How many user/assistant records make a window worth stopping at.</summary>
    public const int TailMinConv = 6;

    [GeneratedRegex(@"""type""\s*:\s*""(?:user|assistant)""")]
    private static partial Regex ConversationRecord();

    /// <summary>Argument keys that identify a tool call at a glance, in order.</summary>
    private static readonly string[] ArgKeys =
        ["command", "file_path", "path", "pattern", "prompt", "description", "url", "query"];

    private static readonly Regex Whitespace = new(@"\s+", RegexOptions.Compiled);

    /// <summary>
    /// Reads the tail of <paramref name="path"/> and returns its blocks, oldest
    /// first.
    /// </summary>
    public static List<TranscriptBlock> Read(
        string path,
        int maxRecords = DefaultMaxRecords,
        int maxTailBytes = DefaultMaxTailBytes)
    {
        var text = ReadWideningTail(path, maxTailBytes);
        var lines = TranscriptTail.WholeRecords(text);
        if (lines.Count == 0)
        {
            return [];
        }

        if (lines.Count > maxRecords)
        {
            lines = lines[^maxRecords..];
        }

        var blocks = new List<TranscriptBlock>();
        foreach (var line in lines)
        {
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

            AddRecord(blocks, r);
        }

        return blocks;
    }

    /// <summary>
    /// The tail, widened until it holds whole records and some conversation.
    /// </summary>
    /// <remarks>
    /// 🔴 A TAIL CAN LAND ENTIRELY INSIDE ONE RECORD, AND THEN IT READS AS AN
    /// EMPTY CONVERSATION. Measured 2026-09-03 on a 180 MB transcript: records
    /// run to 916 KB against a median of 629 bytes, so whenever the newest
    /// record is bigger than the window, every line in it is a fragment, the
    /// whole-record filter keeps none of them, and the pane draws nothing.
    ///
    /// It is intermittent by construction - it depends entirely on how big the
    /// last few records happen to be - which is why it was reported as
    /// "sometimes the tool does not show the conversation". A compact summary
    /// and a large tool result are both exactly that kind of record, which is
    /// precisely when it was reported.
    ///
    /// 🪤 THE WIDENING TEST IS THE SAME TEST THE FILTER USES. Anything else here
    /// would widen on one rule and then keep nothing by another.
    /// </remarks>
    private static string ReadWideningTail(string path, int maxTailBytes)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path))
        {
            return string.Empty;
        }

        long len;
        try
        {
            len = new FileInfo(path).Length;
        }
        catch (IOException)
        {
            return string.Empty;
        }

        if (len == 0)
        {
            return string.Empty;
        }

        var take = (int)Math.Min(len, maxTailBytes);
        var text = string.Empty;
        while (true)
        {
            text = TranscriptTail.Read(path, take);

            var anyWhole = TranscriptTail.WholeRecords(text).Count > 0;
            if (!anyWhole)
            {
                // Nothing whole yet: the original rule, and it owns the high ceiling.
                if (take >= len || take >= TailCeiling)
                {
                    break;
                }

                take = (int)Math.Min(Math.Min(len, TailCeiling), (long)take * 2);
                continue;
            }

            // Whole records, but are any of them the conversation?
            if (ConversationRecord().Matches(text).Count >= TailMinConv)
            {
                break;
            }

            if (take >= len || take >= TailConvCeiling)
            {
                break;
            }

            take = (int)Math.Min(Math.Min(len, TailConvCeiling), (long)take * 2);
        }

        return text;
    }

    private static void AddRecord(List<TranscriptBlock> outp, JsonElement r)
    {
        var type = Str(r, "type");
        var when = Timestamp(r);

        if (string.Equals(type, "system", StringComparison.Ordinal))
        {
            AddSystem(outp, r, when);
            return;
        }

        // A hook's own output rides on a record that carries no message at all,
        // so it has to be caught before the message check below.
        if (r.TryGetProperty("attachment", out var att) && att.ValueKind == JsonValueKind.Object)
        {
            AddAttachment(outp, att, when);
            return;
        }

        // 🔴 AN INBOUND MESSAGE IS A QUEUE OPERATION, NOT A USER RECORD - which
        // is why it was dropped by the guard below and never reached the pane.
        // Measured: 202 of them in a single conversation on this machine.
        if (string.Equals(type, "queue-operation", StringComparison.Ordinal))
        {
            if (string.Equals(Str(r, "operation"), "enqueue", StringComparison.Ordinal))
            {
                var qc = TranscriptText.RemoveAnsi(Str(r, "content"));
                // ONLY an actual message. A plain enqueued prompt arrives again
                // as a user record when the session takes it, and drawing it
                // here as well would show everything the operator typed twice.
                if (UserBlocks.IsInboundMessage(qc))
                {
                    outp.Add(UserBlocks.Build(qc, when));
                }
            }

            return;
        }

        if (!string.Equals(type, "user", StringComparison.Ordinal) &&
            !string.Equals(type, "assistant", StringComparison.Ordinal))
        {
            return;
        }

        if (!r.TryGetProperty("message", out var m) || m.ValueKind != JsonValueKind.Object)
        {
            return;
        }

        var role = Str(m, "role");
        if (!m.TryGetProperty("content", out var content))
        {
            return;
        }

        if (content.ValueKind == JsonValueKind.String)
        {
            var s = content.GetString() ?? string.Empty;
            if (!string.IsNullOrWhiteSpace(s))
            {
                outp.Add(string.Equals(role, "user", StringComparison.Ordinal)
                    ? UserBlocks.Build(s, when)
                    : new TranscriptBlock(BlockKind.Said, string.Empty, s, string.Empty, when));
            }

            return;
        }

        if (content.ValueKind != JsonValueKind.Array)
        {
            return;
        }

        foreach (var b in content.EnumerateArray())
        {
            AddContentBlock(outp, r, b, role, when);
        }
    }

    private static void AddSystem(List<TranscriptBlock> outp, JsonElement r, DateTimeOffset? when)
    {
        var sub = Str(r, "subtype");

        // turn_duration is bookkeeping the window computes for itself and there
        // are 68 of them in a busy tail; it would be the loudest thing in the
        // pane and say the least.
        if (string.Equals(sub, "turn_duration", StringComparison.Ordinal))
        {
            return;
        }

        if (!string.Equals(sub, "compact_boundary", StringComparison.Ordinal) &&
            !string.Equals(sub, "stop_hook_summary", StringComparison.Ordinal))
        {
            // away_summary, informational, bridge_status, local_command - every
            // one carries content, and every one is something the terminal
            // PRINTS and this pane was swallowing.
            var sc = TranscriptText.RemoveAnsi(Str(r, "content"));
            if (!string.IsNullOrWhiteSpace(sc))
            {
                outp.Add(new TranscriptBlock(BlockKind.System,
                    sub.Replace('_', ' '), sc, string.Empty, when));
            }

            return;
        }

        if (string.Equals(sub, "compact_boundary", StringComparison.Ordinal))
        {
            var pre = string.Empty;
            if (r.TryGetProperty("compactMetadata", out var md) && md.ValueKind == JsonValueKind.Object)
            {
                if (md.TryGetProperty("preTokens", out var pt))
                {
                    pre = Scalar(pt) + " tokens summarised";
                }

                var trig = Str(md, "trigger");
                if (trig.Length > 0)
                {
                    pre = pre.Length > 0 ? pre + "  -  " + trig : trig;
                }
            }

            outp.Add(new TranscriptBlock(BlockKind.Compact, "compacted", pre, string.Empty, when));
            return;
        }

        // Which hooks ran and what they cost. The one system record with a real
        // answer in it rather than bookkeeping.
        var names = new List<string>();
        if (r.TryGetProperty("hookInfos", out var hooks) && hooks.ValueKind == JsonValueKind.Array)
        {
            foreach (var h in hooks.EnumerateArray())
            {
                if (h.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                var ms = string.Empty;
                if (h.TryGetProperty("durationMs", out var d) && d.ValueKind == JsonValueKind.Number)
                {
                    // The operator's own machine formats this, because he is
                    // the one reading it: "3,8s" on a German desktop, "3.8s" on
                    // an English one. Logic elsewhere is ordinal by saying so.
                    ms = string.Format(CultureInfo.CurrentCulture, " {0:N1}s", d.GetDouble() / 1000);
                }

                names.Add(Str(h, "command") + ms);
            }
        }

        var errs = new List<string>();
        if (r.TryGetProperty("hookErrors", out var he) && he.ValueKind == JsonValueKind.Array)
        {
            errs.AddRange(he.EnumerateArray()
                            .Select(Scalar)
                            .Where(e => !string.IsNullOrWhiteSpace(e)));
        }

        var body = string.Join("   ", names);
        if (errs.Count > 0)
        {
            var joined = string.Join("  ", errs);
            body = body.Length > 0 ? body + "   -   " + joined : joined;
        }

        if (body.Length > 0)
        {
            outp.Add(new TranscriptBlock(BlockKind.System, "hooks", body, string.Empty, when));
        }
    }

    private static void AddAttachment(List<TranscriptBlock> outp, JsonElement att, DateTimeOffset? when)
    {
        var kind = Str(att, "type");
        switch (kind)
        {
            case "hook_success":
            case "hook_system_message":
            {
                var hk = Str(att, "hookName");
                if (hk.Length == 0)
                {
                    hk = Str(att, "hookEvent");
                }

                if (hk.Length == 0)
                {
                    hk = "hook";
                }

                var txt = TranscriptText.RemoveAnsi(Str(att, "content"));
                if (!string.IsNullOrWhiteSpace(txt))
                {
                    outp.Add(new TranscriptBlock(BlockKind.Hook, hk, txt, string.Empty, when));
                }

                break;
            }

            case "file":
            case "edited_text_file":
            {
                // The "Read <file> (N lines)" list the terminal prints after a
                // compact. Only the NAME and the size are wanted - the
                // attachment carries the ENTIRE FILE, and putting that in the
                // pane would bury the conversation it belongs to.
                var fn = Str(att, "filename");
                var content = att.TryGetProperty("content", out var c) ? c : default;
                if (fn.Length == 0 && content.ValueKind == JsonValueKind.Object &&
                    content.TryGetProperty("file", out var fileObj))
                {
                    fn = Str(fileObj, "filePath");
                }

                if (fn.Length == 0)
                {
                    break;
                }

                var lines = string.Empty;
                if (content.ValueKind == JsonValueKind.Object &&
                    content.TryGetProperty("file", out var f2) &&
                    f2.ValueKind == JsonValueKind.Object)
                {
                    var fc = Str(f2, "content");
                    if (fc.Length > 0)
                    {
                        lines = string.Format(CultureInfo.InvariantCulture,
                            "{0} lines", fc.Split('\n').Length);
                    }
                }

                var head = string.Equals(kind, "edited_text_file", StringComparison.Ordinal) ? "edited" : "read";
                outp.Add(new TranscriptBlock(BlockKind.File, head,
                    System.IO.Path.GetFileName(fn), lines, when));
                break;
            }

            case "queued_command":
            {
                var qp = TranscriptText.RemoveAnsi(Str(att, "prompt"));
                if (!string.IsNullOrWhiteSpace(qp))
                {
                    outp.Add(new TranscriptBlock(BlockKind.Queued, "queued", qp, string.Empty, when));
                }

                break;
            }

            // 🪤 EVERYTHING ELSE IS DELIBERATELY DROPPED. output_style and
            // total_tokens_reminder alone are 2.246 attachments in a busy tail -
            // per-turn machinery the terminal never shows either, and rendering
            // them would swamp the pane with the exact noise this removed.
            default:
                break;
        }
    }

    private static void AddContentBlock(
        List<TranscriptBlock> outp, JsonElement record, JsonElement b, string role, DateTimeOffset? when)
    {
        if (b.ValueKind != JsonValueKind.Object)
        {
            return;
        }

        var type = Str(b, "type");
        switch (type)
        {
            case "text":
            {
                var s = Str(b, "text");
                if (string.IsNullOrWhiteSpace(s))
                {
                    return;
                }

                outp.Add(string.Equals(role, "user", StringComparison.Ordinal)
                    ? UserBlocks.Build(s, when)
                    : new TranscriptBlock(BlockKind.Said, string.Empty, s, string.Empty, when));
                return;
            }

            case "thinking":
            {
                var s = Str(b, "thinking");
                if (string.IsNullOrWhiteSpace(s))
                {
                    return;
                }

                var n = s.Split('\n').Length;
                outp.Add(new TranscriptBlock(BlockKind.Thinking, "thinking", s,
                    n.ToString(CultureInfo.InvariantCulture) + " lines", when));
                return;
            }

            case "tool_use":
                AddToolUse(outp, b, when);
                return;

            case "tool_result":
                AddToolResult(outp, record, b, when);
                return;

            default:
                return;
        }
    }

    private static void AddToolUse(List<TranscriptBlock> outp, JsonElement b, DateTimeOffset? when)
    {
        var name = Str(b, "name");
        var input = b.TryGetProperty("input", out var i) && i.ValueKind == JsonValueKind.Object ? i : default;

        var arg = string.Empty;
        if (input.ValueKind == JsonValueKind.Object)
        {
            foreach (var k in ArgKeys)
            {
                if (input.TryGetProperty(k, out var v))
                {
                    var s = Scalar(v);
                    if (s.Length > 0)
                    {
                        arg = s;
                        break;
                    }
                }
            }

            if (arg.Length == 0)
            {
                foreach (var p in input.EnumerateObject())
                {
                    arg = Scalar(p.Value);
                    break;
                }
            }
        }

        arg = arg.Trim();

        // Compress BEFORE truncating, or the budget is spent on the part of the
        // path that is identical on every line and the end - the part that says
        // WHICH worktree - is what gets cut.
        var argShort = TranscriptText.CompressPaths(Whitespace.Replace(arg, " ").Trim());
        if (argShort.Length > 150)
        {
            argShort = string.Concat(argShort.AsSpan(0, 147), "…");
        }

        // 🔑 THE TWO CALLS THAT START SOMETHING THAT OUTLIVES THEM. A Task spawns
        // a sub-agent and a backgrounded Bash leaves a shell running, and both
        // were drawn as an ordinary tool call - the same grey row as a Read.
        if (string.Equals(name, "SendMessage", StringComparison.Ordinal))
        {
            // 🪤 NEITHER `to` NOR `message` IS IN THE ARGUMENT KEY LIST, so the
            // generic path fell through to "the first property" and picked the
            // RECIPIENT as the argument - so what was actually sent never
            // reached the pane at all.
            //
            // 🪤 AND `to` IS OFTEN A NAMED PIPE, not a name. Printing that as the
            // recipient is the same defect as printing the envelope as prose: a
            // peer addressed by name keeps its name, an address becomes words.
            var to = Str(input, "to").Trim();
            if (to.StartsWith("uds:", StringComparison.Ordinal) ||
                to.Contains(@"\pipe\", StringComparison.Ordinal))
            {
                to = "another session";
            }

            argShort = to;
            arg = Str(input, "message").Trim();
        }
        else if (string.Equals(name, "Agent", StringComparison.Ordinal) ||
                 string.Equals(name, "Task", StringComparison.Ordinal))
        {
            // 🪤 IT IS 'Agent', AND THE POWERSHELL ONLY SAID 'Task' AT FIRST.
            // Counted across every transcript on this machine: 'Task' appears in
            // ZERO files and 'Agent' in 40, so that branch had never once run.
            // Both are accepted because 'Task' costs nothing to keep.
            argShort = Str(input, "description").Trim();
        }
        else if (string.Equals(name, "Bash", StringComparison.Ordinal) &&
                 input.ValueKind == JsonValueKind.Object &&
                 input.TryGetProperty("run_in_background", out var bg) &&
                 bg.ValueKind == JsonValueKind.True)
        {
            // 🪤 run_in_background IS ON THE INPUT AND NOWHERE ELSE. The
            // transcript answers a backgrounded Bash immediately and records no
            // shell id, so this flag on the CALL is the only evidence in the
            // file that a shell was ever left running.
            name = "Bash (background)";
            argShort = Str(input, "description").Trim();
        }

        // 🔴 A QUESTION YOU ANSWERED IS NOT A TOOL CALL, and drawing it as one is
        // what made it unreadable - the argument slot got a stringified object
        // and the answer came back as one run-on line of quoted pairs. The
        // RESULT emits an 'asked' block; the call itself is dropped rather than
        // drawn twice.
        if (string.Equals(name, "AskUserQuestion", StringComparison.Ordinal))
        {
            return;
        }

        outp.Add(new TranscriptBlock(BlockKind.Tool, name, arg, argShort, when));
    }

    private static void AddToolResult(
        List<TranscriptBlock> outp, JsonElement record, JsonElement b, DateTimeOffset? when)
    {
        // 🔑 THE ANSWERED ROUND, STRUCTURED. toolUseResult carries `answers` as a
        // plain question -> chosen map, so nothing has to be recovered from the
        // sentence claude writes back, which is where the wall of quoted text
        // came from. One line per question, the halves separated by U+0001 so
        // neither can contain the separator.
        if (record.TryGetProperty("toolUseResult", out var tur) &&
            tur.ValueKind == JsonValueKind.Object &&
            tur.TryGetProperty("answers", out var answers) &&
            answers.ValueKind == JsonValueKind.Object)
        {
            var pairs = new List<string>();
            foreach (var p in answers.EnumerateObject())
            {
                var q = p.Name.Trim();
                var a = Scalar(p.Value).Trim();
                if (q.Length == 0 && a.Length == 0)
                {
                    continue;
                }

                pairs.Add(q + '\u0001' + a);
            }

            if (pairs.Count > 0)
            {
                outp.Add(new TranscriptBlock(BlockKind.Asked, "you answered",
                    string.Join("\n", pairs),
                    pairs.Count.ToString(CultureInfo.InvariantCulture), when));
                return;
            }
        }

        var s = string.Empty;
        if (b.TryGetProperty("content", out var c))
        {
            if (c.ValueKind == JsonValueKind.String)
            {
                s = c.GetString() ?? string.Empty;
            }
            else if (c.ValueKind == JsonValueKind.Array)
            {
                foreach (var part in c.EnumerateArray())
                {
                    if (part.ValueKind == JsonValueKind.Object &&
                        string.Equals(Str(part, "type"), "text", StringComparison.Ordinal))
                    {
                        s += Str(part, "text");
                    }
                }
            }
        }

        // The ONE place a child process's raw stdout enters this tool.
        // Everything else here is JSON claude wrote.
        s = TranscriptText.RemoveAnsi(s);
        var lines = s.Split('\n').Length;
        var failed = b.TryGetProperty("is_error", out var e) && e.ValueKind == JsonValueKind.True;

        outp.Add(new TranscriptBlock(BlockKind.Result, failed ? "failed" : "result", s,
            lines.ToString(CultureInfo.InvariantCulture) + " lines", when));
    }

    /// <summary>
    /// When the record was written, in LOCAL time - the only question anyone
    /// asks of it is "was that before or after I went to lunch".
    /// </summary>
    private static DateTimeOffset? Timestamp(JsonElement r)
    {
        var ts = Str(r, "timestamp");
        if (ts.Length == 0)
        {
            return null;
        }

        return DateTimeOffset.TryParse(ts, CultureInfo.InvariantCulture,
            DateTimeStyles.AdjustToUniversal, out var when) ? when.ToLocalTime() : null;
    }

    private static string Str(JsonElement e, string name) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v)
            ? Scalar(v)
            : string.Empty;

    /// <summary>One JSON value as the string PowerShell would have made of it.</summary>
    /// <remarks>
    /// 🔴 THIS IS A DISPLAY STRING, AND POWERSHELL'S SHAPE IS THE BETTER ONE.
    /// A tool argument that is an array reaches the pane as its elements with
    /// spaces between them - "a.png b.png" - where JSON would put
    /// ["a.png","b.png"] on a reading surface. The oracle found this at
    /// $.rows[495].meta on a call whose only argument was a list of files.
    ///
    /// 🪤 IT IS NOT A GENERAL JSON-TO-STRING. It exists to reproduce what
    /// PowerShell's string interpolation does to the ONE value that ends up in a
    /// tool call's argument slot; nothing should reach for it to serialise
    /// anything.
    /// </remarks>
    private static string Scalar(JsonElement v) => v.ValueKind switch
    {
        JsonValueKind.String => v.GetString() ?? string.Empty,
        JsonValueKind.Number => v.ToString(),
        JsonValueKind.True => "True",
        JsonValueKind.False => "False",
        JsonValueKind.Null or JsonValueKind.Undefined => string.Empty,
        JsonValueKind.Array => string.Join(" ", v.EnumerateArray().Select(Scalar)),
        JsonValueKind.Object => "@{" + string.Join("; ",
            v.EnumerateObject().Select(p => p.Name + "=" + Scalar(p.Value))) + "}",
        _ => v.ToString(),
    };
}
