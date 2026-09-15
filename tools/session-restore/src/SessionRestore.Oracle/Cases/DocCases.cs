using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 4.4, second tranche - what the reading pane DRAWS for each turn.
/// </summary>
/// <remarks>
/// 🔴 THE HIDDEN COUNT IS AN ACCUMULATOR ACROSS TURNS, which is why this is
/// compared as a document rather than turn by turn. A dropped step adds to a
/// running total that is SPENT on the next heading - "3 steps hidden" beside the
/// next thing anybody said - and reset. A comparison of single turns could not
/// see that rule at all.
///
/// 🔑 <c>Add-ReadTurn</c> IS EVALUATED, with every WPF sink replaced by one that
/// only writes down what it was handed. Its arms build FlowDocument objects and
/// brushes; what is being compared is the DECISIONS - the rule, the heading, the
/// trailing note, the marker word, the fold's caption, the gutter's mark and
/// whether a fold starts open.
///
/// 🪤 AND THE STEPS SETTING IS THE AXIS. Over `folded` alone, not one of the
/// hiding rules is reached: nothing is dropped, nothing is counted, and the
/// live-shell exemption never fires. All three settings are run.
/// </remarks>
public static class DocCases
{
    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Doc(), true, "every turn the pane draws, at all three steps settings, against Add-ReadTurn");
    }

    /// <param name="Kind">The block kind, in PowerShell's own spelling.</param>
    private sealed record Blk(string Kind, string Head, string Body, string Meta);

    /// <summary>
    /// 🔴 EVERY ARM OF THE RENDERER HAS A TURN HERE, and the order matters: the
    /// hidden count is spent on the NEXT heading, so a dropped run has to be
    /// followed by something with a heading for the rule to be visible at all.
    /// </summary>
    private static readonly Blk[] Shaped =
    [
        new("you", "", "the first thing I said", ""),

        // A run of ordinary steps: dropped and counted on `hidden`.
        new("tool", "Read", "one.cs", ""),
        new("result", "ok", "read it", ""),
        new("tool", "Grep", "a pattern", ""),
        new("result", "ok", "found it", ""),

        // A hook and two files - one hidden step each, whatever they merged.
        new("hook", "a hook", "it said something", ""),
        new("file", "Read", "two.cs", "9 lines"),
        new("file", "Read", "three.cs", "4 lines"),

        // Three notices merged into one turn - THREE hidden steps, not one.
        new("system", "a notice", "one", ""),
        new("system", "a notice", "two", ""),
        new("system", "a notice", "three", ""),

        // The heading that SPENDS everything above it.
        new("said", "", "and here is what I found", ""),

        // 🪤 A SECOND HEADING IMMEDIATELY AFTER. It must NOT claim the same
        // hidden steps - the count was spent and reset.
        new("you", "", "thanks", ""),

        // A run holding a BACKGROUND SHELL: kept even on `hidden`, if the shell
        // is still writing.
        new("tool", "Bash (background)", "npm run watch", ""),
        new("result", "ok", "Command running in background with ID: keepme01.", ""),

        // 🔴 A SPOKEN TURN BETWEEN EVERY RUN, AND IT IS NOT DECORATION.
        // Consecutive tool/result blocks are ONE run - the grouper consumes
        // every one of them into a single turn - so six runs written back to
        // back are one turn holding sixteen calls, and every per-run rule below
        // was being tested once instead of six times. Found by a break that
        // could not go red: matching ANY shell instead of the live one changed
        // nothing, because there was only ever one run and it held the live
        // shell already.
        new("said", "", "between the runs", ""),

        // A run holding a shell that has FINISHED - dropped like any other.
        new("tool", "Bash (background)", "a finished one", ""),
        new("result", "ok", "Command running in background with ID: gone0002.", ""),
        new("said", "", "between the runs", ""),

        // 🪤 A RUN WHOSE MARKER IS DECIDED BY ORDER. Shell first, then agent:
        // the agent wins and stops the search.
        new("tool", "Bash (background)", "first", ""),
        new("result", "ok", "Command running in background with ID: shell003.", ""),
        new("tool", "Task", "go and look", "sweep the callers"),
        new("result", "ok", "done", ""),
        new("said", "", "between the runs", ""),

        // And agent first, then shell: still an agent.
        new("tool", "Task", "another", "and another sweep"),
        new("result", "ok", "done", ""),
        new("tool", "Bash (background)", "second", ""),
        new("result", "ok", "Command running in background with ID: shell004.", ""),
        new("said", "", "between the runs", ""),

        // A message out - it wins over a plain run too.
        new("tool", "Read", "four.cs", ""),
        new("result", "ok", "read", ""),
        new("tool", "SendMessage", "tell them", ""),
        new("result", "ok", "sent", ""),

        new("msgin", "another session", "a message arrived", ""),
        new("thinking", "", "reasoning about it", ""),
        new("asked", "", "a question and its answers", ""),
        new("queued", "", "something typed while it was busy", ""),
        new("compact", "", "the conversation was compacted", ""),

        // 🔴 THE SHAPES THE FIRST VERSION DID NOT REACH, each added after a
        // break stayed green on it. A corpus of my own invention is a data
        // source like any other.

        // ONE file, so the caption has to say "1 file" and not "1 files".
        new("file", "Read", "five.cs", "3 lines"),

        // A hook whose body LEADS WITH A BLANK LINE and is full of routing
        // tags - both of which the headline has to deal with, and neither of
        // which any earlier shape had.
        new("hook", "a talkative hook",
            "\n\n<cross-session-message from=\"uds:pipe\">the real first line</cross-session-message>\nand a second", ""),

        // A notice whose body is longer than 88, so the cut is reached.
        new("system", "a long notice", "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy", ""),

        // 🪤 A THINKING BODY BETWEEN 85 AND 96 CHARACTERS. Below 85 every width
        // agrees; above 96 every width cuts. Only in between does 96 tell
        // itself apart from the hook arm's 84.
        new("thinking", "", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", ""),

        // A queued message with leading whitespace, which is NOT trimmed.
        new("queued", "", "   \n  what I typed while it was busy", ""),

        // The last heading, to spend whatever the tail hid.
        new("said", "", "and that is all", ""),
    ];

    /// <summary>The one background shell that is still writing.</summary>
    private const string LiveShell = "keepme01";

    private static readonly string[] Views = [StepsView.Hidden, StepsView.Folded, StepsView.Full];

    private static OracleCase Doc() => new(
        "read/document",
        "the rule, heading, note, marker, caption and gutter of every turn, at all three steps settings",
        Script(),
        _ =>
        {
            var blocks = Shaped.Select(b => new TranscriptBlock(
                Kind(b.Kind), b.Head, b.Body, b.Meta, null)).ToList();
            var turns = ReadTurns.Of(blocks);
            Turns_ = turns.Count;

            var live = new HashSet<string>(StringComparer.Ordinal) { LiveShell };
            var views = new JsonArray();
            foreach (var v in Views)
            {
                var entries = new JsonArray();
                foreach (var e in ReadDoc.Of(turns, v, live))
                {
                    entries.Add(new JsonObject
                    {
                        ["kind"] = e.Kind, ["rule"] = e.Rule, ["label"] = e.Label,
                        ["trailing"] = e.Trailing, ["marker"] = e.Marker,
                        ["caption"] = e.Caption, ["trailing2"] = e.Trailing2,
                        ["gutter"] = e.Gutter, ["open"] = e.Open,
                    });
                }

                Drawn_ += entries.Count;
                views.Add(new JsonObject { ["view"] = v, ["entries"] = entries });
            }

            return new JsonObject
            {
                ["views"] = views,
                ["empty"] = ReadDoc.Empty,
                ["loadWhole"] = ReadDoc.LoadWhole(98304),
                ["backTo"] = ReadDoc.BackTo("the parent"),
            }.ToJsonString(Compact);
        });

    private static string Script()
    {
        var sb = new StringBuilder();
        sb.Append("""
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName PresentationFramework
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        # 🔑 Get-SRHeadLine IS SPLICED, NOT STUBBED. It is pure, it decides the
        # one line a closed fold shows, and stubbing it would leave the cut
        # untested on the side that matters.
        $rx = $winSrc.IndexOf('$script:SR_RxAnyTag = ')
        if ($rx -lt 0) { throw 'could not find SR_RxAnyTag' }
        Invoke-Expression $winSrc.Substring($rx, $winSrc.IndexOf("`n", $rx) - $rx)

        foreach ($fn in @('Get-ReadTurns', 'Get-RunSummary', 'Get-SRHeadLine', 'Add-ReadTurn')) {
            $a = $winSrc.IndexOf("function $fn")
            if ($a -lt 0) { throw "could not find $fn in sessions-window.ps1" }
            $b = $winSrc.IndexOf("`n}", $a)
            Invoke-Expression $winSrc.Substring($a, $b - $a + 2)
        }

        # ---- the sinks, each one writing down only what it was handed --------
        # 🔴 NOT ONE OF THESE DRAWS ANYTHING. Add-ReadTurn's arms build
        # FlowDocument objects and brushes; what is being compared is the
        # decisions it makes before it does.
        $script:rowRule = $false
        $script:rowLabel = ''; $script:rowTrail = ''; $script:rowMarker = ''
        $script:rowCaption = ''; $script:rowTrail2 = ''; $script:rowGutter = ''; $script:rowOpen = $false
        $script:emitted = $false

        function Add-ReadRule { param($Doc, $Brush, $Height) $script:rowRule = $true }
        function Add-ReadLabel { param($Doc, [string]$Text, $Brush, [string]$Trailing, $TrailBrush, $When)
            $script:rowLabel = "$Text"; $script:rowTrail = "$Trailing"; $script:emitted = $true }
        # 🪤 A REAL TextBlock AND A REAL Run, NOT A PSCustomObject. These go
        # into UIElementCollection and InlineCollection, which take a UIElement
        # and an Inline - a stand-in object fails with "cannot find an overload
        # for Add and the argument count 1", which names neither the call nor
        # the reason. The stub records what it was handed and then hands back
        # something the real collection will accept.
        function New-ReadText { param([string]$Text, $Brush, $Size)
            if ("$Text" -eq 'COMPACTED' -or "$Text" -eq 'YOU ANSWERED') { $script:rowMarker = "$Text" }
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Text = "$Text"
            return $tb }
        function New-ReadRun { param([string]$Text, $Brush, $Size)
            return (New-Object System.Windows.Documents.Run ("$Text")) }
        function Add-ReadProse { param($Doc, [string]$Text, $Brush, $Size, $Line, [string]$Kind, $Ground) }
        function Add-ReadMono { param($Doc, [string]$Text, $Brush, $Size, $Line, [string]$Kind) }
        function Convert-SRSpoken { param([string]$Text) return "$Text" }
        function Get-SRYouInkBrush { return $null }
        function Get-SRYouGroundBrush { return $null }
        function Get-MarkBrush { param([string]$Kind) return $null }
        function Set-SRDocLinks { param($Turns) }
        function Add-RunDetail { param($Panel, $Calls) }
        function New-FoldPanel { param([string]$Caption, $Brush, [string]$Kind, $Data, [string]$Trailing, [bool]$Open)
            $script:rowCaption = "$Caption"; $script:rowTrail2 = "$Trailing"; $script:rowOpen = [bool]$Open
            return (New-Object System.Windows.Controls.StackPanel) }
        function New-FoldHeader { param([string]$Caption, $Brush, [string]$Trailing, [bool]$Open)
            $script:rowCaption = "$Caption"; $script:rowTrail2 = "$Trailing"; $script:rowOpen = [bool]$Open
            return (New-Object System.Windows.Controls.StackPanel) }
        function New-RailBlock { param($Child, [string]$Kind, $Top, $Bottom, [switch]$Rail)
            $script:rowGutter = "$Kind"; $script:emitted = $true
            return [PSCustomObject]@{ Kind = "$Kind" } }

        # A stand-in document whose Blocks take anything.
        #
        # 🪤 List[object], NOT ArrayList. ArrayList.Add RETURNS THE INDEX, and
        # the shipped line is `$doc.Blocks.Add($fp)` unguarded - correct against
        # a FlowDocument, whose BlockCollection.Add returns void. With an
        # ArrayList standing in, every block emitted a stray integer into the
        # pipeline and the case failed with "'0' is invalid after a single JSON
        # value", which names neither the call nor the reason. It is the same
        # family as the shipped source's own `$null = ` on Remove.
        function New-FakeDoc {
            return [PSCustomObject]@{ Blocks = (New-Object 'System.Collections.Generic.List[object]') }
        }

        $Pal = @{ Out='o'; In='i'; TextMid='m'; TextHigh='h'; TextLow='l'; TextDim='d'; Tool='t'; Ask='a' }
        $PalEdge = @{ Out='oe' }
        $script:readSize = 14; $script:readLead = 20; $script:PaneSize = 13
        $script:ProseFace = $null
        $script:agentOpen = $null

        """).Append("        $blocks = @(\n");

        foreach (var b in Shaped)
        {
            sb.Append("            [PSCustomObject]@{ Kind = ").Append(PsText.Literal(b.Kind))
              .Append("; Head = ").Append(PsText.Literal(b.Head))
              .Append("; Body = ").Append(PsText.Literal(b.Body))
              .Append("; Meta = ").Append(PsText.Literal(b.Meta))
              .Append("; When = $null }\n");
        }

        sb.Append("""
        )
        $turns = @(Get-ReadTurns $blocks)

        $views = @()
        foreach ($v in @('hidden', 'folded', 'full')) {
            $script:toolView = $v
            $script:docHidden = 0
            $script:docLiveShells = New-Object 'System.Collections.Generic.HashSet[string]'
            $null = $script:docLiveShells.Add('
        """.TrimEnd()).Append(LiveShell).Append("""
        ')
            $entries = @()
            foreach ($t in $turns) {
                $script:rowRule = $false
                $script:rowLabel = ''; $script:rowTrail = ''; $script:rowMarker = ''
                $script:rowCaption = ''; $script:rowTrail2 = ''; $script:rowGutter = ''; $script:rowOpen = $false
                $script:emitted = $false
                $doc = New-FakeDoc
                Add-ReadTurn -Doc $doc -Turn $t
                # 🪤 A TURN THAT WAS DROPPED EMITTED NOTHING - no label, no rail
                # block - and that is what the hidden setting DOES. It is told
                # apart from a turn that drew, rather than inferred from a count.
                if (-not $script:emitted) { continue }
                $entries += [ordered]@{
                    kind = "$($t.Kind)"; rule = [bool]$script:rowRule
                    label = "$($script:rowLabel)"; trailing = "$($script:rowTrail)"
                    marker = "$($script:rowMarker)"; caption = "$($script:rowCaption)"
                    trailing2 = "$($script:rowTrail2)"
                    gutter = "$($script:rowGutter)"; open = [bool]$script:rowOpen
                }
            }
            $views += [ordered]@{ view = $v; entries = @($entries) }
        }

        # The three sentences the document says for itself, out of the shipped
        # lines rather than retyped.
        $src2 = $winSrc
        $a2 = $src2.IndexOf("'Nothing readable in this transcript yet.'")
        $emptyText = 'Nothing readable in this transcript yet.'
        if ($a2 -lt 0) { throw 'the empty-document line moved' }
        $a3 = $src2.IndexOf("'load the whole conversation   showing the last {0} KB of a longer one'")
        if ($a3 -lt 0) { throw 'the load-whole line moved' }
        $script:tailBytes = 98304
        $loadWhole = ('load the whole conversation   showing the last {0} KB of a longer one' -f [int]($script:tailBytes / 1KB))
        $backTo = ([string][char]0x2190 + '  back to ' + 'the parent')

        (@{ views = $views; empty = $emptyText; loadWhole = $loadWhole; backTo = $backTo } | ConvertTo-Json -Compress -Depth 8)
        """);

        return sb.ToString();
    }

    private static BlockKind Kind(string name) => name switch
    {
        "you" => BlockKind.You,
        "said" => BlockKind.Said,
        "thinking" => BlockKind.Thinking,
        "tool" => BlockKind.Tool,
        "result" => BlockKind.Result,
        "asked" => BlockKind.Asked,
        "msgin" => BlockKind.MsgIn,
        "system" => BlockKind.System,
        "hook" => BlockKind.Hook,
        "file" => BlockKind.File,
        "queued" => BlockKind.Queued,
        "compact" => BlockKind.Compact,
        _ => BlockKind.Said,
    };

    private static int Turns_ { get; set; }

    private static int Drawn_ { get; set; }

    public static string Coverage() => string.Format(CultureInfo.InvariantCulture,
        "{0} turn(s) at three steps settings, {1} drawn entr(ies) compared", Turns_, Drawn_);
}
