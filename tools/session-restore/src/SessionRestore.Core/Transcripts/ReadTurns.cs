using System.Globalization;
using System.Text.RegularExpressions;

namespace SessionRestore.Core.Transcripts;

/// <summary>What sort of thing a tool call started.</summary>
public static class CallKinds
{
    /// <summary>An ordinary step: a read, an edit, a search.</summary>
    public const string Run = "run";

    /// <summary>A Task - it starts a sub-agent that outlives the call.</summary>
    public const string Agent = "agent";

    /// <summary>A backgrounded Bash - it starts a shell that outlives the call.</summary>
    public const string Shell = "shell";

    /// <summary>A message sent to another session.</summary>
    public const string MsgOut = "msgout";
}

/// <summary>
/// One tool call, with what it answered.
/// </summary>
/// <param name="Name">The tool.</param>
/// <param name="Arg">The prompt, the command, the path - uncut.</param>
/// <param name="Res">One line of the answer, for a folded step.</param>
/// <param name="ResFull">
/// The whole answer.
/// 🔴 FOLDED KEEPS ITS ONE LINE; OPENED IS THE WHOLE THING, AND THERE IS NO CAP.
/// It used to stop at six lines or 900 characters, which was the single biggest
/// reason the terminal showed more than this tool did: even with the steps
/// opened, the view whose entire purpose is to show what ran was cutting the
/// output off. What keeps it manageable is the FOLD, and a scroll region around
/// an open one.
/// </param>
/// <param name="Bad">The call failed.</param>
/// <param name="Desc">What a person wrote to say what this is FOR, as opposed to what it does.</param>
/// <param name="CallKind">See <see cref="CallKinds"/>.</param>
/// <param name="Shell">
/// 🔑 THE SHELL ID, OUT OF THE ANSWER'S OWN PROSE. A backgrounded Bash returns
/// "Command running in background with ID: beqvs0dpb." and that id is the ONLY
/// link from the transcript to the file the shell is still writing. There is no
/// structured field for it anywhere in the record, which is why a background
/// shell looked unreadable until it was read out of the sentence.
/// </param>
public sealed record ToolCall(
    string Name, string Arg, string Res, string ResFull, bool Bad,
    string Desc, string CallKind, string Shell);

/// <summary>
/// One turn of the conversation, as the reading pane draws it.
/// </summary>
/// <param name="Kind">The block kind it came from, or <c>run</c> for a group of tool calls.</param>
/// <param name="Head">Its label.</param>
/// <param name="Body">The text.</param>
/// <param name="Calls">The steps, when this is a run. Empty otherwise.</param>
/// <param name="When">
/// 🔑 WHEN THE TURN STARTED, NOT WHEN IT ENDED. Merged blocks keep the first
/// one's time, because that is the moment the reader is placing.
/// </param>
/// <param name="Count">How many blocks were merged into this one.</param>
public sealed record ReadTurn(
    string Kind, string Head, string Body,
    IReadOnlyList<ToolCall> Calls, DateTimeOffset? When, int Count);

/// <summary>
/// Blocks, grouped into the turns the reading pane draws.
/// </summary>
/// <remarks>
/// 🔑 THIS IS THE WHOLE OF WHAT THE PANE SHOWS, AS A VALUE. The shipped window
/// builds a FlowDocument straight out of it, which is why the document could
/// never be virtualized and why it needs a tail budget; a list of turns can be
/// bound to a virtualizing panel instead. Either way the GROUPING is the same
/// rule, and it is the half that can be compared.
///
/// 🔴 THREE KINDS OF RUN ARE MERGED, EACH FOR A DIFFERENT REASON - and each was
/// added after a rendered pane was LOOKED AT:
///
/// - **Consecutive you/said blocks** join into one turn, because two messages in
///   a row from the same voice are one thing being said.
/// - **Notices arrive in runs and drown the conversation.** A Remote Control
///   session prints one per artifact per reconnect, and a rendered pane turned
///   out to be ELEVEN of them in cramped mono with two lines of what claude
///   actually said above it - exactly the "flooded with text" this surface was
///   rebuilt to fix, still there, and invisible until the pane was drawn with
///   real content in it.
/// - **A compact re-reads a handful of files** and the terminal prints them as
///   one list. Six separate cards would be six times the height and no more
///   information.
/// </remarks>
public static class ReadTurns
{
    /// <summary>
    /// 🪤 THE FOLDED LINE IS CUT AT 130 AND THE ELLIPSIS REPLACES THREE OF THEM.
    /// 127 + one character, not 130 + one - the shipped line takes
    /// <c>Substring(0, 127)</c>, so a port that cut at 130 would be one
    /// character out on every long result and on nothing else.
    /// </summary>
    private const int FoldedLine = 130;

    private const int FoldedCut = 127;

    private static readonly Regex ShellId = new(
        @"with\s+ID:\s*([A-Za-z0-9_-]{1,64})", RegexOptions.CultureInvariant);

