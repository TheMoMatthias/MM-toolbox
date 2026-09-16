using System.Globalization;
using System.Text.RegularExpressions;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.Core.Reading;

/// <summary>The kinds of thing the pane puts on a line.</summary>
public static class RowShape
{
    /// <summary>The hairline above a human turn.</summary>
    public const string Rule = "rule";

    /// <summary>Who is speaking, the time of day, and what trails it.</summary>
    public const string Label = "label";

    /// <summary>One source line of what somebody wrote.</summary>
    public const string Prose = "prose";

    /// <summary>A fenced block - machine text, on the rail, never in a card.</summary>
    public const string Code = "code";

    /// <summary>A fold, a run, a notice - a block of controls rather than words.</summary>
    public const string Block = "block";
}

/// <summary>
/// One row of the reading pane.
/// </summary>
/// <remarks>
/// 🔑 A ROW IS A LINE, NOT A TURN, AND THAT IS WHAT MAKES VIRTUALIZING WORTH
/// ANYTHING. A reply of four hundred lines drawn as one item is one item the
/// panel must realize in full before it can measure the next; as four hundred
/// rows, the panel realizes the dozen on screen. The shipped FlowDocument had no
/// choice in the matter - it does not virtualize at all, which is the whole
/// reason there is a 96 KB tail budget to retire.
/// </remarks>
/// <param name="Shape">See <see cref="RowShape"/>.</param>
/// <param name="Kind">The turn kind, which decides the marker and its hue.</param>
/// <param name="Text">The words, with any list marker already taken off the front.</param>
/// <param name="Semi">A heading - weight, never size.</param>
/// <param name="Marker">The list marker, drawn in the hang: <c>""</c>, a bullet, or <c>"3."</c>.</param>
/// <param name="Mark">Whether this line draws the gutter glyph.</param>
/// <param name="Blank">An empty source line, which is a paragraph break set small.</param>
/// <param name="Ground">Whether this line is painted.</param>
/// <param name="GroundFirst">The first painted line of a turn - it carries the ground's top inset.</param>
/// <param name="GroundLast">The last painted line of a turn - it carries the bottom one.</param>
/// <param name="Label">Who is speaking.</param>
/// <param name="Trailing">What trails the speaker - the hidden-step tally.</param>
/// <param name="Caption">A fold's one line.</param>
/// <param name="Marker2">A block's marker word.</param>
/// <param name="Gutter">Which glyph a block draws.</param>
/// <param name="Open">Whether a fold starts open.</param>
/// <param name="Trailing2">A fold's own trailing note.</param>
/// <param name="When">When the turn happened.</param>
/// <param name="Turn">Which turn this came from.</param>
/// <param name="Spans">
/// The pieces a prose line is set in - bold, inline code, emphasis, a link.
/// 🪤 EMPTY ON A BLANK LINE, and that is not the same as one empty piece: a
/// blank source line is a paragraph break drawn at 0.4 of the body size, which
/// is a decision about HEIGHT and has no words in it at all.
/// </param>
public sealed record PaneRow(
    string Shape,
    string Kind,
    string Text,
    bool Semi = false,
    string Marker = "",
    bool Mark = false,
    bool Blank = false,
    bool Ground = false,
    bool GroundFirst = false,
    bool GroundLast = false,
    string Label = "",
    string Trailing = "",
    string Caption = "",
    string Marker2 = "",
    string Gutter = "",
    bool Open = false,
    string Trailing2 = "",
    DateTimeOffset? When = null,
    int Turn = -1,
    IReadOnlyList<InlineSpan>? Spans = null);

/// <summary>
/// The reading pane as a flat list of rows - what <see cref="ReadDoc"/> decided,
/// turned into the lines that carry it.
/// </summary>
/// <remarks>
/// 🔴 THE DECISIONS ARE NOT REMADE HERE. <see cref="ReadDoc.Of"/> already said
/// which turns are drawn, what each one's heading is, what a fold says and which
/// glyph goes in the gutter - and it did that against the shipped
/// <c>Add-ReadTurn</c>, case by case. This walks its answer and splits the three
/// kinds that carry PROSE into source lines, the way <c>Add-ReadProse</c> does.
/// Anything that looks like a decision in here is a bug.
///
/// 🪤 THE GUTTER MARK IS DRAWN ONCE PER TURN, on the first line that carries
/// words. A turn is one thing said; marking every paragraph of it would put a
/// column of dots down the side of a long reply and say nothing the first one
/// did not.
/// </remarks>
public static partial class PaneRows
{
    /// <summary>The three kinds whose body is prose.</summary>
    private static readonly string[] Spoke = ["you", "msgin", "said"];

