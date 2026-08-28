#requires -Version 5.1
# ===========================================================================
# THE READING PANE
#
# Reading one conversation and replying to it: the document, the seen gate, the composer, the split pane.
#
# DOT-SOURCED BY sessions-gui.ps1, into its own scope, AFTER $window, $Pal and
# $ui exist - everything here reads them at CALL time, never at load time.
#
# Read tools/session-restore/CONTEXT.md before changing anything in here. The
# traps in it are not hypothetical: every one of them shipped.
# ===========================================================================

# ---------------------------------------------------------------------------
# Reading one conversation
#
# Four kinds of block, told apart by FORM rather than by hue, because the window
# has no hue to spend:
#
#   you        a bar down the left edge and the brightest text. It is the only
#              thing on the page with a bar, so your own words are findable by
#              shape while scrolling past everything else.
#   said       plain prose at reading weight. The default, so it needs no mark.
#   thinking   indented, dimmest, italic. Present but clearly not addressed to
#              you -- and folded to a couple of lines unless you ask for it.
#   tool       one mono line, dim, with a chevron. Tool traffic outnumbers prose
#              five to one in a real transcript; giving each call more than a
#              line would bury the conversation inside its own machinery.
#
# Code is monospaced on a lifted panel with its own left rule. No syntax colour
# yet, by decision: structure first, polish once it has been used.
# ---------------------------------------------------------------------------
$script:readSession = $null
$script:readDir     = $null

function New-ReadRun {
    param([string]$Text, $Brush, [double]$Size = 13, [string]$Weight = 'Normal', [switch]$Mono, [switch]$Italic)
    $r = New-Object System.Windows.Documents.Run ([string]$Text)
    if ($Brush) { $r.Foreground = $Brush }
    $r.FontSize = $Size
    if ($Mono)   { $r.FontFamily = $script:MonoFace }
    if ($Italic) { $r.FontStyle = [System.Windows.FontStyles]::Italic }
    $r.FontWeight = $(if ($Weight -eq 'SemiBold') { $FW_Semi } elseif ($Weight -eq 'Bold') { [System.Windows.FontWeights]::Bold } else { $FW_Normal })
    return $r
}

# Markdown, but only the parts that change how a line READS: fenced code, a
# heading, a bullet, and inline `code`. Anything more elaborate would be a
# markdown engine, which is not what this needs to be.
function Add-ReadProse {
    param($Doc, [string]$Text, $Brush)
    $lines = @($Text -replace "`r", '' -split "`n")
    $i = 0
    while ($i -lt $lines.Count) {
        $ln = $lines[$i]

        if ($ln.TrimStart().StartsWith('```')) {
            $code = New-Object System.Collections.Generic.List[string]
            $i++
            while ($i -lt $lines.Count -and -not $lines[$i].TrimStart().StartsWith('```')) {
                $code.Add($lines[$i]); $i++
            }
            $i++
            $p = New-Object System.Windows.Documents.Paragraph
            $p.Margin = New-Object System.Windows.Thickness 0, 6, 0, 6
            $p.Padding = New-Object System.Windows.Thickness 12, 8, 12, 8
            $p.Background = $Pal.Raised
            $p.BorderBrush = $Pal.HairlineHi
            $p.BorderThickness = New-Object System.Windows.Thickness 2, 0, 0, 0
            $p.Inlines.Add((New-ReadRun -Text ($code -join "`n") -Brush $Pal.TextHigh -Size 12 -Mono))
            $Doc.Blocks.Add($p)
            continue
        }

        $p = New-Object System.Windows.Documents.Paragraph
        $p.Margin = New-Object System.Windows.Thickness 0, 3, 0, 3
        $p.LineHeight = 21
        $p.LineStackingStrategy = 'BlockLineHeight'
        $body = $ln
        # 13pt at default leading was the operator's "type is too small or too
        # tight". Prose is the thing this pane exists to show; the tool lines around
        # it are the ones that should stay small.
        $size = 14.5; $weight = 'Normal'; $indent = 0

        if ($body -match '^\s*#{1,6}\s+(.*)$') { $body = $Matches[1]; $weight = 'SemiBold'; $size = 16 }
        elseif ($body -match '^\s*[-*]\s+(.*)$') { $body = [char]0x2022 + '  ' + $Matches[1]; $indent = 14 }
        elseif ($body -match '^\s*(\d+)\.\s+(.*)$') { $body = $Matches[1] + '.  ' + $Matches[2]; $indent = 14 }
        if ($indent) { $p.Margin = New-Object System.Windows.Thickness $indent, 2, 0, 2 }

        # Inline `code` and **bold**, split in one pass so a line can carry both.
        $rest = $body
        while ($rest -match '^(.*?)(`([^`]+)`|\*\*([^*]+)\*\*)(.*)$') {
            $before = $Matches[1]; $codeTxt = $Matches[3]; $boldTxt = $Matches[4]; $rest = $Matches[5]
            if ($before) { $p.Inlines.Add((New-ReadRun -Text $before -Brush $Brush -Size $size -Weight $weight)) }
            if ($codeTxt) { $p.Inlines.Add((New-ReadRun -Text $codeTxt -Brush $Pal.TextMax -Size ($size - 1) -Mono)) }
            elseif ($boldTxt) { $p.Inlines.Add((New-ReadRun -Text $boldTxt -Brush $Pal.TextMax -Size $size -Weight 'SemiBold')) }
        }
        if ($rest) { $p.Inlines.Add((New-ReadRun -Text $rest -Brush $Brush -Size $size -Weight $weight)) }
        if ($p.Inlines.Count -eq 0) { $p.Inlines.Add((New-ReadRun -Text ' ' -Brush $Brush -Size $size)) }
        $Doc.Blocks.Add($p)
        $i++
    }
}

