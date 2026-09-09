using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace SessionRestore.Core.Transcripts;

/// <summary>What a conversation last said, and what it left running.</summary>
/// <remarks>
/// 🔑 <see cref="Full"/> IS THE WHOLE LAST MESSAGE AND IT IS FREE.
/// <see cref="Said"/> is deliberately ONE LINE - it is a column in a list - but
/// a headline cannot answer "did it leave anything open", which is a question
/// about the rest of the message. Measured over 26 live conversations: Said runs
/// 29-160 characters and not one of them matched an open-item pattern; the text
/// that would have matched was in the same content the first line came from.
/// </remarks>
public sealed record SaidResult(
    string Said,
    string Pending,
    string PendingTool,
    DateTimeOffset? At,
    string Full)
{
    public static SaidResult Empty { get; } = new(string.Empty, string.Empty, string.Empty, null, string.Empty);

    public bool HasSaid => !string.IsNullOrWhiteSpace(Said);
}

/// <summary>
/// Reads the last thing a conversation actually said, out of the tail of its
/// transcript.
/// </summary>
public static class LastSaid
{
    private const int DefaultMaxRecords = 120;

    /// <summary>Argument keys that identify a tool call at a glance, in order.</summary>
    private static readonly string[] ArgKeys =
        ["command", "file_path", "path", "pattern", "prompt", "description", "url", "query"];

    private static readonly Regex Whitespace = new(@"\s+", RegexOptions.Compiled);
    private static readonly Regex Heading = new(@"^#{1,6}\s+", RegexOptions.Compiled);
    private static readonly Regex Bullet = new(@"^[-*]\s+", RegexOptions.Compiled);

