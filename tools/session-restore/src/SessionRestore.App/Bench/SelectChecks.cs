using System.Globalization;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using SessionRestore.App.Services;
using SessionRestore.App.Views;
using SessionRestore.Core.Reading;
using SessionRestore.Core.Registry;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.App.Bench;

/// <summary>
/// Dragging a selection across the reading pane, over a real conversation.
/// </summary>
/// <remarks>
/// 🔴 THIS CHECKS A CAPABILITY THE PORT HAD LOST, so the thing it must be able to
/// say NO to is "the selection does not survive the panel". A virtualizing panel
/// recycles rows; a selection that was anchored to an element would be perfect in
/// every check that never scrolled and gone in the one gesture people actually
/// make.
///
/// 🪤 THE CLIPBOARD IS BEHIND A SEAM AND THIS USES THE FAKE. The clipboard is the
/// OPERATOR'S: a check that pressed the real Ctrl+C would throw away whatever he
/// had copied, on the machine he is working on.
/// </remarks>
public static class SelectChecks
{
    private const double W = 1480.0;
    private const double H = 980.0;

    public sealed record Line(bool Ok, string What, string Detail);

    public sealed record Result(IReadOnlyList<Line> Lines, int Rows)
    {
        public int Failures => Lines.Count(l => !l.Ok);
    }

