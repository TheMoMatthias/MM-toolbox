using System.Text.Json;
using System.Text.RegularExpressions;

namespace SessionRestore.Core.Transcripts;

/// <summary>
/// Deciding what a <c>user</c> record actually is - because most of them are
/// not the operator.
/// </summary>
/// <remarks>
/// 🔴 THE ROLE IS <c>user</c> AND THE AUTHOR IS NOT. Claude Code injects several
/// things into a transcript as user records: background-task notifications,
/// <c>&lt;system-reminder&gt;</c> context, the caveat block that wraps a slash
/// command, and messages from other sessions. Reading "role: user" as "the human
/// said this" is what put all of them in his voice, on the one surface whose
/// entire job is saying who is speaking. Reported as text "shown to be sent from
/// me, which I actually didn't send".
/// </remarks>
public static partial class UserBlocks
{
    [GeneratedRegex(@"(?s)<command-name>\s*(.*?)\s*</command-name>")]
    private static partial Regex CmdName();

    [GeneratedRegex(@"(?s)<command-args>\s*(.*?)\s*</command-args>")]
    private static partial Regex CmdArgs();

    [GeneratedRegex(@"(?s)<(task-notification|system-reminder|local-command-caveat)\b[^>]*>.*?</\1>")]
    private static partial Regex MachineWrap();

    [GeneratedRegex(@"(?m)^\s*\[(Cross-session idle notice|Request interrupted[^\]]*)\][^\r\n]*$")]
    private static partial Regex MachineLine();

    [GeneratedRegex(@"(?s)\A(?<pre>[^<]{0,200}?)<(?<tag>cross-session-message|teammate-message)\b(?<attrs>[^>]*)>")]
    private static partial Regex MsgIn();

    [GeneratedRegex(@"(?s)</(cross-session-message|teammate-message)>.*\z")]
    private static partial Regex MsgEnd();

    [GeneratedRegex(@"from-name=""([^""]*)""")]
    private static partial Regex MsgFrom();

    [GeneratedRegex(@"teammate_id=""([^""]*)""")]
    private static partial Regex MsgMate();

    /// <summary>Does this text carry an inbound message envelope?</summary>
    public static bool IsInboundMessage(string? text) =>
        !string.IsNullOrEmpty(text) && MsgIn().IsMatch(text);

    /// <summary>
    /// A slash command as the operator typed it: its name and its arguments,
    /// and nothing else out of the record.
    /// </summary>
    /// <remarks>
    /// 🔴 CLAUDE CODE EXPANDS A SLASH COMMAND INTO THE WHOLE PROMPT BODY and
    /// files it as a user record - so invoking a skill of two hundred lines put
    /// two hundred lines on screen in the operator's own voice. His words: "it
    /// looks like I am pasting the entire content, which is a little bit
    /// misleading."
    ///
    /// 🪤 THE EXPANSION IS NOT A LONGER VERSION OF WHAT HE TYPED. It is a
    /// different text, written by the skill, so there is nothing in it to trim
    /// down to. What he typed is exactly the name plus the arguments.
    /// </remarks>
    public static string SlashCommandText(string? text)
    {
        // A cheap gate before two regexes: the overwhelming majority of records
        // carry no command envelope at all, and this runs once per record.
        if (string.IsNullOrEmpty(text) ||
            !text.Contains("<command-name>", StringComparison.Ordinal))
        {
            return string.Empty;
        }

        var n = CmdName().Match(text);
        if (!n.Success)
        {
            return string.Empty;
        }

        var name = n.Groups[1].Value.Trim();
        if (name.Length == 0)
        {
            return string.Empty;
        }

        // Some records carry the slash, some do not. One shape on screen either way.
        if (!name.StartsWith('/'))
        {
            name = "/" + name;
        }

        var a = CmdArgs().Match(text);
        var args = a.Success ? a.Groups[1].Value.Trim() : string.Empty;
        return args.Length > 0 ? name + " " + args : name;
    }