    /// <summary>
    /// One pass over the tail. Walks records backwards to the newest assistant
    /// record that actually said something.
    /// </summary>
    public static SaidResult Pass(string path, int tailBytes = TranscriptTail.DefaultTailBytes, int maxRecords = DefaultMaxRecords)
    {
        var text = TranscriptTail.Read(path, tailBytes);
        var lines = TranscriptTail.WholeRecords(text);
        if (lines.Count == 0)
        {
            return SaidResult.Empty;
        }

        var pending = string.Empty;
        var pendingTool = string.Empty;

        var seen = 0;
        for (var i = lines.Count - 1; i >= 0 && seen < maxRecords; i--)
        {
            seen++;
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

            if (!TryString(r, "type", out var type) || !string.Equals(type, "assistant", StringComparison.Ordinal))
            {
                continue;
            }

            if (!r.TryGetProperty("message", out var m) || m.ValueKind != JsonValueKind.Object)
            {
                continue;
            }

            if (!m.TryGetProperty("content", out var content))
            {
                continue;
            }

            var at = ReadTimestamp(r);

            if (content.ValueKind == JsonValueKind.String)
            {
                var s = content.GetString() ?? string.Empty;
                if (!string.IsNullOrWhiteSpace(s))
                {
                    return new SaidResult(FirstLine(s), pending, pendingTool, at, SaidBody(s));
                }

                continue;
            }

            if (content.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            // 🪤 THIS RECORD'S BLOCKS ARE WALKED IN REVERSE TOO, so a text block
            // followed by a tool_use in the SAME record reports the tool as
            // pending rather than losing it.
            var blocks = content.EnumerateArray().ToArray();
            for (var k = blocks.Length - 1; k >= 0; k--)
            {
                var b = blocks[k];
                if (b.ValueKind != JsonValueKind.Object || !TryString(b, "type", out var bt))
                {
                    continue;
                }

                if (string.Equals(bt, "tool_use", StringComparison.Ordinal) && pending.Length == 0)
                {
                    var name = TryString(b, "name", out var n) ? n : string.Empty;
                    var arg = FirstArgument(b);
                    pendingTool = name;
                    pending = arg.Length > 0 ? $"{name}({arg})" : name;
                }
                else if (string.Equals(bt, "text", StringComparison.Ordinal))
                {
                    var s = TryString(b, "text", out var t) ? t : string.Empty;
                    if (!string.IsNullOrWhiteSpace(s))
                    {
                        return new SaidResult(FirstLine(s), pending, pendingTool, at, SaidBody(s));
                    }
                }
            }
        }

        return new SaidResult(string.Empty, pending, pendingTool, null, string.Empty);
    }

    /// <summary>
    /// The pass, widened if it found nothing.
    /// </summary>
    /// <remarks>
    /// 🔴 A SESSION CAN GENUINELY HAVE NO PROSE IN ITS TAIL - a long unbroken
    /// chain of tool calls, or one enormous record. So a first pass that finds
    /// nothing is retried at 8x and 32x rather than reported as silence.
    ///
    /// 🪤 THE NEARER PASS'S PENDING TOOL WINS. The wider read reaches further
    /// back and will find an OLDER tool call; what is running now is what the
    /// closest read saw.
    /// </remarks>
    public static SaidResult Read(string path, int tailBytes = TranscriptTail.DefaultTailBytes, int maxRecords = DefaultMaxRecords)
    {
        var first = Pass(path, tailBytes, maxRecords);
        if (first.HasSaid)
        {
            return first;
        }

        long len;
        try
        {
            len = new FileInfo(path).Length;
        }
        catch (IOException)
        {
            return first;
        }

        if (len <= tailBytes)
        {
            return first;
        }

        foreach (var mult in new[] { 8, 32 })
        {
            var wider = Pass(path, tailBytes * mult, maxRecords * mult);
            if (wider.HasSaid)
            {
                return string.IsNullOrWhiteSpace(first.Pending)
                    ? wider
                    : wider with { Pending = first.Pending, PendingTool = first.PendingTool };
            }

            if (len <= (long)tailBytes * mult)
            {
                break;
            }
        }

        return first;
    }

    /// <summary>
    /// One line out of prose that may be paragraphs, markdown or a code fence.
    /// </summary>
    /// <remarks>
    /// The FIRST MEANINGFUL line rather than the first N characters: a leading
    /// blank, a heading marker or a bullet dash is not what the conversation
    /// said.
    /// </remarks>
    public static string FirstLine(string text, int max = 160)
    {
        var s = (text ?? string.Empty).Replace("\r", string.Empty, StringComparison.Ordinal);
        foreach (var line in s.Split('\n'))
        {
            var t = line.Trim();
            if (t.Length == 0 || t.StartsWith("```", StringComparison.Ordinal))
            {
                continue;
            }

            t = Heading.Replace(t, string.Empty);
            t = Bullet.Replace(t, string.Empty);
            t = t.Replace("**", string.Empty, StringComparison.Ordinal)
                 .Replace("`", string.Empty, StringComparison.Ordinal);
            t = Whitespace.Replace(t, " ").Trim();
            if (t.Length == 0)
            {
                continue;
            }

            return t.Length > max ? string.Concat(t.AsSpan(0, max - 3), "...") : t;
        }

        return string.Empty;
    }

    /// <summary>
    /// The message as written, capped.
    /// </summary>
    /// <remarks>
    /// 🪤 IT KEEPS THE END, NOT THE START. What is still open is written at the
    /// close of a message, so a cap that took the first 4.000 characters would
    /// throw away the only part anything reads this for. Capped at all because
    /// a reply can be tens of thousands of characters and this is held in memory
    /// for every live conversation.
    /// </remarks>
    public static string SaidBody(string text, int max = 4000)
    {
        var s = (text ?? string.Empty).Replace("\r", string.Empty, StringComparison.Ordinal);
        return s.Length > max ? s[^max..] : s;
    }

    private static string FirstArgument(JsonElement block)
    {
        if (!block.TryGetProperty("input", out var input) || input.ValueKind != JsonValueKind.Object)
        {
            return string.Empty;
        }

        var arg = string.Empty;
        foreach (var key in ArgKeys)
        {
            if (input.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String)
            {
                var s = v.GetString();
                if (!string.IsNullOrEmpty(s))
                {
                    arg = s;
                    break;
                }
            }
        }

        arg = Whitespace.Replace(arg, " ").Trim();
        return arg.Length > 90 ? string.Concat(arg.AsSpan(0, 87), "...") : arg;
    }

    private static DateTimeOffset? ReadTimestamp(JsonElement r)
    {
        if (!TryString(r, "timestamp", out var ts) || ts.Length == 0)
        {
            return null;
        }

        return DateTimeOffset.TryParse(ts, CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind, out var when) ? when : null;
    }

    private static bool TryString(JsonElement e, string name, out string value)
    {
        value = string.Empty;
        if (e.ValueKind != JsonValueKind.Object || !e.TryGetProperty(name, out var v))
        {
            return false;
        }

        if (v.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = v.GetString() ?? string.Empty;
        return true;
    }
}