    public static Result Run()
    {
        var lines = new List<Line>();
        var rowCount = 0;

        var w = new SessionsWindow
        {
            WindowStartupLocation = WindowStartupLocation.Manual,
            Left = -32000,
            Top = -32000,
            ShowInTaskbar = false,
            ShowActivated = false,
            Width = W,
            Height = H,
        };

        try
        {
            w.Show();
            Drain();

            var rows = Document();
            if (rows.Count < 40)
            {
                lines.Add(new Line(false, "a real conversation was read",
                    $"only {rows.Count} row(s) - this pass proves nothing"));
                return new Result(lines, rows.Count);
            }

            rowCount = rows.Count;
            var pad = PaneMetrics.PagePadding(w.PaneDoc.ActualWidth, 13.0, PaneMetrics.Gutter(100));
            w.PaneDoc.Padding = new Thickness(pad.Left, pad.Top, pad.Right, pad.Bottom);
            w.PaneDoc.ItemsSource = rows;

            var clip = new NoClip();
            var sel = new PaneSelect(w.PaneDoc, clip);
            sel.Attach();
            Settle(w);

            // ---- the keys, as values -------------------------------------
            lines.Add(new Line(
                PaneSelect.KeyAct(Key.C, true) == PaneSelect.SelectAct.Copy &&
                PaneSelect.KeyAct(Key.A, true) == PaneSelect.SelectAct.All &&
                PaneSelect.KeyAct(Key.C, false) == PaneSelect.SelectAct.PassOn &&
                PaneSelect.KeyAct(Key.V, true) == PaneSelect.SelectAct.PassOn,
                "Ctrl+C copies and Ctrl+A takes the lot; without Ctrl neither does",
                string.Empty));

            // ---- what a row DRAWS is what a row COPIES --------------------
            // 🔴 THE VALUE AGAINST THE CONTROL, NOT AGAINST ITSELF. Asserting
            // that the copy matches PaneSelection.RowText proves nothing: both
            // sides move together, and three separate breaks in RowText stayed
            // green under exactly that comparison. This reads the TextBlocks the
            // row actually drew - and it is what found the copy putting `**bold**`
            // on the clipboard where the screen shows weight.
            //
            // 🔑 AND IT SAYS WHICH SHAPES IT REACHED. Two of those three
            // breaks went on staying green after the comparison was right, because
            // the one view it loaded had no label carrying a trailing note and no
            // block carrying both a marker and a caption. A check that cannot say
            // what it covered cannot be trusted about what it did not.
            var seen = new SortedSet<string>(StringComparer.Ordinal);
            var trips = 0;
            var offBy = string.Empty;
            var drawn = 0;
            var fillers = 0;
            var wrong = string.Empty;

            foreach (var view in (string[])[StepsView.Folded, StepsView.Hidden])
            {
                w.PaneDoc.ItemsSource = PaneRows.Of(Turns, ReadDoc.Of(Turns, view));
                sel.Clear();
                Settle(w);

                // 🔴 IT SCROLLS, BECAUSE THE PANEL VIRTUALIZES. Comparing only
                // what is on screen compared the first 37 rows of a 294-row
                // document - and the coverage line said so: it never reached a
                // block carrying both a marker and a caption, so the break that
                // dropped the gap between them stayed green twice.
                var scroll = Scroller(w.PaneDoc);
                var pages = scroll is null
                    ? 1
                    : (int)Math.Ceiling(scroll.ExtentHeight / Math.Max(1.0, scroll.ViewportHeight));
                for (var page = 0; page < Math.Max(1, pages); page++)
                {
                    scroll?.ScrollToVerticalOffset(page * (scroll.ViewportHeight - 1));
                    Settle(w);
                    Drawn(sel, ref drawn, ref fillers, ref wrong, seen);
                    Trip(sel, w, ref trips, ref offBy);
                }

                scroll?.ScrollToVerticalOffset(0);
                Settle(w);
            }

            w.PaneDoc.ItemsSource = rows;
            sel.Clear();
            Settle(w);

            lines.Add(new Line(
                drawn > 8 && wrong.Length == 0,
                "every row copies exactly the characters it draws",
                wrong.Length > 0 ? wrong
                    : $"{drawn} row(s) compared, {fillers} blank line(s) draw a spacer and copy nothing"));

            // 🔴 A BLOCK'S MARKER AND ITS CAPTION ARE MUTUALLY EXCLUSIVE, so
            // they are asked for separately. Only `compact` and `asked` set a
            // marker word and neither carries a caption; everything else carries a
            // caption and no marker. That makes PaneMetrics.BlockGap - the gap
            // BETWEEN them - unreachable in the document as it stands, and a break
            // that removed it stayed green over 729 compared rows. It is kept, with
            // this note, rather than deleted: the shipped builder has the same
            // branch and a future arm could set both.
            // 🔑 THE ROUND TRIP IS WHAT MAKES THE OFFSETS CHECKABLE. Hit-test
            // the far end of a row and the answer has to be the length of what that
            // row copies - which is false the moment a marker is miscounted, a
            // TextPointer offset is mistaken for a character count, or the gutter
            // is treated as content. It runs inside the scrolled sweep because on
            // one screenful only three rows were short enough to try.
            lines.Add(new Line(
                trips > 12 && offBy.Length == 0,
                "the far end of a row hit-tests to the length of what it copies",
                offBy.Length > 0 ? offBy : $"{trips} row(s) round-tripped"));

            lines.Add(new Line(
                seen.Contains("list") && seen.Contains("label+trailing") &&
                seen.Contains("block+caption") && seen.Contains("code-or-plain"),
                "that comparison reached a list, a label with a trailing note and a block with a caption",
                "reached: " + string.Join(", ", seen)));

            // ---- an empty selection covers nothing -----------------------
            lines.Add(new Line(
                PaneSelection.Covered(3, 20, new PanePoint(3, 5), new PanePoint(3, 5)) is null &&
                PaneSelection.Covered(3, 20, PaneSelection.None, new PanePoint(3, 5)) is null &&
                PaneSelection.Covered(9, 20, new PanePoint(3, 0), new PanePoint(7, 4)) is null,
                "an empty selection, and a row outside one, cover nothing",
                string.Empty));

            // ---- a click selects nothing ---------------------------------
            var (first, last) = TwoRows(sel, w);
            if (first is null || last is null)
            {
                lines.Add(new Line(false, "two rows with words are on screen", "none were realized"));
                return new Result(lines, rowCount);
            }

            sel.Begin(first.Value);
            lines.Add(new Line(
                sel.Selected.Length == 0 && !sel.Copy() && clip.Wrote.Count == 0,
                "a click with no drag selects nothing, and copies nothing",
                $"selected {sel.Selected.Length} char(s), {clip.Wrote.Count} copy attempt(s)"));

            // ---- a drag across rows --------------------------------------
            var moved = sel.Extend(last.Value);
            string dragged;
            dragged = sel.Selected;
            lines.Add(new Line(
                moved && dragged.Length > 0 && dragged.Contains('\n', StringComparison.Ordinal),
                "a drag across rows selects more than one line",
                $"{dragged.Length} char(s), {dragged.Split('\n').Length} line(s)"));

            lines.Add(new Line(
                sel.Copy() && string.Equals(clip.Last, dragged, StringComparison.Ordinal),
                "Ctrl+C copies exactly what is selected",
                Show(clip.Last)));

            // 🔴 AND IT IS REALLY IN THE DOCUMENT. A copy that agreed with the
            // selection would agree just as well if both were nonsense; every
            // line of it has to be a slice of a row that exists.
            lines.Add(new Line(
                InDocument(dragged, rows),
                "every copied line is a slice of a row in the document",
                string.Empty));

            // ---- a drag that starts and ends MID-LINE --------------------
            // 🔴 EVERY OFFSET IN THE FIRST VERSION OF THIS PASS WAS ZERO,
            // because it dragged from the left edge of one row to the left edge of
            // another. Six breaks stayed green on it - including a TextPointer
            // offset used as a character count, which is wrong on every line that
            // carries inline code. A selection that never starts mid-line cannot
            // test where a line is cut.
            var (midFrom, midTo) = MidPoints(sel, w);
            if (midFrom is not null && midTo is not null)
            {
                sel.Begin(midFrom.Value);
                sel.Extend(midTo.Value);
                var mid = sel.Selected.Split('\n');
                var firstRow = RowTextAt(sel, midFrom.Value);
                var lastRow = RowTextAt(sel, midTo.Value);

                lines.Add(new Line(
                    mid.Length > 1 && firstRow.Length > 0 && lastRow.Length > 0 &&
                    mid[0].Length > 0 && mid[0].Length < firstRow.Length &&
                    firstRow.EndsWith(mid[0], StringComparison.Ordinal),
                    "a drag starting mid-line copies that line from where it started",
                    $"\"{Show(mid[0])}\" out of \"{Show(firstRow)}\""));

                lines.Add(new Line(
                    mid.Length > 1 && mid[^1].Length > 0 && mid[^1].Length < lastRow.Length &&
                    lastRow.StartsWith(mid[^1], StringComparison.Ordinal),
                    "and ends the last line where it stopped",
                    $"\"{Show(mid[^1])}\" out of \"{Show(lastRow)}\""));
            }
            else
            {
                lines.Add(new Line(false, "two long lines were found to drag between", "none were"));
            }

            // ---- a wrapped line is highlighted line by line ---------------
            var wrapped = Wrapped(sel, w);
            if (wrapped is not null)
            {
                sel.Begin(wrapped.Value.Head);
                sel.Extend(wrapped.Value.Tail);
                Settle(w);
                var boxes = sel.Rects().Count;
                lines.Add(new Line(
                    boxes > 1,
                    "a line that wraps is highlighted once per rendered line, not once per span",
                    $"{boxes} rectangle(s) over one wrapped row"));
            }
            else
            {
                lines.Add(new Line(false, "a wrapped line was found to highlight", "none was"));
            }

            sel.Begin(first.Value);
            sel.Extend(last.Value);
            dragged = sel.Selected;

            // ---- the selection survives the panel ------------------------
            var before = sel.Selected;
            var sv = Scroller(w.PaneDoc);
            if (sv is not null)
            {
                sv.ScrollToVerticalOffset(sv.ExtentHeight);
                Settle(w);
                sv.ScrollToVerticalOffset(0);
                Settle(w);
            }

            lines.Add(new Line(
                sv is not null && string.Equals(sel.Selected, before, StringComparison.Ordinal),
                "the selection survives scrolling to the end and back",
                sv is null ? "no scroll viewer was found" : $"{before.Length} char(s) before, {sel.Selected.Length} after"));

            // ---- backwards is the same selection -------------------------
            sel.Begin(last.Value);
            sel.Extend(first.Value);
            lines.Add(new Line(
                string.Equals(sel.Selected, dragged, StringComparison.Ordinal),
                "dragging upwards selects the same text as dragging down",
                Show(sel.Selected)));

            // ---- select all ----------------------------------------------
            sel.SelectAll();
            var all = sel.Selected;
            lines.Add(new Line(
                all.Length > dragged.Length && all.Split('\n').Length > 10,
                "Ctrl+A takes the whole document",
                $"{all.Length} char(s), {all.Split('\n').Length} line(s)"));

            // 🪤 A RULE DRAWS A DIVIDER AND CONTRIBUTES NO TEXT, so it must not
            // leave a blank line behind it - but a blank SOURCE line must.
            var rules = rows.Count(r => string.Equals(r.Shape, RowShape.Rule, StringComparison.Ordinal));
            var blanks = rows.Count(r => r.Blank);
            lines.Add(new Line(
                rules > 0 && blanks > 0 && all.Split('\n').Length == rows.Count - rules,
                "a rule contributes no line to the copy and a blank source line does",
                $"{rows.Count} row(s), {rules} rule(s), {blanks} blank(s), {all.Split('\n').Length} copied line(s)"));

            // ---- the highlight is really painted -------------------------
            Settle(w);
            var marks = sel.Marks();
            lines.Add(new Line(
                sel.Rects().Count > 0 && marks is not null && marks.Children.Count > 0,
                "the selection paints rectangles into the pane's own highlight layer",
                $"{sel.Rects().Count} rectangle(s), {marks?.Children.Count ?? -1} drawn"));

            // 🔴 AND THEY LAND ONLY ON THE ROW THEY BELONG TO. Counting
            // rectangles says the highlight exists; it says nothing about WHERE,
            // and a bounds error that highlighted the row after the selection
            // stayed green on a count.
            var one = OneRow(sel, w);
            if (one is not null)
            {
                sel.Begin(one.Value.Head);
                sel.Extend(one.Value.Tail);
                Settle(w);
                var box = one.Value.Bounds;
                var strays = sel.Rects().Count(r => r.Top < box.Top - 2 || r.Bottom > box.Bottom + 2);
                lines.Add(new Line(
                    sel.Rects().Count > 0 && strays == 0,
                    "selecting one row highlights that row and no other",
                    $"{sel.Rects().Count} rectangle(s), {strays} outside the row"));
            }
            else
            {
                lines.Add(new Line(false, "a single row was found to select", "none was"));
            }

            sel.Clear();
            lines.Add(new Line(
                sel.Selected.Length == 0 && sel.Rects().Count == 0 &&
                (sel.Marks()?.Children.Count ?? -1) == 0,
                "clearing the selection removes the highlight",
                string.Empty));
        }
        finally
        {
            w.Close();
        }

        return new Result(lines, rowCount);
    }

