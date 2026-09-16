using System.Text.RegularExpressions;

namespace SessionRestore.Core.Reading;

/// <summary>One piece of a line of prose, set the way the pane sets it.</summary>
/// <param name="Text">The words, with the marks that selected them removed.</param>
/// <param name="Semi">Bold - weight, never size.</param>
/// <param name="Italic">Emphasis.</param>
/// <param name="Mono">On the grid: inline code.</param>
/// <param name="Link">Pressable, with Ctrl held.</param>
/// <param name="Target">Where a link goes.</param>
/// <param name="Hue">
/// Which palette key paints it, or empty for whatever the caller was using.
/// </param>
public sealed record InlineSpan(
    string Text,
    bool Semi = false,
    bool Italic = false,
    bool Mono = false,
    bool Link = false,
    string Target = "",
    string Hue = "");

/// <summary>
/// Markdown, but only the parts that change how a line READS: fenced code is
/// handled a level up; this is inline code, bold, emphasis and the things in a
/// line that can be opened.
/// </summary>
/// <remarks>
/// 🔑 ANYTHING MORE WOULD BE A MARKDOWN ENGINE, which is not what this needs to
/// be. The shipped pattern is one regex with three alternatives, applied left to
/// right, and a recursion depth of three.
///
/// 🔴 INLINE CODE IS WHERE THE PATHS ARE. A backticked span in a reply is a file
/// name far more often than it is anything else - which is why it is NOT set
/// smaller than the prose around it. It was <c>size - 1.5</c>, the smallest thing
/// in the document and the one most often a path you actually need to read. The
/// hue says it is code; the size says nothing.
///
/// 🪤 Ctrl+CLICK, NEVER A PLAIN ONE, for a link. A plain click in a reading pane
/// starts a text SELECTION, and taking that gesture away to open a browser would
/// break copying a path out of a transcript - which is the thing these links are
/// made of. That is the terminal's rule and the operator asked for it by name.
/// </remarks>
public static partial class Inline
{
    /// <summary>How deep a bold inside an italic inside a bold may go.</summary>
    public const int MaxDepth = 3;

    /// <summary>The hue inline code and bold are set in.</summary>
    public const string StrongHue = "TextMax";

    /// <summary>The hue a link is set in.</summary>
    public const string LinkHue = "Link";

    /// <summary>
    /// The shipped inline pattern, alternative for alternative.
    /// </summary>
    /// <remarks>
    /// 🪤 NOT Singleline, AND NOT ANCHORED MULTILINE EITHER. It is applied one
    /// source line at a time, so <c>.</c> never needs to cross a newline; giving
    /// it Singleline would let a stray backtick swallow the rest of a reply.
    /// </remarks>
    [GeneratedRegex(@"^(.*?)(`([^`]+)`|\*\*(.+?)\*\*|\*([^*\s][^*]*)\*)(.*)$", RegexOptions.CultureInvariant)]
    private static partial Regex Marks();

    /// <summary>A URL, stopping before the punctuation that usually follows one.</summary>
    [GeneratedRegex(@"https?://[^\s<>""'\)\]}]+", RegexOptions.CultureInvariant)]
    private static partial Regex Url();

    /// <summary>
    /// A line of prose, as the pieces it is set in.
    /// </summary>
    /// <param name="text">One source line, with any list marker already off it.</param>
    /// <param name="semi">Whether the line as a whole is bold - a heading.</param>
    /// <param name="italic">Whether the line as a whole is emphasised.</param>
    /// <param name="paths">
    /// Files this conversation wrote, which become links wherever they are named.
    /// 🔑 HARVESTED FROM THE TOOL RECORDS, NOT FROM PATH-SHAPED TEXT, so a link
    /// points at something a tool actually wrote rather than at an example in a
    /// sentence. Empty means only URLs are linked.
    /// </param>
    public static List<InlineSpan> Of(
        string? text, bool semi = false, bool italic = false, Regex? paths = null)
    {
        var outp = new List<InlineSpan>();
        Split(outp, text ?? string.Empty, semi, italic, 0, paths);
        return outp;
    }

