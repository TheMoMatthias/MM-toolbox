using System.Text;

namespace SessionRestore.Core.Reading;

/// <summary>A place in the document: which row, and how far into its text.</summary>
/// <param name="Row">The index of the row in the document.</param>
/// <param name="Offset">A character offset into that row's text, never a TextPointer offset.</param>
public readonly record struct PanePoint(int Row, int Offset);

/// <summary>
/// What is selected in the reading pane, and what copying it produces.
/// </summary>
/// <remarks>
/// 🔴 THIS EXISTS BECAUSE THE PORT LOST A CAPABILITY. The shipped pane is a
/// FlowDocument with <c>IsSelectionEnabled</c>, so dragging across paragraphs and
/// pressing Ctrl+C came free. 4.4c replaced it with a virtualizing ItemsControl -
/// which a 2,5 MB conversation needs - and an ItemsControl has no selection at
/// all. Copying a path out of a transcript is a thing this pane is FOR: the link
/// work says so in as many words, and the reason a plain click must not open a
/// link is that it would break exactly this.
///
/// 🔑 CHARACTER-PRECISE WITHIN A ROW, ROW-GRANULAR ACROSS ROWS - which is not a
/// compromise, it is how text selection works. The anchor and the focus each name
/// a row and an offset; the first row is taken from its offset to the end, the
/// rows between are taken whole, and the last is taken from its start to its
/// offset.
///
/// 🪤 AND THE SELECTION IS A MODEL RANGE, NOT A VISUAL ONE. A virtualizing panel
/// throws containers away as you scroll; a selection anchored to an element would
/// vanish when its row left the screen, which is precisely the drag a person
/// makes when they select more than a page.
/// </remarks>
public static class PaneSelection
{
    /// <summary>A point that is not in the document.</summary>
    public static readonly PanePoint None = new(-1, 0);

    /// <summary>Whether a point names a row at all.</summary>
    public static bool IsSomewhere(PanePoint p) => p.Row >= 0;

    /// <summary>
    /// The two points in document order.
    /// </summary>
    /// <remarks>
    /// 🪤 A DRAG GOES BOTH WAYS. The anchor is where the mouse went down and the
    /// focus is where it is now, so upwards and leftwards drags arrive with the
    /// pair reversed - and every rule below assumes a start before an end.
    /// </remarks>
    public static (PanePoint From, PanePoint To) Order(PanePoint a, PanePoint b) =>
        a.Row < b.Row || (a.Row == b.Row && a.Offset <= b.Offset) ? (a, b) : (b, a);

    /// <summary>Whether anything at all is selected.</summary>
    public static bool IsEmpty(PanePoint a, PanePoint b) =>
        !IsSomewhere(a) || !IsSomewhere(b) || (a.Row == b.Row && a.Offset == b.Offset);

    /// <summary>
    /// Which part of one row is covered, or null when none of it is.
    /// </summary>
    /// <param name="row">The row's index in the document.</param>
    /// <param name="length">How many characters that row's text has.</param>
    /// <param name="a">One end of the selection.</param>
    /// <param name="b">The other end.</param>
    public static (int Start, int End)? Covered(int row, int length, PanePoint a, PanePoint b)
    {
        if (IsEmpty(a, b))
        {
            return null;
        }

        var (from, to) = Order(a, b);
        if (row < from.Row || row > to.Row)
        {
            return null;
        }

        var start = row == from.Row ? Math.Clamp(from.Offset, 0, length) : 0;
        var end = row == to.Row ? Math.Clamp(to.Offset, 0, length) : length;
        return end <= start ? null : (start, end);
    }

