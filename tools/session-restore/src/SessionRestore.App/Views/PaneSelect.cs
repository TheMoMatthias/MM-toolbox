using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using SessionRestore.App.Services;
using SessionRestore.Core.Reading;

namespace SessionRestore.App.Views;

/// <summary>
/// Dragging a selection across the reading pane, and copying it.
/// </summary>
/// <remarks>
/// 🔴 THE FLOWDOCUMENT GAVE THIS AWAY FOR FREE AND THE PORT LOST IT. 4.4c
/// replaced <c>FlowDocumentScrollViewer</c> with a virtualizing ItemsControl -
/// which a 2,5 MB conversation needs - and an ItemsControl has no selection at
/// all. This puts it back: mouse down anchors, mouse move extends, Ctrl+C copies,
/// Ctrl+A takes the lot.
///
/// 🪤 THE SELECTION IS A MODEL RANGE AND THE HIGHLIGHT IS AN ADORNER, because
/// the panel RECYCLES rows. Anchoring to an element would lose the selection the
/// moment its row scrolled off - which is exactly the drag a person makes when
/// they want more than a page - and painting into the row would be thrown away
/// and reapplied to whatever row the container was handed next.
///
/// 🪤 AND THE OFFSETS ARE CHARACTER COUNTS, NEVER TextPointer OFFSETS. A
/// TextPointer offset counts element edges as well as characters, so a line built
/// from four Runs answers four higher than the string it draws - and the copy
/// would be cut in the wrong place on exactly the lines that carry inline code.
/// </remarks>
public sealed class PaneSelect
{
    private readonly ItemsControl _pane;
    private readonly IClip _clip;
    private PanePoint _anchor = PaneSelection.None;
    private PanePoint _focus = PaneSelection.None;

    public PaneSelect(ItemsControl pane, IClip clip)
    {
        _pane = pane ?? throw new ArgumentNullException(nameof(pane));
        _clip = clip ?? throw new ArgumentNullException(nameof(clip));
    }

    /// <summary>Where the drag started.</summary>
    public PanePoint Anchor => _anchor;

    /// <summary>Where it is now.</summary>
    public PanePoint Focus => _focus;

    /// <summary>What a copy would put on the clipboard.</summary>
    public string Selected => PaneSelection.Text(Rows, _anchor, _focus, Stamps());

    /// <summary>The document, as the pane currently has it.</summary>
    public IReadOnlyList<PaneRow>? Rows => _pane.ItemsSource as IReadOnlyList<PaneRow>;

    /// <summary>
    /// Wires the gestures onto the pane.
    /// </summary>
    /// <remarks>
    /// 🪤 PREVIEW, AND ON THE PANE RATHER THAN THE WINDOW. A bubbling handler
    /// never sees the press: the rows are Borders and TextBlocks, which do not
    /// handle the mouse, but the ScrollViewer inside the ItemsControl's template
    /// does - and the window's own PreviewKeyDown tunnel would take Ctrl+C before
    /// the pane ever saw it if this sat any higher.
    /// </remarks>
    public void Attach()
    {
        _pane.Focusable = true;
        _pane.PreviewMouseLeftButtonDown += OnDown;
        _pane.PreviewMouseMove += OnMove;
        _pane.PreviewMouseLeftButtonUp += OnUp;
        _pane.PreviewKeyDown += OnKey;
    }

    /// <summary>Forgets the selection - after the document is replaced.</summary>
    public void Clear()
    {
        _anchor = PaneSelection.None;
        _focus = PaneSelection.None;
        Redraw();
    }

    /// <summary>Selects the whole document.</summary>
    public void SelectAll()
    {
        var (a, b) = PaneSelection.All(Rows, Stamps());
        _anchor = a;
        _focus = b;
        Redraw();
    }

    /// <summary>Copies the selection, and says whether anything went.</summary>
    public bool Copy()
    {
        var text = Selected;
        return text.Length > 0 && _clip.Put(text);
    }

    // ------------------------------------------------------------- gestures

    /// <summary>What a key press in the pane asks for.</summary>
    public enum SelectAct
    {
        /// <summary>Nothing - let it go wherever it was going.</summary>
        PassOn,

        /// <summary>Copy what is selected.</summary>
        Copy,

        /// <summary>Take the whole document.</summary>
        All,
    }