    /// <summary>
    /// Hit-tests both ends of every realized row that fits on one line.
    /// </summary>
    private static void Trip(PaneSelect sel, SessionsWindow w, ref int trips, ref string offBy)
    {
        foreach (var line in sel.Lines())
        {
            if (line.DataContext is not PaneRow row || row.Blank ||
                string.Equals(row.Shape, RowShape.Rule, StringComparison.Ordinal))
            {
                continue;
            }

            var pieces = PaneSelect.Pieces(line, row);
            if (pieces.Count == 0)
            {
                continue;
            }

            var tb = pieces[^1].Text;

            // A wrapped line's far right is not its last character.
            if (tb.ActualHeight > 2.0 * tb.FontSize || PaneSelect.Words(tb).Length == 0)
            {
                continue;
            }

            var want = PaneSelection.RowText(row, PaneLine.TurnStamp(row.When));
            var end = tb.TranslatePoint(new Point(tb.ActualWidth - 1, tb.ActualHeight / 2), w.PaneDoc);
            var head = tb.TranslatePoint(new Point(1, tb.ActualHeight / 2), w.PaneDoc);
            var got = sel.At(end).Offset;
            var zero = sel.At(head).Offset;

            trips++;
            if ((got != want.Length || zero != pieces[^1].At) && offBy.Length == 0)
            {
                offBy = $"{row.Shape}: end {got} of {want.Length}, start {zero} of {pieces[^1].At}";
            }
        }
    }

