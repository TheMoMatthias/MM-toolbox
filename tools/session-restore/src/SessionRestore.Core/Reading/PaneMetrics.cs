using System.Globalization;

namespace SessionRestore.Core.Reading;

/// <summary>
/// The reading pane's geometry and type, as numbers.
/// </summary>
/// <remarks>
/// 🔴 THIS EXISTS BECAUSE THE ALIGNMENT RULE IS MADE OF THESE NUMBERS. The
/// shipped harness asserts that <em>every block starts on the text column</em>,
/// and the text column is <c>PagePadding.Left + GutterW</c> - two values that
/// live in two different parts of a 15,000-line script. A port that retyped
/// either of them would pass its own alignment check while sitting on a
/// different column from the window it replaces, because the check would be
/// measuring the port against the port.
///
/// 🔑 SO THE COLUMN IS DERIVED, NEVER WRITTEN DOWN TWICE. <see cref="Gutter"/>
/// is the one source for the hanging indent of a flowed paragraph AND for the
/// first Grid column of a block that is controls rather than text - which is
/// what makes prose and machine output start at the same x. The shipped file
/// says it plainly: *"two numbers that were meant to be equal would drift the
/// first time one moved."*
///
/// 🪤 AND THE GUTTER IS A TYPE MEASURE, NOT A LAYOUT CONSTANT. It holds one
/// marker glyph and the space after it, so it scales with the type; a literal
/// written back into it is how a zoom stops reaching the gutter while
/// everything around it moves.
/// </remarks>
public static class PaneMetrics
{
    // ---- the column -------------------------------------------------------

    /// <summary>The gutter at 100%. <c>$SR_GutterBase</c>.</summary>
    public const double GutterBase = 22.0;

    /// <summary>The zoom floor, in percent.</summary>
    public const int ZoomMin = 70;

    /// <summary>The zoom ceiling, in percent.</summary>
    public const int ZoomMax = 200;

    /// <summary>The zoom, clamped the way <c>Set-SRTypeScale</c> clamps it.</summary>
    public static int Zoom(int percent) => Math.Max(ZoomMin, Math.Min(ZoomMax, percent));

    /// <summary>The pane's type size at 100%, when the XAML does not say.</summary>
    public const double PaneBase = 13.0;

    /// <summary>
    /// Every size in the window, at a zoom - to the half pixel.
    /// </summary>
    /// <remarks>
    /// 🔑 THE ROUNDING LIVES HERE AND NOWHERE ELSE. <see cref="PaneMetrics"/> owns
    /// it because the gutter and the size have to move together; a second copy in
    /// the view is how a zoom would land the marker and the words on different
    /// half-pixels. Banker's rounding, because that is what <c>[Math]::Round</c>
    /// does and a 12.25 has to break the same way on both sides.
    /// </remarks>
    public static double Size(double paneBase, int zoomPercent) =>
        Math.Round(paneBase * (Zoom(zoomPercent) / 100.0) * 2.0, MidpointRounding.ToEven) / 2.0;

    /// <summary>
    /// The gutter at a zoom - one marker glyph wide, to a tenth of a pixel.
    /// </summary>
    public static double Gutter(int zoomPercent) =>
        Math.Round(GutterBase * (Zoom(zoomPercent) / 100.0), 1);

    /// <summary>
    /// 🔑 THE TEXT COLUMN ITSELF - the x every block in the document starts on.
    /// </summary>
    /// <remarks>
    /// The page padding gets you to the marker; one gutter more gets you to the
    /// words. A rail block's own Grid earns that gutter the same way a
    /// paragraph's negative TextIndent does, which is the invariant the
    /// alignment harness measures in rendered coordinates.
    /// </remarks>
    public static double TextColumn(double padLeft, double gutter) => padLeft + gutter;

    // ---- the page ---------------------------------------------------------

    /// <summary>The page padding's left, and the harness's <c>PadL</c>.</summary>
    public const double PadLeft = 44.0;

    /// <summary>Above the first block.</summary>
    public const double PadTop = 24.0;

    /// <summary>The narrowest right margin, measured or not.</summary>
    public const double PadRightMin = 44.0;

    /// <summary>Below the last block.</summary>
    public const double PadBottom = 34.0;