    /// <summary>A markdown heading - one to six hashes and a space.</summary>
    [GeneratedRegex(@"^\s*#{1,6}\s+(.*)$", RegexOptions.CultureInvariant)]
    private static partial Regex Heading();

    /// <summary>A bulleted line.</summary>
    [GeneratedRegex(@"^\s*[-*]\s+(.*)$", RegexOptions.CultureInvariant)]
    private static partial Regex Bullet();

    /// <summary>A numbered line.</summary>
    [GeneratedRegex(@"^\s*(\d+)\.\s+(.*)$", RegexOptions.CultureInvariant)]
    private static partial Regex Numbered();

    /// <summary>The fence that opens and closes a code block.</summary>
    private const string Fence = "```";

    /// <summary>Whether a turn kind draws its body as prose.</summary>
    public static bool IsSpoken(string? kind) =>
        kind is not null && Array.IndexOf(Spoke, kind) >= 0;

    /// <summary>
    /// Every row the pane draws, in order.
    /// </summary>
    /// <param name="turns">The turns, from <see cref="ReadTurns.Of"/>.</param>
    /// <param name="entries">What the document decided, from <see cref="ReadDoc.Of"/>.</param>
    /// <param name="youGround">
    /// Whether what you said is painted. 🔑 BOTH THE INK AND THE GROUND ARE
    /// SETTINGS, INDEPENDENTLY - either can be off, including both at once - so
    /// this is asked rather than assumed.
    /// </param>
    public static List<PaneRow> Of(
        IReadOnlyList<ReadTurn>? turns, IReadOnlyList<DocEntry>? entries, bool youGround = true,
        System.Text.RegularExpressions.Regex? paths = null)
    {
        var rows = new List<PaneRow>();
        if (entries is null)
        {
            return rows;
        }

        foreach (var e in entries)
        {
            var t = turns is not null && e.Turn >= 0 && e.Turn < turns.Count ? turns[e.Turn] : null;

            if (e.Rule)
            {
                rows.Add(new PaneRow(RowShape.Rule, e.Kind, string.Empty, Turn: e.Turn));
            }

            if (e.Label.Length > 0)
            {
                rows.Add(new PaneRow(
                    RowShape.Label, e.Kind, string.Empty,
                    Label: e.Label, Trailing: e.Trailing, When: t?.When, Turn: e.Turn));
            }

            if (IsSpoken(e.Kind))
            {
                var body = string.Equals(e.Kind, "you", StringComparison.Ordinal)
                    ? Spoken.Of(t?.Body)
                    : t?.Body ?? string.Empty;
                var ground = youGround && string.Equals(e.Kind, "you", StringComparison.Ordinal);
                rows.AddRange(Body(body, e.Kind, ground, e.Turn, paths));
                continue;
            }

            rows.Add(new PaneRow(
                RowShape.Block, e.Kind, string.Empty,
                Caption: e.Caption, Marker2: e.Marker, Gutter: e.Gutter,
                Open: e.Open, Trailing2: e.Trailing2, When: t?.When, Turn: e.Turn));
        }

        return rows;
    }