    /// <summary>
    /// One source line, through the gate the shipped builder puts in front of
    /// this whole machine.
    /// </summary>
    /// <remarks>
    /// 🪤 THE CHEAP TEST FIRST, AND IT IS WHAT MAKES THE RECURSION AFFORDABLE. A
    /// line with no backtick and no asterisk cannot carry any inline mark, and an
    /// empty PowerShell function call costs 0.068 ms - which over the ~1,000
    /// lines of a large document is 68 ms of nothing. Two Ordinal IndexOf calls
    /// answer it for the majority of lines without entering the emitter or
    /// running a regex at all.
    ///
    /// 🔴 AND THE GATE COSTS SOMETHING THE SHIPPED WINDOW DOES NOT SAY OUT LOUD:
    /// **a URL on a line with no markdown marks is not a link.** Link detection
    /// lives inside the emitter this gate skips, so
    /// <c>see https://example.com</c> is pressable only if the same line also
    /// happens to hold a backtick or an asterisk. The behaviour is reproduced
    /// here because it is what the window does and the oracle compares against
    /// the window - but it reads as a defect, not a decision, and the plan
    /// carries it as one.
    /// </remarks>
    public static List<InlineSpan> Line(
        string? text, bool semi = false, bool italic = false, Regex? paths = null)
    {
        var t = text ?? string.Empty;
        if (t.IndexOf('*', StringComparison.Ordinal) < 0 &&
            t.IndexOf('`', StringComparison.Ordinal) < 0)
        {
            return t.Length == 0 ? [] : [new InlineSpan(t, semi, italic)];
        }

        return Of(t, semi, italic, paths);
    }

    private static void Split(
        List<InlineSpan> outp, string text, bool semi, bool italic, int depth, Regex? paths)
    {
        var rest = text;
        while (rest.Length > 0)
        {
            var m = Marks().Match(rest);
            if (!m.Success)
            {
                break;
            }

            var before = m.Groups[1].Value;
            var code = m.Groups[3].Value;
            var bold = m.Groups[4].Value;
            var ital = m.Groups[5].Value;
            rest = m.Groups[6].Value;

            if (before.Length > 0)
            {
                Linked(outp, before, semi, italic, false, string.Empty, paths);
            }

            if (code.Length > 0)
            {
                // 🪤 THE CODE PIECE TAKES NEITHER THE WEIGHT NOR THE EMPHASIS
                // AROUND IT. The shipped call passes neither switch, so bold
                // stops at a backtick and starts again after it.
                Linked(outp, code, false, false, true, StrongHue, paths);
            }
            else if (bold.Length > 0)
            {
                if (depth < MaxDepth)
                {
                    Split(outp, bold, true, italic, depth + 1, paths);
                }
                else
                {
                    outp.Add(new InlineSpan(bold, true, italic, false, Hue: StrongHue));
                }
            }
            else if (ital.Length > 0)
            {
                if (depth < MaxDepth)
                {
                    Split(outp, ital, semi, true, depth + 1, paths);
                }
                else
                {
                    outp.Add(new InlineSpan(ital, semi, true));
                }
            }
        }

        if (rest.Length > 0)
        {
            Linked(outp, rest, semi, italic, false, string.Empty, paths);
        }
    }

    /// <summary>
    /// One piece of plain text, split again around anything in it that opens.
    /// </summary>
    /// <remarks>
    /// 🪝 TWO CHEAP GATES BEFORE ANY REGEX. This runs for every piece of prose in
    /// the document on every build, and the overwhelming majority contain neither
    /// a URL nor a path this session wrote.
    ///
    /// 🪤 A PATH INSIDE A URL, OR TWO PATTERNS OVER THE SAME CHARACTERS: the
    /// first one wins and the second is skipped rather than drawn twice.
    /// </remarks>
    private static void Linked(
        List<InlineSpan> outp, string text, bool semi, bool italic, bool mono, string hue, Regex? paths)
    {
        if (text.Length == 0)
        {
            return;
        }

        var hasUrl = text.Contains("http", StringComparison.OrdinalIgnoreCase);
        if (!hasUrl && paths is null)
        {
            outp.Add(new InlineSpan(text, semi, italic, mono, Hue: hue));
            return;
        }

        var hits = new List<(int At, int Len, string Text)>();
        if (hasUrl)
        {
            foreach (Match m in Url().Matches(text))
            {
                hits.Add((m.Index, m.Length, m.Value));
            }
        }

        if (paths is not null)
        {
            foreach (Match m in paths.Matches(text))
            {
                hits.Add((m.Index, m.Length, m.Value));
            }
        }

        if (hits.Count == 0)
        {
            outp.Add(new InlineSpan(text, semi, italic, mono, Hue: hue));
            return;
        }

        // 🪤 A STABLE SORT BY POSITION. Two patterns can land on the same index,
        // and which of them is drawn has to be the same on every run.
        var pos = 0;
        foreach (var h in hits.OrderBy(h => h.At))
        {
            if (h.At < pos)
            {
                continue;
            }

            if (h.At > pos)
            {
                outp.Add(new InlineSpan(text[pos..h.At], semi, italic, mono, Hue: hue));
            }

            // A link takes neither the weight nor the emphasis around it - the
            // shipped builder calls New-ReadRun with only the size and the face.
            outp.Add(new InlineSpan(h.Text, false, false, mono, true, h.Text, LinkHue));
            pos = h.At + h.Len;
        }

        if (pos < text.Length)
        {
            outp.Add(new InlineSpan(text[pos..], semi, italic, mono, Hue: hue));
        }
    }
}