    /// <summary>A pane narrower than this has not been laid out yet.</summary>
    public const double TooNarrow = 200.0;

    /// <summary>What to assume when it has not.</summary>
    public const double AssumedWidth = 900.0;

    /// <summary>How many characters a measured column holds. <c>$script:ReadMeasureChars</c>.</summary>
    public const int MeasureChars = 125;

    /// <summary>
    /// The average advance of the pane face, in ems.
    /// </summary>
    /// <remarks>
    /// 🪤 A FALLBACK, NOT A CONSTANT. The shipped window measures the installed
    /// face and only keeps the answer when it is between <see cref="AdvanceMin"/>
    /// and <see cref="AdvanceMax"/>; this is Manrope's, kept for when the
    /// measurement is refused. It stayed at 0.52 when the pane went monospaced
    /// once, and the column then held 87 of the 100 characters it was asked for.
    /// </remarks>
    public const double AdvanceEm = 0.52;

    /// <summary>A measured advance below this is not believed.</summary>
    public const double AdvanceMin = 0.2;

    /// <summary>A measured advance above this is not believed.</summary>
    public const double AdvanceMax = 1.5;

    /// <summary>The reading width that does not measure the column.</summary>
    public const string WidthFull = "full";

    /// <summary>
    /// The page padding <c>Set-ReadMeasure</c> computes.
    /// </summary>
    /// <param name="available">The pane's actual width.</param>
    /// <param name="size">The type size the document is set at.</param>
    /// <param name="gutter">The gutter at this zoom.</param>
    /// <param name="readWidth">The reading width - <c>full</c> or a measured one.</param>
    /// <param name="padLeft">The left padding, overridable by the shot harness.</param>
    /// <param name="advanceEm">The face's average advance.</param>
    /// <remarks>
    /// 🪤 THE GUTTER IS INSIDE THE MEASURE, NOT OUTSIDE IT. What is being capped
    /// is the TEXT column, and the text starts one gutter in - so the target
    /// width has to carry the gutter or a measured column comes out one marker
    /// narrower than it was asked for.
    /// </remarks>
    public static (double Left, double Top, double Right, double Bottom) PagePadding(
        double available, double size, double gutter,
        string readWidth = WidthFull, double padLeft = PadLeft, double advanceEm = AdvanceEm)
    {
        if (available < TooNarrow)
        {
            available = AssumedWidth;
        }

        // 🪤 CASE-INSENSITIVE, BECAUSE `-ne` IS. The shipped test is
        // `$script:readWidth -ne 'full'`, and PowerShell's -ne ignores case - so
        // a config that says `Full` measures nothing there and would have
        // measured a column here. The config path lowercases before it gets this
        // far, which is exactly why the difference would never have shown up in
        // anything but a check that asked.
        var right = PadRightMin;
        if (!string.Equals(readWidth, WidthFull, StringComparison.OrdinalIgnoreCase))
        {
            var target = (MeasureChars * size * advanceEm) + gutter;
            right = Math.Max(PadRightMin, available - padLeft - target);
        }

        return (padLeft, PadTop, right, PadBottom);
    }

    // ---- type -------------------------------------------------------------

    /// <summary>The leading, as a multiple of the size. <c>$SR_LeadFactor</c>.</summary>
    public const double LeadFactor = 1.45;

    /// <summary>The three line spacings the settings panel offers.</summary>
    public static readonly IReadOnlyDictionary<string, double> LineSpacings =
        new Dictionary<string, double>(StringComparer.Ordinal)
        {
            ["tight"] = 1.33,
            ["normal"] = 1.45,
            ["relaxed"] = 1.62,
        };

    /// <summary>One line of prose, at a size.</summary>
    public static double Lead(double size, double factor = LeadFactor) =>
        Math.Round(size * factor, 1);

    /// <summary>
    /// The air above and below a paragraph of prose. <c>$SR_ProsePad</c>.
    /// </summary>
    /// <remarks>
    /// 🪤 ZERO, AND MEASURED TO BE RIGHT AT ZERO. A blank source line already
    /// becomes an empty Paragraph of full height, so a break measures exactly
    /// 2.00x the pitch with this off - what the terminal does. The margin was
    /// never carrying the paragraph break; the blank line was.
    /// </remarks>
    public const double ProsePad = 0.0;

