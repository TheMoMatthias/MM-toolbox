using System.Globalization;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Threading;
using SessionRestore.App.Views;
using SessionRestore.Core.Reading;
using SessionRestore.Core.Registry;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.App.Bench;

/// <summary>
/// EVERY BLOCK STARTS ON THE TEXT COLUMN, OR IT IS ON A NAMED LIST.
/// </summary>
/// <remarks>
/// 🔴 THE CHECK THIS REPLACES COULD NOT GO RED. The first version of it in the
/// shipped suite took the FIRST prose paragraph and the FIRST rail block and
/// compared those two - and both are on the column by construction, so it passed
/// while 14.5% of the blocks in the operator's own view had drifted. A check that
/// cannot fail is worse than no check, because it reads as coverage.
///
/// 🔑 SO THIS WALKS EVERY REALIZED ROW AND EVERY WORD-BEARING ELEMENT INSIDE IT.
/// What is allowed to sit off the column is a TABLE OF EXACT (shape, form)
/// PAIRS, not a pattern: a row shape that did not exist when the table was
/// written has no row and FAILS, which is the whole point.
///
/// 🪤 AND AN ALLOWANCE THAT MATCHES NOTHING IS ITSELF A FAILURE - but only when
/// its situation OCCURRED and it was not needed. One sample cannot tell "no
/// longer possible" from "not in this conversation today", and failing on that
/// would be a check that goes red for the wrong reason.
///
/// 🪤 IT SCROLLS, BECAUSE THE PANEL VIRTUALIZES. Measuring only what is on
/// screen at offset zero would measure the first dozen rows of every
/// conversation and call it the document. The pass walks the whole thing a page
/// at a time, and it REPORTS how many containers were ever realized at once -
/// which is the same number that says whether virtualizing is really happening.
/// </remarks>
public static class AlignChecks
{
    /// <summary>How far a rendered x may be from the column, in pixels.</summary>
    private const double Slack = 1.5;

    /// <summary>The window the pass lays out in.</summary>
    private const double W = 1480.0;

    /// <summary>The height the window is laid out at.</summary>
    private const double H = 980.0;

    /// <summary>What a row is allowed to do instead of starting on the column.</summary>
    /// <param name="Shape">The row shape, from <see cref="RowShape"/>.</param>
    /// <param name="Form">Empty, or <c>list</c>, or <c>ground</c>.</param>
    /// <param name="Off">Symbolic, so it survives a zoom: <c>-gutter</c>, <c>+bump</c>.</param>
    /// <param name="Why">Why this one is not a defect.</param>
    private sealed record Allow(string Shape, string Form, string Off, string Why);

    private static readonly Allow[] Allowed =
    [
        new(RowShape.Rule, string.Empty, "-gutter",
            "the turn rule is full-bleed from the page padding, one gutter left of all text - deliberate, it is a divider and not a line of text"),
        new(RowShape.Prose, "list", "+bump",
            "a list is indented as a block by the bump; the block indent is a reason, the ragged wrap inside it is not - and the marker box makes the wrap exact"),
    ];

    /// <summary>What one pass found.</summary>
    public sealed record Result(
        int Rows, int Measured, int Realized, int Docs,
        IReadOnlyList<string> Offences,
        IReadOnlyList<string> Live,
        IReadOnlyList<string> Dead,
        IReadOnlyList<string> Notes)
    {
        public int Failures => Offences.Count + Dead.Count + (Measured == 0 ? 1 : 0);
    }