# 🔴 TOOL TRAFFIC OUTNUMBERS PROSE FIVE TO ONE. Measured across six transcripts:
# text 50, thinking 84, tool_use 129, tool_result 130. Collapsing each call to one
# line was not enough -- twenty consecutive Bash lines still bury the sentence
# above them, which is what the operator meant by "tool noise still dominates".
#
# A RUN of them becomes ONE line saying how many and naming the last, because the
# question a reader has about a wall of tool calls is "how much of this is there,
# and where does the conversation start again". A short run is left alone: two
# lines are cheaper to read than a summary of two lines.
function Compress-ToolRuns { param($Blocks)
    $out = New-Object System.Collections.Generic.List[object]
    $arr = @($Blocks)
    $i = 0
    while ($i -lt $arr.Count) {
        if ($arr[$i].Kind -ne 'tool' -and $arr[$i].Kind -ne 'result') { $out.Add($arr[$i]); $i++; continue }
        $j = $i
        $calls = 0
        $lastHead = ''
        while ($j -lt $arr.Count -and ($arr[$j].Kind -eq 'tool' -or $arr[$j].Kind -eq 'result')) {
            if ($arr[$j].Kind -eq 'tool') { $calls++; $lastHead = "$($arr[$j].Head)" }
            $j++
        }
        if ($calls -le 2) {
            for ($k = $i; $k -lt $j; $k++) { $out.Add($arr[$k]) }
        } else {
            $out.Add([PSCustomObject]@{
                Kind = 'tools'
                Head = "$calls tool calls"
                Body = $(if ($lastHead) { "last: $lastHead" } else { '' })
                Meta = ''
            })
        }
        $i = $j
    }
    # 🪤 A PLAIN ARRAY, NEVER a comma-wrapped one. Wrapping protects a one-element
    # result from unrolling and makes @(f) at every call site a ONE-ELEMENT array
    # holding everything -- and for an EMPTY result it yields a single empty array,
    # so "nothing to render" becomes one phantom row. This codebase has shipped that
    # bug six times. The assertion for the empty case is in the headless suite.
    return $out.ToArray()
}
function Build-ReadDocument {
    param($Blocks)
    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.FontFamily        = $script:UiFace
    $doc.Background        = $Pal.Ink
    $doc.Foreground        = $Pal.TextHigh
    $doc.PagePadding       = New-Object System.Windows.Thickness 26, 18, 26, 26
    $doc.ColumnWidth       = [double]::PositiveInfinity   # one column, never split
    $doc.IsOptimalParagraphEnabled = $false

    if (-not @($Blocks).Count) {
        $p = New-Object System.Windows.Documents.Paragraph
        $p.Inlines.Add((New-ReadRun -Text 'Nothing readable in this transcript yet.' -Brush $Pal.TextMid -Size 13))
        $doc.Blocks.Add($p)
        return $doc
    }

    foreach ($b in @(Compress-ToolRuns $Blocks)) {
        switch ($b.Kind) {
            'you' {
                $s = New-Object System.Windows.Documents.Section
                $s.Margin = New-Object System.Windows.Thickness 0, 12, 0, 6
                $s.Padding = New-Object System.Windows.Thickness 12, 2, 0, 2
                $s.BorderBrush = $Pal.TextMax
                $s.BorderThickness = New-Object System.Windows.Thickness 2, 0, 0, 0
                $lab = New-Object System.Windows.Documents.Paragraph
                $lab.Margin = New-Object System.Windows.Thickness 0, 0, 0, 3
                $lab.Inlines.Add((New-ReadRun -Text 'YOU' -Brush $Pal.TextMax -Size 10.5 -Weight 'SemiBold'))
                $s.Blocks.Add($lab)
                $inner = New-Object System.Windows.Documents.FlowDocument
                Add-ReadProse -Doc $inner -Text $b.Body -Brush $Pal.TextMax
                # Blocks is a live collection: moving them while enumerating it
                # silently drops every second one, hence the @() snapshot.
                #
                # $null = on the Remove is NOT tidiness. BlockCollection.Remove
                # returns a BOOL, PowerShell emits every uncaptured value, and a
                # function that emits anything returns all of it -- so this
                # returned an array of $true with the document buried inside, and
                # the pane failed with "Cannot convert System.Object[] to
                # FlowDocument". Void-looking methods are not all void.
                foreach ($blk in @($inner.Blocks)) { $null = $inner.Blocks.Remove($blk); $s.Blocks.Add($blk) }
                $doc.Blocks.Add($s)
            }
            'said' {
                # WHO IS TALKING, SAID OUT LOUD. YOU had a label and a rule down its
                # side; the reply had neither, so a long exchange ran together into one
                # column of grey and the operator could not tell where a turn ended.
                $lab = New-Object System.Windows.Documents.Paragraph
                $lab.Margin = New-Object System.Windows.Thickness 0, 14, 0, 4
                $lab.Inlines.Add((New-ReadRun -Text 'CLAUDE' -Brush $Pal.TextLow -Size 10.5 -Weight 'SemiBold'))
                $doc.Blocks.Add($lab)
                $inner = New-Object System.Windows.Documents.FlowDocument
                Add-ReadProse -Doc $inner -Text $b.Body -Brush $Pal.TextHigh
                foreach ($blk in @($inner.Blocks)) { $null = $inner.Blocks.Remove($blk); $doc.Blocks.Add($blk) }
                $sp = New-Object System.Windows.Documents.Paragraph
                $sp.Margin = New-Object System.Windows.Thickness 0, 0, 0, 14
                $sp.Inlines.Add((New-ReadRun -Text ' ' -Brush $Pal.TextDim -Size 4))
                $doc.Blocks.Add($sp)
            }
            'thinking' {
                $head = @($b.Body -replace "`r", '' -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' '
                if ($head.Length -gt 170) { $head = $head.Substring(0, 167) + '...' }
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 18, 3, 0, 6
                $p.Inlines.Add((New-ReadRun -Text ('thinking  ' + $b.Meta + '   ') -Brush $Pal.TextDim -Size 10.5 -Weight 'SemiBold'))
                $p.Inlines.Add((New-ReadRun -Text $head -Brush $Pal.TextDim -Size 12 -Italic))
                $doc.Blocks.Add($p)
            }
            'tool' {
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 4, 1, 0, 1
                $p.Inlines.Add((New-ReadRun -Text ([char]0x203A + '  ') -Brush $Pal.TextLow -Size 12 -Mono))
                $p.Inlines.Add((New-ReadRun -Text ($b.Head + '  ') -Brush $Pal.TextMid -Size 11.5 -Weight 'SemiBold' -Mono))
                $p.Inlines.Add((New-ReadRun -Text $b.Body -Brush $Pal.TextLow -Size 11.5 -Mono))
                $doc.Blocks.Add($p)
            }
            'tools' {
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 4, 3, 0, 3
                $p.Inlines.Add((New-ReadRun -Text ([char]0x203A + '  ') -Brush $Pal.TextLow -Size 12 -Mono))
                $p.Inlines.Add((New-ReadRun -Text ($b.Head + '   ') -Brush $Pal.TextDim -Size 11 -Weight 'SemiBold' -Mono))
                $p.Inlines.Add((New-ReadRun -Text $b.Body -Brush $Pal.TextDim -Size 11 -Mono))
                $doc.Blocks.Add($p)
            }
            'result' {
                $first = @($b.Body -replace "`r", '' -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                $first = "$first"
                if ($first.Length -gt 120) { $first = $first.Substring(0, 117) + '...' }
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 22, 0, 0, 4
                $p.Inlines.Add((New-ReadRun -Text ($b.Head + '  ' + $b.Meta + '   ') -Brush $Pal.TextDim -Size 10.5 -Mono))
                $p.Inlines.Add((New-ReadRun -Text $first -Brush $Pal.TextDim -Size 11 -Mono))
                $doc.Blocks.Add($p)
            }
        }
    }
    return $doc
}

# FlowDocumentScrollViewer has no ScrollToEnd of its own -- it OWNS a
# ScrollViewer inside its template rather than being one. Walk the visual tree
# for it. Guarded because the template is only realised once the control has been
# laid out, so this is $null on the very first call.
function Get-ReadScroller {
    $q = New-Object System.Collections.Generic.Queue[object]
    $q.Enqueue($ui.ReadView)
    while ($q.Count) {
        $n = $q.Dequeue()
        if ($n -is [System.Windows.Controls.ScrollViewer]) { return $n }
        $c = 0
        try { $c = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($n) } catch { $c = 0 }
        for ($i = 0; $i -lt $c; $i++) { $q.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($n, $i)) }
    }
    return $null
}

function Show-ReadPane {
    param($Row)
    if (-not $Row -or $Row.Kind -ne 'session') {
        Set-Status 'select a conversation to read it' 'warn'
        return
    }
    # Cleared BEFORE the read, so a pane that is mid-read is never mistaken for
    # one that is current.
    $script:readShownFor = $null
    $script:readShownAt  = $null
    $script:readSession = $Row.Session
    $script:readDir     = $Row.Dir
    $ui.ReadName.Text   = "$(Get-SessionTitle $Row.Session $Row.Dir)"
    $cv = Get-Conv $Row.Session
    $ui.ReadWhat.Text   = $(if ($cv) { "$($cv.State)  -  $($cv.Detail)" } else { '' })
    # THE LIST STAYS UP. This used to hide RowList and the NEEDS YOU strip, so
    # reading anything cost you your place in the list you were reading it from.
    $ui.ReadPane.Visibility = $V_Show
    $ui.ReadSplit.Visibility = $V_Show
    $ui.SplitRow.Height = New-Object System.Windows.GridLength 5
    $ui.ReadRow.Height  = New-Object System.Windows.GridLength $script:readHeight
    $script:readOpen = $true
    $ui.SendBox.Text = ''
    # ORDER MATTERS, AND IT WAS WRONG. Update-SendState asks whether the document
    # on screen is current; running it BEFORE the document is read means the
    # answer is always no, so the composer opened for nobody, ever. It is the
    # read that stamps what the gate checks, so the gate is checked after it.
    Update-ReadDocument
    Update-SendState
    # After the document, for the same reason Update-SendState is: the panel is
    # judged against what is now on screen, not against what was on screen before.
    Update-AskPanel
    # SEEN, HERE AND ONLY HERE. Marking things seen because they scrolled past
    # would make the dot mean nothing, which is the one way an unread mark is
    # worse than no mark at all.
    Set-Seen $Row.Session
    $ui.ReadNote.Text = Get-SessionNote $Row.Session
    Update-RowSeenMarks
}

# Repaint the marks without rebuilding the list: a row that has just been read
# has to lose its dot immediately, and a full rebuild would move the selection
# out from under the operator while they are reading.
function Update-RowSeenMarks {
    foreach ($r in $script:rows) {
        if ($r.Kind -eq 'session') { $r.MovedVisibility = $(if (Test-Moved $r.Session) { $V_Show } else { $V_Hide }) }
    }
    foreach ($r in $script:inboxRows) {
        if ($r.Kind -eq 'session') { $r.MovedVisibility = $(if (Test-Moved $r.Session) { $V_Show } else { $V_Hide }) }
    }
}

# Follow the selection while the pane is open, so arrowing down the list reads
# each conversation in turn -- but DEBOUNCED, because Update-ReadDocument parses
# a transcript (measured at ~680 ms on a 15 MB one) and holding an arrow key
# would queue one parse per row.
$script:readTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:readTimer.Interval = [TimeSpan]::FromMilliseconds(220)
$script:readTimer.Add_Tick({
    $script:readTimer.Stop()
    Invoke-Guarded {
        if (-not $script:readOpen) { return }
        $row = (Get-ActiveList).SelectedItem
        if (-not $row -or $row.Kind -ne 'session') { return }
        if ($script:readSession -and "$($script:readSession.sessionId)" -eq "$($row.Session.sessionId)") { return }
        Show-ReadPane $row
    } 'the reading pane'
})
function Update-ReadFollow {
    if (-not $script:readOpen) { return }
    $script:readTimer.Stop()
    $script:readTimer.Start()
}

# The composer is only usable when there is a console to type into, and it says
# why rather than sitting there dead. A disabled control with no explanation is
# indistinguishable from a broken one.
# Has the pane read this conversation, and has it moved since? Returns $null
# when the composer may be used, otherwise the reason it may not.
# THE QUESTION THE OPEN CONVERSATION IS WAITING ON.
#
# The operator's complaint was exact: "I cannot see the questions I am getting
# asked". The window could say a session was waiting and never say what it wanted,
# so the terminal had to be opened anyway -- which is most of what this window
# exists to avoid.
function Update-AskPanel {
    $ui.AskPanel.Visibility = $V_Hide
    $ui.AskOptions.Items.Clear()
    $script:askPending = $null
    $s = $script:readSession
    if (-not $s) { return }

    $sid = "$($s.sessionId)"
    $a = $script:agents[$sid.ToLower()]

    # 🔴 THE SCREEN FIRST, because the transcript CANNOT hold a pending question.
    # claude writes the AskUserQuestion block when the tool RETURNS, so the
    # transcript only ever proves what was already answered -- a panel built on it
    # would say a session was waiting and never once show what it wanted, which is
    # the complaint this whole feature exists to answer.
    #
    # The transcript is still read, second: it names the header and the descriptions,
    # and it is all there is for a session that has since moved on.
    $screen = $null
    if ($a -and $a.Pid -and $a.Kind -eq 'interactive') {
        try { $screen = Get-SRScreenQuestion -ProcessId ([int]$a.Pid) } catch { }
    }
    $j = Get-SRTranscriptPath -Dir (Get-SessionCwd $s $script:readDir) -SessionId $sid -Recorded $s.jsonl
    $q = $null
    try { $q = Get-SRPendingQuestion -JsonlPath $j } catch { }
    if (-not $screen -and (-not $q -or -not $q.Questions.Count)) { return }

    $first = $(if ($q -and $q.Questions.Count) { $q.Questions[0] } else { $null })
    $script:askPending = $(if ($screen) { $screen } else { $q })
    $head = $(if ($first -and $first.header) { "$($first.header)" } else { '' })
    $ui.AskHeader.Text = $(if ($head) { "IT IS ASKING YOU  -  $head".ToUpper() } else { 'IT IS ASKING YOU' })
    $ui.AskText.Text   = $(if ($screen -and $screen.Question) { "$($screen.Question)" }
                           elseif ($first) { "$($first.question)" } else { '' })

    $canAnswer = ($a -and $a.Pid -and $a.Kind -eq 'interactive' -and "$($a.Status)" -eq 'waiting' -and $screen)

    # 🔒 MULTI-SELECT IS SHOWN, NOT ANSWERED. Ticking several options means Space
    # on each and then Enter, and that choreography was never verified against a
    # live TUI -- only single-select was. Half-answering a question from here would
    # leave the session in a state nobody can see, so it says so and offers the
    # terminal instead. This is the pre-agreed fallback, not a shortcut.
    $multi = $(if ($first) { [bool]$first.multiSelect } else { $false })

    # 🪤 THE SCREEN LISTS MORE OPTIONS THAN THE TRANSCRIPT. 'Type something' and
    # 'Chat about this' are added by the TUI and appear in no tool input, so a menu
    # claude asked three questions about is five items on screen. Driving it from
    # the transcript's count would be arithmetic against the wrong menu.
    $labels = $(if ($screen) { @($screen.Options) }
                elseif ($first) { @($first.options | ForEach-Object { "$($_.label)" }) }
                else { @() })
    $descs = @{}
    if ($first) { foreach ($o in @($first.options)) { $descs["$($o.label)"] = "$($o.description)" } }

    $i = 0
    foreach ($lab in $labels) {
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $window.FindResource('Btn')
        $b.HorizontalAlignment = 'Stretch'
        $b.HorizontalContentAlignment = 'Left'
        $b.Margin = New-Object System.Windows.Thickness (0, 0, 0, 5)
        $b.Content = "$($i + 1).  $lab"
        $b.Tag = $i
        $b.ToolTip = $(if ($descs["$lab"]) { $descs["$lab"] } else { "$lab" })
        $b.IsEnabled = ($canAnswer -and -not $multi)
        $b.Add_Click({ param($sender, $e) Invoke-Guarded { Invoke-AskAnswer ([int]$sender.Tag) } 'answering it' })
        $null = $ui.AskOptions.Items.Add($b)
        $i++
    }

    $ui.AskNote.Text = $(
        if ($multi)          { 'This one takes several answers at once. That is answered in the terminal - Go to its terminal, below.' }
        elseif (-not $a)     { 'This conversation is not running, so there is nothing to answer into. It is the last question it asked.' }
        elseif (-not $a.Pid) { 'A background agent has no console to answer in.' }
        elseif ("$($a.Status)" -ne 'waiting') { 'It has moved on since it asked this.' }
        else { "Clicking an option presses it in that session's own menu." }
    )
    $ui.AskPanel.Visibility = $V_Show
}

# 🪤 RE-READ BEFORE SENDING. Everything about the arrow-key choreography assumes
# the cursor is still on the first option, and the only evidence for that is that
# the question is still the one we drew. If it has changed or gone since the panel
# was painted, the keys would land somewhere unknown -- possibly a shell prompt.
function Invoke-AskAnswer { param([int]$Index)
    $s = $script:readSession
    if (-not $s -or -not $script:askPending) { Set-Status 'there is no question open' 'warn'; return }
    $sid = "$($s.sessionId)"
    $a = $script:agents[$sid.ToLower()]
    if (-not $a -or -not $a.Pid) { Set-Status 'that session is not running any more' 'warn'; Update-AskPanel; return }

    # 🪤 RE-READ THE SCREEN, NOT THE TRANSCRIPT. This used to compare a tool_use id
    # from the transcript against the one the panel was drawn from -- and a PENDING
    # question has no tool_use in the transcript at all, so the comparison could only
    # ever fail and every click would silently refuse to send. The screen is what the
    # panel is drawn from now, so the screen is what has to still agree.
    $now = $null
    try { $now = Get-SRScreenQuestion -ProcessId ([int]$a.Pid) } catch { }
    if (-not $now) {
        Set-Status 'that question is no longer on screen - nothing was sent' 'warn'
        Update-AskPanel
        return
    }
    # SAME MENU, not merely A menu. Comparing the option list catches the case that
    # matters: it answered, moved on, and asked something else while the pane sat
    # open. Sending into that would answer a question the operator never read.
    $wasOpts = @($script:askPending.Options)
    $nowOpts = @($now.Options)
    if (($wasOpts -join '|') -ne ($nowOpts -join '|')) {
        Set-Status 'it is asking something different now - nothing was sent' 'warn'
        Update-AskPanel
        return
    }
    if ($Index -ge $nowOpts.Count) { Set-Status 'that option is not on the menu any more' 'warn'; Update-AskPanel; return }

    $label = "$($nowOpts[$Index])"
    $why = Send-SRQuestionAnswer -SessionId $sid -Index $Index -OptionCount $nowOpts.Count
    if ($why) { Set-Status $why 'bad'; return }
    Set-Status "answered: $label"
    $ui.AskPanel.Visibility = $V_Hide
}
function Get-SendBlock {
    if (-not $script:readSession) { return 'nothing is open' }
    $sid = "$($script:readSession.sessionId)"
    if ("$script:readShownFor" -ne $sid) {
        return 'still reading this conversation'
    }
    try {
        $j = Get-SRTranscriptPath -Dir (Get-SessionCwd $script:readSession $script:readDir) -SessionId $sid -Recorded $script:readSession.jsonl
        if (Test-Path -LiteralPath $j) {
            $mt = (Get-Item -LiteralPath $j).LastWriteTime
            if ($script:readShownAt -and $mt -gt $script:readShownAt) {
                return 'it has said something since this was drawn'
            }
        }
    } catch { }
    return $null
}

function Update-SendState {
    if (-not $script:readSession) { return }
    $a = $script:agents["$($script:readSession.sessionId)".ToLower()]
    if (-not $a -or -not $a.Pid -or $a.Kind -ne 'interactive') {
        $ui.SendBox.IsEnabled = $false
        $ui.SendBtn.IsEnabled = $false
        $ui.SendNote.Text = 'Not running, so there is no console to type into. Open the terminal first.'
        return
    }
    # THE SEEN GATE, and it is a real gate rather than a warning: the box is dead
    # until what is on screen is what the session last said. Anything else is a
    # reply written against a conversation that has moved on, and the operator
    # cannot tell by looking - the document renders identically either way.
    $blocked = Get-SendBlock
    if ($blocked) {
        $ui.SendBox.IsEnabled = $false
        $ui.SendBtn.IsEnabled = $false
        $ui.SendNote.Text = $(if ($blocked -match 'said something') {
            'It has said something since this was drawn. Press Refresh to read the rest before replying.'
        } else { 'Reading it first - the composer opens once what is on screen is what it last said.' })
        return
    }
    $ui.SendBox.IsEnabled = $true
    $ui.SendBtn.IsEnabled = $true
    if ($a.WaitingFor -match 'dialog') {
        # The one case worth spelling out: prose typed at a permission prompt
        # ANSWERS the prompt. That has to be a deliberate act, not a surprise.
        $ui.SendNote.Text = 'A dialog is open in this session. Anything sent now answers the DIALOG, not the conversation.'
    } elseif ($a.Status -eq 'busy') {
        $ui.SendNote.Text = 'It is working. What you send will be read when it next comes up for air.'
    } else {
        $ui.SendNote.Text = "Types into $($a.Name) and presses Enter. Ctrl+Enter sends."
    }
}

function Invoke-SendReply {
    if (-not $script:readSession) { return }
    $text = "$($ui.SendBox.Text)"
    if (-not $text.Trim()) { return }
    $sid = "$($script:readSession.sessionId)"
    $a = $script:agents[$sid.ToLower()]

    $force = $false
    if ($a -and $a.WaitingFor -match 'dialog') {
        # Show-Confirm, not the in-window overlay: that one cannot block, and this
        # decision has to be answered BEFORE anything is typed into somebody
        # else's permission prompt. Same reason the close prompt uses it.
        $ans = Show-Confirm ("A dialog is open in that session.`n`nWhat you send will be typed AT THE DIALOG and will answer it, not go into the conversation.`n`n" + $text + "`n`nSend it anyway?") 'Answering a dialog'
        if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { Set-Status 'not sent' 'warn'; return }
        $force = $true
    }

    Set-Busy 'sending'
    try {
        $why = $(if ($force) { Send-SRSessionInput -SessionId $sid -Text $text -Force }
                 else        { Send-SRSessionInput -SessionId $sid -Text $text })
    } finally { Set-Busy '' }

    if ($why) { Set-Status "not sent - $why" 'bad'; return }
    $ui.SendBox.Text = ''
    Set-Status 'sent' 'ok'
    # Give it a moment to record the message, then show it in place rather than
    # leaving the operator wondering whether it landed.
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(3)
    $t.Add_Tick({ $this.Stop(); Invoke-Guarded { Update-ReadDocument } 'reread after sending' })
    $t.Start()
}

function Update-ReadDocument {
    if (-not $script:readSession) { return }
    $s = $script:readSession
    $j = Get-SRTranscriptPath -Dir (Get-SessionCwd $s $script:readDir) -SessionId $s.sessionId -Recorded $s.jsonl
    # ~680 ms on a 15 MB transcript, so it is announced rather than looking hung.
    Set-Busy 'reading the conversation'
    try {
        # 60 records was "not enough of the conversation is shown": with tool traffic
        # outnumbering prose five to one, sixty records is a dozen sentences. Runs of
        # tool calls now fold to one line each, so a wider window costs far less
        # screen than it used to and buys back the context that makes the last
        # message make sense.
        $blocks = Get-SRTranscriptBlocks -JsonlPath $j -MaxRecords 220
        $docObj = Build-ReadDocument -Blocks $blocks
        if ($docObj -isnot [System.Windows.Documents.FlowDocument]) {
            throw ("Build-ReadDocument returned {0}, not a FlowDocument - something in it emitted to the pipeline" -f $docObj.GetType().Name)
        }
        $ui.ReadView.Document = $docObj
        # STAMP WHAT WAS READ, AND WHEN. This is the whole of the seen gate:
        # without it "the pane is open" and "the pane is current" are the same
        # thing to the code and different things on screen.
        $script:readShownFor = "$($s.sessionId)"
        $script:readShownAt  = $(try { if (Test-Path -LiteralPath $j) { (Get-Item -LiteralPath $j).LastWriteTime } else { Get-Date } } catch { Get-Date })
        # Newest last, so the end is where the conversation is. Deferred to
        # Loaded priority: the document has only just been set and the scroller
        # does not know how tall it is until layout has run.
        $null = $window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded,
            [action]{ $sv = Get-ReadScroller; if ($sv) { $sv.ScrollToEnd() } })
        Set-Status ("read {0} block(s) from the end of the transcript" -f @($blocks).Count) 'ok'
    } finally { Set-Busy '' }
}

