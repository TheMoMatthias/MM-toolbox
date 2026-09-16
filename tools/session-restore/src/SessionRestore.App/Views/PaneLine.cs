using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Shapes;
using SessionRestore.Core.Reading;

namespace SessionRestore.App.Views;

/// <summary>
/// One row of the reading pane, built from the <see cref="PaneRow"/> it is
/// handed.
/// </summary>
/// <remarks>
/// 🔴 THE COLUMN IS A GRID, NOT AN INDENT, AND THAT IS THE ONE STRUCTURAL
/// CHANGE IN THIS PORT. The shipped pane is a FlowDocument: prose hangs off a
/// negative <c>TextIndent</c> so a marker can sit in the space, and blocks of
/// controls get a two-column Grid whose first column is one gutter wide. Two
/// constructions, one invariant - *"a paragraph of prose and a block of machine
/// output start their text at exactly the same x"* - and the shipped source
/// says plainly that two numbers meant to be equal would drift.
///
/// 🔑 EVERY ROW HERE IS THE GRID. The marker column is
/// <see cref="PaneMetrics.Gutter"/> wide whatever the row is, so the invariant
/// holds by construction rather than by arithmetic, and the alignment harness
/// measures it in rendered coordinates exactly as before.
///
/// 🪤 REBUILT ON EVERY DataContext CHANGE, because the panel RECYCLES these.
/// A virtualizing panel hands the same container a different row as you scroll;
/// a control that built its children once would show the twelfth line of the
/// conversation forever.
/// </remarks>
public sealed class PaneLine : Border
{
    /// <summary>The blank line's height, as a fraction of the body size.</summary>
    /// <remarks>
    /// 🔑 AN EMPTY SOURCE LINE IS A PARAGRAPH BREAK, AND IT IS SET SMALL. At the
    /// full body size a blank line between two paragraphs is a whole line of
    /// nothing and the reply looks double-spaced.
    /// </remarks>
    public const double BlankScale = 0.4;

    /// <remarks>
    /// 🔴 A Border, NOT A ContentControl, AND THE DIFFERENCE IS NOT COSMETIC. A
    /// ContentControl draws its Content through a TEMPLATE, and WPF looks a theme
    /// template up by the control's own type - a derived class with no style of
    /// its own gets none, so every row laid out to the page padding with an empty
    /// presenter inside it. Measured as 1,835 identical failures that read as a
    /// layout defect in the port. A Border hosts its Child directly and needs no
    /// style to exist.
    /// </remarks>
    public PaneLine()
    {
        DataContextChanged += (_, _) => Rebuild();
        Focusable = false;
    }

    /// <summary>The pane's type size, as the window currently has it.</summary>
    private double Size => TryFindResource("SzPane") is double d && d > 0 ? d : PaneMetrics.PaneBase;

    /// <summary>
    /// The grid face, or null when there is not one.
    /// </summary>
    /// <remarks>
    /// 🪤 NULL IS NOT A FONT FAMILY, AND WPF THROWS ON IT. Assigning the result of
    /// a failed resource lookup straight to FontFamily raises *"'' is not a valid
    /// value for property 'FontFamily'"* from inside the panel's Measure - which
    /// surfaces as a layout crash three frames away from the line that caused it.
    /// A row with no grid face inherits the prose one, which is the right
    /// fallback and the visible one.
    /// </remarks>
    private FontFamily? Grid_ => TryFindResource("FontMono") as FontFamily;

    private void SetMono(TextBlock t)
    {
        if (Grid_ is { } f)
        {
            t.FontFamily = f;
        }
    }

    private void Rebuild()
    {
        if (DataContext is not PaneRow row)
        {
            Child = null;
            return;
        }

        var size = Size;
        var gutter = PaneMetrics.Gutter(100);
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(gutter) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        switch (row.Shape)
        {
            case RowShape.Rule:
                Child = Rule(row);
                return;

            case RowShape.Label:
                Child = LabelRow(row, size, gutter);
                return;

            case RowShape.Code:
                Mark(grid, PaneMetrics.MarkSub, "Tool", size, rail: true);
                Put(grid, Mono(row.Text, size));
                break;

            case RowShape.Block:
                if (row.Gutter.Length > 0)
                {
                    Mark(grid, PaneMetrics.Glyph(row.Gutter), PaneMetrics.Hue(row.Gutter), size, rail: true);
                }

                Put(grid, BlockRow(row, size));
                break;

            default:
                if (row.Mark)
                {
                    Mark(grid, PaneMetrics.Glyph(row.Kind), PaneMetrics.Hue(row.Kind), size, rail: false);
                }

                Put(grid, Prose(row, size));
                break;
        }

        Child = grid;
    }

    // ---------------------------------------------------------------- pieces