    /// <summary>The bullet a <c>-</c> or <c>*</c> line is drawn with.</summary>
    public const string Bullet = "•";

    /// <summary>
    /// How far a grounded paragraph is inset from its own background.
    /// </summary>
    /// <remarks>
    /// 🔑 AND THE BOX IS PULLED LEFT BY THE SAME AMOUNT, so the words still start
    /// on the one x every other block uses. Pad without the offset and every line
    /// you wrote sits a column right of every line Claude did - which is the
    /// alignment complaint, not the fix for it.
    /// </remarks>
    public const double GroundPad = 11.0;

    /// <summary>
    /// The air inside the top and bottom of a ground, and only there.
    /// </summary>
    /// <remarks>
    /// 🔴 THE FIRST PARAGRAPH AND THE LAST, NOT EVERY PARAGRAPH. A grounded turn
    /// is one background painted across a run of Paragraphs, so putting this on
    /// each of them would open a gap between every pair of lines - the same
    /// failure the vertical margin has, one level in. The cap goes on the first
    /// block's Padding.Top and the last block's Padding.Bottom; a one-line turn
    /// gets both because it is both.
    /// </remarks>
    public const double GroundCap = 9.0;

    /// <summary>
    /// The hanging indent of a list item, as a multiple of the size.
    /// </summary>
    /// <remarks>
    /// 🔴 A CONSTANT RENDERED WIDTH, NOT A CHARACTER COUNT. A count is not a
    /// width on a proportional face: bullets hung at 107px and one-digit numbered
    /// items at 113px, so the wrapped lines lined up and the MARKERS then
    /// disagreed with each other - a `10.` item would have opened a third column.
    /// The marker is padded out to this figure instead, and the hang is taken
    /// from the figure rather than from the marker.
    ///
    /// 🪤 ARITHMETIC RATHER THAN A HOSTED BOX, on the evidence: a fixed-width
    /// element per bullet guarantees the column exactly and measures 0.85 ms
    /// EACH, which at 5.6% of blocks is ~24 ms on a 500-block rebuild.
    /// </remarks>
    public const double HangFactor = 1.9;

    /// <summary>The hanging indent at a size.</summary>
    public static double Hang(double size) => Math.Round(size * HangFactor, 1);

    /// <summary>
    /// How far a list item is indented as a block. <c>$bump</c> in Add-ReadProse.
    /// </summary>
    /// <remarks>
    /// 🔑 THE ALIGNMENT HARNESS NAMES THIS RATHER THAN CARRYING A COPY, because
    /// its allowance for a bulleted line is "one bump right of the column" - and
    /// a second copy of 18 is how the allowance would go on excusing an offset
    /// that had moved.
    /// </remarks>
    public const double ListBump = 18.0;

    // ---- the blocks -------------------------------------------------------

    /// <summary>A speaker label's air above.</summary>
    public const double LabelTop = 20.0;

    /// <summary>A speaker label's air below.</summary>
    public const double LabelBottom = 5.0;

    /// <summary>Between the label and the time of day - spaces, not a tab stop.</summary>
    public const string StampGap = "        ";

    /// <summary>Between the label and what trails it.</summary>
    public const string TrailGap = "          ";

    /// <summary>The turn rule's air above.</summary>
    public const double RuleTop = 26.0;

    /// <summary>The turn rule's air below.</summary>
    public const double RuleBottom = 0.0;

    /// <summary>The turn rule, a hairline.</summary>
    public const double RuleHeight = 1.0;

    /// <summary>A rail block's air above.</summary>
    public const double RailTop = 8.0;

    /// <summary>A rail block's air below.</summary>
    public const double RailBottom = 8.0;

    /// <summary>The rail itself - one pixel, so it is noticed and not read.</summary>
    public const double RailWidth = 1.0;

    /// <summary>How far the rail is tinted towards the ground.</summary>
    /// <remarks>0.28 was invisible in review at 100% - drawn, and the same as not drawn.</remarks>
    public const double RailTint = 0.5;

    /// <summary>The rail's left inset inside the gutter column.</summary>
    public const double RailInset = 3.0;

    /// <summary>The rail's own bottom margin.</summary>
    public const double RailFoot = 2.0;