    /// <summary>
    /// Lays the pane out over real conversations and measures every row in it.
    /// </summary>
    public static Result Run(int docs = 4)
    {
        var offences = new List<string>();
        var notes = new List<string>();
        var hit = new HashSet<string>(StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var rowsTotal = 0;
        var measured = 0;
        var realizedMax = 0;
        var read = 0;
        var blanks = 0;

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

            // 🔑 THE PADDING IS THE PAGE. PaneMetrics owns it, so the column the
            // rows are measured against is the same number the shipped document
            // sets on its FlowDocument.
            var pad = PaneMetrics.PagePadding(w.PaneDoc.ActualWidth, 13.0, PaneMetrics.Gutter(100));
            w.PaneDoc.Padding = new Thickness(pad.Left, pad.Top, pad.Right, pad.Bottom);

            foreach (var path in Transcripts(docs))
            {
                var blocks = TranscriptBlocks.Read(path, 400, 2 * 1024 * 1024);
                if (blocks.Count == 0)
                {
                    continue;
                }

                var turns = ReadTurns.Of(blocks);
                foreach (var view in (string[])[StepsView.Hidden, StepsView.Folded, StepsView.Full])
                {
                    var rows = PaneRows.Of(turns, ReadDoc.Of(turns, view));
                    if (rows.Count == 0)
                    {
                        continue;
                    }

                    read++;
                    rowsTotal += rows.Count;
                    w.PaneDoc.ItemsSource = rows;
                    Settle(w);

                    var sv = Scroller(w.PaneDoc);
                    var col = PaneMetrics.TextColumn(pad.Left, PaneMetrics.Gutter(100));

                    var pages = sv is null ? 1 : (int)Math.Ceiling(sv.ExtentHeight / Math.Max(1.0, sv.ViewportHeight));
                    for (var page = 0; page < Math.Max(1, pages); page++)
                    {
                        if (sv is not null)
                        {
                            sv.ScrollToVerticalOffset(page * sv.ViewportHeight);
                        }

                        Settle(w);

                        var realized = 0;
                        foreach (var line in Lines(w.PaneDoc))
                        {
                            realized++;
                            if (line.DataContext is not PaneRow row)
                            {
                                continue;
                            }

                            // 🪤 A BLANK LINE HAS NO WORDS, SO IT IS ON NO COLUMN -
                            // and the honest answer is a third state, not a pass and
                            // not a failure. It is a paragraph break drawn at 0.4 of
                            // the body size; measuring its box would measure the page
                            // padding and report 455 offences about nothing.
                            if (row.Blank)
                            {
                                blanks++;
                                continue;
                            }

                            var form = Form(row);
                            seen.Add(row.Shape + "|" + form);

                            var x = Left(line, w.PaneDoc, out var what);
                            if (x is null)
                            {
                                continue;
                            }

                            measured++;
                            var allow = Array.Find(Allowed, a =>
                                string.Equals(a.Shape, row.Shape, StringComparison.Ordinal) &&
                                string.Equals(a.Form, form, StringComparison.Ordinal));

                            var want = col + Offset(allow?.Off);
                            if (Math.Abs(x.Value - want) <= Slack)
                            {
                                if (allow is not null)
                                {
                                    hit.Add(allow.Shape + "|" + allow.Form);
                                }
                            }
                            else
                            {
                                var key = string.Format(CultureInfo.InvariantCulture,
                                    "{0}|{1}|x={2:N1}|expected {3:N1}", row.Shape, form, x.Value, want);
                                if (!offences.Contains(key, StringComparer.Ordinal))
                                {
                                    offences.Add(key + "   [" + what + "]   e.g. \"" + Sample(row) + "\"");
                                }
                            }

                            // 🔴 A LIST IS TWO COLUMNS, AND ONLY ONE OF THEM MOVES
                            // WITH THE HANG. The marker sits at the bump whatever
                            // width its box is, so a hang of twice the right size
                            // passed the column rule unchanged - the check could not
                            // see the one number that decides how far a bulleted line
                            // is from its own bullet. The words after the marker get
                            // their own measurement, against bump + hang.
                            if (string.Equals(form, "list", StringComparison.Ordinal) &&
                                ListWords(line, w.PaneDoc) is { } wx)
                            {
                                measured++;
                                var wantW = col + PaneMetrics.ListBump + PaneMetrics.Hang(13.0);
                                if (Math.Abs(wx - wantW) > Slack)
                                {
                                    var k2 = string.Format(CultureInfo.InvariantCulture,
                                        "{0}|list-words|x={1:N1}|expected {2:N1}", row.Shape, wx, wantW);
                                    if (!offences.Contains(k2, StringComparer.Ordinal))
                                    {
                                        offences.Add(k2 + "   e.g. \"" + Sample(row) + "\"");
                                    }
                                }
                            }
                        }

                        realizedMax = Math.Max(realizedMax, realized);
                    }
                }
            }
        }
        finally
        {
            w.Close();
        }

        var live = new List<string>();
        var dead = new List<string>();
        foreach (var a in Allowed)
        {
            var key = a.Shape + "|" + a.Form;
            if (hit.Contains(key))
            {
                live.Add($"{a.Shape} {(a.Form.Length == 0 ? "(plain)" : a.Form)} {a.Off}");
            }
            else if (seen.Contains(key))
            {
                dead.Add($"the allowance for {a.Shape} \"{a.Form}\" was never needed although that exact shape IS in the document - the offset it excuses is gone, so delete the row rather than carry it");
            }
            else
            {
                notes.Add($"allowance for {a.Shape} \"{a.Form}\" not exercised - that shape does not occur in this sample");
            }
        }

        if (blanks > 0)
        {
            notes.Add(string.Format(CultureInfo.InvariantCulture,
                "{0} blank line(s) carry no words and are on no column - a paragraph break, drawn at {1} of the body size",
                blanks, Views.PaneLine.BlankScale));
        }

        if (rowsTotal > 0 && realizedMax > 0)
        {
            notes.Add(string.Format(CultureInfo.InvariantCulture,
                "{0} row(s) across {1} document(s); at most {2} container(s) were realized at once",
                rowsTotal, read, realizedMax));
        }

        return new Result(rowsTotal, measured, realizedMax, read, offences, live, dead, notes);
    }