    /// <summary>
    /// The hairline above a human turn.
    /// </summary>
    /// <remarks>
    /// 🪤 FULL-BLEED FROM THE PAGE PADDING, one gutter left of all text. It is
    /// the one block in the document that is deliberately NOT on the text column,
    /// and the alignment harness carries a named allowance saying so: it is a
    /// divider, not a line of text.
    /// </remarks>
    private Rectangle Rule(PaneRow row) => new Rectangle
    {
        Height = PaneMetrics.RuleHeight,
        Fill = Palette.Brush(this, "Out") ?? Brushes.Gray,
        HorizontalAlignment = HorizontalAlignment.Stretch,
        Margin = new Thickness(0, PaneMetrics.RuleTop, 0, PaneMetrics.RuleBottom),
        Tag = row.Kind,
    };

    /// <summary>
    /// Who is speaking, when, and what is folded away above it.
    /// </summary>
    /// <remarks>
    /// 🔴 BARE: UPPERCASE AND HUE, NOTHING ELSE. This was tracked AND SemiBold
    /// AND a size step below the prose - three devices to say "label" where the
    /// pane already says it twice, in the marker and the colour. Asked which
    /// thing read as "fat", the operator answered *"the SemiBold labels and
    /// captions"*.
    /// </remarks>
    private TextBlock LabelRow(PaneRow row, double size, double gutter)
    {
        var tb = new TextBlock
        {
            Margin = new Thickness(gutter, PaneMetrics.LabelTop, 0, PaneMetrics.LabelBottom),
            FontSize = size,
            TextWrapping = TextWrapping.NoWrap,
        };

        tb.Inlines.Add(new Run(row.Label.ToUpperInvariant())
        {
            Foreground = Palette.Brush(this, PaneMetrics.Hue(row.Kind)),
        });

        var stamp = TurnStamp(row.When);
        if (stamp.Length > 0)
        {
            tb.Inlines.Add(new Run(PaneMetrics.StampGap + stamp)
            {
                Foreground = Palette.Brush(this, "TextLow"),
            });
        }

        if (row.Trailing.Length > 0)
        {
            tb.Inlines.Add(new Run(PaneMetrics.TrailGap + row.Trailing)
            {
                Foreground = Palette.Brush(this, "TextLow"),
            });
        }

        return tb;
    }

    /// <summary>
    /// One source line of what somebody wrote.
    /// </summary>
    /// <remarks>
    /// 🪤 THE LIST MARKER IS ITS OWN FIXED-WIDTH BOX. The shipped builder pads
    /// the marker out with spaces to a constant rendered width, because *"a
    /// character count is not a width on a proportional face"* - bullets hung at
    /// 107px and one-digit numbered items at 113px. A box of
    /// <see cref="PaneMetrics.Hang"/> is the same intent with none of the
    /// measuring, and it makes the wrapped lines exact rather than within half a
    /// space.
    /// </remarks>
    private FrameworkElement Prose(PaneRow row, double size)
    {
        if (row.Blank)
        {
            // 🔴 A BLANK LINE INSIDE A GROUNDED TURN IS STILL ON THE GROUND, and
            // this returned early without painting it. The bands then touched
            // between the lines of a paragraph and BROKE at every blank line, so a
            // message read as a stack of separate cards - which is the exact
            // failure the shipped builder's own note warns about, arrived at from
            // the other direction. No check saw it: a blank line carries no words,
            // so the alignment pass abstains on it by design. It was found by
            // LOOKING at --render-pane.
            return Grounded(row, new TextBlock { Text = " ", FontSize = size * BlankScale }, size);
        }

        var text = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            FontSize = size,
            LineHeight = PaneMetrics.Lead(size),
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            Foreground = Palette.Brush(this, "TextHigh"),
        };

        foreach (var sp in row.Spans ?? [])
        {
            text.Inlines.Add(Span(sp, size));
        }

        if (row.Marker.Length == 0)
        {
            return Grounded(row, text, size);
        }

