using System.Globalization;

namespace SessionRestore.Core.Transcripts;

/// <summary>How much of what ran the pane is showing.</summary>
public static class StepsView
{
    /// <summary>Finished steps are history and go away. What is still happening keeps its line.</summary>
    public const string Hidden = "hidden";

    /// <summary>One summary line per run, closed.</summary>
    public const string Folded = "folded";

    /// <summary>Every run open.</summary>
    public const string Full = "full";
}

/// <summary>
/// One entry the reading pane draws for one turn.
/// </summary>
/// <param name="Kind">The turn's kind, or empty when the turn was dropped.</param>
/// <param name="Rule">A horizontal rule above it.</param>
/// <param name="Label">The heading, if it has one.</param>
/// <param name="Trailing">What is said beside the heading - the hidden-step count.</param>
/// <param name="Marker">A word drawn in the block itself, rather than as a heading.</param>
/// <param name="Caption">A fold's caption - the run summary, or what the block is.</param>
/// <param name="Trailing2">
/// The one line a CLOSED fold shows beside its caption, so a folded block still
/// says what is in it. 🪤 Not the same field as the heading's trailing note -
/// one is "3 steps hidden" beside a person's name, the other is the first line
/// of what is folded away.
/// </param>
/// <param name="Gutter">
/// Which marker the gutter draws. 🔑 THE BLOCK IS MARKED BY THE MOST NOTABLE
/// THING IN IT: a run that spawned a sub-agent is not the same event as a run of
/// Reads, and at a glance down the gutter that difference is the one worth
/// seeing.
/// </param>
/// <param name="Open">Whether a fold starts open.</param>
public sealed record DocEntry(
    string Kind, bool Rule, string Label, string Trailing,
    string Marker, string Caption, string Gutter, bool Open, string Trailing2 = "");

/// <summary>
/// What the reading pane shows for a list of turns - the decisions, without the
/// pixels.
/// </summary>
/// <remarks>
/// 🔴 THE HIDDEN COUNT IS AN ACCUMULATOR ACROSS TURNS, and that is the whole
/// reason this is one function rather than a per-turn one. A dropped step adds
/// to a running total that is then SPENT on the next heading - "3 steps hidden"
/// beside the next thing anybody said - and reset. A port that decided each turn
/// in isolation could not produce that line at all.
///
/// 🔑 HIDDEN HIDES HISTORY, NOT WHAT IS STILL HAPPENING. A run whose shell is
/// still open keeps its one-line fold even on `hidden`, because its output is
/// only reachable through that fold. This was reported as "when I click on the
/// respective background running agent or task, I cannot see its output" - the
/// setting was removing the one route to a running shell rather than reducing
/// noise. Everything finished still goes away, and is still counted.
///
/// 🪤 AND AN UNKNOWN LIVE-SHELL SET HIDES NOTHING EXTRA AND EXEMPTS NOTHING.
/// The shipped path only consults the list when it belongs to THIS conversation;
/// when it does not, the set is empty and `hidden` behaves exactly as it did
/// before. It must not guess in either direction.
/// </remarks>
public static class ReadDoc
{
    /// <summary>Nothing in this transcript could be read.</summary>
    public const string Empty = "Nothing readable in this transcript yet.";

    /// <summary>
    /// 🔴 A CONTROL, NOT A CAPTION. This said "press L to load earlier" - a
    /// keyboard shortcut announced in italics at the top of a document nobody
    /// had focused. The thing that looks like the affordance has to BE the
    /// affordance. It also says what you are looking at NOW: "load earlier"
    /// described a slice, and it fetches the lot.
    /// </summary>
    public static string LoadWhole(int tailBytes) => string.Format(
        CultureInfo.InvariantCulture,
        "load the whole conversation   showing the last {0} KB of a longer one",
        tailBytes / 1024);

    /// <summary>The way back out of a sub-agent. Drilling in is not a selection.</summary>
    public static string BackTo(string parentTitle) =>
        "←  back to " + (parentTitle ?? string.Empty);


