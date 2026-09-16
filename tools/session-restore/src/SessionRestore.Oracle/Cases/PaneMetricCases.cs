using System.Globalization;
using System.Text.Json.Nodes;
using SessionRestore.Core.Reading;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 4.4c - the reading pane's geometry, compared as numbers and as
/// rendered elements.
/// </summary>
/// <remarks>
/// 🔴 THIS IS THE HALF THE ALIGNMENT HARNESS IS MADE OF. The shipped rule is
/// *"every block starts on the text column, or it is on a named list"*, and the
/// text column is <c>PagePadding.Left + GutterW</c>. Port either of those wrong
/// and the ported harness still passes - it would be measuring the port against
/// the port. So the numbers are settled against the shipped window FIRST, and
/// the harness is built on top of numbers that are already known to agree.
///
/// 🔑 AND THE ELEMENTS ARE BUILT, NOT DESCRIBED. <c>pane/blocks</c> calls the
/// real <c>New-GutterPara</c>, <c>New-RailBlock</c>, <c>Add-ReadRule</c> and
/// <c>Add-ReadLabel</c> and reads the margins, indents and widths back off the
/// objects they return. That is the lesson the breathing dot cost: a comparison
/// that proves the table is right passes identically when the control never
/// reads it. [[feedback-element-not-the-table]]
///
/// 🪤 NONE OF IT DRAWS. A Paragraph with a margin, a Grid with two columns and
/// a Rectangle with a fill are descriptions until something arranges them; the
/// oracle never shows a window.
/// </remarks>
public static class PaneMetricCases
{
    /// <summary>The kinds asked about, and three that are not kinds.</summary>
    /// <remarks>
    /// 🪤 `RUN` IS IN HERE ON PURPOSE. A PowerShell hashtable ignores case, so
    /// the shipped lookup answers for it; a port keyed Ordinal would hand back a
    /// blank marker. Nothing emits a capitalised kind today, which is exactly
    /// why only a check that asks would ever find the difference.
    /// </remarks>
    private static readonly string[] Kinds =
    [
        "said", "you", "thinking", "run", "result", "system", "hook", "file",
        "asked", "queued", "compact", "agent", "shell", "msgin", "msgout",
        "RUN", "", "not-a-kind",
    ];

    /// <summary>The zooms the ladder is walked at, two of them outside the clamp.</summary>
    private static readonly int[] Zooms = [40, 70, 100, 125, 150, 200, 500];

    /// <summary>Pane widths, either side of the "not laid out yet" line.</summary>
    private static readonly double[] Widths = [0.0, 199.0, 200.0, 900.0, 1480.0, 3000.0];

