using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Reading;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 4.4c-b - the pane as LINES: what a turn's body is split into, and
/// what a slash command's envelope is taken off first.
/// </summary>
/// <remarks>
/// 🔑 A ROW IS A LINE, NOT A TURN. <see cref="ReadDoc"/> already settled which
/// turns are drawn and what each one's heading says; this settles the split
/// underneath it, because that is the unit a virtualizing panel realizes and the
/// unit the alignment rule is about.
///
/// 🔴 A SHAPES TABLE AND THE REAL CORPUS, BOTH. The corpus alone is a data
/// source and not a spec - it contains whatever it happens to contain, and four
/// rules stayed green over fourteen real screens the last time that was
/// forgotten. The table carries the shapes that must be decided; the corpus
/// catches the shapes nobody thought to write down.
/// [[feedback-captured-corpus]]
/// </remarks>
public static class RowCases
{
    /// <summary>How many real conversations the live halves read.</summary>
    private const int Sample = 8;

    private static readonly JsonSerializerOptions Compact = new() { WriteIndented = false };

    /// <summary>How many rows the live comparison actually managed to compare.</summary>
    private static int LiveRows;

    /// <summary>How many bodies it read them from.</summary>
    private static int LiveBodies;

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Envelopes(), true, "what a slash command's envelope leaves behind");
        yield return (Shapes(), true, "every line shape a body can be split into");
        yield return (Live(), true, $"the same split over the bodies of {Sample} real conversations");
        yield return (Harvest(), true, "which files a conversation wrote, out of its own tool records");
    }

    public static string Coverage() => string.Format(CultureInfo.InvariantCulture,
        "{0} row(s) split out of {1} real bodies", LiveRows, LiveBodies);

    // =======================================================================
    // read/spoken
    // =======================================================================

    /// <summary>
    /// The envelopes, including the two that must be removed before the general
    /// form unwraps them.
    /// </summary>
    private static readonly string[] Envelopes_ =
    [
        "just something typed",
        "<command-name>/compact</command-name><command-message>compact</command-message><command-args>save the state</command-args>",
        "<command-name>compact</command-name>",
        "<command-name>/compact</command-name><command-args>   </command-args>",
        "<local-command-stdout>  </local-command-stdout>",
        "<local-command-stdout>ran and printed this</local-command-stdout>",
        "<local-command-caveat>ignore me</local-command-caveat>kept",
        "words <system-reminder>context for the model</system-reminder> more words",
        "a < b and c > d",
        "<html>not an envelope</html>",
        "one\n\n\n\n\ntwo",
        "<command-name>/x</command-name>\n\n\n\n\nafter",
        "before<command-args>   </command-args>after",
        "before<local-command-stdout>  </local-command-stdout>after",
        "<command-name>/x</command-name>\n\nonly two",
        "<command-name>/x</command-name>a\n \nb",
        "   <command-name>/x</command-name> trailing   ",
        "",
        "   ",
    ];

    private static OracleCase Envelopes() => new(
        "read/spoken",
        "Convert-SRSpoken, over a table of envelopes and over real bodies",
        PaneMetricCases.Preamble + """

        Invoke-Expression (SR-Func 'Convert-SRSpoken')

        $rows = @()
        foreach ($t in @(TEXTS)) {
            $rows += [ordered]@{ inp = $t; out = (Convert-SRSpoken $t) }
        }
        (@{ rows = @($rows) } | ConvertTo-Json -Compress -Depth 4)
        """.Replace("TEXTS", string.Join(", ", Envelopes_.Select(PsText.Literal)), StringComparison.Ordinal),
        _ =>
        {
            var rows = new JsonArray();
            foreach (var t in Envelopes_)
            {
                rows.Add(new JsonObject { ["inp"] = t, ["out"] = Spoken.Of(t) });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        });

    // =======================================================================
    // the shared PowerShell that runs the real Add-ReadProse and describes it
    // =======================================================================

    /// <summary>
    /// Splices <c>Add-ReadProse</c> and defines <c>Describe-Prose</c>, which turns
    /// the document it builds back into a row per block.
    /// </summary>
    /// <remarks>
    /// 🪤 THE MARKER IS BAKED INTO THE BODY by the time a paragraph exists - the
    /// shipped builder pads it out to a constant rendered width and prepends it -
    /// so the only way to read it back is to take the first token off again. That
    /// is exactly why <c>list</c> is decided by the GEOMETRY (a list paragraph
    /// hangs by the hang, a prose one by the gutter) rather than by looking at the
    /// text and guessing.
    ///
    /// 🔴 AND THE COMPARISON IS RUN BY RUN, NOT LINE BY LINE. It started as
    /// a whole-line text compare with the marked-up lines excused as
    /// <c>(inline)</c> - which excused about a third of the real corpus, and the
    /// first thing the exclusion hid was that the two sides disagreed about what
    /// <c>semi</c> even meant on a line holding bold. <c>Add-SRInlineRuns</c> and
    /// <c>Add-SRLinkedText</c> are ported instead, so every piece is compared on
    /// its text, its weight, its slant, its face and whether it opens.
    /// </remarks>
    private const string ProseHarness = """

        Invoke-Expression (SR-LineOf '$SR_MarkDot =')
        Invoke-Expression (SR-LineOf '$SR_MarkSub =')
        Invoke-Expression (SR-BlockOf '$SR_Marks = @{')
        Invoke-Expression (SR-LineOf '$script:SR_RxInline = ')
        # 🪤 Add-SRLinkedText TURNS A URL INTO ITS OWN RUN, so the pattern it does
        # that with has to be here too. Without it the function throws on the
        # first real body that mentions a link - which is most of them.
        Invoke-Expression (SR-LineOf '$script:SR_RxUrl = ')
        foreach ($fn in @('Get-MarkGlyph', 'Get-MarkBrush', 'New-GutterMark', 'New-ReadRun',
                          'New-ReadText', 'New-RailBlock', 'New-SRLinkRun', 'Add-SRLinkedText', 'Add-SRInlineRuns',
                          'Add-ReadProse', 'Convert-SRSpoken')) {
            Invoke-Expression (SR-Func $fn)
        }

        $hueNames = @('Out', 'In', 'TextMid', 'TextHigh', 'TextMax', 'TextLow', 'TextDim',
                      'Tool', 'Ask', 'Link', 'Edge')
        $Pal = @{}
        foreach ($h in $hueNames) { $Pal[$h] = [System.Windows.Media.SolidColorBrush]::new() }
        $PalEdge = @{ Out = [System.Windows.Media.SolidColorBrush]::new() }

        Set-SRTypeScale -Percent 100
        $script:readSize = $script:PaneSize
        $script:readLead = [Math]::Round($script:PaneSize * $SR_LeadFactor, 1)
        $script:PaneFace  = [System.Windows.Media.FontFamily]::new('Cascadia Mono')
        $script:ProseFace = [System.Windows.Media.FontFamily]::new('Segoe UI')
        $FW_Semi   = [System.Windows.FontWeights]::SemiBold
        $FW_Normal = [System.Windows.FontWeights]::Normal
        # 🔴 Remove-SRAnsi IS NOT STUBBED HERE. A stub that returned its input
        # was: it made no difference to the synthetic shapes, and then the first
        # real body carrying a colour escape - a compact notice - came back with
        # its escapes intact on one side and stripped on the other. The real one
        # lives in _common.ps1 and is already in this session.
        function New-SRTint { param($Brush, [double]$Alpha) return $Brush }
        function Measure-SRProseWidth { param([string]$Text, [double]$Size = 0) return 7.0 }

        $script:hang = [Math]::Round($script:PaneSize * 1.9, 1)

        # 🔑 THE FILES THIS CONVERSATION WROTE, SUPPLIED RATHER THAN HARVESTED.
        # Set-SRDocLinks reads them off the tool records; what is being compared
        # here is what a line does WITH them - the overlap rule and the order
        # rule - so both sides are handed the same set and the harvesting is
        # compared separately.
        Invoke-Expression (SR-Func 'Get-SRDocLinkRx')
        $script:docLinkRx = $null
        $script:docLinkPaths = @{}
        foreach ($lp in @('C:\a\bb.txt', 'C:\a\bb.txt.bak')) { $script:docLinkPaths[$lp.ToLower()] = $lp }

        function Describe-Prose {
            param([string]$Text, [string]$Kind, [bool]$Ground)
            $g = $(if ($Ground) { [System.Windows.Media.SolidColorBrush]::new() } else { $null })
            $doc = [System.Windows.Documents.FlowDocument]::new()
            Add-ReadProse -Doc $doc -Text $Text -Brush $Pal.TextHigh -Size $script:readSize `
                          -Line $script:readLead -Kind $Kind -Ground $g
            $out = @()
            foreach ($b in @($doc.Blocks)) {
                if ($b -is [System.Windows.Documents.BlockUIContainer]) {
                    $tb = $null
                    try { $tb = $b.Child.Children[$b.Child.Children.Count - 1] } catch { }
                    $out += [ordered]@{
                        shape = 'code'; mark = $false; blank = $false
                        list = $false; pre = ''
                        runs = @(@{ t = "$($tb.Text)"; w = 'norm'; i = $false; m = $true; k = $false })
                        gf = $false; gl = $false
                    }
                    continue
                }
                $ins = @($b.Inlines)
                $mark = [bool]($ins.Count -gt 0 -and $ins[0] -is [System.Windows.Documents.InlineUIContainer])
                $runs = @($ins | Where-Object { $_ -is [System.Windows.Documents.Run] })
                # The filler a blank source line gets is the only run, and it is
                # set at 0.4 of the body size.
                $blank = [bool]($runs.Count -eq 1 -and "$($runs[0].Text)" -eq ' ' -and
                                [Math]::Abs([double]$runs[0].FontSize - ($script:readSize * 0.4)) -lt 0.01)
                $list = [bool]([Math]::Abs([double]$b.TextIndent + $script:hang) -lt 0.01)
                # THE RUNS, ONE BY ONE, AND THE MARKER TAKEN BACK OFF THE FIRST
                # OF THEM. A list marker is baked into the body text before the
                # line is split, so the first run always opens with it; taking it
                # off again here is the inverse of what the builder did, and
                # `list` is decided by the GEOMETRY rather than by the text.
                $pre = ''
                $rr = @()
                $first = $true
                foreach ($r in $runs) {
                    if ($blank) { break }
                    $t = "$($r.Text)"
                    if ($first -and $list) {
                        $m = [regex]::Match($t, '^(\S+)\s+(.*)$', 'Singleline')
                        if ($m.Success) { $pre = $m.Groups[1].Value; $t = $m.Groups[2].Value }
                    }
                    $first = $false
                    if ($t.Length -eq 0) { continue }
                    $rr += [ordered]@{
                        t = $t
                        w = $(if ("$($r.FontWeight)" -eq 'SemiBold') { 'semi' } else { 'norm' })
                        i = [bool]("$($r.FontStyle)" -eq 'Italic')
                        m = [bool]("$($r.FontFamily)" -eq 'Cascadia Mono')
                        k = [bool]($null -ne $r.TextDecorations -and $r.TextDecorations.Count -gt 0)
                    }
                }
                $out += [ordered]@{
                    shape = 'prose'; mark = $mark; blank = $blank
                    list = $list; pre = $pre; runs = @($rr)
                    gf = [bool]($Ground -and [double]$b.Padding.Top -gt 0)
                    gl = [bool]($Ground -and [double]$b.Padding.Bottom -gt 0)
                }
            }
            return ,@($out)
        }
        """;

    /// <summary>
    /// The same description, from the ported rows.
    /// </summary>
    /// <summary>The same two paths the PowerShell side is handed.</summary>
    private static readonly string[] LinkPaths = [@"C:\a\bb.txt", @"C:\a\bb.txt.bak"];

    /// <summary>The pattern they make, built once.</summary>
    internal static readonly System.Text.RegularExpressions.Regex? Links = DocLinks.Rx(LinkPaths);

    private static JsonArray Describe(IReadOnlyList<PaneRow> rows, bool ground)
    {
        var outp = new JsonArray();
        foreach (var r in rows)
        {
            var code = string.Equals(r.Shape, RowShape.Code, StringComparison.Ordinal);
            var runs = new JsonArray();

            if (code)
            {
                runs.Add(Run(r.Text, false, false, true, false));
            }
            else if (!r.Blank)
            {
                foreach (var sp in r.Spans ?? [])
                {
                    if (sp.Text.Length == 0)
                    {
                        continue;
                    }

                    runs.Add(Run(sp.Text, sp.Semi, sp.Italic, sp.Mono, sp.Link));
                }
            }

            outp.Add(new JsonObject
            {
                ["shape"] = r.Shape,
                ["mark"] = r.Mark,
                ["blank"] = r.Blank,
                ["list"] = r.Marker.Length > 0,
                ["pre"] = r.Marker,
                ["runs"] = runs,
                ["gf"] = ground && r.GroundFirst,
                ["gl"] = ground && r.GroundLast,
            });
        }

        return outp;
    }

    /// <summary>One run, described the same way on both sides.</summary>
    private static JsonObject Run(string text, bool semi, bool italic, bool mono, bool link) => new()
    {
        ["t"] = text,
        ["w"] = semi ? "semi" : "norm",
        ["i"] = italic,
        ["m"] = mono,
        ["k"] = link,
    };

    // =======================================================================
    // read/prose-shapes
    // =======================================================================

    /// <summary>
    /// The line shapes a body can be made of, and the ones that only look like
    /// shapes.
    /// </summary>
    /// <remarks>
    /// 🪤 EVERY ROW HERE EXISTS BECAUSE SOMETHING ABOUT IT IS DECIDED. A fence
    /// that never closes, a line of spaces, a bullet on the FIRST line (so the
    /// gutter mark and the list hang collide), a heading that is also the first
    /// line, and a `10.` beside a `3.` - the two-digit marker is what broke the
    /// first version of the hang, which counted characters.
    /// </remarks>
    private static readonly (string Name, string Kind, bool Ground, string Text)[] Shaped =
    [
        ("one plain line", "said", false, "just a line"),
        ("two lines with a break", "said", false, "first\n\nsecond"),
        ("a bullet on the first line", "said", false, "- opens on a bullet\nand carries on"),
        ("a starred bullet", "said", false, "words\n* starred\n* again"),
        ("numbers, one and two digits", "said", false, "3. three\n10. ten\n100. hundred"),
        ("a heading first", "said", false, "# A heading\nand words"),
        ("six hashes", "said", false, "###### deep\ntext"),
        ("a hash with no space is not a heading", "said", false, "#nothashed"),
        ("a fence", "said", false, "before\n```\ncode one\ncode two\n```\nafter"),
        ("a fence that never closes", "said", false, "before\n```\nrunaway\nand more"),
        ("an indented fence", "said", false, "   ```\n  x\n   ```"),
        ("leading blank lines", "said", false, "\n\nwords at last"),
        ("a line of spaces", "said", false, "a\n   \nb"),
        ("trailing blank lines", "said", false, "words\n\n\n"),
        ("inline code and bold", "said", false, "a `code` and **bold** line"),
        ("bold is the whole line", "said", false, "**all of it**"),
        ("emphasis", "said", false, "an *emphasised* word"),
        ("a star with a space after it is not emphasis", "said", false, "2 * 3 * 4"),
        ("bold inside emphasis inside bold", "said", false, "*a **b *c **d** e* f** g*"),
        ("an unclosed backtick", "said", false, "a `never closed line"),
        ("code beside bold, code first", "said", false, "`**not bold**` then **bold**"),
        ("a heading that is also bold", "said", false, "# a **heading** of sorts"),
        ("a url on its own", "said", false, "https://example.com/a/b"),
        ("a url in a sentence, with a bracket", "said", false, "see (https://example.com/x) now"),
        ("a url inside inline code", "said", false, "run `curl https://example.com` first"),
        ("two urls", "said", false, "https://a.example https://b.example"),
        ("the word http but no url", "said", false, "http is a protocol"),
        ("a bulleted line with bold in it", "said", false, "- a **bold** bullet"),
        ("a numbered line with code in it", "said", false, "7. run `x`"),
        ("a fence ending on blank lines", "said", false, "before\n```\nx\n\n\n```\nafter"),
        ("seven hashes are not a heading", "said", false, "####### seven\nafter"),
        ("a plus is not a bullet", "said", false, "+ plus item"),
        ("windows line endings", "said", false, "one\r\ntwo\r\n\r\nthree"),
        ("nested four deep", "said", false, "**a *b **c *d **e** f* g** h* i**"),
        ("bold inside emphasis", "said", false, "*italic with **bold** inside*"),
        ("code inside emphasis", "said", false, "*a `code` b*"),
        ("code inside bold", "said", false, "**a `code` b**"),
        ("emphasis inside bold", "said", false, "**a *b* c**"),
        ("a url inside emphasis inside bold", "said", false,
            "**a *see https://example.com now* b**"),
        ("a url inside bold", "said", false, "**see https://example.com now**"),
        ("a path this session wrote", "said", false, "wrote `x` then C:\\a\\bb.txt here"),
        ("a path before a url", "said", false, "see `x` C:\\a\\bb.txt then https://z.example"),
        ("a path inside a url", "said", false, "at `x` https://z.example/C:\\a\\bb.txt end"),
        ("a short path is not linked", "said", false, "`x` and C:\\a here"),
        ("a url in brackets, on a line that is split", "said", false,
            "see `x` (https://example.com/y) now"),
        ("a longer path that opens with a shorter one", "said", false,
            "see `x` C:\\a\\bb.txt.bak here"),
        ("the same path in another case", "said", false,
            "see `x` c:\\A\\BB.TXT here"),
        ("no kind draws no mark", "", false, "unmarked\nlines"),
        ("grounded, one line", "you", true, "a single grounded line"),
        ("grounded, three lines", "you", true, "one\ntwo\nthree"),
        ("grounded, opening on a bullet", "you", true, "- first\n- second"),
        ("grounded, opening blank", "you", true, "\nwords"),
        ("an envelope, unwrapped first", "you", true,
            "<command-name>/compact</command-name><command-message>compact</command-message>"),
        ("empty", "said", false, ""),
    ];

    private static OracleCase Shapes()
    {
        var sb = new StringBuilder(PaneMetricCases.Preamble).Append(ProseHarness).Append("""

        $rows = @()

        """);

        foreach (var (name, kind, ground, text) in Shaped)
        {
            // 🔑 THE BODY IS UNWRAPPED ON BOTH SIDES THE SAME WAY. `you` is the
            // only kind whose body the pane edits before drawing it, and the
            // shipped arm does it in Add-ReadTurn rather than in Add-ReadProse -
            // so the harness does it here, once, and both sides split the same
            // string.
            var body = string.Equals(kind, "you", StringComparison.Ordinal)
                ? "(Convert-SRSpoken " + PsText.Literal(text) + ")"
                : PsText.Literal(text);

            sb.Append("        $rows += [ordered]@{ name = ").Append(PsText.Literal(name))
              .Append("; blocks = (Describe-Prose -Text ").Append(body)
              .Append(" -Kind ").Append(PsText.Literal(kind))
              .Append(" -Ground $").Append(ground ? "true" : "false").Append(") }\n");
        }

        sb.Append("""
        (@{ rows = @($rows) } | ConvertTo-Json -Compress -Depth 8)
        """);

        return new OracleCase(
            "read/prose-shapes",
            "every line shape Add-ReadProse can split a body into",
            sb.ToString(),
            _ =>
            {
                var rows = new JsonArray();
                foreach (var (name, kind, ground, text) in Shaped)
                {
                    var body = string.Equals(kind, "you", StringComparison.Ordinal)
                        ? Spoken.Of(text)
                        : text;
                    rows.Add(new JsonObject
                    {
                        ["name"] = name,
                        ["blocks"] = Describe(PaneRows.Body(body, kind, ground, -1, Links), ground),
                    });
                }

                return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
            });
    }


    // =======================================================================
    // read/doc-links
    // =======================================================================

    /// <summary>
    /// Tool calls built to reach every rule in the harvest.
    /// </summary>
    /// <remarks>
    /// 🪤 A Read IS IN HERE ON PURPOSE, and so is a two-character argument, an
    /// empty one, a quoted one and the same path in another case. Every row is a
    /// reason a path is kept or dropped; the real corpus that follows contains
    /// whatever it happens to contain. [[feedback-captured-corpus]]
    /// </remarks>
    private static readonly (string Tool, string Arg)[] Harvested =
    [
        ("Write", @"C:\one\alpha.txt"),
        ("Read", @"C:\one\not-kept.txt"),
        ("Edit", @"C:\one\beta.cs"),
        ("MULTIEDIT", @"C:\one\gamma.cs"),
        ("notebookedit", @"C:\one\delta.ipynb"),
        ("Artifact", @"C:\one\epsilon.html"),
        ("Bash", @"C:\one\not-a-file-tool.txt"),
        ("Write", "  C:\\one\\spaced.txt  "),
        ("Write", "\"C:\\one\\quoted.txt\""),
        ("Write", "ab"),
        ("Write", @"C:\one\ALPHA.TXT"),
        ("Write", ""),
        ("Write", @"C:\one\" + new string('z', 400) + ".txt"),
    ];

    /// <summary>The same calls, on a turn that is not a run.</summary>
    private static readonly (string Tool, string Arg)[] NotARun =
    [
        ("Write", @"C:\one\not-a-run.txt"),
    ];

    private static string Calls((string Tool, string Arg)[] rows) =>
        string.Join(", ", rows.Select(r =>
            "[PSCustomObject]@{ Name = " + PsText.Literal(r.Tool) +
            "; Arg = " + PsText.Literal(r.Arg) + " }"));

    private static OracleCase Harvest() => new(
        "read/doc-links",
        "Set-SRDocLinks over a table of tool calls and over real conversations",
        (PaneMetricCases.Preamble + """

        Invoke-Expression (SR-LineOf '$script:SR_FileTools = ')
        Invoke-Expression (SR-LineOf '$script:docLinkPaths = ')
        Invoke-Expression (SR-LineOf '$script:docLinkRx = ')
        Invoke-Expression (SR-Func 'Set-SRDocLinks')
        Invoke-Expression (SR-Func 'Get-RunSummary')
        Invoke-Expression (SR-Func 'Get-SRHeadLine')
        Invoke-Expression (SR-Func 'Get-ReadTurns')
        Invoke-Expression (SR-LineOf '$script:SR_RxAnyTag = ')

        $turn  = [PSCustomObject]@{ Kind = 'run';  Calls = @(CALLS) }
        $other = [PSCustomObject]@{ Kind = 'said'; Calls = @(OTHERCALLS) }
        Set-SRDocLinks @($turn, $other)
        # 🪤 SORTED, BECAUSE A POWERSHELL HASHTABLE HAS NO ORDER. What is compared
        # is the SET that was kept and the form each entry was stored in; the
        # order only ever reaches the pattern, and there it is sorted by length.
        # 🪤 ORDINAL, NOT Sort-Object. PowerShell's default string sort is
        # culture-aware and case-insensitive, so it puts `bcdc864d358f` before
        # `bcdc86-scratch` while an ordinal one does the opposite - and the two
        # sides then disagree about a SET they both got right.
        # 🪤 AND `return ,$a` FROM A HELPER WOULD HAVE MADE IT WORSE: it emits the
        # array as ONE object, so @() around the call gives a single element that
        # happens to be a list. Sorted in place, read back by name.
        $shaped = [string[]]@($script:docLinkPaths.Values)
        [array]::Sort($shaped, [System.StringComparer]::Ordinal)

        """ + LivePart)
            // 🪤 THE LONGER TOKEN FIRST. "CALLS" is a substring of "OTHERCALLS",
            // so replacing it first turns the second placeholder into
            // "OTHER[PSCustomObject]@{...}" and the script will not parse. The
            // same collision cost a case earlier in this file.
            .Replace("OTHERCALLS", Calls(NotARun), StringComparison.Ordinal)
            .Replace("CALLS", Calls(Harvested), StringComparison.Ordinal),
        psOut =>
        {
            var turn = new ReadTurn("run", string.Empty, string.Empty, Made(Harvested), null, 0);
            var other = new ReadTurn("said", string.Empty, string.Empty, Made(NotARun), null, 0);
            var shaped = DocLinks.Paths([turn, other]);
            shaped.Sort(StringComparer.Ordinal);

            var live = new JsonArray();
            foreach (var f in JsonNode.Parse(psOut)?["live"]?.AsArray() ?? [])
            {
                live.Add(Harvest(f));
            }

            return new JsonObject
            {
                ["shaped"] = Strings(shaped),
                ["live"] = live,
            }.ToJsonString(Compact);
        });

    private static List<ToolCall> Made((string Tool, string Arg)[] rows) =>
        [.. rows.Select(r => new ToolCall(
            r.Tool, r.Arg, string.Empty, string.Empty, false, string.Empty,
            CallKinds.Run, string.Empty))];

    private static JsonArray Strings(IEnumerable<string> xs)
    {
        // 🪤 JsonValue.Create, NOT Add(string). The generic overload builds a
        // customized value and wants a TypeInfoResolver, which this project does
        // not configure - so it throws at the first element rather than at build
        // time. Third time in this rebuild.
        var a = new JsonArray();
        foreach (var x in xs)
        {
            a.Add(JsonValue.Create(x));
        }

        return a;
    }

    /// <summary>
    /// One real conversation's paths, from the turns the PowerShell side handed
    /// over.
    /// </summary>
    /// <remarks>
    /// 🔑 THE TURNS ARE THE QUESTION. They are compared field for field by
    /// read/turns-live already; what is asked here is which of their calls name a
    /// file this conversation wrote.
    /// </remarks>
    private static JsonObject Harvest(JsonNode? f)
    {
        var turns = new List<ReadTurn>();
        foreach (var t in f?["turns"]?.AsArray() ?? [])
        {
            var calls = new List<ToolCall>();
            foreach (var c in t?["calls"]?.AsArray() ?? [])
            {
                calls.Add(new ToolCall(
                    c?["name"]?.GetValue<string>() ?? string.Empty,
                    c?["arg"]?.GetValue<string>() ?? string.Empty,
                    string.Empty, string.Empty, false, string.Empty,
                    CallKinds.Run, string.Empty));
            }

            turns.Add(new ReadTurn(
                t?["kind"]?.GetValue<string>() ?? string.Empty,
                string.Empty, string.Empty, calls, null, 0));
        }

        var paths = DocLinks.Paths(turns);
        paths.Sort(StringComparer.Ordinal);
        return new JsonObject
        {
            ["turns"] = f?["turns"]?.DeepClone(),
            ["paths"] = Strings(paths),
        };
    }

    /// <summary>The live half: the same harvest over real conversations.</summary>
    private static readonly string LivePart = BlockCases.PsPickListFor(Sample) + """

        $live = @()
        foreach ($row in $pick) {
            $got = Get-SRTranscriptBlocks -JsonlPath $row.P -MaxRecords 300 -MaxTailBytes 2097152
            $turns = @(Get-ReadTurns @($got))
            Set-SRDocLinks $turns
            $live += [ordered]@{
                turns = @($turns | ForEach-Object { [ordered]@{
                    kind = "$($_.Kind)"
                    calls = @(@($_.Calls | Where-Object { $_ }) | ForEach-Object {
                        [ordered]@{ name = "$($_.Name)"; arg = "$($_.Arg)" } }) } })
                paths = $(
                    $v = [string[]]@($script:docLinkPaths.Values)
                    [array]::Sort($v, [System.StringComparer]::Ordinal)
                    ,$v)
            }
        }
        (@{ shaped = @($shaped); live = @($live) } | ConvertTo-Json -Compress -Depth 10)
        """;

    // =======================================================================
    // read/prose-live
    // =======================================================================

    private static OracleCase Live() => new(
        "read/prose-live",
        $"the same split over every spoken body in {Sample} real conversations",
        PaneMetricCases.Preamble + ProseHarness + BlockCases.PsPickListFor(Sample) + """

        foreach ($fn in @('Get-ReadTurns', 'Get-RunSummary', 'Get-SRHeadLine')) {
            Invoke-Expression (SR-Func $fn)
        }
        Invoke-Expression (SR-LineOf '$script:SR_RxAnyTag = ')

        trap { throw ("at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim()) -- $($_.Exception.Message)") }
        $out = @()
        foreach ($row in $pick) {
            $got = Get-SRTranscriptBlocks -JsonlPath $row.P -MaxRecords 300 -MaxTailBytes 2097152
            $blocks = @($got)
            foreach ($t in @(Get-ReadTurns $blocks)) {
                if (@('you', 'msgin', 'said') -notcontains "$($t.Kind)") { continue }
                $body = "$($t.Body)"
                if ("$($t.Kind)" -eq 'you') { $body = Convert-SRSpoken $body }
                $g = ("$($t.Kind)" -eq 'you')
                $out += [ordered]@{
                    kind = "$($t.Kind)"
                    body = $body
                    blocks = (Describe-Prose -Text $body -Kind "$($t.Kind)" -Ground $g)
                }
            }
        }
        (@{ bodies = @($out) } | ConvertTo-Json -Compress -Depth 8)
        """,
        psOut =>
        {
            var bodies = new JsonArray();
            LiveRows = 0;
            LiveBodies = 0;

            foreach (var b in JsonNode.Parse(psOut)?["bodies"]?.AsArray() ?? [])
            {
                // 🔑 THE BODY IS THE QUESTION, NEVER THE ANSWER. It is already
                // compared field for field by read/turns-live; what is asked here
                // is whether two SPLITTERS of the same string agree. Reading the
                // transcript again on this side would compare two readers and two
                // splitters at once, and a difference in either would look the same.
                var kind = b?["kind"]?.GetValue<string>() ?? string.Empty;
                var body = b?["body"]?.GetValue<string>() ?? string.Empty;
                var ground = string.Equals(kind, "you", StringComparison.Ordinal);
                var rows = PaneRows.Body(body, kind, ground, -1, Links);

                LiveBodies++;
                LiveRows += rows.Count;

                bodies.Add(new JsonObject
                {
                    ["kind"] = kind,
                    ["body"] = body,
                    ["blocks"] = Describe(rows, ground),
                });
            }

            if (LiveBodies == 0)
            {
                bodies.Add(new JsonObject
                {
                    ["kind"] = "NOTHING WAS COMPARED - no real conversation had a spoken turn",
                });
            }

            return new JsonObject { ["bodies"] = bodies }.ToJsonString(Compact);
        });
}