    /// <summary>Which named form this row is in.</summary>
    private static string Form(PaneRow row) => row.Marker.Length > 0 ? "list" : string.Empty;

    /// <summary>What the first words of this row say, for a failure message.</summary>
    private static string Sample(PaneRow row)
    {
        var t = row.Text.Length > 0 ? row.Text
            : row.Caption.Length > 0 ? row.Caption
            : row.Label.Length > 0 ? row.Label
            : "(no text - a rule or a spacer)";
        return t.Length > 60 ? t[..60] : t;
    }

    private static double Offset(string? off) => off switch
    {
        "-gutter" => -PaneMetrics.Gutter(100),
        "+gutter" => PaneMetrics.Gutter(100),
        "+bump" => PaneMetrics.ListBump,
        _ => 0.0,
    };

    /// <summary>
    /// Where this row's WORDS start, in the pane's own coordinates.
    /// </summary>
    /// <remarks>
    /// 🔴 THE FIRST WORD-BEARING ELEMENT, NOT THE ROW'S BOX. A row's container
    /// starts at the page padding whatever it holds, so measuring the container
    /// would pass for every row ever written and tell you nothing. What is being
    /// asserted is where the TEXT lands.
    ///
    /// 🪤 AND A ROW WITH NO WORDS IS MEASURED BY ITS CHILD. A rule carries no
    /// text at all, so measuring only word-bearing elements left it unmeasured -
    /// and its own allowance then read as "stopped firing".
    /// </remarks>
    private static double? Left(PaneLine line, Visual pane, out string what)
    {
        what = string.Empty;
        var el = Content(line) ?? FirstChild(line);
        if (el is null)
        {
            return null;
        }

        try
        {
            var x = el.TransformToAncestor(pane).Transform(new Point(0, 0)).X;
            var inRow = el.TransformToAncestor(line).Transform(new Point(0, 0)).X;
            var parent = VisualTreeHelper.GetParent(el);
            what = string.Format(CultureInfo.InvariantCulture,
                "{0} col {1} margin {2:N1}, {3:N1} into its row, parent {4}, rowW {5:N0}",
                el.GetType().Name, System.Windows.Controls.Grid.GetColumn(el), el.Margin.Left, inRow,
                parent?.GetType().Name ?? "none", line.ActualWidth);
            return x;
        }
        catch (InvalidOperationException)
        {
            return null;
        }
    }