    /// <summary>Groups blocks into turns.</summary>
    public static List<ReadTurn> Of(IReadOnlyList<TranscriptBlock>? blocks)
    {
        var outp = new List<ReadTurn>();
        if (blocks is null)
        {
            return outp;
        }

        var i = 0;
        while (i < blocks.Count)
        {
            var b = blocks[i];
            var kind = Name(b.Kind);

            if (b.Kind is not (BlockKind.Tool or BlockKind.Result))
            {
                var prev = outp.Count > 0 ? outp[^1] : null;

                if (prev is not null
                    && string.Equals(prev.Kind, kind, StringComparison.Ordinal)
                    && (b.Kind is BlockKind.You or BlockKind.Said))
                {
                    outp[^1] = prev with
                    {
                        Body = prev.Body.TrimEnd() + "\n\n" + (b.Body ?? string.Empty).TrimStart(),
                    };
                }
                else if (prev is not null
                         && string.Equals(prev.Kind, "system", StringComparison.Ordinal)
                         && b.Kind == BlockKind.System)
                {
                    outp[^1] = prev with
                    {
                        Body = prev.Body.TrimEnd() + "\n" + Joined(b.Head, b.Body).Trim(),
                        Count = prev.Count + 1,
                    };
                }
                else if (prev is not null
                         && string.Equals(prev.Kind, "file", StringComparison.Ordinal)
                         && b.Kind == BlockKind.File)
                {
                    outp[^1] = prev with
                    {
                        Body = prev.Body + "\n" + Joined(b.Body, b.Meta).TrimEnd(),
                        Count = prev.Count + 1,
                    };
                }
                else
                {
                    // 🪤 THE FIRST OF A RUN IS WRITTEN THE WAY THE RUN JOINS, or
                    // the run reads ragged: a notice joined head-first has to
                    // START head-first too.
                    var body = b.Body ?? string.Empty;
                    if (b.Kind == BlockKind.File)
                    {
                        body = Joined(b.Body, b.Meta).TrimEnd();
                    }
                    else if (b.Kind == BlockKind.System)
                    {
                        body = Joined(b.Head, b.Body).Trim();
                    }

                    outp.Add(new ReadTurn(kind, b.Head ?? string.Empty, body, [], b.When, 1));
                }

                i++;
                continue;
            }

            var calls = new List<ToolCall>();
            while (i < blocks.Count && blocks[i].Kind is BlockKind.Tool or BlockKind.Result)
            {
                var c = blocks[i];
                if (c.Kind == BlockKind.Tool)
                {
                    // Which of the three shapes this call is. A Task and a
                    // backgrounded Bash each start something that outlives the
                    // call, so they carry their own marker in the pane rather
                    // than being one more grey row among the Reads.
                    var name = c.Head ?? string.Empty;
                    var ck = name switch
                    {
                        "Task" => CallKinds.Agent,
                        "Bash (background)" => CallKinds.Shell,
                        "SendMessage" => CallKinds.MsgOut,
                        _ => CallKinds.Run,
                    };

                    calls.Add(new ToolCall(name, c.Body ?? string.Empty, string.Empty, string.Empty,
                                           false, c.Meta ?? string.Empty, ck, string.Empty));
                }
                else if (calls.Count > 0 && calls[^1].Res.Length == 0)
                {
                    var last = calls[^1];
                    var raw = (c.Body ?? string.Empty).Replace("\r", string.Empty, StringComparison.Ordinal);

                    // The first line that is not blank. 🪤 The blank-stripped
                    // lines are for the FOLDED line only - a result's own blank
                    // lines are part of how the opened one reads.
                    var one = string.Empty;
                    foreach (var line in raw.Split('\n'))
                    {
                        if (line.Trim().Length > 0)
                        {
                            one = line;
                            break;
                        }
                    }

                    if (one.Length > FoldedLine)
                    {
                        one = one[..FoldedCut] + "…";
                    }

                    var full = raw.TrimEnd();
                    var shell = last.Shell;
                    if (string.Equals(last.CallKind, CallKinds.Shell, StringComparison.Ordinal))
                    {
                        var m = ShellId.Match(full);
                        if (m.Success)
                        {
                            shell = m.Groups[1].Value;
                        }
                    }

                    calls[^1] = last with
                    {
                        Res = one,
                        ResFull = full,
                        Bad = string.Equals(c.Head, "failed", StringComparison.Ordinal),
                        Shell = shell,
                    };
                }

                i++;
            }

            if (calls.Count > 0)
            {
                outp.Add(new ReadTurn("run", string.Empty, string.Empty, calls, null, 1));
            }
        }

        return outp;
    }

    /// <summary>
    /// What a folded run of steps says about itself.
    /// </summary>
    /// <remarks>
    /// 🪤 UNIQUE NAMES, FIRST THREE, IN THE ORDER THEY WERE CALLED. Not sorted,
    /// and not de-duplicated afterwards - the shipped line takes distinct names
    /// in first-seen order and then the first three of those.
    /// </remarks>
    public static string Summary(IReadOnlyList<ToolCall>? calls)
    {
        var list = calls ?? [];
        var names = new List<string>();
        foreach (var c in list)
        {
            if (!names.Contains(c.Name, StringComparer.Ordinal))
            {
                names.Add(c.Name);
            }
        }

        var shown = names.Take(3).ToList();
        var tail = names.Count > shown.Count
            ? "  +" + (names.Count - shown.Count).ToString(CultureInfo.InvariantCulture)
            : string.Empty;

        return string.Format(
            CultureInfo.InvariantCulture,
            "{0} {1}     {2}{3}",
            list.Count,
            list.Count == 1 ? "step" : "steps",
            string.Join("  ·  ", shown),
            tail);
    }

    /// <summary>Two fields with the gap the shipped format string puts between them.</summary>
    private static string Joined(string? a, string? b) =>
        string.Format(CultureInfo.InvariantCulture, "{0}   {1}", a ?? string.Empty, b ?? string.Empty);

    /// <summary>PowerShell's own name for a block kind.</summary>
    public static string Name(BlockKind k) => k switch
    {
        BlockKind.You => "you",
        BlockKind.Said => "said",
        BlockKind.Thinking => "thinking",
        BlockKind.Tool => "tool",
        BlockKind.Result => "result",
        BlockKind.Asked => "asked",
        BlockKind.MsgIn => "msgin",
        BlockKind.System => "system",
        BlockKind.Hook => "hook",
        BlockKind.File => "file",
        BlockKind.Queued => "queued",
        BlockKind.Compact => "compact",
        _ => "?",
    };
}