    /// <summary>
    /// The text a row contributes to a copy - what it DRAWS, not what it holds.
    /// </summary>
    /// <param name="row">The row.</param>
    /// <param name="stamp">
    /// The time of day beside a speaker label, already formatted. Passed in rather
    /// than computed, because a value function must not read the clock.
    /// </param>
    /// <remarks>
    /// 🪤 A RULE CONTRIBUTES NOTHING AND A BLANK LINE CONTRIBUTES AN EMPTY LINE.
    /// They are not the same: a divider is not part of what anybody wrote, while a
    /// paragraph break is - and a copy that swallowed the break would run two
    /// paragraphs together.
    /// </remarks>
    public static string RowText(PaneRow? row, string stamp = "")
    {
        if (row is null)
        {
            return string.Empty;
        }

        switch (row.Shape)
        {
            case RowShape.Rule:
                return string.Empty;

            case RowShape.Label:
            {
                var sb = new StringBuilder(row.Label.ToUpperInvariant());
                if (stamp.Length > 0)
                {
                    sb.Append(PaneMetrics.StampGap).Append(stamp);
                }

                if (row.Trailing.Length > 0)
                {
                    sb.Append(PaneMetrics.TrailGap).Append(row.Trailing);
                }

                return sb.ToString();
            }

            case RowShape.Block:
            {
                var sb = new StringBuilder(row.Marker2);
                if (row.Caption.Length > 0)
                {
                    if (sb.Length > 0)
                    {
                        sb.Append(PaneMetrics.BlockGap);
                    }

                    sb.Append(row.Caption);
                }

                if (row.Trailing2.Length > 0)
                {
                    sb.Append(PaneMetrics.BlockTrailGap).Append(row.Trailing2);
                }

                return sb.ToString();
            }

            case RowShape.Code:
                return row.Text;

            default:
                if (row.Blank)
                {
                    return string.Empty;
                }

                // 🔑 THE LIST MARKER COMES WITH THE LINE. On screen it sits in its
                // own box; in a copy it is the bullet the line was written with, and
                // a transcript pasted without its bullets is not the transcript.
                //
                // 🔴 AND THE WORDS COME FROM THE SPANS, NOT FROM Text. A line's
                // Text still carries the markdown that selected its emphasis -
                // `**bold**`, `` `code` `` - and the pane draws those as WEIGHT and
                // a face, with the marks stripped. Copying Text would put asterisks
                // on the clipboard that are nowhere on the screen, which is exactly
                // the thing a person pasting a path out of a transcript would not
                // forgive. Caught by comparing what a row copies with what its own
                // TextBlocks draw.
                var words = Words(row);
                return row.Marker.Length > 0 ? row.Marker + " " + words : words;
        }
    }

    /// <summary>The words of a prose row, as they are set on screen.</summary>
    private static string Words(PaneRow row)
    {
        if (row.Spans is null || row.Spans.Count == 0)
        {
            return row.Text;
        }

        var sb = new StringBuilder();
        foreach (var sp in row.Spans)
        {
            sb.Append(sp.Text);
        }

        return sb.ToString();
    }

    /// <summary>
    /// What the selection copies to.
    /// </summary>
    /// <param name="rows">The document.</param>
    /// <param name="a">One end of the selection.</param>
    /// <param name="b">The other.</param>
    /// <param name="stamps">
    /// The rendered time of day per row, or null for none. Only speaker labels use
    /// it.
    /// </param>
    /// <remarks>
    /// 🪤 THE LINE BREAKS ARE THE ROWS, and a row that contributes nothing still
    /// contributes its break when it is INSIDE the selection. Dropping the empty
    /// lines would paste a reply as one paragraph; dropping the break at the very
    /// end would leave a trailing newline on every copy.
    /// </remarks>
    public static string Text(
        IReadOnlyList<PaneRow>? rows, PanePoint a, PanePoint b, IReadOnlyList<string>? stamps = null)
    {
        if (rows is null || IsEmpty(a, b))
        {
            return string.Empty;
        }

        var (from, to) = Order(a, b);
        var lines = new List<string>();
        for (var i = Math.Max(0, from.Row); i <= Math.Min(rows.Count - 1, to.Row); i++)
        {
            var stamp = stamps is not null && i < stamps.Count ? stamps[i] : string.Empty;
            var text = RowText(rows[i], stamp);
            var span = Covered(i, text.Length, a, b);

            // A row inside the selection that carries no words still ends a line.
            lines.Add(span is null ? string.Empty : text[span.Value.Start..span.Value.End]);
        }

        // 🪤 A RULE IS NOT A BLANK LINE. It draws a divider and contributes no text
        // at all, so it must not leave an empty line behind it in the paste - but a
        // blank SOURCE line must. They are told apart by the row, never by whether
        // the text came out empty.
        var outp = new List<string>();
        for (var i = 0; i < lines.Count; i++)
        {
            var r = rows[Math.Max(0, from.Row) + i];
            if (string.Equals(r.Shape, RowShape.Rule, StringComparison.Ordinal))
            {
                continue;
            }

            outp.Add(lines[i]);
        }

        return string.Join("\n", outp);
    }

    /// <summary>The whole document, as a selection.</summary>
    public static (PanePoint A, PanePoint B) All(IReadOnlyList<PaneRow>? rows, IReadOnlyList<string>? stamps = null)
    {
        if (rows is null || rows.Count == 0)
        {
            return (None, None);
        }

        var last = rows.Count - 1;
        var stamp = stamps is not null && last < stamps.Count ? stamps[last] : string.Empty;
        return (new PanePoint(0, 0), new PanePoint(last, RowText(rows[last], stamp).Length));
    }
}