    /// <summary>
    /// The first thing in a row that is CONTENT rather than the gutter.
    /// </summary>
    /// <remarks>
    /// 🔴 THE GUTTER MARKER IS SKIPPED BY POSITION, NOT BY LENGTH. The first
    /// attempt skipped any TextBlock of one character - which is what the marker
    /// is - and that also skipped a bulleted line's BULLET, so every list item
    /// was measured at the words after its marker and reported 25 px right of
    /// where the rule says a list starts. The marker belongs to column 0 of the
    /// row's own grid by construction; that is the thing to skip, and everything
    /// else is content however short it is.
    /// </remarks>
    private static FrameworkElement? Content(PaneLine line)
    {
        if (line.Child is not System.Windows.Controls.Grid g)
        {
            return FirstWords(line);
        }

        foreach (var kid in g.Children)
        {
            if (kid is not UIElement d ||
                System.Windows.Controls.Grid.GetColumn(d) == 0)
            {
                continue;
            }

            if (FirstWords(d) is { } hit)
            {
                return hit;
            }
        }

        return null;
    }

    private static FrameworkElement? FirstWords(DependencyObject d)
    {
        // 🪤 MORE THAN ONE CHARACTER, AND THE MARKER IS WHY. The gutter glyph is
        // a TextBlock too, one character wide, sitting in column 0 - so a walk
        // that accepted any TextBlock found the MARKER first and reported the row
        // at the page padding, which is exactly where a marker belongs. Two
        // versions of this test were wrong in the same direction: `Text` alone
        // missed every line built from Inlines, and `Inlines.Count > 0` caught
        // the marker, because a TextBlock with its Text set has one implicit Run.
        if (d is TextBlock tb && Words(tb).Trim().Length > 0)
        {
            return tb;
        }

        var n = VisualTreeHelper.GetChildrenCount(d);
        for (var i = 0; i < n; i++)
        {
            if (FirstWords(VisualTreeHelper.GetChild(d, i)) is { } hit)
            {
                return hit;
            }
        }

        return null;
    }

    /// <summary>
    /// Where a list item's WORDS start - the inner grid's second column.
    /// </summary>
    private static double? ListWords(PaneLine line, Visual pane)
    {
        if (line.Child is not System.Windows.Controls.Grid outer)
        {
            return null;
        }

        foreach (var kid in outer.Children)
        {
            if (kid is not UIElement k || System.Windows.Controls.Grid.GetColumn(k) == 0)
            {
                continue;
            }

            // The content of a list row is the inner grid, possibly inside the
            // Border that paints a grounded turn.
            var inner = k as System.Windows.Controls.Grid
                     ?? (k as System.Windows.Controls.Border)?.Child as System.Windows.Controls.Grid;
            if (inner is null)
            {
                continue;
            }

            foreach (var g in inner.Children)
            {
                if (g is not UIElement e || System.Windows.Controls.Grid.GetColumn(e) == 0)
                {
                    continue;
                }

                try
                {
                    return ((Visual)e).TransformToAncestor(pane).Transform(new Point(0, 0)).X;
                }
                catch (InvalidOperationException)
                {
                    return null;
                }
            }
        }

        return null;
    }

    /// <summary>What this TextBlock actually says, however it was built.</summary>
    private static string Words(TextBlock tb)
    {
        if (tb.Text.Length > 0)
        {
            return tb.Text;
        }

        var sb = new StringBuilder();
        foreach (var inl in tb.Inlines)
        {
            if (inl is System.Windows.Documents.Run r)
            {
                sb.Append(r.Text);
            }
        }

        return sb.ToString();
    }

    private static FrameworkElement? FirstChild(DependencyObject d)
    {
        var n = VisualTreeHelper.GetChildrenCount(d);
        for (var i = 0; i < n; i++)
        {
            if (VisualTreeHelper.GetChild(d, i) is FrameworkElement fe)
            {
                return fe;
            }
        }

        return null;
    }

    /// <summary>Every realized row, in document order.</summary>
    private static List<PaneLine> Lines(ItemsControl items)
    {
        var outp = new List<PaneLine>();
        Collect(items, outp);
        return outp;
    }