    /// <summary>
    /// One turn's body, split the way <c>Add-ReadProse</c> splits it.
    /// </summary>
    /// <remarks>
    /// 🪤 THE MARKER IS KEPT SEPARATE FROM THE WORDS so its rendered width can be
    /// measured. A wrapped list line used to sit under its own bullet while prose
    /// correctly wrapped to the text column - the one block type meant to be a
    /// column was the one with a ragged left edge. Reported as *"the text also
    /// sometimes looks misaligned and not unified. It is not left bounded."*
    /// </remarks>
    public static List<PaneRow> Body(
        string? body, string kind, bool ground = false, int turn = -1,
        System.Text.RegularExpressions.Regex? paths = null)
    {
        var rows = new List<PaneRow>();
        var text = TranscriptText.RemoveAnsi(body ?? string.Empty);
        var lines = text.Replace("\r", string.Empty, StringComparison.Ordinal).Split('\n');

        // The marker is drawn ONCE, on the first line that carries words.
        var firstMark = kind.Length > 0;
        var firstGround = -1;
        var lastGround = -1;

        var i = 0;
        while (i < lines.Length)
        {
            var ln = lines[i];
            if (ln.TrimStart().StartsWith(Fence, StringComparison.Ordinal))
            {
                var code = new List<string>();
                i++;
                while (i < lines.Length && !lines[i].TrimStart().StartsWith(Fence, StringComparison.Ordinal))
                {
                    code.Add(lines[i]);
                    i++;
                }

                i++;

                // 🔑 A FENCED BLOCK IS MACHINE TEXT: mono, on the rail, and NOT
                // in a card. Nothing in this document is in a card any more.
                rows.Add(new PaneRow(
                    RowShape.Code, "result", string.Join("\n", code).TrimEnd(), Turn: turn));
                continue;
            }

            // 🪤 TWO DIFFERENT TESTS, AND THEY ARE NOT THE SAME TEST. The gutter
            // mark goes on the first line that carries WORDS - `$ln.Trim()` - so
            // a line of spaces does not take it. Whether a line is BLANK is
            // whether the builder ended up adding no run at all, which in
            // PowerShell is `if ($body)` on the body AFTER a heading or a list
            // marker has been taken off it: an empty string is false, three
            // spaces are true. A line of three spaces therefore takes no marker
            // and is NOT blank - it is a line of three spaces, at full height.
            // Conflating them set every whitespace line to 0.4 of the body size
            // and quietly closed up every deliberate gap in a reply.
            var mark = firstMark && ln.Trim().Length > 0;
            if (mark)
            {
                firstMark = false;
            }

            var bodyLine = ln;
            var semi = false;
            var marker = string.Empty;

            var h = Heading().Match(bodyLine);
            if (h.Success)
            {
                // 🪤 A HEADING IS WEIGHT NOW, NOT SIZE. `$Size + 2` was one of the
                // twelve sizes that made this pane ragged, and it is the easiest
                // one to justify and still wrong: one size means one size.
                bodyLine = h.Groups[1].Value;
                semi = true;
            }
            else
            {
                var b = Bullet().Match(bodyLine);
                if (b.Success)
                {
                    marker = PaneMetrics.Bullet;
                    bodyLine = b.Groups[1].Value;
                }
                else
                {
                    var n = Numbered().Match(bodyLine);
                    if (n.Success)
                    {
                        marker = n.Groups[1].Value + ".";
                        bodyLine = n.Groups[2].Value;
                    }
                }
            }

            var blank = bodyLine.Length == 0;

            if (ground)
            {
                if (firstGround < 0)
                {
                    firstGround = rows.Count;
                }

                lastGround = rows.Count;
            }

            rows.Add(new PaneRow(
                RowShape.Prose, kind, bodyLine,
                Semi: semi, Marker: marker, Mark: mark, Blank: blank,
                Ground: ground, Turn: turn,
                Spans: blank ? [] : Inline.Line(bodyLine, semi, false, paths)));
            i++;
        }

        // 🔴 THE GROUND'S TOP AND BOTTOM INSET GO ON THE FIRST AND LAST PAINTED
        // ROW, and which row is last is only known once there are no more of
        // them. Putting the inset on every row instead would open a gap between
        // every pair of lines - the same failure the vertical margin has, one
        // level in.
        if (firstGround >= 0)
        {
            rows[firstGround] = rows[firstGround] with { GroundFirst = true };
            rows[lastGround] = rows[lastGround] with { GroundLast = true };
        }

        return rows;
    }

    /// <summary>What a run of rows covers, for a report.</summary>
    public static string Coverage(IReadOnlyList<PaneRow> rows)
    {
        var shapes = new SortedDictionary<string, int>(StringComparer.Ordinal);
        foreach (var r in rows)
        {
            shapes[r.Shape] = shapes.TryGetValue(r.Shape, out var n) ? n + 1 : 1;
        }

        var parts = new List<string>();
        foreach (var (k, n) in shapes)
        {
            parts.Add(string.Format(CultureInfo.InvariantCulture, "{0} {1}", n, k));
        }

        return string.Format(CultureInfo.InvariantCulture,
            "{0} row(s): {1}", rows.Count, string.Join(", ", parts));
    }
}