    /// <summary>
    /// Which act a key press is, as a value.
    /// </summary>
    /// <remarks>
    /// 🔑 A VALUE, SO IT CAN BE CHECKED WITHOUT A KEYBOARD. Raising a real
    /// KeyEventArgs in a headless check gets the MODIFIERS of whatever is actually
    /// held down at the time, which is nothing - so the check would drive the
    /// handler and watch it decline, every run, green. The same reason
    /// <c>Core.Keys.KeyRoute</c> exists.
    /// </remarks>
    public static SelectAct KeyAct(Key key, bool ctrl) => !ctrl
        ? SelectAct.PassOn
        : key switch
        {
            Key.C => SelectAct.Copy,
            Key.A => SelectAct.All,
            _ => SelectAct.PassOn,
        };

    /// <summary>Starts a selection at a point in the pane.</summary>
    public void Begin(Point p)
    {
        _anchor = At(p);
        _focus = _anchor;
        Redraw();
    }

    /// <summary>Extends it to a point, and says whether anything moved.</summary>
    public bool Extend(Point p)
    {
        var at = At(p);
        if (!PaneSelection.IsSomewhere(at) || at == _focus)
        {
            return false;
        }

        _focus = at;
        Redraw();
        return true;
    }

    private void OnDown(object sender, MouseButtonEventArgs e)
    {
        Begin(e.GetPosition(_pane));

        // 🔑 NOT Handled. A press in the pane also focuses it and may start a
        // scroll; taking the event would break both, and a selection of zero
        // characters is what an ordinary click already means.
        _pane.Focus();
        _pane.CaptureMouse();
    }

    private void OnMove(object sender, MouseEventArgs e)
    {
        if (!_pane.IsMouseCaptured || e.LeftButton != MouseButtonState.Pressed)
        {
            return;
        }

        Extend(e.GetPosition(_pane));
    }

    private void OnUp(object sender, MouseButtonEventArgs e)
    {
        if (_pane.IsMouseCaptured)
        {
            _pane.ReleaseMouseCapture();
        }
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        switch (KeyAct(e.Key, (Keyboard.Modifiers & ModifierKeys.Control) != 0))
        {
            case SelectAct.Copy:
                // 🪤 HANDLED ONLY WHEN SOMETHING WAS COPIED, so an empty Ctrl+C in
                // the pane still reaches whatever else wants it.
                e.Handled = Copy();
                break;

            case SelectAct.All:
                SelectAll();
                e.Handled = true;
                break;

            default:
                break;
        }
    }

    // ------------------------------------------------------- where a point is

    /// <summary>
    /// The row and character offset under a point in the pane.
    /// </summary>
    public PanePoint At(Point p)
    {
        var rows = Rows;
        if (rows is null)
        {
            return PaneSelection.None;
        }

        var line = LineAt(p);
        if (line?.DataContext is not PaneRow row)
        {
            return PaneSelection.None;
        }

        var ix = IndexOf(rows, row);
        if (ix < 0)
        {
            return PaneSelection.None;
        }

        var pieces = Pieces(line, row);
        if (pieces.Count == 0)
        {
            return new PanePoint(ix, 0);
        }

        // 🔴 THE PIECE IS CHOSEN BY X AS WELL AS Y, AND THE FIRST VERSION
        // WAS NOT. A bulleted line draws its marker and its words as two
        // TextBlocks side by side on the SAME line, so picking the first piece
        // whose Y contains the point always picked the MARKER - and clicking
        // anywhere in the words of a list item put the caret at offset 1, inside
        // the bullet. Found by hit-testing the far end of a row and asking for the
        // length of what that row copies: it answered 1 of 64.
        // 🪤 WALKED FROM THE RIGHT, BECAUSE THE PIECES TOUCH. A list
        // marker's TextBlock fills its whole hang-wide column, so the first
        // character of the words sits exactly on the marker's right EDGE - inside
        // both boxes. Walking left to right answered "the end of the bullet" for
        // every click in the text of a bulleted line; walking right to left
        // answers the piece the point is actually in, and the leftmost piece is
        // still the fallback for a point left of everything.
        foreach (var (tb, at) in Enumerable.Reverse(pieces))
        {
            var local = _pane.TranslatePoint(p, tb);
            if (local.Y < 0 || local.Y > tb.ActualHeight || local.X < 0)
            {
                continue;
            }

            return new PanePoint(ix, at + Within(tb, local));
        }

        foreach (var (tb, at) in pieces)
        {
            var local = _pane.TranslatePoint(p, tb);
            if (local.Y >= 0 && local.Y <= tb.ActualHeight)
            {
                return new PanePoint(ix, at);
            }
        }

        // Nothing on this row is at that height: the end of the row.
        var last = pieces[^1];
        return new PanePoint(ix, last.At + Words(last.Text).Length);
    }