function Hide-ReadPane {
    $ui.AskPanel.Visibility = $V_Hide
    $script:askPending = $null
    $script:readSession = $null
    $script:readOpen = $false
    if ($script:readTimer) { $script:readTimer.Stop() }
    # Keep whatever split the operator dragged to, so reopening lands where they
    # left it rather than snapping back to the default every time.
    if ($ui.ReadRow.Height.IsAbsolute -and $ui.ReadRow.Height.Value -gt 80) {
        $script:readHeight = [double]$ui.ReadRow.Height.Value
    }
    $ui.ReadPane.Visibility = $V_Hide
    $ui.ReadSplit.Visibility = $V_Hide
    $ui.SplitRow.Height = New-Object System.Windows.GridLength 0
    $ui.ReadRow.Height  = New-Object System.Windows.GridLength 0
    # WHICH LIST IS SHOWING IS Set-ViewMode'S BUSINESS, not this function's. It
    # used to force RowList visible on the way out, which in the inbox left the
    # All view's list realised underneath the inbox's own.
    Update-NeedsBand
    $null = (Get-ActiveList).Focus()
}

function Update-Selection {
    $row = (Get-ActiveList).SelectedItem
    # A band heading is a label. Selecting one must not light up actions that
    # would then have nothing to act on.
    # A band heading and the older-conversations row are labels, not things to
    # act on.
    if ($row -and ($row.Kind -eq 'band' -or $row.Kind -eq 'more')) { $row = $null }
    if (-not $row) {
        $ui.SelName.Text = 'nothing selected'
        $ui.SelPath.Text = ''
        foreach ($b in @($ui.SelTick, $ui.SelUnpin, $ui.SelLaunch, $ui.SelSpawn)) { $b.IsEnabled = $false }
        return
    }
    if (-not $script:busy) {
        foreach ($b in @($ui.SelTick, $ui.SelUnpin, $ui.SelLaunch, $ui.SelSpawn)) { $b.IsEnabled = $true }
    }
    $ui.SelName.Text = "{0}   conversation" -f $row.Name
    $ui.SelPath.Text = Get-RowPath $row
    # ONE CLICK. Selecting a row IS opening it, whenever the pane is open.
    Update-ReadFollow
}