    /// <summary>Any opening or closing tag, for the plain form.</summary>
    private static readonly System.Text.RegularExpressions.Regex AnyTag =
        new("</?[a-zA-Z][a-zA-Z0-9-]*[^>]*>", System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    /// <summary>
    /// The first line worth reading, cut to a width. <c>Get-SRHeadLine</c>.
    /// </summary>
    /// <remarks>
    /// 🪤 THE CUT IS AT <c>Max - 1</c> PLUS THE ELLIPSIS, so the result is
    /// exactly Max characters and not Max + 1 - the same off-by-one the folded
    /// result line has, in the other direction.
    ///
    /// 🪤 AND `plain` STRIPS TAGS FIRST, because a machine message is mostly
    /// routing envelope: sixty characters of &lt;cross-session-message from=...&gt;
    /// before a word of content.
    /// </remarks>
    public static string HeadLine(string? text, int max = 88, bool plain = false)
    {
        var t = text ?? string.Empty;
        if (plain && t.Length > 0)
        {
            t = AnyTag.Replace(t, " ");
        }

        var head = string.Empty;
        foreach (var line in t.Replace("\r", string.Empty, StringComparison.Ordinal).Split('\n'))
        {
            if (line.Trim().Length > 0)
            {
                head = line;
                break;
            }
        }

        head = head.Trim();
        return head.Length > max ? head[..(max - 1)] + "\u2026" : head;
    }

    /// <summary>What the pane draws, turn by turn.</summary>
    /// <param name="turns">The turns, from <see cref="ReadTurns.Of"/>.</param>
    /// <param name="stepsView">See <see cref="StepsView"/>.</param>
    /// <param name="liveShells">
    /// The background shells still writing for THIS conversation. Empty or null
    /// means nothing is known, which hides nothing extra and exempts nothing.
    /// </param>
    public static List<DocEntry> Of(
        IReadOnlyList<ReadTurn>? turns, string stepsView, IReadOnlySet<string>? liveShells = null)
    {
        var outp = new List<DocEntry>();
        if (turns is null)
        {
            return outp;
        }

        var hiddenView = string.Equals(stepsView, StepsView.Hidden, StringComparison.Ordinal);
        var openFolds = string.Equals(stepsView, StepsView.Full, StringComparison.Ordinal);
        var hidden = 0;

        foreach (var t in turns)
        {
            switch (t.Kind)
            {
                case "you":
                {
                    // A human turn is the one real boundary in a conversation,
                    // and it keeps a rule. Claude's turns no longer do: a rule
                    // above every reply is a rule above almost everything, which
                    // is noise rather than structure.
                    // 🪤 NO GUTTER MARK. A spoken turn is LABELLED - a heading
                    // in the speaker's hue - and only the blocks that go in the
                    // rail carry a mark beside them. A port that marked these
                    // too would put a dot beside every line of the conversation,
                    // which is the density this surface was rebuilt to remove.
                    outp.Add(new DocEntry("you", true, "you said", Spend(ref hidden),
                                          string.Empty, string.Empty, string.Empty, false));
                    break;
                }

                case "msgin":
                    outp.Add(new DocEntry("msgin", false, "message from " + t.Head, Spend(ref hidden),
                                          string.Empty, string.Empty, string.Empty, false));
                    break;

                case "said":
                    outp.Add(new DocEntry("said", false, "claude", Spend(ref hidden),
                                          string.Empty, string.Empty, string.Empty, false));
                    break;

                case "compact":
                    outp.Add(new DocEntry("compact", false, string.Empty, string.Empty,
                                          "COMPACTED", string.Empty, "compact", false));
                    break;

                case "asked":
                    outp.Add(new DocEntry("asked", false, string.Empty, string.Empty,
                                          "YOU ANSWERED", string.Empty, "asked", false));
                    break;

                case "thinking":
                {
                    // 🔴 HIDDEN DROPS REASONING AND DOES NOT COUNT IT. Every
                    // other hidden arm adds to the tally; this one just leaves.
                    // Thinking is not a STEP - counting it would put "4 steps
                    // hidden" beside a turn in which three things ran and one
                    // was thought about.
                    if (hiddenView)
                    {
                        break;
                    }

                    outp.Add(new DocEntry("thinking", false, string.Empty, string.Empty,
                                          string.Empty, "THINKING", "thinking", openFolds,
                                          HeadLine(t.Body.Trim(), 96)));
                    break;
                }

                case "queued":
                {
                    // 🪤 NOT TRIMMED, AND THE ARM BESIDE IT IS. One `.Trim()`
                    // apart in the shipped source, kept because the source has
                    // it - NOT because it can be seen from here.
                    //
                    // 🔴 IT IS NOT OBSERVABLE THROUGH THE HEADLINE AT ALL, and
                    // a break proved it: adding the trim changed nothing.
                    // HeadLine already skips blank lines and trims the one it
                    // picks, so leading whitespace on the body cannot reach the
                    // answer. Where it WOULD show is the fold's DATA - the body
                    // drawn when the block is opened - which this comparison
                    // does not reach. Written down so the next reader does not
                    // spend the afternoon on the same break.
                    outp.Add(new DocEntry("queued", false, string.Empty, string.Empty,
                                          string.Empty, "QUEUED", "queued", openFolds,
                                          HeadLine(t.Body, 84)));
                    break;
                }

                case "hook":
                {
                    // 🪤 ONE EACH, WHATEVER THEY MERGED. A hook turn counts as
                    // ONE hidden step even when several were folded into it -
                    // only a notice turn spends its Count.
                    if (hiddenView)
                    {
                        hidden++;
                        break;
                    }

                    // 🪤 THE BODY IS TRIMMED BEFORE THE HEADLINE IS TAKEN, and
                    // the notice arm's is NOT - so a notice whose first line is
                    // blank shows nothing beside its caption and a hook shows
                    // its first real line. Two arms, two rules, and the
                    // difference is one `.Trim()` in the shipped source.
                    var hookBody = t.Body.Trim();
                    outp.Add(new DocEntry("hook", false, string.Empty, string.Empty, string.Empty,
                                          "HOOK  " + t.Head, "hook", openFolds,
                                          HeadLine(hookBody, 84, plain: true)));
                    break;
                }

                case "file":
                {
                    if (hiddenView)
                    {
                        hidden++;
                        break;
                    }

                    var fileBody = t.Body.Trim();
                    outp.Add(new DocEntry("file", false, string.Empty, string.Empty, string.Empty,
                                          string.Format(CultureInfo.InvariantCulture, "{0}  {1} {2}",
                                              t.Head, t.Count, t.Count == 1 ? "file" : "files"),
                                          "file", openFolds, HeadLine(fileBody, 84)));
                    break;
                }

                case "system":
                {
                    // 🪤 AND A RUN OF NOTICES SPENDS ITS COUNT. Eleven merged
                    // notices are eleven hidden steps, not one.
                    if (hiddenView)
                    {
                        hidden += t.Count;
                        break;
                    }

                    var n = t.Count < 1 ? 1 : t.Count;
                    outp.Add(new DocEntry("system", false, string.Empty, string.Empty, string.Empty,
                                          n == 1 ? "NOTICE" : n.ToString(CultureInfo.InvariantCulture) + " NOTICES",
                                          "system", openFolds, HeadLine(t.Body, 88, plain: true)));
                    break;
                }

                case "run":
                {
                    if (hiddenView && !StillHappening(t, liveShells))
                    {
                        hidden += t.Calls.Count;
                        break;
                    }

                    outp.Add(new DocEntry("run", false, string.Empty, string.Empty, string.Empty,
                                          ReadTurns.Summary(t.Calls), RunGutter(t), openFolds));
                    break;
                }

                default:
                    break;
            }
        }

        return outp;
    }

    /// <summary>
    /// 🪤 THE COUNT IS SPENT, NOT READ. It goes onto the next heading and resets
    /// - so two headings in a row do not both claim the same hidden steps.
    /// </summary>
    private static string Spend(ref int hidden)
    {
        if (hidden <= 0)
        {
            return string.Empty;
        }

        var text = hidden.ToString(CultureInfo.InvariantCulture) + " steps hidden";
        hidden = 0;
        return text;
    }

    private static bool StillHappening(ReadTurn t, IReadOnlySet<string>? liveShells)
    {
        if (liveShells is null || liveShells.Count == 0)
        {
            return false;
        }

        foreach (var c in t.Calls)
        {
            if (c.Shell.Length > 0 && liveShells.Contains(c.Shell))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// 🪤 THE FIRST AGENT OR MESSAGE WINS AND STOPS LOOKING; A SHELL DOES NOT.
    /// The shipped loop breaks on agent and on msgout but merely ASSIGNS on
    /// shell - so a run holding a shell and then an agent is marked as an agent,
    /// and one holding an agent and then a shell is still an agent. A port that
    /// broke on all three, or on none, disagrees on exactly those runs.
    /// </summary>
    private static string RunGutter(ReadTurn t)
    {
        var rk = "run";
        foreach (var c in t.Calls)
        {
            if (string.Equals(c.CallKind, CallKinds.Agent, StringComparison.Ordinal))
            {
                return CallKinds.Agent;
            }

            if (string.Equals(c.CallKind, CallKinds.MsgOut, StringComparison.Ordinal))
            {
                return CallKinds.MsgOut;
            }

            if (string.Equals(c.CallKind, CallKinds.Shell, StringComparison.Ordinal))
            {
                rk = CallKinds.Shell;
            }
        }

        return rk;
    }
}