    /// <summary>The character offset inside one TextBlock, at a local point.</summary>
    private static int Within(TextBlock tb, Point local)
    {
        var tp = tb.GetPositionFromPoint(local, true);
        var acc = 0;
        foreach (var inl in tb.Inlines)
        {
            if (inl is not Run r)
            {
                continue;
            }

            if (tp is not null &&
                tp.CompareTo(r.ContentStart) >= 0 && tp.CompareTo(r.ContentEnd) <= 0)
            {
                // Inside a single Run with no nested elements, a TextPointer
                // offset IS a character count.
                return acc + Math.Clamp(r.ContentStart.GetOffsetToPosition(tp), 0, r.Text.Length);
            }

            acc += r.Text.Length;
        }

        return acc;
    }

    /// <summary>The realized row under a point, or the nearest one above it.</summary>
    private PaneLine? LineAt(Point p)
    {
        PaneLine? best = null;
        var bestY = double.NegativeInfinity;
        foreach (var line in Lines())
        {
            var top = line.TranslatePoint(new Point(0, 0), _pane).Y;
            if (top <= p.Y && top > bestY)
            {
                bestY = top;
                best = line;
            }
        }

        return best;
    }

    /// <summary>Every realized row.</summary>
    internal List<PaneLine> Lines()
    {
        var outp = new List<PaneLine>();
        Collect(_pane, outp);
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

    /// <summary>
    /// The text-bearing pieces of a row, in order, each with the offset its first
    /// character has in the row's copied text.
    /// </summary>
    /// <remarks>
    /// 🔴 A LIST MARKER IS DRAWN IN ITS OWN BOX AND COPIED WITH A SPACE AFTER IT,
    /// so the piece after it starts one further along than its own length. Get
    /// that wrong and every bulleted line copies one character out of step.
    /// </remarks>
    internal static List<(TextBlock Text, int At)> Pieces(PaneLine line, PaneRow row)
    {
        var outp = new List<(TextBlock, int)>();
        var found = new List<TextBlock>();
        Texts(line, found);
        if (found.Count == 0)
        {
            return outp;
        }

        var at = 0;
        for (var i = 0; i < found.Count; i++)
        {
            outp.Add((found[i], at));
            var len = Words(found[i]).Length;

            // The gutter marker is not part of the row's text at all; the LIST
            // marker is, and it is copied with a space after it.
            at += i == 0 && row.Marker.Length > 0 ? len + 1 : len;
        }

        return outp;
    }

    /// <summary>
    /// Every TextBlock of a row that carries its words, skipping the gutter.
    /// </summary>
    private static void Texts(PaneLine line, List<TextBlock> outp)
    {
        if (line.Child is not Grid g)
        {
            Walk(line, outp);
            return;
        }

        foreach (var kid in g.Children)
        {
            if (kid is UIElement e && Grid.GetColumn(e) != 0)
            {
                Walk(e, outp);
            }
        }
    }

    private static void Walk(DependencyObject d, List<TextBlock> outp)
    {
        if (d is TextBlock tb)
        {
            outp.Add(tb);
            return;
        }

        var n = VisualTreeHelper.GetChildrenCount(d);
        for (var i = 0; i < n; i++)
        {
            Walk(VisualTreeHelper.GetChild(d, i), outp);
        }
    }

    /// <summary>What a TextBlock says, however it was built.</summary>
    internal static string Words(TextBlock tb)
    {
        if (tb.Text.Length > 0)
        {
            return tb.Text;
        }

        var sb = new System.Text.StringBuilder();
        foreach (var inl in tb.Inlines)
        {
            if (inl is Run r)
            {
                sb.Append(r.Text);
            }
        }

        return sb.ToString();
    }

    private static int IndexOf(IReadOnlyList<PaneRow> rows, PaneRow row)
    {
        for (var i = 0; i < rows.Count; i++)
        {
            if (ReferenceEquals(rows[i], row))
            {
                return i;
            }
        }

        return -1;
    }

    /// <summary>The rendered time of day per row, for the copy.</summary>
    private string[]? Stamps()
    {
        var rows = Rows;
        if (rows is null)
        {
            return null;
        }

        var outp = new string[rows.Count];
        for (var i = 0; i < rows.Count; i++)
        {
            outp[i] = string.Equals(rows[i].Shape, RowShape.Label, StringComparison.Ordinal)
                ? PaneLine.TurnStamp(rows[i].When)
                : string.Empty;
        }

        return outp;
    }

    // ------------------------------------------------------------ the paint

    /// <summary>How far the highlight is washed out over the words it covers.</summary>
    /// <remarks>
    /// 🔴 IT HAS TO BE READ THROUGH. A selection that hides the text it
    /// selects is the one state in which a person is definitely reading it.
    /// </remarks>
    public const double Wash = 0.28;

    /// <summary>The layer inside the pane's own template.</summary>
    internal Canvas? Marks() => _pane.Template?.FindName("PaneMarks", _pane) as Canvas;

    private void Redraw()
    {
        var layer = Marks();
        if (layer is null)
        {
            return;
        }

        layer.Children.Clear();
        var brush = Palette.Brush(_pane, "Out") ?? Brushes.SteelBlue;
        var fill = brush.Clone();
        fill.Opacity = Wash;
        fill.Freeze();

        foreach (var r in Rects())
        {
            var box = new System.Windows.Shapes.Rectangle
            {
                Width = r.Width,
                Height = r.Height,
                Fill = fill,
            };
            Canvas.SetLeft(box, r.X);
            Canvas.SetTop(box, r.Y);
            layer.Children.Add(box);
        }
    }

    /// <summary>
    /// Every rectangle the selection covers, in pane coordinates.
    /// </summary>
    internal List<Rect> Rects()
    {
        var outp = new List<Rect>();
        var rows = Rows;
        if (rows is null || PaneSelection.IsEmpty(_anchor, _focus))
        {
            return outp;
        }

        foreach (var line in Lines())
        {
            if (line.DataContext is not PaneRow row)
            {
                continue;
            }

            var ix = IndexOf(rows, row);
            if (ix < 0)
            {
                continue;
            }

            var pieces = Pieces(line, row);
            foreach (var (tb, at) in pieces)
            {
                var len = Words(tb).Length;
                if (len == 0)
                {
                    continue;
                }

                var span = PaneSelection.Covered(ix, at + len, _anchor, _focus);
                if (span is null)
                {
                    continue;
                }

                var s = Math.Max(0, span.Value.Start - at);
                var e = Math.Min(len, span.Value.End - at);
                if (e <= s)
                {
                    continue;
                }

                Lines(tb, s, e, outp);
            }
        }

        return outp;
    }

    /// <summary>
    /// One span of one TextBlock, as a rectangle per rendered LINE.
    /// </summary>
    /// <remarks>
    /// 🪤 ONE RECTANGLE PER WRAPPED LINE, NOT ONE PER SPAN. A paragraph that wraps
    /// four times would otherwise be highlighted as a single box from the first
    /// character to the last, painting over the margin and everything beside it.
    /// </remarks>
    private void Lines(TextBlock tb, int start, int end, List<Rect> outp)
    {
        var from = PointerAt(tb, start);
        var to = PointerAt(tb, end);
        if (from is null || to is null)
        {
            return;
        }

        var guard = 0;
        var cur = from;
        while (cur is not null && cur.CompareTo(to) < 0 && guard++ < 400)
        {
            var nextLine = cur.GetLineStartPosition(1);
            var stop = nextLine is not null && nextLine.CompareTo(to) < 0 ? nextLine : to;

            var a = cur.GetCharacterRect(LogicalDirection.Forward);
            var b = stop.GetCharacterRect(LogicalDirection.Backward);

            // 🪤 A POSITION THAT HAS NOT BEEN RENDERED GIVES Rect.Empty, whose
            // Height is NEGATIVE - and `new Rect(...)` throws on that from inside
            // the adorner's OnRender, which is three frames away from anything
            // that looks like the cause. It happens for real: a row measured but
            // not yet arranged has no character rects at all.
            if (a.IsEmpty || a.Height <= 0)
            {
                if (ReferenceEquals(stop, to))
                {
                    break;
                }

                cur = nextLine;
                continue;
            }

            var right = Math.Abs(a.Top - b.Top) < 0.5 && !b.IsEmpty ? b.Left : tb.ActualWidth;
            var width = Math.Max(1.0, right - a.Left);

            var topLeft = tb.TranslatePoint(new Point(a.Left, a.Top), _pane);
            outp.Add(new Rect(topLeft.X, topLeft.Y, width, a.Height));

            if (ReferenceEquals(stop, to))
            {
                break;
            }

            cur = nextLine;
        }
    }

    /// <summary>The TextPointer at a character offset.</summary>
    private static TextPointer? PointerAt(TextBlock tb, int offset)
    {
        var acc = 0;
        TextPointer? last = null;
        foreach (var inl in tb.Inlines)
        {
            if (inl is not Run r)
            {
                continue;
            }

            last = r.ContentEnd;
            if (offset <= acc + r.Text.Length)
            {
                return r.ContentStart.GetPositionAtOffset(offset - acc);
            }

            acc += r.Text.Length;
        }

        return last ?? tb.ContentEnd;
    }

}