    private static void Collect(DependencyObject d, List<PaneLine> outp)
    {
        if (d is PaneLine p)
        {
            outp.Add(p);
            return;
        }

        var n = VisualTreeHelper.GetChildrenCount(d);
        for (var i = 0; i < n; i++)
        {
            Collect(VisualTreeHelper.GetChild(d, i), outp);
        }
    }

    private static ScrollViewer? Scroller(DependencyObject d)
    {
        if (d is ScrollViewer sv)
        {
            return sv;
        }

        var n = VisualTreeHelper.GetChildrenCount(d);
        for (var i = 0; i < n; i++)
        {
            if (Scroller(VisualTreeHelper.GetChild(d, i)) is { } hit)
            {
                return hit;
            }
        }

        return null;
    }

    /// <summary>
    /// The conversations the pass reads - the most recent, one per project.
    /// </summary>
    /// <remarks>
    /// 🪤 NOT THE BIGGEST. A harness that picks the biggest transcript picks the
    /// session running it, which is the one conversation guaranteed to be growing
    /// while it is measured.
    /// </remarks>
    private static List<string> Transcripts(int take)
    {
        var reg = SessionRegistry.Read();
        var byProject = new Dictionary<string, (DateTimeOffset When, string Path)>(StringComparer.OrdinalIgnoreCase);
        foreach (var d in reg.Directories)
        {
            if (d.Missing)
            {
                continue;
            }

            foreach (var s in d.Sessions)
            {
                var p = s.Jsonl ?? string.Empty;
                if (p.Length == 0 || !File.Exists(p))
                {
                    continue;
                }

                var when = s.LastActive ?? DateTimeOffset.MinValue;
                if (!byProject.TryGetValue(d.Path, out var have) || when > have.When)
                {
                    byProject[d.Path] = (when, p);
                }
            }
        }

        return [.. byProject.Values.OrderByDescending(v => v.When).Take(take).Select(v => v.Path)];
    }

    /// <summary>
    /// Pumps until the rows are not only realized but ARRANGED.
    /// </summary>
    /// <remarks>
    /// 🔴 ONE PUMP IS NOT ENOUGH, AND THE SYMPTOM LOOKS EXACTLY LIKE A LAYOUT
    /// DEFECT. A PaneLine builds its content when the panel hands it a row -
    /// during Measure - so after a single drain the container exists, its
    /// ContentPresenter exists, and the presenter's child does not. The walk then
    /// finds no words, falls back to the presenter, and reports every row at the
    /// page padding with a margin of zero: 1,835 identical failures that read as
    /// "the port put everything in the wrong place" and are one missing pass.
    /// </remarks>
    private static void Settle(FrameworkElement el)
    {
        for (var i = 0; i < 2; i++)
        {
            el.UpdateLayout();
            Drain();
        }
    }

    private static void Drain()
    {
        Dispatcher.CurrentDispatcher.Invoke(DispatcherPriority.ContextIdle, new Action(() => { }));
    }

    public static string Report(Result r)
    {
        ArgumentNullException.ThrowIfNull(r);
        var sb = new StringBuilder();
        var inv = CultureInfo.InvariantCulture;
        sb.AppendLine("alignment - plan item 4.4c, every block on the text column");
        sb.AppendLine(inv,
            $"  {(r.Offences.Count == 0 && r.Measured > 0 ? "ok  " : "FAIL")}  {r.Measured} measurable row position(s) in {r.Rows} row(s)");

        if (r.Measured == 0)
        {
            sb.AppendLine("        FAIL  NOTHING WAS MEASURED - this pass proves nothing");
        }

        foreach (var x in r.Offences)
        {
            sb.AppendLine(inv, $"        FAIL  {x}");
        }

        foreach (var x in r.Live)
        {
            sb.AppendLine(inv, $"  ok    allowance in use: {x}");
        }

        foreach (var x in r.Dead)
        {
            sb.AppendLine(inv, $"  FAIL  {x}");
        }

        foreach (var x in r.Notes)
        {
            sb.AppendLine(inv, $"  note  {x}");
        }

        return sb.ToString();
    }
}