        var hang = PaneMetrics.Hang(size);
        var inner = new Grid { Margin = new Thickness(PaneMetrics.ListBump, 0, 0, 0) };
        inner.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(hang) });
        inner.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        inner.Children.Add(new TextBlock
        {
            Text = row.Marker,
            FontSize = size,
            Foreground = Palette.Brush(this, "TextLow"),
        });
        Grid.SetColumn(text, 1);
        inner.Children.Add(text);
        return Grounded(row, inner, size);
    }

    /// <summary>
    /// The background a human turn is painted on, if it is painted.
    /// </summary>
    /// <remarks>
    /// 🔴 THE BANDS HAVE TO TOUCH OR IT IS NOT A GROUND. Every source line is its
    /// own row, so a background with air above and below each one draws a STRIPE
    /// PER LINE - looked at in a shot, a five-line message reads as five separate
    /// cards stacked up. The inset goes on the FIRST row's top and the LAST row's
    /// bottom, and nowhere else.
    ///
    /// 🪤 PADDING, NOT MARGIN, AND THE BOX IS PULLED LEFT BY THE SAME AMOUNT. A
    /// background paints its padding and never its margin, so expressing the
    /// inset as margin would move the left edge of the surface with it - measured
    /// as a 45.6 px bite out of the left of the panel on every list line.
    /// </remarks>
    private FrameworkElement Grounded(PaneRow row, FrameworkElement inner, double size)
    {
        if (!row.Ground)
        {
            return inner;
        }

        return new Border
        {
            Background = Palette.Brush(this, "HueOutWash") ?? Palette.Brush(this, "Raised"),
            Margin = new Thickness(-PaneMetrics.GroundPad, 0, 0, 0),
            Padding = new Thickness(
                PaneMetrics.GroundPad,
                row.GroundFirst ? PaneMetrics.GroundCap : 0,
                PaneMetrics.GroundPad,
                row.GroundLast ? PaneMetrics.GroundCap : 0),
            Child = inner,
        };
    }

    /// <summary>A fenced block - machine text, on the rail, never in a card.</summary>
    private TextBlock Mono(string text, double size)
    {
        var t = new TextBlock
        {
            Text = text,
            FontSize = size,
            TextWrapping = TextWrapping.Wrap,
            LineHeight = PaneMetrics.Lead(size),
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            Foreground = Palette.Brush(this, "TextHigh"),
            Margin = new Thickness(0, PaneMetrics.RailTop, 0, PaneMetrics.RailBottom),
        };
        SetMono(t);
        return t;
    }

    /// <summary>A fold, a run, a notice - what the document says about a step.</summary>
    private StackPanel BlockRow(PaneRow row, double size)
    {
        var line = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, PaneMetrics.RailTop, 0, PaneMetrics.RailBottom),
        };

        if (row.Marker2.Length > 0)
        {
            line.Children.Add(new TextBlock
            {
                Text = row.Marker2,
                FontSize = size,
                Foreground = Palette.Brush(this, PaneMetrics.Hue(row.Gutter)),
            });
        }

        if (row.Caption.Length > 0)
        {
            line.Children.Add(new TextBlock
            {
                Text = (row.Marker2.Length > 0 ? "  " : string.Empty) + row.Caption,
                FontSize = size,
                Foreground = Palette.Brush(this, "TextMid"),
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
        }

        if (row.Trailing2.Length > 0)
        {
            line.Children.Add(new TextBlock
            {
                Text = "   " + row.Trailing2,
                FontSize = size,
                Foreground = Palette.Brush(this, "TextLow"),
            });
        }

        return line;
    }

    /// <summary>One piece of a line, set the way the span says.</summary>
    private Run Span(InlineSpan sp, double size)
    {
        var r = new Run(sp.Text) { FontSize = size };
        if (sp.Semi)
        {
            r.FontWeight = FontWeights.SemiBold;
        }

        if (sp.Italic)
        {
            r.FontStyle = FontStyles.Italic;
        }

        if (sp.Mono && Grid_ is { } face)
        {
            r.FontFamily = face;
        }

        if (sp.Link)
        {
            r.TextDecorations = TextDecorations.Underline;
            r.Cursor = System.Windows.Input.Cursors.Hand;
            r.ToolTip = "Ctrl+click to open:  " + sp.Target;
            r.Tag = sp.Target;
        }

        var brush = Palette.Brush(this, sp.Hue);
        if (brush is not null)
        {
            r.Foreground = brush;
        }

        return r;
    }

    /// <summary>
    /// The marker column, and the rail that says what belongs to it.
    /// </summary>
    private void Mark(Grid grid, string glyph, string hue, double size, bool rail)
    {
        var brush = Palette.Brush(this, hue);
        var mk = new TextBlock
        {
            Text = glyph,
            FontSize = size,
            Foreground = brush,
            VerticalAlignment = VerticalAlignment.Top,
        };
        SetMono(mk);
        grid.Children.Add(mk);

        if (!rail)
        {
            return;
        }

        grid.Children.Add(new Rectangle
        {
            Width = PaneMetrics.RailWidth,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Stretch,
            Margin = new Thickness(
                PaneMetrics.RailInset, PaneMetrics.RailHead(size), 0, PaneMetrics.RailFoot),
            Fill = brush,
            Opacity = PaneMetrics.RailTint,
        });
    }

    private static void Put(Grid grid, FrameworkElement child)
    {
        Grid.SetColumn(child, 1);
        grid.Children.Add(child);
    }

    /// <summary>
    /// When a turn happened. <c>Format-TurnTime</c>.
    /// </summary>
    /// <remarks>
    /// 🔑 TIME OF DAY ALONE WHILE IT IS TODAY, because that is the form anyone
    /// reads without converting; the date appears only once it is needed. Nothing
    /// on this surface answered "when" before - the list says how long ago a
    /// conversation last spoke, and inside it every turn looked equally recent.
    /// </remarks>
    public static string TurnStamp(DateTimeOffset? when, DateTime? today = null)
    {
        if (when is null)
        {
            return string.Empty;
        }

        var t = when.Value.LocalDateTime;
        var day = (today ?? DateTime.Today).Date;
        if (t.Date == day)
        {
            return t.ToString("HH:mm", CultureInfo.CurrentCulture);
        }

        if (t.Date == day.AddDays(-1))
        {
            return "yesterday " + t.ToString("HH:mm", CultureInfo.CurrentCulture);
        }

        return t.ToString("d MMM HH:mm", CultureInfo.CurrentCulture);
    }
}