    /// <summary>The turns the document was built from, kept so a second view can be laid out.</summary>
    private static IReadOnlyList<ReadTurn> Turns { get; set; } = [];

    /// <summary>
    /// Compares what every realized row copies with what its own TextBlocks draw.
    /// </summary>
    private static void Drawn(
        PaneSelect sel, ref int drawn, ref int fillers, ref string wrong, SortedSet<string> seen)
    {
        foreach (var line in sel.Lines())
        {
            if (line.DataContext is not PaneRow row ||
                string.Equals(row.Shape, RowShape.Rule, StringComparison.Ordinal))
            {
                continue;
            }

            // A blank line draws one space and copies nothing, and that is not a
            // disagreement: the space is a layout device giving the row the height
            // a paragraph break needs. Counted, never silently skipped.
            if (row.Blank)
            {
                fillers++;
                continue;
            }

            var want = PaneSelection.RowText(row, PaneLine.TurnStamp(row.When));
            var pieces = PaneSelect.Pieces(line, row);
            var got = new StringBuilder();
            for (var i = 0; i < pieces.Count; i++)
            {
                got.Append(PaneSelect.Words(pieces[i].Text));
                if (i == 0 && row.Marker.Length > 0)
                {
                    got.Append(' ');
                }
            }

            seen.Add(
                row.Marker.Length > 0 ? "list"
                : string.Equals(row.Shape, RowShape.Label, StringComparison.Ordinal) && row.Trailing.Length > 0 ? "label+trailing"
                : string.Equals(row.Shape, RowShape.Block, StringComparison.Ordinal) && row.Marker2.Length > 0 ? "block+marker"
                : string.Equals(row.Shape, RowShape.Block, StringComparison.Ordinal) && row.Caption.Length > 0 ? "block+caption"
                : "code-or-plain");

            drawn++;
            if (!string.Equals(want, got.ToString(), StringComparison.Ordinal) && wrong.Length == 0)
            {
                wrong = $"{row.Shape}: copies \"{Show(want)}\", draws \"{Show(got.ToString())}\"";
            }
        }
    }