    /// <summary>
    /// How far down the rail starts, so it clears the marker glyph.
    /// </summary>
    /// <remarks>
    /// 🪤 THE CLEARANCE IS THE MARKER'S HEIGHT, so it scales with it. A fixed 17
    /// was tuned against Caption at 100% and, at 150%, left the rail starting
    /// part-way up a marker that had grown past it.
    /// </remarks>
    public static double RailHead(double paneSize) => Math.Round(paneSize * 1.3, 1);

    // ---- the tail ---------------------------------------------------------

    /// <summary>How much of a long transcript is read by default, in bytes.</summary>
    public const int TailBase = 98304;

    // ---- the gutter markers -----------------------------------------------

    /// <summary>
    /// One dot for every kind.
    /// </summary>
    /// <remarks>
    /// 🪤 A CHAR CODE, NEVER A LITERAL, on the PowerShell side: PS 5.1 reads a
    /// BOM-less UTF-8 file as ANSI, so a literal dot reaches the screen as two
    /// mojibake characters. That constraint does not apply here - but the value
    /// has to be identical, so the oracle compares the code point.
    /// </remarks>
    public const string MarkDot = "●";

    /// <summary>
    /// The one exception, and not an exception to what the rule meant.
    /// </summary>
    /// <remarks>
    /// 🔑 THE RULING WAS ABOUT TELLING KINDS APART, which the dot and a hue do.
    /// U+23BF does not name a kind: it names a RELATIONSHIP - *"this line belongs
    /// to the one above it"*. A result is the most common thing on screen, and
    /// carrying subordination in a 22px indent alone makes you re-derive
    /// "belongs to that call" from position on every result you read.
    /// Relationships may have a shape; kinds may not.
    /// </remarks>
    public const string MarkSub = "⎿";

    /// <summary>What a kind draws in the gutter, and in which hue.</summary>
    /// <remarks>
    /// 🪤 KEYED WITHOUT REGARD TO CASE, because a PowerShell hashtable is. The
    /// kinds this is asked about are all lowercase today; the lookup is the
    /// shipped one anyway, so a kind that ever arrives capitalised gets its own
    /// marker rather than the blank one.
    /// </remarks>
    public static readonly IReadOnlyDictionary<string, (string Glyph, string Hue)> Marks =
        new Dictionary<string, (string, string)>(StringComparer.OrdinalIgnoreCase)
        {
            ["said"] = (MarkDot, "TextMid"),
            ["you"] = (MarkDot, "Out"),
            ["thinking"] = (MarkDot, "Tool"),
            ["run"] = (MarkDot, "Tool"),
            ["result"] = (MarkSub, "Tool"),
            ["system"] = (MarkDot, "Tool"),
            ["hook"] = (MarkDot, "Tool"),
            ["file"] = (MarkDot, "Tool"),
            ["asked"] = (MarkDot, "Ask"),
            ["queued"] = (MarkDot, "Out"),
            ["compact"] = (MarkDot, "Tool"),
            ["agent"] = (MarkDot, "Tool"),
            ["shell"] = (MarkDot, "Tool"),
            ["msgin"] = (MarkDot, "In"),
            ["msgout"] = (MarkDot, "In"),
        };

    /// <summary>A kind with no marker draws a space, not nothing.</summary>
    public const string NoGlyph = " ";

    /// <summary>A kind with no marker takes the quietest hue there is.</summary>
    public const string NoHue = "TextLow";

    /// <summary>The glyph for a kind. <c>Get-MarkGlyph</c>.</summary>
    public static string Glyph(string? kind) =>
        kind is not null && Marks.TryGetValue(kind, out var m) ? m.Glyph : NoGlyph;

    /// <summary>The palette key for a kind. <c>Get-MarkBrush</c>.</summary>
    public static string Hue(string? kind) =>
        kind is not null && Marks.TryGetValue(kind, out var m) ? m.Hue : NoHue;

    /// <summary>What this file covers, for the run report.</summary>
    public static string Coverage() => string.Format(CultureInfo.InvariantCulture,
        "the pane's geometry: a {0} gutter on a {1} page, {2} marks, {3} chars measured at {4} leading",
        GutterBase, PadLeft, Marks.Count, MeasureChars, LeadFactor);
}