    /// <summary>
    /// Is this record machinery rather than a person?
    /// </summary>
    /// <remarks>
    /// 🪤 STRIPPED FOR THE TEST, KEPT FOR THE BLOCK. A record is machinery only
    /// if NOTHING is left once the envelopes come off - a real message with a
    /// system-reminder appended is still a real message. What the block carries
    /// is the full text either way.
    /// </remarks>
    public static bool IsMachineRecord(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return false;
        }

        // Every envelope opens with one of these two characters, and most of
        // what the operator types carries neither.
        if (!text.Contains('<', StringComparison.Ordinal) &&
            !text.Contains('[', StringComparison.Ordinal))
        {
            return false;
        }

        var s = MachineWrap().Replace(text, string.Empty);
        s = MachineLine().Replace(s, string.Empty);
        return string.IsNullOrWhiteSpace(s);
    }

    /// <summary>
    /// The block a <c>user</c> record becomes: the operator's words, a message
    /// from another session, or machinery.
    /// </summary>
    public static TranscriptBlock Build(string text, DateTimeOffset? when)
    {
        // Before anything else: a record carrying a command envelope IS that
        // command, whatever else was pasted in beside it.
        var slash = SlashCommandText(text);
        if (slash.Length > 0)
        {
            return new TranscriptBlock(BlockKind.You, string.Empty, slash, string.Empty, when);
        }

        var m = MsgIn().Match(text);
        if (!m.Success)
        {
            return IsMachineRecord(text)
                ? new TranscriptBlock(BlockKind.System, string.Empty, text, string.Empty, when)
                : new TranscriptBlock(BlockKind.You, string.Empty, text, string.Empty, when);
        }

        var attrs = m.Groups["attrs"].Value;
        var who = string.Empty;
        var f = MsgFrom().Match(attrs);
        if (f.Success)
        {
            who = f.Groups[1].Value;
        }
        else
        {
            f = MsgMate().Match(attrs);
            if (f.Success)
            {
                who = f.Groups[1].Value;
            }
        }

        // 🪤 NEVER THE from= PIPE PATH AS A FALLBACK. It is a named-pipe address
        // - uds:\\.\pipe\LOCAL\cc-msg-d6f54257... - and putting that where a
        // name goes is how the envelope ended up on screen in the first place.
        // If nobody is named, say so in words.
        if (who.Length == 0)
        {
            who = "another session";
        }

        var body = text[(m.Index + m.Length)..];
        body = MsgEnd().Replace(body, string.Empty).Trim();

        // 🔴 AND IT IS NOT JSON SOURCE. The envelope's payload is an object, and
        // printing it raw put backslash-n and ## on screen as literal characters
        // with every quote escaped. Reported with a screenshot of exactly that.
        //
        // 🪤 THE FIELD, IF THERE IS ONE - NEVER A GUESS AT THE SHAPE. Only a body
        // that actually parses is unwrapped, only a known payload field is taken,
        // and anything else is left EXACTLY as it arrived. A message this cannot
        // read is still readable; a message it mangles is not.
        if (body.Length > 1 && body[0] == '{')
        {
            try
            {
                using var doc = JsonDocument.Parse(body);
                if (doc.RootElement.ValueKind == JsonValueKind.Object)
                {
                    foreach (var field in new[] { "result", "message", "content", "summary" })
                    {
                        if (doc.RootElement.TryGetProperty(field, out var v) &&
                            v.ValueKind == JsonValueKind.String)
                        {
                            var s = v.GetString();
                            if (!string.IsNullOrWhiteSpace(s))
                            {
                                body = s.Trim();
                                break;
                            }
                        }
                    }
                }
            }
            catch (JsonException)
            {
                // Not JSON after all. Leave it exactly as it arrived.
            }
        }

        return new TranscriptBlock(BlockKind.MsgIn, who, body.Trim(), string.Empty, when);
    }
}