    /// <summary>
    /// Two points, each a few characters INTO a long line on a different row.
    /// </summary>
    private static (Point? From, Point? To) MidPoints(PaneSelect sel, SessionsWindow w)
    {
        var got = new List<Point>();
        foreach (var line in sel.Lines())
        {
            if (line.DataContext is not PaneRow row || row.Blank ||
                !string.Equals(row.Shape, RowShape.Prose, StringComparison.Ordinal))
            {
                continue;
            }

            var pieces = PaneSelect.Pieces(line, row);
            if (pieces.Count == 0)
            {
                continue;
            }

            var tb = pieces[^1].Text;
            if (PaneSelect.Words(tb).Length < 30 || tb.ActualWidth < 120)
            {
                continue;
            }

            got.Add(tb.TranslatePoint(new Point(40, tb.FontSize * 0.6), w.PaneDoc));
        }

        return got.Count < 2 ? (null, null) : (got[0], got[^1]);
    }

    /// <summary>What the row under a point copies.</summary>
    private static string RowTextAt(PaneSelect sel, Point p)
    {
        var rows = sel.Rows;
        var at = sel.At(p);
        return rows is null || at.Row < 0 || at.Row >= rows.Count
            ? string.Empty
            : PaneSelection.RowText(rows[at.Row], PaneLine.TurnStamp(rows[at.Row].When));
    }

    /// <summary>One whole row, and the bounds it occupies in the pane.</summary>
    private static (Point Head, Point Tail, Rect Bounds)? OneRow(PaneSelect sel, SessionsWindow w)
    {
        foreach (var line in sel.Lines())
        {
            if (line.DataContext is not PaneRow row || row.Blank ||
                !string.Equals(row.Shape, RowShape.Prose, StringComparison.Ordinal))
            {
                continue;
            }

            var pieces = PaneSelect.Pieces(line, row);
            if (pieces.Count == 0 || PaneSelect.Words(pieces[^1].Text).Length < 10)
            {
                continue;
            }

            var tb = pieces[^1].Text;
            var top = line.TranslatePoint(new Point(0, 0), w.PaneDoc);
            return (tb.TranslatePoint(new Point(0, tb.FontSize * 0.5), w.PaneDoc),
                    tb.TranslatePoint(new Point(tb.ActualWidth - 2, tb.ActualHeight - tb.FontSize * 0.5), w.PaneDoc),
                    new Rect(top.X, top.Y, Math.Max(1, line.ActualWidth), Math.Max(1, line.ActualHeight)));
        }

        return null;
    }

    /// <summary>The two ends of one line that wraps.</summary>
    private static (Point Head, Point Tail)? Wrapped(PaneSelect sel, SessionsWindow w)
    {
        foreach (var line in sel.Lines())
        {
            if (line.DataContext is not PaneRow row || row.Blank)
            {
                continue;
            }

            var pieces = PaneSelect.Pieces(line, row);
            if (pieces.Count == 0)
            {
                continue;
            }

            var tb = pieces[^1].Text;
            if (tb.ActualHeight < 2.2 * tb.FontSize)
            {
                continue;
            }

            return (tb.TranslatePoint(new Point(0, tb.FontSize * 0.5), w.PaneDoc),
                    tb.TranslatePoint(new Point(tb.ActualWidth - 2, tb.ActualHeight - tb.FontSize * 0.5), w.PaneDoc));
        }

        return null;
    }