    /// <summary>Reading widths, including one that differs only in case.</summary>
    private static readonly string[] ReadWidths = ["full", "measured", "FULL"];

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Metrics(), true, "the pane's scalars and the gutter at seven zooms");
        yield return (Marks(), true, "every gutter marker's glyph and hue, and three kinds that are not kinds");
        yield return (Measure(), true, "the page padding at six widths and three reading widths");
        yield return (Blocks(), true, "the four builders that put a block on the column, read back off the objects");
        yield return (Prose(), true, "a paragraph of prose, a bullet and a numbered item, grounded and not");
    }

    // =======================================================================
    // the shared preamble - the shipped declarations, spliced and run
    // =======================================================================

    /// <summary>
    /// Everything the pane's geometry is computed from, taken from the shipped
    /// file rather than retyped.
    /// </summary>
    /// <remarks>
    /// 🪤 THE ANCHOR IS A NEWLINE PLUS THE NAME, never the name alone. These
    /// declarations are column-aligned with differing whitespace around the `=`,
    /// so an anchor of <c>'$SR_LeadFactor ='</c> matches the assignment inside
    /// the `if` above it just as well - and that one is conditional.
    ///
    /// 🔑 THE Sz* RESOURCES COME OUT OF window2.xaml. Seeding them from the real
    /// markup is what keeps this honest: the fallback table inside the shipped
    /// loop happens to hold the same seven numbers, so a stub window with no
    /// resources would agree for the wrong reason and go on agreeing after
    /// somebody changed the XAML.
    /// </remarks>
    private const string Preamble = """
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName PresentationFramework
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        function SR-LineOf([string]$anchor) {
            $i = $winSrc.IndexOf("`n" + $anchor)
            if ($i -lt 0) { throw "could not find a line starting $anchor" }
            $i++
            $j = $winSrc.IndexOf("`n", $i)
            return $winSrc.Substring($i, $j - $i)
        }
        function SR-BlockOf([string]$anchor) {
            $i = $winSrc.IndexOf("`n" + $anchor)
            if ($i -lt 0) { throw "could not find a block starting $anchor" }
            $i++
            $j = $winSrc.IndexOf("`n}", $i)
            if ($j -lt 0) { throw "unterminated block at $anchor" }
            return $winSrc.Substring($i, $j - $i + 2)
        }
        function SR-Func([string]$name) {
            $a = $winSrc.IndexOf("function $name")
            if ($a -lt 0) { throw "could not find $name in sessions-window.ps1" }
            $b = $winSrc.IndexOf("`n}", $a)
            if ($b -lt 0) { throw "unterminated $name" }
            return $winSrc.Substring($a, $b - $a + 2)
        }

        Invoke-Expression (SR-LineOf '$SR_GutterBase =')
        Invoke-Expression (SR-LineOf '$SR_LineSpacings =')
        Invoke-Expression (SR-LineOf '$SR_LeadFactor =')
        Invoke-Expression (SR-LineOf '$SR_ProsePad =')
        Invoke-Expression (SR-LineOf '$script:ReadMeasureChars =')
        Invoke-Expression (SR-LineOf '$script:PaneAdvanceEm =')
        Invoke-Expression (SR-LineOf '$script:TailBase =')

        # The window is a bare Grid - it has a ResourceDictionary and nothing
        # else, which is all Set-SRTypeScale reads and writes.
        $window = [System.Windows.Controls.Grid]::new()
        $xamlSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\window2.xaml'))
        foreach ($m in [regex]::Matches($xamlSrc, '<sys:Double x:Key="Sz([A-Za-z]+)">([0-9.]+)</sys:Double>')) {
            $window.Resources[('Sz' + $m.Groups[1].Value)] = [double]$m.Groups[2].Value
        }
        Invoke-Expression (SR-BlockOf '$script:TypeBase = @{}')
        Invoke-Expression (SR-LineOf '$script:Type = @{}')
        Invoke-Expression (SR-LineOf '$script:Zoom = 100')
        Invoke-Expression (SR-Func 'Set-SRTypeScale')
        """;

    // =======================================================================
    // pane/metrics
    // =======================================================================

    private static OracleCase Metrics() => new(
        "pane/metrics",
        "the gutter, the leading, the measure and the tail - and the gutter at every zoom",
        Preamble + """

        $rows = @()
        foreach ($z in @(40, 70, 100, 125, 150, 200, 500)) {
            Set-SRTypeScale -Percent $z
            $rows += [ordered]@{
                ask    = $z
                zoom   = [int]$script:Zoom
                gutter = [double]$script:GutterW
                size   = [double]$script:PaneSize
                lead   = [double]$script:readLead
            }
        }
        (@{
            gutterBase = [double]$SR_GutterBase
            leadFactor = [double]$SR_LeadFactor
            spacings   = $SR_LineSpacings
            prosePad   = [double]$SR_ProsePad
            chars      = [int]$script:ReadMeasureChars
            advance    = [double]$script:PaneAdvanceEm
            tail       = [int]$script:TailBase
            zooms      = @($rows)
        } | ConvertTo-Json -Compress -Depth 6)
        """,
        _ =>
        {
            var zooms = new JsonArray();
            foreach (var z in Zooms)
            {
                zooms.Add(new JsonObject
                {
                    ["ask"] = z,
                    ["zoom"] = PaneMetrics.Zoom(z),
                    ["gutter"] = PaneMetrics.Gutter(z),
                    ["size"] = PaneMetrics.Size(PaneMetrics.PaneBase, z),
                    ["lead"] = PaneMetrics.Lead(PaneMetrics.Size(PaneMetrics.PaneBase, z)),
                });
            }

            var spacings = new JsonObject();
            foreach (var (k, v) in PaneMetrics.LineSpacings)
            {
                spacings[k] = v;
            }

            return new JsonObject
            {
                ["gutterBase"] = PaneMetrics.GutterBase,
                ["leadFactor"] = PaneMetrics.LeadFactor,
                ["spacings"] = spacings,
                ["prosePad"] = PaneMetrics.ProsePad,
                ["chars"] = PaneMetrics.MeasureChars,
                ["advance"] = PaneMetrics.AdvanceEm,
                ["tail"] = PaneMetrics.TailBase,
                ["zooms"] = zooms,
            }.ToJsonString();
        });

    // =======================================================================
    // pane/marks
    // =======================================================================

    private static OracleCase Marks() => new(
        "pane/marks",
        "Get-MarkGlyph and Get-MarkBrush, by code point and by palette key",
        Preamble + """

        # 🪤 THE TWO CODES BEFORE THE TABLE THAT USES THEM. Running the $SR_Marks
        # literal first bound every G to $null, [char]$null is [char]0, and the
        # whole table came back as fifteen NUL glyphs - a shape that looks like a
        # port defect and is a splice order.
        Invoke-Expression (SR-LineOf '$SR_MarkDot =')
        Invoke-Expression (SR-LineOf '$SR_MarkSub =')
        Invoke-Expression (SR-BlockOf '$SR_Marks = @{')
        Invoke-Expression (SR-Func 'Get-MarkGlyph')
        Invoke-Expression (SR-Func 'Get-MarkBrush')

        # 🔑 THE PALETTE IS REAL BRUSHES WITH TRACEABLE VALUES. Get-MarkBrush
        # hands back a Brush, and what is being compared is WHICH key it came
        # from - so each key gets a distinct red channel and the answer is read
        # back off the object rather than out of the table it was built from.
        $hueNames = @('Out', 'In', 'TextMid', 'TextHigh', 'TextLow', 'TextDim', 'Tool', 'Ask')
        $Pal = @{}
        $byBrush = @{}
        $ci = 1
        foreach ($h in $hueNames) {
            $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb($ci, 0, 0))
            $Pal[$h] = $b
            $byBrush[$ci] = $h
            $ci++
        }
        function SR-HueOf($brush) {
            if (-not $brush) { return '' }
            $k = [int]$brush.Color.R
            if ($byBrush.ContainsKey($k)) { return [string]$byBrush[$k] }
            return '?'
        }

        $rows = @()
        foreach ($k in @(KINDS)) {
            $g = Get-MarkGlyph $k
            $rows += [ordered]@{
                kind  = $k
                glyph = $(if ("$g".Length -gt 0) { [int][char]"$g"[0] } else { -1 })
                hue   = (SR-HueOf (Get-MarkBrush $k))
            }
        }
        (@{ dot = [int]$SR_MarkDot; sub = [int]$SR_MarkSub; marks = @($rows) } | ConvertTo-Json -Compress -Depth 5)
        """.Replace("KINDS", string.Join(", ", Kinds.Select(PsText.Literal)), StringComparison.Ordinal),
        _ =>
        {
            var rows = new JsonArray();
            foreach (var k in Kinds)
            {
                var g = PaneMetrics.Glyph(k);
                rows.Add(new JsonObject
                {
                    ["kind"] = k,
                    ["glyph"] = g.Length > 0 ? (int)g[0] : -1,
                    ["hue"] = PaneMetrics.Hue(k),
                });
            }

            return new JsonObject
            {
                ["dot"] = (int)PaneMetrics.MarkDot[0],
                ["sub"] = (int)PaneMetrics.MarkSub[0],
                ["marks"] = rows,
            }.ToJsonString();
        });

    // =======================================================================
    // pane/measure
    // =======================================================================

    private static OracleCase Measure() => new(
        "pane/measure",
        "Set-ReadMeasure's page padding, at six pane widths and three reading widths",
        Preamble + """

        Invoke-Expression (SR-Func 'Set-ReadMeasure')

        # 🔴 TWO ZOOMS, BECAUSE ONE OF THEM CANNOT SEE HALF THE FUNCTION. At 100%
        # the measured target is 867 px and the assumed pane is 900, so
        # `available - 44 - target` is negative at every width below about 1400
        # and the 44 px floor answers instead - which makes the "not laid out
        # yet" branch and the width it assumes both unobservable. At 70% the
        # target is 600 and the arithmetic reaches the surface. Two breaks
        # stayed green until this was added, and neither was wrong about the
        # code: the case could not tell.
        # 🪤 A PSCustomObject, BECAUSE ActualWidth IS READ-ONLY ON A REAL CONTROL
        # and the whole question is what happens at six different widths. The
        # shipped function reads it through a try/catch, so it never learns the
        # difference.
        $ui = @{ PaneDoc = [PSCustomObject]@{ ActualWidth = 0.0 } }

        $rows = @()
        foreach ($z in @(100, 70)) {
            Set-SRTypeScale -Percent $z
            foreach ($w in @(WIDTHLIST)) {
                foreach ($rw in @(RWLIST)) {
                    $ui.PaneDoc.ActualWidth = [double]$w
                    $script:readWidth = $rw
                    $d = [System.Windows.Documents.FlowDocument]::new()
                    Set-ReadMeasure -Doc $d -PadL 44
                    $rows += [ordered]@{
                        z = $z; w = [double]$w; rw = $rw
                        l = [double]$d.PagePadding.Left
                        t = [double]$d.PagePadding.Top
                        r = [double][Math]::Round($d.PagePadding.Right, 4)
                        b = [double]$d.PagePadding.Bottom
                        size = [double]$script:readSize
                        lead = [double]$script:readLead
                        # 🔑 THE ALIGNMENT HARNESS'S OWN LINE, verbatim: the text
                        # column is the page padding plus one gutter. Every block
                        # in the document is asserted against this number, so a
                        # port that computed it differently would pass its own
                        # harness and sit on a different column from the window
                        # it replaces.
                        col = [double]($d.PagePadding.Left + $script:GutterW)
                    }
                }
            }
        }
        Set-SRTypeScale -Percent 100
        # 🔴 BOTH OVERRIDES ARE ASKED FOR AND ONLY ONE OF THEM HAPPENS. -PadL
        # moves the page; -Size does nothing at all, and the shipped comment
        # beside it says it is "the one legitimate override (the shot harness
        # renders at a fixed size so a picture is comparable between runs)".
        # PowerShell variable names ignore case, so the function's own first line
        # - $size = $script:PaneSize - overwrites the $Size PARAMETER before the
        # `if ($Size -gt 0)` below it ever looks at it. The test then reads 13,
        # passes, and assigns 13 over 13.
        $ui.PaneDoc.ActualWidth = 1480.0
        $script:readWidth = 'measured'
        $d2 = [System.Windows.Documents.FlowDocument]::new()
        Set-ReadMeasure -Doc $d2 -Size 16 -PadL 60
        $over = [ordered]@{
            l = [double]$d2.PagePadding.Left
            r = [double][Math]::Round($d2.PagePadding.Right, 4)
            size = [double]$script:readSize
            lead = [double]$script:readLead
        }
        (@{ rows = @($rows); over = $over } | ConvertTo-Json -Compress -Depth 5)
        """
            .Replace("WIDTHLIST", string.Join(", ", Widths.Select(w => w.ToString("0.0", CultureInfo.InvariantCulture))), StringComparison.Ordinal)
            .Replace("RWLIST", string.Join(", ", ReadWidths.Select(PsText.Literal)), StringComparison.Ordinal),
        _ =>
        {
            var size = PaneMetrics.Size(PaneMetrics.PaneBase, 100);
            var gutter = PaneMetrics.Gutter(100);
            var rows = new JsonArray();
            foreach (var z in (int[])[100, 70])
            {
                var sz = PaneMetrics.Size(PaneMetrics.PaneBase, z);
                var gz = PaneMetrics.Gutter(z);
                foreach (var w in Widths)
                {
                    foreach (var rw in ReadWidths)
                    {
                        var p = PaneMetrics.PagePadding(w, sz, gz, rw);
                        rows.Add(new JsonObject
                        {
                            ["z"] = z,
                            ["w"] = w,
                            ["rw"] = rw,
                            ["l"] = p.Left,
                            ["t"] = p.Top,
                            ["r"] = Math.Round(p.Right, 4),
                            ["b"] = p.Bottom,
                            ["size"] = sz,
                            ["lead"] = PaneMetrics.Lead(sz),
                            ["col"] = PaneMetrics.TextColumn(p.Left, gz),
                        });
                    }
                }
            }

            // 🔴 SIXTEEN IS ASKED FOR AND THIRTEEN IS WHAT HAPPENS - see the note
            // on the PowerShell side. This is the shipped behaviour, so it is what
            // the oracle asserts; the day somebody repairs $size/$Size this case
            // goes red and the comment explains why. The port does not carry the
            // collision, because a C# parameter cannot be shadowed by its own
            // local - it just never gets asked for a size other than the pane's.
            var o = PaneMetrics.PagePadding(1480.0, size, gutter, "measured", 60.0);
            return new JsonObject
            {
                ["rows"] = rows,
                ["over"] = new JsonObject
                {
                    ["l"] = o.Left,
                    ["r"] = Math.Round(o.Right, 4),
                    ["size"] = size,
                    ["lead"] = PaneMetrics.Lead(size),
                },
            }.ToJsonString();
        });

    // =======================================================================
    // pane/blocks
    // =======================================================================

    private static OracleCase Blocks() => new(
        "pane/blocks",
        "the four builders that put a block on the column, read back off what they return",
        Preamble + """

        # 🪤 THE TWO CODES BEFORE THE TABLE THAT USES THEM. Running the $SR_Marks
        # literal first bound every G to $null, [char]$null is [char]0, and the
        # whole table came back as fifteen NUL glyphs - a shape that looks like a
        # port defect and is a splice order.
        Invoke-Expression (SR-LineOf '$SR_MarkDot =')
        Invoke-Expression (SR-LineOf '$SR_MarkSub =')
        Invoke-Expression (SR-BlockOf '$SR_Marks = @{')
        foreach ($fn in @('Get-MarkGlyph', 'Get-MarkBrush', 'New-GutterMark', 'New-GutterPara',
                          'New-RailBlock', 'New-ReadRun', 'Format-TurnTime', 'Add-ReadRule', 'Add-ReadLabel')) {
            Invoke-Expression (SR-Func $fn)
        }

        $hueNames = @('Out', 'In', 'TextMid', 'TextHigh', 'TextLow', 'TextDim', 'Tool', 'Ask')
        $Pal = @{}
        $byBrush = @{}
        $ci = 1
        foreach ($h in $hueNames) {
            $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb($ci, 0, 0))
            $Pal[$h] = $b
            $byBrush[$ci] = $h
            $ci++
        }
        function SR-HueOf($brush) {
            if (-not $brush) { return '' }
            $k = [int]$brush.Color.R
            if ($byBrush.ContainsKey($k)) { return [string]$byBrush[$k] }
            return '?'
        }

        Set-SRTypeScale -Percent 100
        $script:PaneFace  = [System.Windows.Media.FontFamily]::new('Cascadia Mono')
        $script:ProseFace = [System.Windows.Media.FontFamily]::new('Segoe UI')
        $FW_Semi   = [System.Windows.FontWeights]::SemiBold
        $FW_Normal = [System.Windows.FontWeights]::Normal
        # 🔑 A SINK, NOT A STUB. New-SRTint's ANSWER is a brush nobody can read a
        # number off; what is being compared is the factor it was HANDED, which
        # is the constant that decides whether the rail is seen at all.
        $script:tintAlpha = -1.0
        function New-SRTint { param($Brush, [double]$Alpha) $script:tintAlpha = $Alpha; return $Brush }

        # --- a flowed paragraph that hangs off the gutter ---------------------
        $gp = New-GutterPara -Kind 'run' -Top 3 -Bottom 4
        $iuc = @($gp.Inlines)[0]
        $mk  = $iuc.Child
        $gpn = New-GutterPara -Kind 'run' -NoMark
        $gpi = New-GutterPara -Kind 'result' -Indent 12

        # --- the same column, for a block that is controls --------------------
        $kid = [System.Windows.Controls.TextBlock]::new()
        $kid.Text = 'child'
        $rb = New-RailBlock -Child $kid -Kind 'result' -Rail
        $g = $rb.Child
        $rail = $null; $mk2 = $null
        foreach ($c in $g.Children) {
            if ($c -is [System.Windows.Shapes.Rectangle]) { $rail = $c }
            elseif ($c -is [System.Windows.Controls.TextBlock] -and -not $mk2) { $mk2 = $c }
        }

        # --- the rule and the speaker label -----------------------------------
        $doc = [System.Windows.Documents.FlowDocument]::new()
        Add-ReadRule -Doc $doc -Brush $Pal.TextLow
        $rule = @($doc.Blocks)[0]
        # Today at 09:05, computed on this side too, so the stamp is a format and
        # not a clock.
        Add-ReadLabel -Doc $doc -Text 'you said' -Brush $Pal.Out -Trailing '3 steps hidden' `
            -TrailBrush $Pal.TextLow -When ((Get-Date).Date.AddHours(9).AddMinutes(5))
        $lab = @($doc.Blocks)[1]
        $runs = @(@($lab.Inlines) | ForEach-Object { "$($_.Text)" })
        $hues = @(@($lab.Inlines) | ForEach-Object { (SR-HueOf $_.Foreground) })

        (@{
            para = [ordered]@{
                l = [double]$gp.Margin.Left; t = [double]$gp.Margin.Top
                r = [double]$gp.Margin.Right; b = [double]$gp.Margin.Bottom
                indent = [double]$gp.TextIndent; inlines = [int]$gp.Inlines.Count
                glyph = [int][char]"$($mk.Text)"[0]; width = [double]$mk.Width
                size = [double]$mk.FontSize; align = "$($mk.TextAlignment)"
                hue = (SR-HueOf $mk.Foreground); baseline = "$($iuc.BaselineAlignment)"
            }
            noMark = [ordered]@{
                l = [double]$gpn.Margin.Left; indent = [double]$gpn.TextIndent
                inlines = [int]$gpn.Inlines.Count
            }
            indented = [ordered]@{
                l = [double]$gpi.Margin.Left; indent = [double]$gpi.TextIndent
                glyph = [int][char]"$(@($gpi.Inlines)[0].Child.Text)"[0]
            }
            rail = [ordered]@{
                l = [double]$rb.Margin.Left; t = [double]$rb.Margin.Top
                r = [double]$rb.Margin.Right; b = [double]$rb.Margin.Bottom
                col0 = [double]$g.ColumnDefinitions[0].Width.Value
                col1Star = [bool]$g.ColumnDefinitions[1].Width.IsStar
                childCol = [int][System.Windows.Controls.Grid]::GetColumn($kid)
                glyph = [int][char]"$($mk2.Text)"[0]; hue = (SR-HueOf $mk2.Foreground)
                size = [double]$mk2.FontSize; valign = "$($mk2.VerticalAlignment)"
                railW = [double]$rail.Width
                railL = [double]$rail.Margin.Left; railT = [double]$rail.Margin.Top
                railR = [double]$rail.Margin.Right; railB = [double]$rail.Margin.Bottom
                railH = "$($rail.HorizontalAlignment)"; railV = "$($rail.VerticalAlignment)"
                tint = [double]$script:tintAlpha
            }
            rule = [ordered]@{
                t = [double]$rule.Margin.Top; b = [double]$rule.Margin.Bottom
                h = [double]$rule.Child.Height; align = "$($rule.Child.HorizontalAlignment)"
            }
            label = [ordered]@{
                l = [double]$lab.Margin.Left; t = [double]$lab.Margin.Top
                b = [double]$lab.Margin.Bottom
                runs = @($runs); hues = @($hues)
            }
        } | ConvertTo-Json -Compress -Depth 6)
        """,
        _ =>
        {
            var size = PaneMetrics.Size(PaneMetrics.PaneBase, 100);
            var gutter = PaneMetrics.Gutter(100);
            var stamp = DateTime.Today.AddHours(9).AddMinutes(5).ToString("HH:mm", CultureInfo.CurrentCulture);

            return new JsonObject
            {
                ["para"] = new JsonObject
                {
                    ["l"] = gutter,
                    ["t"] = 3.0,
                    ["r"] = 0.0,
                    ["b"] = 4.0,
                    ["indent"] = -gutter,
                    ["inlines"] = 1,
                    ["glyph"] = (int)PaneMetrics.Glyph("run")[0],
                    ["width"] = gutter,
                    ["size"] = size,
                    ["align"] = "Left",
                    ["hue"] = PaneMetrics.Hue("run"),
                    ["baseline"] = "Baseline",
                },
                ["noMark"] = new JsonObject
                {
                    ["l"] = gutter,
                    ["indent"] = 0.0,
                    ["inlines"] = 0,
                },
                ["indented"] = new JsonObject
                {
                    ["l"] = 12.0 + gutter,
                    ["indent"] = -gutter,
                    ["glyph"] = (int)PaneMetrics.Glyph("result")[0],
                },
                ["rail"] = new JsonObject
                {
                    ["l"] = 0.0,
                    ["t"] = PaneMetrics.RailTop,
                    ["r"] = 0.0,
                    ["b"] = PaneMetrics.RailBottom,
                    ["col0"] = gutter,
                    ["col1Star"] = true,
                    ["childCol"] = 1,
                    ["glyph"] = (int)PaneMetrics.Glyph("result")[0],
                    ["hue"] = PaneMetrics.Hue("result"),
                    ["size"] = size,
                    ["valign"] = "Top",
                    ["railW"] = PaneMetrics.RailWidth,
                    ["railL"] = PaneMetrics.RailInset,
                    ["railT"] = PaneMetrics.RailHead(size),
                    ["railR"] = 0.0,
                    ["railB"] = PaneMetrics.RailFoot,
                    ["railH"] = "Left",
                    ["railV"] = "Stretch",
                    ["tint"] = PaneMetrics.RailTint,
                },
                ["rule"] = new JsonObject
                {
                    ["t"] = PaneMetrics.RuleTop,
                    ["b"] = PaneMetrics.RuleBottom,
                    ["h"] = PaneMetrics.RuleHeight,
                    ["align"] = "Stretch",
                },
                ["label"] = new JsonObject
                {
                    ["l"] = gutter,
                    ["t"] = PaneMetrics.LabelTop,
                    ["b"] = PaneMetrics.LabelBottom,
                    ["runs"] = new JsonArray(
                        "YOU SAID",
                        PaneMetrics.StampGap + stamp,
                        PaneMetrics.TrailGap + "3 steps hidden"),
                    ["hues"] = new JsonArray("Out", "TextLow", "TextLow"),
                },
            }.ToJsonString();
        });


    // =======================================================================
    // pane/prose
    // =======================================================================

    /// <summary>The four line shapes, and whether each is a list.</summary>
    private static readonly (string Text, bool List)[] Lines =
    [
        ("a plain line of prose", false),
        ("- a bulleted line", true),
        ("* a starred line", true),
        ("3. a numbered line", true),
        ("10. a two-digit numbered line", true),
        ("## a heading", false),
    ];

    private static OracleCase Prose() => new(
        "pane/prose",
        "where Add-ReadProse puts a paragraph - plain, bulleted, numbered, grounded and not",
        Preamble + """

        Invoke-Expression (SR-LineOf '$SR_MarkDot =')
        Invoke-Expression (SR-LineOf '$SR_MarkSub =')
        Invoke-Expression (SR-BlockOf '$SR_Marks = @{')
        foreach ($fn in @('Get-MarkGlyph', 'Get-MarkBrush', 'New-GutterMark',
                          'New-ReadRun', 'New-ReadText', 'New-RailBlock', 'Add-ReadProse')) {
            Invoke-Expression (SR-Func $fn)
        }

        $hueNames = @('Out', 'In', 'TextMid', 'TextHigh', 'TextLow', 'TextDim', 'Tool', 'Ask')
        $Pal = @{}
        foreach ($h in $hueNames) { $Pal[$h] = [System.Windows.Media.SolidColorBrush]::new() }

        Set-SRTypeScale -Percent 100
        $script:PaneFace  = [System.Windows.Media.FontFamily]::new('Cascadia Mono')
        $script:ProseFace = [System.Windows.Media.FontFamily]::new('Segoe UI')
        $FW_Semi   = [System.Windows.FontWeights]::SemiBold
        $FW_Normal = [System.Windows.FontWeights]::Normal

        # 🔑 THREE STUBS, AND NONE OF THEM TOUCHES THE GEOMETRY. Remove-SRAnsi
        # lives in _common.ps1 and its job is already ported; Add-SRInlineRuns
        # decides which WORDS are code or bold; Measure-SRProseWidth asks the
        # installed face how wide a marker is, and its answer only ever changes
        # how many SPACES pad the marker out to the hang - never the margin, the
        # padding or the indent, which is all this case reads.
        function Remove-SRAnsi { param([string]$Text) return $Text }
        function Add-SRInlineRuns { param($Para, [string]$Text, $Brush, [double]$Size,
                                          [string]$Weight, [switch]$Italic, [int]$Depth)
            $null = $Para.Inlines.Add((New-ReadRun -Text $Text -Brush $Brush -Size $Size)) }
        function Measure-SRProseWidth { param([string]$Text, [double]$Size = 0) return 7.0 }

        $rows = @()
        foreach ($g in @($false, $true)) {
            $ground = $(if ($g) { [System.Windows.Media.SolidColorBrush]::new() } else { $null })
            foreach ($t in @(LINELIST)) {
                $doc = [System.Windows.Documents.FlowDocument]::new()
                Add-ReadProse -Doc $doc -Text $t -Brush $Pal.TextHigh -Kind 'said' -Indent 6 -Ground $ground
                $p = @($doc.Blocks)[0]
                $rows += [ordered]@{
                    ground = [bool]$g
                    text   = $t
                    ml = [double]$p.Margin.Left;  mt = [double]$p.Margin.Top
                    mr = [double]$p.Margin.Right; mb = [double]$p.Margin.Bottom
                    pl = [double]$p.Padding.Left; pt = [double]$p.Padding.Top
                    pr = [double]$p.Padding.Right; pb = [double]$p.Padding.Bottom
                    ti = [double]$p.TextIndent
                    lh = [double]$p.LineHeight
                    ls = "$($p.LineStackingStrategy)"
                    bg = [bool]($null -ne $p.Background)
                    # 🔑 THE MARKER THAT ACTUALLY GOT DRAWN. A list line's
                    # marker is baked into the body text, padded out to the
                    # hang - so the only way to see which character it is, is
                    # to read the first one of the body.
                    head = $(
                        $r0 = @(@($p.Inlines) | Where-Object { $_ -is [System.Windows.Documents.Run] })[0]
                        if ($r0 -and "$($r0.Text)".Length -gt 0) { [int][char]"$($r0.Text)"[0] } else { -1 })
                }
            }
        }
        # 🔴 AND A GROUNDED TURN OF THREE LINES, because the cap is the first
        # paragraph's and the last one's. A one-line turn is both, so it cannot
        # tell "first and last" from "every" - a break that capped every
        # paragraph stayed green until this was here.
        $doc3 = [System.Windows.Documents.FlowDocument]::new()
        Add-ReadProse -Doc $doc3 -Text "one`ntwo`nthree" -Brush $Pal.TextHigh -Kind 'you' `
            -Ground ([System.Windows.Media.SolidColorBrush]::new())
        $caps = @(@($doc3.Blocks) | ForEach-Object {
            [ordered]@{ pt = [double]$_.Padding.Top; pb = [double]$_.Padding.Bottom }
        })
        (@{ rows = @($rows); caps = @($caps) } | ConvertTo-Json -Compress -Depth 5)
        """.Replace("LINELIST", string.Join(", ", Lines.Select(l => PsText.Literal(l.Text))), StringComparison.Ordinal),
        _ =>
        {
            var size = PaneMetrics.Size(PaneMetrics.PaneBase, 100);
            var gutter = PaneMetrics.Gutter(100);
            var lead = PaneMetrics.Lead(size);
            var hang = PaneMetrics.Hang(size);
            const double indent = 6.0;

            var rows = new JsonArray();
            foreach (var ground in (bool[])[false, true])
            {
                var padX = ground ? PaneMetrics.GroundPad : 0.0;

                // 🪤 A GROUNDED TURN LOSES ITS VERTICAL MARGIN ON PURPOSE. Every
                // source line is its own Paragraph, so painting a background
                // per-paragraph with 3 px above and below drew a STRIPE PER LINE -
                // a five-line message read as five stacked cards. It is zero here
                // either way only because ProsePad is currently zero too.
                var groundPad = ground ? 0.0 : PaneMetrics.ProsePad;

                foreach (var (text, isList) in Lines)
                {
                    var bump = isList ? PaneMetrics.ListBump : 0.0;
                    var ml = isList && !ground
                        ? indent + gutter + bump - padX + hang
                        : indent + gutter - padX;
                    var pl = ground ? (isList ? padX + bump + hang : padX) : 0.0;

                    rows.Add(new JsonObject
                    {
                        ["ground"] = ground,
                        ["text"] = text,
                        ["ml"] = ml,
                        ["mt"] = groundPad,
                        ["mr"] = 0.0,
                        ["mb"] = groundPad,
                        ["pl"] = pl,
                        ["pt"] = ground ? PaneMetrics.GroundCap : 0.0,
                        ["pr"] = ground ? padX : 0.0,
                        ["pb"] = ground ? PaneMetrics.GroundCap : 0.0,
                        ["ti"] = isList ? -hang : -gutter,
                        ["lh"] = lead,
                        ["ls"] = "BlockLineHeight",
                        ["bg"] = ground,
                        ["head"] = (int)(text.StartsWith("- ", StringComparison.Ordinal)
                            || text.StartsWith("* ", StringComparison.Ordinal)
                                ? PaneMetrics.Bullet[0]
                                : text.TrimStart('#', ' ')[0]),
                    });
                }
            }

            var caps = new JsonArray();
            for (var i = 0; i < 3; i++)
            {
                caps.Add(new JsonObject
                {
                    ["pt"] = i == 0 ? PaneMetrics.GroundCap : 0.0,
                    ["pb"] = i == 2 ? PaneMetrics.GroundCap : 0.0,
                });
            }

            return new JsonObject { ["rows"] = rows, ["caps"] = caps }.ToJsonString();
        });

    /// <summary>What these cases cover, for the run report.</summary>
    public static string Coverage() => PaneMetrics.Coverage();
}