    /// <summary>Two points, on two different rows that carry words.</summary>
    private static (Point? First, Point? Last) TwoRows(PaneSelect sel, SessionsWindow w)
    {
        var with = new List<Point>();
        foreach (var line in sel.Lines())
        {
            if (line.DataContext is not PaneRow row || row.Blank ||
                string.Equals(row.Shape, RowShape.Rule, StringComparison.Ordinal))
            {
                continue;
            }

            var pieces = PaneSelect.Pieces(line, row);
            if (pieces.Count == 0 || PaneSelect.Words(pieces[0].Text).Trim().Length < 4)
            {
                continue;
            }

            var tb = pieces[0].Text;
            var at = tb.TranslatePoint(new Point(2, tb.ActualHeight / 2), w.PaneDoc);
            with.Add(at);
        }

        return with.Count < 2 ? (null, null) : (with[0], with[^1]);
    }

    /// <summary>Whether every copied line really is part of a row.</summary>
    private static bool InDocument(string copied, IReadOnlyList<PaneRow> rows)
    {
        var texts = new HashSet<string>(StringComparer.Ordinal);
        foreach (var r in rows)
        {
            texts.Add(PaneSelection.RowText(r, PaneLine.TurnStamp(r.When)));
        }

        foreach (var line in copied.Split('\n'))
        {
            if (line.Length == 0)
            {
                continue;
            }

            var hit = false;
            foreach (var t in texts)
            {
                if (t.Contains(line, StringComparison.Ordinal))
                {
                    hit = true;
                    break;
                }
            }

            if (!hit)
            {
                return false;
            }
        }

        return true;
    }

    private static string Show(string s)
    {
        var one = s.Replace('\n', '¶');
        return one.Length > 70 ? one[..70] + "…" : one;
    }

    /// <summary>The most recent conversation that has rules and blank lines in it.</summary>
    private static List<PaneRow> Document()
    {
        var best = new List<PaneRow>();
        foreach (var path in KeystrokeBench.Model()
            .Where(m => !string.IsNullOrEmpty(m.S.Jsonl) && File.Exists(m.S.Jsonl))
            .OrderByDescending(m => m.S.LastActive)
            .Select(m => m.S.Jsonl)
            .Take(30))
        {
            var turns = ReadTurns.Of(TranscriptBlocks.Read(path!, 400, 2 * 1024 * 1024));
            var rows = PaneRows.Of(turns, ReadDoc.Of(turns, StepsView.Folded));
            if (rows.Count > best.Count)
            {
                best = rows;
                Turns = turns;
            }

            // 🔑 THE DOCUMENT IS CHOSEN SO THE RULES CAN BE REACHED. A
            // conversation with no notice or hook in it has no block row carrying
            // both a marker word and a caption - and the break that drops the gap
            // between them then stays green over 493 compared rows. The coverage
            // line is what said so; this is the fix it asked for.
            if (rows.Any(r => string.Equals(r.Shape, RowShape.Rule, StringComparison.Ordinal)) &&
                rows.Any(r => r.Blank) &&
                rows.Any(r => r.Marker.Length > 0) &&
                rows.Any(r => string.Equals(r.Shape, RowShape.Block, StringComparison.Ordinal) && r.Caption.Length > 0) &&
                rows.Count > 60)
            {
                Turns = turns;
                return rows;
            }
        }

        return best;
    }

    private static System.Windows.Controls.ScrollViewer? Scroller(DependencyObject d)
    {
        if (d is System.Windows.Controls.ScrollViewer sv)
        {
            return sv;
        }

        var n = System.Windows.Media.VisualTreeHelper.GetChildrenCount(d);
        for (var i = 0; i < n; i++)
        {
            if (Scroller(System.Windows.Media.VisualTreeHelper.GetChild(d, i)) is { } hit)
            {
                return hit;
            }
        }

        return null;
    }

    private static void Settle(FrameworkElement el)
    {
        for (var i = 0; i < 2; i++)
        {
            el.UpdateLayout();
            Drain();
        }
    }

    private static void Drain() =>
        Dispatcher.CurrentDispatcher.Invoke(DispatcherPriority.ContextIdle, new Action(() => { }));

    public static string Report(Result r)
    {
        ArgumentNullException.ThrowIfNull(r);
        var sb = new StringBuilder();
        var inv = CultureInfo.InvariantCulture;
        sb.AppendLine(inv, $"selection - plan item 4.4c-d, over {r.Rows} real row(s)");
        foreach (var l in r.Lines)
        {
            sb.AppendLine(inv, $"  {(l.Ok ? "ok  " : "FAIL")}  {l.What}");
            if (l.Detail.Length > 0)
            {
                sb.AppendLine(inv, $"        {l.Detail}");
            }
        }

        return sb.ToString();
    }
}
