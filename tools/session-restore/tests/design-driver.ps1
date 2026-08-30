# ===========================================================================
# SIX DESIGNS FOR THE READING SURFACE, EACH DRAWN TO A PNG.
#
# By name only (`run-tests.ps1 -Only design`). It asserts almost nothing: its
# output is six images to LOOK at, drawn from the operator's own conversations
# at real density, because that is the only place a design decision can
# actually be judged. A variant that reads well against three lines of lorem
# and falls apart against a real tool-call storm is not a design.
#
# NOTHING HERE SHIPS. Every variant is defined in this file and applied to the
# live window at render time; lib\ is untouched until one is chosen. That is
# deliberate - six half-merged designs in the real renderer is how a window
# ends up looking like all of them at once.
#
#   SR_DESIGN_OUT=<dir>       where the PNGs go (default .state\design)
#   SR_DESIGN_ONLY=B          draw one variant
#   SR_DESIGN_SIZE=1600x1000
#   SR_DESIGN_SESSION=<name>  draw a different conversation
# ===========================================================================

$dzW = 1600.0; $dzH = 1000.0
if ($env:SR_DESIGN_SIZE -and $env:SR_DESIGN_SIZE -match '^(\d+)x(\d+)$') {
    $dzW = [double]$Matches[1]; $dzH = [double]$Matches[2]
}
$dzOut = $env:SR_DESIGN_OUT
if (-not $dzOut) { $dzOut = Join-Path $SR_StateDir 'design' }
if (-not (Test-Path -LiteralPath $dzOut)) { $null = New-Item -ItemType Directory -Path $dzOut -Force }

Update-Model
Build-Rail
Build-Sessions

# --- the conversation every variant draws ----------------------------------
# The same one in all six, or the comparison is between transcripts rather than
# between designs. Preference goes to the one the operator was looking at when
# they asked; otherwise the biggest live transcript on the machine, which is
# where the wall of tool traffic this redesign is about actually lives.
$dzWant = $env:SR_DESIGN_SESSION
if (-not $dzWant) { $dzWant = 'W1-CLOSE-1' }
$dzItems = @($ui.SessionList.Items | Where-Object { $_.Kind -eq 'session' })
$dzPick = @($dzItems | Where-Object { "$((Get-Title $_.Row.S $_.Row.D).Text)" -eq $dzWant })
if (-not $dzPick.Count) {
    $dzPick = @($dzItems | Where-Object { $_.Row.Live } | Sort-Object {
        $jp = "$($_.Row.S.jsonl)"
        if ($jp -and (Test-Path -LiteralPath $jp)) { (Get-Item -LiteralPath $jp).Length } else { 0 }
    } -Descending)
}
if (-not $dzPick.Count) { $dzPick = $dzItems }
if (-not $dzPick.Count) { Write-Host '  FAIL  no conversations to draw'; exit 1 }
$ui.SessionList.SelectedItem = $dzPick[0]
Show-Selected

$dzJsonl = "$($dzPick[0].Row.S.jsonl)"
Write-Host ("  using  {0}   {1}" -f $ui.PaneName.Text, $dzJsonl)

$dzBlocks = @()
try { $dzBlocks = Get-SRTranscriptBlocks -JsonlPath $dzJsonl -MaxRecords 220 -MaxTailBytes 400000 } catch { }
Write-Host ("  blocks {0}" -f @($dzBlocks).Count)

# --- the question every variant draws --------------------------------------
# Fabricated on purpose: a real one depends on what a live console happens to
# be sitting on, so six shots taken over four minutes would each show a
# different menu and the comparison would be worthless. Shaped like the real
# thing - a label and the reasoning under it.
$dzQ = [PSCustomObject]@{
    Header   = 'It is asking'
    Question = 'I8 has two clauses left unscoped or unbuilt. Which do I take now?'
    Options  = @(
        'Backfill: route the 9 tools through the door (Recommended)',
        'C2-on-merits - the last unscoped clause',
        'Discharge the A7 half formally first',
        'Push the four ref.plane repoints to F5 now',
        'Type something.')
    Details  = @(
        'The A7 half is done and dischargeable; what remains is the nine tools/backfill_*.py named in ref.plane that still bypass the harness door. It is I8 FIRST clause, real engineering rather than measurement.',
        'I8 only clause nobody has looked at. check_c2_create_delete.py exists and C2 is currently failing on main for another lane, so I would be scoping a check that is already red.',
        'Write the 16/0 measurement into the DONE-WHEN as a discharged sub-clause so the row stops implying the whole Backfill clause is open. Ten minutes.',
        'Brief V-FEATURES/F5 properly on W1-CLOSE-1-19 so the repoint migration is written before the deletion commit rather than after.',
        '')
    Footer   = 'Nothing is sent until you pick one.'
    Multi    = $false
}

# ===========================================================================
# SHARED GROUND - what every variant gets, because these are FIXES and not
# choices.
# ===========================================================================

# ANSI ESCAPES REACHED THE SCREEN. A tool_result carries whatever the child
# process wrote, colour codes included, and the parser passes it through
# untouched - so a python log line renders as "[32m2026-08-30[0m | [1mINFO".
# It reads as a broken font, which is exactly what it was mistaken for.
$dzEsc = [string][char]27
$dzBel = [string][char]7
function Dz-Clean { param([string]$S)
    if (-not $S) { return '' }
    $t = [regex]::Replace($S, [regex]::Escape($dzEsc) + '\[[0-9;?]*[ -/]*[@-~]', '')
    $t = [regex]::Replace($t, [regex]::Escape($dzEsc) + '\][^' + [regex]::Escape($dzBel) + ']*' + [regex]::Escape($dzBel), '')
    $t = [regex]::Replace($t, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
    return $t
}

# WPF HAS NO LETTER-SPACING. Tracking a small uppercase caption is the one
# typographic move that makes it read as a label rather than as shouting, and
# it has to be built by hand out of thin spaces.
function Dz-Track { param([string]$S, [string]$Sp = $([string][char]0x2009))
    return (($S.ToCharArray() | ForEach-Object { [string]$_ }) -join $Sp)
}

# A ROUNDED, PADDED SURFACE INSIDE A FLOWDOCUMENT. Paragraph.Background paints
# a hard rectangle and Paragraph has no CornerRadius at all - which is the
# whole reason the code blocks in the shipped pane have square corners inside
# a card with a 12px radius. A Border in a BlockUIContainer is the only way to
# get a rounded, glassy block in flowed text.
function Dz-Card {
    param($Child, $Bg, $Stroke, [double]$Radius = 10, [double]$BW = 0,
          [double]$PadL = 14, [double]$PadT = 10, [double]$PadR = 14, [double]$PadB = 10,
          [double]$Left = 0, [double]$Top = 6, [double]$Bottom = 6, $Shadow)
    $bd = New-Object System.Windows.Controls.Border
    if ($Bg) { $bd.Background = $Bg }
    if ($Stroke -and $BW -gt 0) { $bd.BorderBrush = $Stroke; $bd.BorderThickness = New-Object System.Windows.Thickness $BW }
    $bd.CornerRadius = New-Object System.Windows.CornerRadius $Radius
    $bd.Padding = New-Object System.Windows.Thickness $PadL, $PadT, $PadR, $PadB
    $bd.SnapsToDevicePixels = $true
    if ($Shadow) { $bd.Effect = $Shadow }
    $bd.Child = $Child
    $c = New-Object System.Windows.Documents.BlockUIContainer $bd
    $c.Margin = New-Object System.Windows.Thickness $Left, $Top, 0, $Bottom
    return $c
}

function Dz-Text {
    param([string]$S, $Brush, [double]$Size = 13, [switch]$Mono, [switch]$Semi, [switch]$Wrap, [double]$Line = 0)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $S
    if ($Brush) { $t.Foreground = $Brush }
    $t.FontSize = $Size
    if ($Mono) { $t.FontFamily = $script:MonoFace } else { $t.FontFamily = $script:UiFace }
    if ($Semi) { $t.FontWeight = $FW_Semi }
    if ($Wrap) { $t.TextWrapping = 'Wrap' } else { $t.TextWrapping = 'NoWrap'; $t.TextTrimming = 'CharacterEllipsis' }
    if ($Line -gt 0) { $t.LineHeight = $Line; $t.LineStackingStrategy = 'BlockLineHeight' }
    return $t
}

function Dz-Row { param([switch]$Wide)
    $g = New-Object System.Windows.Controls.StackPanel
    $g.Orientation = 'Horizontal'
    return $g
}

# Prose, parameterised. The same markdown subset the shipped renderer handles -
# fenced code, headings, bullets, inline code, bold - but the sizes, the
# leading and the code-block treatment belong to the variant.
function Dz-Prose {
    param($Doc, [string]$Text, $Brush, [double]$Size = 15, [double]$Line = 26,
          $CodeBg, $CodeStroke, [double]$CodeRadius = 8, [double]$Indent = 0)
    $lines = @((Dz-Clean $Text) -replace "`r", '' -split "`n")
    $k = 0
    while ($k -lt $lines.Count) {
        $ln = $lines[$k]
        if ($ln.TrimStart().StartsWith('``' + '`')) {
            $code = New-Object System.Collections.Generic.List[string]
            $k++
            while ($k -lt $lines.Count -and -not $lines[$k].TrimStart().StartsWith('``' + '`')) { $code.Add($lines[$k]); $k++ }
            $k++
            $tb = Dz-Text -S (($code -join "`n").TrimEnd()) -Brush $Pal.TextHigh -Size ($Size - 2) -Mono -Wrap -Line ($Size + 6)
            $bw = 0; if ($CodeStroke) { $bw = 1 }
            $Doc.Blocks.Add((Dz-Card -Child $tb -Bg $CodeBg -Stroke $CodeStroke -BW $bw -Radius $CodeRadius -Left $Indent))
            continue
        }
        $p = New-Object System.Windows.Documents.Paragraph
        $p.Margin = New-Object System.Windows.Thickness $Indent, 2, 0, 2
        $p.LineHeight = $Line
        $p.LineStackingStrategy = 'BlockLineHeight'
        $body = $ln; $sz = $Size; $wt = 'Normal'; $bump = 0
        if ($body -match '^\s*#{1,6}\s+(.*)$') { $body = $Matches[1]; $wt = 'SemiBold'; $sz = $Size + 2 }
        elseif ($body -match '^\s*[-*]\s+(.*)$') { $body = [string][char]0x2022 + '   ' + $Matches[1]; $bump = 16 }
        elseif ($body -match '^\s*(\d+)\.\s+(.*)$') { $body = $Matches[1] + '.   ' + $Matches[2]; $bump = 16 }
        if ($bump) { $p.Margin = New-Object System.Windows.Thickness ($Indent + $bump), 1, 0, 1 }
        $rest = $body
        while ($rest -match '^(.*?)(`([^`]+)`|\*\*([^*]+)\*\*)(.*)$') {
            $pre = $Matches[1]; $cd = $Matches[3]; $bo = $Matches[4]; $rest = $Matches[5]
            if ($pre) { $p.Inlines.Add((New-ReadRun -Text $pre -Brush $Brush -Size $sz -Weight $wt)) }
            if ($cd)     { $p.Inlines.Add((New-ReadRun -Text $cd -Brush $Pal.TextMax -Size ($sz - 1.5) -Mono)) }
            elseif ($bo) { $p.Inlines.Add((New-ReadRun -Text $bo -Brush $Pal.TextMax -Size $sz -Weight 'SemiBold')) }
        }
        if ($rest) { $p.Inlines.Add((New-ReadRun -Text $rest -Brush $Brush -Size $sz -Weight $wt)) }
        if ($p.Inlines.Count -eq 0) { $p.Inlines.Add((New-ReadRun -Text ' ' -Brush $Brush -Size ($Size * 0.4))) }
        $Doc.Blocks.Add($p)
        $k++
    }
}

# TURNS, NOT BLOCKS. Every variant wants the same input shape: prose turns, and
# RUNS of tool traffic with each result already paired to the call that caused
# it. Doing it once here is what stops six renderers disagreeing about what a
# "step" is.
function Dz-Turns { param($Blocks)
    $out = New-Object System.Collections.Generic.List[object]
    $arr = @($Blocks)
    $i = 0
    while ($i -lt $arr.Count) {
        $b = $arr[$i]
        if ($b.Kind -ne 'tool' -and $b.Kind -ne 'result') {
            # 🔴 ONE TURN PER SPEAKER, NOT ONE PER CONTENT BLOCK. A single reply
            # arrives as several `text` blocks whenever thinking or a tool call
            # sits between them, and naming the speaker over each one printed
            # CLAUDE three times down a screen with two sentences under each.
            # It read as a stutter and it wasted the vertical space this whole
            # exercise is about reclaiming.
            $prev = $null
            if ($out.Count) { $prev = $out[$out.Count - 1] }
            if ($prev -and $prev.Kind -eq "$($b.Kind)" -and ($b.Kind -eq 'you' -or $b.Kind -eq 'said')) {
                $prev.Body = ($prev.Body.TrimEnd() + "`n`n" + "$($b.Body)".TrimStart())
            } else {
                $out.Add([PSCustomObject]@{ Kind = "$($b.Kind)"; Body = "$($b.Body)"; Calls = $null })
            }
            $i++
            continue
        }
        $calls = New-Object System.Collections.Generic.List[object]
        while ($i -lt $arr.Count -and ($arr[$i].Kind -eq 'tool' -or $arr[$i].Kind -eq 'result')) {
            if ($arr[$i].Kind -eq 'tool') {
                $calls.Add([PSCustomObject]@{ Name = "$($arr[$i].Head)"; Arg = "$($arr[$i].Body)"; Res = ''; Bad = $false })
            } elseif ($calls.Count) {
                $last = $calls[$calls.Count - 1]
                if (-not $last.Res) {
                    $one = "$(@((Dz-Clean $arr[$i].Body) -replace "`r", '' -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1))"
                    if ($one.Length -gt 130) { $one = $one.Substring(0, 127) + [string][char]0x2026 }
                    $last.Res = $one
                    $last.Bad = ("$($arr[$i].Head)" -eq 'failed')
                }
            }
            $i++
        }
        # 🪤 .ToArray(), NEVER the List itself. @($someList) over a
        # List[object] throws "Argument types do not match" in PS 5.1, and
        # PowerShell reports it against whatever OUTER assignment started the
        # chain - here, six variants all failing to draw with no hint that a
        # property four calls down was the cause.
        if ($calls.Count) { $out.Add([PSCustomObject]@{ Kind = 'run'; Body = ''; Calls = $calls.ToArray() }) }
    }
    return $out.ToArray()
}

function Dz-RunSummary { param($Calls)
    $names = @(@($Calls) | ForEach-Object { $_.Name } | Select-Object -Unique)
    $shown = @($names | Select-Object -First 3)
    $tail = ''
    if ($names.Count -gt $shown.Count) { $tail = '  +' + ($names.Count - $shown.Count) }
    $word = 'steps'
    if (@($Calls).Count -eq 1) { $word = 'step' }
    return ('{0} {1}     {2}{3}' -f @($Calls).Count, $word, ($shown -join ('  ' + [string][char]0x00B7 + '  ')), $tail)
}

function Dz-Doc { param([double]$PadL = 34, [double]$PadT = 18, [double]$PadR = 34)
    $d = New-Object System.Windows.Documents.FlowDocument
    $d.FontFamily = $script:UiFace
    $d.Background = [System.Windows.Media.Brushes]::Transparent
    $d.Foreground = $Pal.TextHigh
    $d.ColumnWidth = [double]::PositiveInfinity
    $d.IsOptimalParagraphEnabled = $true
    $d.IsHyphenationEnabled = $false
    $d.PagePadding = New-Object System.Windows.Thickness $PadL, $PadT, $PadR, 30
    return $d
}

# THE MEASURE. Prose set across the full width of a 950px pane runs to about
# 120 characters a line and the eye loses the start of the next one - which is
# a large part of "flooded with text" that no amount of grey will fix. Every
# variant that caps its measure computes the right padding from the LIVE pane
# width, so it stays a measure rather than a fixed indent that breaks the
# moment the window is resized.
function Dz-Measure { param($Doc, [double]$Chars = 78, [double]$Size = 15, [double]$PadL = 34)
    $target = $Chars * $Size * 0.52
    $avail = $script:dzPaneW - $PadL
    $right = [Math]::Max(34.0, $avail - $target)
    $Doc.PagePadding = New-Object System.Windows.Thickness $PadL, $Doc.PagePadding.Top, $right, 30
}

function Dz-Rule { param($Doc, $Brush, [double]$Top = 18, [double]$Bottom = 12, [double]$H = 1)
    $r = New-Object System.Windows.Shapes.Rectangle
    $r.Height = $H
    $r.Fill = $Brush
    $r.HorizontalAlignment = 'Stretch'
    $c = New-Object System.Windows.Documents.BlockUIContainer $r
    $c.Margin = New-Object System.Windows.Thickness 0, $Top, 0, $Bottom
    $Doc.Blocks.Add($c)
}

function Dz-Label { param($Doc, [string]$S, $Brush, [double]$Size = 10, [double]$Top = 22, [double]$Bottom = 6, [switch]$Track)
    $p = New-Object System.Windows.Documents.Paragraph
    $p.Margin = New-Object System.Windows.Thickness 0, $Top, 0, $Bottom
    $txt = $S.ToUpper()
    if ($Track) { $txt = Dz-Track $txt }
    $p.Inlines.Add((New-ReadRun -Text $txt -Brush $Brush -Size $Size -Weight 'SemiBold'))
    $Doc.Blocks.Add($p)
}

# ===========================================================================
# THE HUES.
#
# The window was monochrome by rule - window2.xaml says every distinction is a
# LUMINANCE step so it survives greyscale and colour blindness. That rule is
# amended, not abandoned: hue now carries exactly two things, WHO SPOKE and
# WHICH PROJECT, and nothing else. State is still luminance, so a band still
# reads without colour.
#
# Fixed across all six variants on purpose. Six layouts against six palettes is
# not a comparison - it is noise, and the eye answers "which colour" long
# before it answers "which layout".
# ===========================================================================
function Dz-Brush { param([string]$Hex, [double]$Alpha = 1.0)
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    if ($Alpha -lt 1.0) { $c.A = [byte][math]::Round(255 * $Alpha) }
    $b = New-Object System.Windows.Media.SolidColorBrush $c
    $b.Freeze()
    return $b
}

$dzHex = @{
    In   = '#7AA2FF'   # what came IN - claude speaking
    Out  = '#FFB86B'   # what went OUT - you speaking
    Tool = '#A78BFA'   # the machinery between the two
    Bad  = '#FF7A8A'   # a call that failed
    Ask  = '#5EEAD4'   # a question waiting on you
    Warn = '#FFD166'
}
$dzC = @{}
foreach ($dzK in @($dzHex.Keys)) { $dzC[$dzK] = Dz-Brush $dzHex[$dzK] }
$dzWash = @{}
foreach ($dzK in @($dzHex.Keys)) { $dzWash[$dzK] = Dz-Brush $dzHex[$dzK] 0.10 }
$dzFilm = @{}
foreach ($dzK in @($dzHex.Keys)) { $dzFilm[$dzK] = Dz-Brush $dzHex[$dzK] 0.05 }
$dzEdge = @{}
foreach ($dzK in @($dzHex.Keys)) { $dzEdge[$dzK] = Dz-Brush $dzHex[$dzK] 0.34 }

$dzGlassLo = Dz-Brush '#FFFFFF' 0.035
$dzGlassMid = Dz-Brush '#FFFFFF' 0.055
$dzGlassHi = Dz-Brush '#FFFFFF' 0.08
$dzHair = Dz-Brush '#FFFFFF' 0.07
$dzSunk = Dz-Brush '#000000' 0.22

# BRIGHTER PROJECT ACCENTS. The shipped wheel sits at S 0.38-0.58 / L 0.60-0.72,
# which on a #0F0F11 ground reads as grey with a suggestion of colour in it -
# reported as "the colors for the projects seem a little bit dark". Same twelve
# hues, same dealt-by-index spread (that part was right and is why they are
# distinguishable at all); saturation and lightness raised so they actually
# arrive as colour.
$script:accentCache = @{}
function Get-ProjectAccent { param([string]$Path)
    $k = "$Path".ToLower()
    if ($script:accentCache.ContainsKey($k)) { return $script:accentCache[$k] }
    $wheel = @(
        @(206, 0.88, 0.68),   # azure
        @(  8, 0.86, 0.70),   # coral
        @(150, 0.72, 0.62),   # jade
        @(276, 0.80, 0.74),   # violet
        @( 34, 0.92, 0.64),   # amber
        @(188, 0.78, 0.62),   # teal
        @(330, 0.82, 0.72),   # rose
        @(102, 0.66, 0.62),   # moss
        @(248, 0.82, 0.76),   # indigo
        @( 18, 0.84, 0.64),   # rust
        @(168, 0.72, 0.66),   # spring
        @(300, 0.70, 0.72)    # magenta
    )
    $idx = 0
    $all = @($script:accentOrder)
    if ($all.Count) {
        $at = [array]::IndexOf($all, $k)
        if ($at -ge 0) { $idx = $at }
    }
    $slot = $wheel[$idx % $wheel.Count]
    $brush = New-Object System.Windows.Media.SolidColorBrush (
        Convert-HslToColor ([double]$slot[0]) ([double]$slot[1]) ([double]$slot[2]))
    $brush.Freeze()
    $script:accentCache[$k] = $brush
    return $brush
}

# ===========================================================================
# VITALS - what the terminal's own status line knows, read off the transcript.
#
# Nothing new has to be plumbed for any of it. An assistant record carries
# `message.model` and `message.usage`; every record carries `gitBranch`; a
# sub-agent is a `Task` tool_use and a background shell is a Bash call with
# run_in_background, and either is STILL RUNNING exactly when no tool_result
# quotes its id back. Remote Control is a launch flag this tool already stores.
#
# 🪤 It is read over a TAIL, so a sub-agent started before the window is not
# counted. That is honest for "what is running now" and wrong for "what has
# ever run" - this chip means the former.
# ===========================================================================
function Dz-Vitals { param([string]$JsonlPath, $Row)
    $v = [PSCustomObject]@{
        Model = ''; Tokens = 0; Window = 200000; Branch = ''
        Shells = 0; Agents = 0; Remote = $false; Ok = $false
        Effort = ''; Mode = ''; Elapsed = 0.0; TurnTokens = 0
        Added = -1; Removed = -1
    }
    # The launch flags this tool already stores. Read through the accessors
    # rather than off the raw record: Test-SRRemoteWanted carries the DEFAULT-ON
    # rule, and a bare property read would report every unset session as no.
    if ($Row -and $Row.S) {
        $v.Effort = "$(Get-SRSessionPref $Row.S 'effort')".Trim()
        $v.Mode   = "$(Get-SRSessionPref $Row.S 'permissionMode')".Trim()
        try { $v.Remote = [bool](Test-SRRemoteWanted $Row.S) } catch { }
    }
    if (-not $JsonlPath -or -not (Test-Path -LiteralPath $JsonlPath)) { return $v }
    $text = ''
    try {
        $fi = Get-Item -LiteralPath $JsonlPath
        $fs = [System.IO.File]::Open($JsonlPath, 'Open', 'Read', 'ReadWrite')
        try {
            $take = [int][Math]::Min($fi.Length, 600000)
            $null = $fs.Seek(-$take, 'End')
            $buf = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
    } catch { return $v }

    $lines = @($text -split "`n" | Where-Object { $_.Trim().StartsWith('{') })
    if (-not $lines.Count) { return $v }

    $open = @{}
    $turnAt = $null      # when the CURRENT turn started - the last thing you said
    $lastAt = $null
    $turnOut = 0
    for ($n = 0; $n -lt $lines.Count; $n++) {
        $r = $null
        try { $r = $lines[$n] | ConvertFrom-Json } catch { continue }
        if ($r.PSObject.Properties['gitBranch'] -and "$($r.gitBranch)") { $v.Branch = "$($r.gitBranch)" }
        if ($r.PSObject.Properties['timestamp'] -and "$($r.timestamp)") {
            try {
                $ts = [datetime]::Parse("$($r.timestamp)", [System.Globalization.CultureInfo]::InvariantCulture,
                                        [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                $lastAt = $ts
                # A turn STARTS when you speak. Everything after it is the reply
                # being composed, which is what the elapsed clock is timing.
                if ("$($r.type)" -eq 'user') { $turnAt = $ts; $turnOut = 0 }
            } catch { }
        }
        $m = $r.message
        if (-not $m) { continue }
        if ($m.PSObject.Properties['usage'] -and $m.usage -and $m.usage.PSObject.Properties['output_tokens']) {
            $turnOut += [int]$m.usage.output_tokens
        }
        if ($m.PSObject.Properties['model'] -and "$($m.model)") { $v.Model = "$($m.model)" }
        if ($m.PSObject.Properties['usage'] -and $m.usage) {
            $u = $m.usage
            $tot = 0
            foreach ($f in @('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens')) {
                if ($u.PSObject.Properties[$f]) { $tot += [int]$u.$f }
            }
            if ($tot -gt 0) { $v.Tokens = $tot }
        }
        foreach ($b in @($m.content)) {
            if (-not $b -or -not $b.type) { continue }
            if ($b.type -eq 'tool_use') {
                $nm = "$($b.name)"
                if ($nm -eq 'Task') { $open["$($b.id)"] = 'agent' }
                elseif ($nm -eq 'Bash' -and $b.input -and $b.input.PSObject.Properties['run_in_background'] -and $b.input.run_in_background) {
                    $open["$($b.id)"] = 'shell'
                }
            } elseif ($b.type -eq 'tool_result') {
                $id = "$($b.tool_use_id)"
                if ($id -and $open.ContainsKey($id)) { $null = $open.Remove($id) }
            }
        }
    }
    foreach ($k in @($open.Keys)) {
        if ($open[$k] -eq 'agent') { $v.Agents++ } else { $v.Shells++ }
    }
    # 🔴 THE MODEL ID DOES NOT SAY WHICH WINDOW IT HAS. A 1M session records
    # itself as plain "claude-opus-5" in the transcript - the [1m] suffix is a
    # launch-time selection, not part of what gets written down - so keying the
    # window off the id reported a 759k context as 380% of 200k. Observation
    # settles it instead: a context that has exceeded the standard window is
    # proof of the larger one, whatever the id says.
    $v.Window = 200000
    if ($v.Model -match '1m' -or $v.Tokens -gt 200000) { $v.Window = 1000000 }
    $v.TurnTokens = $turnOut
    $ref = $turnAt
    if (-not $ref) { $ref = $lastAt }
    if ($ref) { $v.Elapsed = ([datetime]::UtcNow - $ref).TotalSeconds }

    # (+166,-66). The one figure here that is NOT in the transcript, so it costs
    # a git call - cheap, and --no-optional-locks keeps it from fighting a
    # session that is mid-commit in the same tree.
    $cwd = ''
    if ($Row -and $Row.D) { $cwd = "$($Row.D.path)" }
    if ($cwd -and (Test-Path -LiteralPath $cwd)) {
        try {
            $st = & git --no-optional-locks -C $cwd diff --shortstat HEAD 2>$null
            $line = ($st -join ' ')
            $v.Added = 0; $v.Removed = 0
            if ($line -match '(\d+) insertion') { $v.Added = [int]$Matches[1] }
            if ($line -match '(\d+) deletion') { $v.Removed = [int]$Matches[1] }
        } catch { }
        # 🪤 "HEAD" IS NOT A BRANCH NAME. Every worktree session in this registry
        # recorded gitBranch=HEAD, because that is what claude writes for a
        # detached checkout - and a chip reading "HEAD" tells the operator
        # nothing they did not already know. Ask git, and if git says HEAD too,
        # name the worktree instead, which IS the thing they are working in.
        if (-not $v.Branch -or $v.Branch -eq 'HEAD') {
            try {
                $bn = "$(& git --no-optional-locks -C $cwd rev-parse --abbrev-ref HEAD 2>$null)".Trim()
                if ($bn -and $bn -ne 'HEAD') { $v.Branch = $bn }
                else { $v.Branch = (Split-Path -Leaf $cwd) + '  (detached)' }
            } catch { }
        }
    }
    $v.Ok = $true
    return $v
}

function Dz-Clock { param([double]$Sec)
    if ($Sec -lt 0) { return '' }
    if ($Sec -lt 60) { return ('{0}s' -f [int]$Sec) }
    $m = [int][math]::Floor($Sec / 60)
    $s = [int][math]::Floor($Sec - $m * 60)
    if ($m -lt 60) { return ('{0}m {1}s' -f $m, $s) }
    $h = [int][math]::Floor($m / 60)
    return ('{0}h {1}m' -f $h, ($m - $h * 60))
}

function Dz-ShortModel { param([string]$M)
    if (-not $M) { return 'unknown' }
    $s = $M -replace '^claude-', '' -replace '-\d{8}$', ''
    $s = $s -replace '\[1m\]', ' 1M'
    $s = $s -replace '-', ' '
    return $s
}

function Dz-Kilo { param([int]$N)
    if ($N -ge 1000000) { return ('{0:0.0}M' -f ($N / 1000000.0)) }
    if ($N -ge 1000) { return ('{0}k' -f [int][math]::Round($N / 1000.0)) }
    return "$N"
}

# ===========================================================================
# THE CHIP STRIP. One row under the session title carrying what the terminal's
# own status line shows: model, context pressure, branch, Remote Control, and
# whatever is running right now. Built into the live header rather than mocked,
# so the shots show real widths against real names.
# ===========================================================================
$dzStateRow = $ui.PaneState.Parent
$dzHeadStack = $dzStateRow.Parent
$dzChips = New-Object System.Windows.Controls.WrapPanel
$dzChips.Margin = New-Object System.Windows.Thickness 0, 9, 0, 0
$null = $dzHeadStack.Children.Add($dzChips)

function Dz-Chip {
    param([string]$Text, $Fg, $Bg, $Stroke, [double]$Radius = 7, $Dot, [double]$Bar = -1, $BarFg)
    $bd = New-Object System.Windows.Controls.Border
    $bd.Background = $Bg
    if ($Stroke) { $bd.BorderBrush = $Stroke; $bd.BorderThickness = New-Object System.Windows.Thickness 1 }
    $bd.CornerRadius = New-Object System.Windows.CornerRadius $Radius
    $bd.Padding = New-Object System.Windows.Thickness 9, 4, 10, 5
    $bd.Margin = New-Object System.Windows.Thickness 0, 0, 7, 0
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    if ($Dot) {
        $d = New-Object System.Windows.Controls.Border
        $d.Width = 6; $d.Height = 6
        $d.CornerRadius = New-Object System.Windows.CornerRadius 3
        $d.Background = $Dot
        $d.VerticalAlignment = 'Center'
        $d.Margin = New-Object System.Windows.Thickness 0, 0, 7, 0
        $null = $sp.Children.Add($d)
    }
    if ($Bar -ge 0) {
        $track = New-Object System.Windows.Controls.Border
        $track.Width = 46; $track.Height = 5
        $track.CornerRadius = New-Object System.Windows.CornerRadius 3
        $track.Background = $dzSunk
        $track.VerticalAlignment = 'Center'
        $track.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
        $track.HorizontalAlignment = 'Left'
        $fill = New-Object System.Windows.Controls.Border
        $fill.Height = 5
        $fill.Width = [Math]::Max(2.0, 46.0 * [Math]::Min(1.0, $Bar))
        $fill.CornerRadius = New-Object System.Windows.CornerRadius 3
        $fill.Background = $BarFg
        $fill.HorizontalAlignment = 'Left'
        $track.Child = $fill
        $null = $sp.Children.Add($track)
    }
    $null = $sp.Children.Add((Dz-Text -S $Text -Brush $Fg -Size 11.5 -Semi))
    $bd.Child = $sp
    return $bd
}

function Dz-BuildChips { param($V, [string]$Style = 'glass')
    $dzChips.Children.Clear()
    if (-not $V.Ok) { return }

    $bg = $dzGlassLo; $stroke = $null; $radius = 7.0
    if ($Style -eq 'outline') { $bg = $null; $stroke = $dzHair; $radius = 7.0 }
    if ($Style -eq 'flat')    { $bg = $dzGlassMid; $stroke = $null; $radius = 5.0 }
    if ($Style -eq 'pill')    { $bg = $dzGlassMid; $stroke = $null; $radius = 11.0 }

    $null = $dzChips.Children.Add((Dz-Chip -Text (Dz-ShortModel $V.Model) -Fg $Pal.TextHigh -Bg $bg -Stroke $stroke -Radius $radius -Dot $dzC.In))

    $frac = 0.0
    if ($V.Window -gt 0) { $frac = [double]$V.Tokens / [double]$V.Window }
    $barFg = $dzC.Ask
    if ($frac -gt 0.60) { $barFg = $dzC.Warn }
    if ($frac -gt 0.85) { $barFg = $dzC.Bad }
    $ctx = ('{0} / {1}   {2}%' -f (Dz-Kilo $V.Tokens), (Dz-Kilo $V.Window), [int][math]::Round($frac * 100))
    $null = $dzChips.Children.Add((Dz-Chip -Text $ctx -Fg $Pal.TextHigh -Bg $bg -Stroke $stroke -Radius $radius -Bar $frac -BarFg $barFg))

    if ($V.Branch) {
        $null = $dzChips.Children.Add((Dz-Chip -Text ([string][char]0x2387 + '  ' + $V.Branch) -Fg $Pal.TextMid -Bg $bg -Stroke $stroke -Radius $radius))
    }
    # (+166,-66) - the working tree against HEAD. Green and rose rather than one
    # grey string, because the question it answers is "how much is uncommitted",
    # and the two halves of that answer mean opposite things.
    if ($V.Added -ge 0) {
        $bd = New-Object System.Windows.Controls.Border
        $bd.Background = $bg
        if ($stroke) { $bd.BorderBrush = $stroke; $bd.BorderThickness = New-Object System.Windows.Thickness 1 }
        $bd.CornerRadius = New-Object System.Windows.CornerRadius $radius
        $bd.Padding = New-Object System.Windows.Thickness 9, 4, 10, 5
        $bd.Margin = New-Object System.Windows.Thickness 0, 0, 7, 0
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $null = $sp.Children.Add((Dz-Text -S ('+' + $V.Added) -Brush $dzC.Ask -Size 11.5 -Semi))
        $null = $sp.Children.Add((Dz-Text -S ('   ' + [string][char]0x2212 + $V.Removed) -Brush $dzC.Bad -Size 11.5 -Semi))
        $bd.Child = $sp
        $null = $dzChips.Children.Add($bd)
    }
    if ($V.Remote) {
        $null = $dzChips.Children.Add((Dz-Chip -Text 'remote control' -Fg $dzC.Ask -Bg $dzWash.Ask -Stroke $dzEdge.Ask -Radius $radius -Dot $dzC.Ask))
    }
    if ($V.Mode) {
        $null = $dzChips.Children.Add((Dz-Chip -Text ($V.Mode -replace '([a-z])([A-Z])', '$1 $2').ToLower() -Fg $dzC.Warn -Bg $dzWash.Warn -Stroke $dzEdge.Warn -Radius $radius))
    }
    if ($V.Effort) {
        $null = $dzChips.Children.Add((Dz-Chip -Text ($V.Effort + ' effort') -Fg $Pal.TextMid -Bg $bg -Stroke $stroke -Radius $radius))
    }
    if ($V.Shells -gt 0) {
        $w = 'shells'; if ($V.Shells -eq 1) { $w = 'shell' }
        $null = $dzChips.Children.Add((Dz-Chip -Text ('{0} {1}' -f $V.Shells, $w) -Fg $dzC.Tool -Bg $dzWash.Tool -Stroke $dzEdge.Tool -Radius $radius -Dot $dzC.Tool))
    }
    if ($V.Agents -gt 0) {
        $w = 'sub-agents'; if ($V.Agents -eq 1) { $w = 'sub-agent' }
        $null = $dzChips.Children.Add((Dz-Chip -Text ('{0} {1}' -f $V.Agents, $w) -Fg $dzC.Out -Bg $dzWash.Out -Stroke $dzEdge.Out -Radius $radius -Dot $dzC.Out))
    }
    # The turn clock, last, because it is the one thing here that is always
    # moving and would otherwise drag the eye off everything that is not.
    if ($V.Elapsed -gt 0) {
        $t = Dz-Clock $V.Elapsed
        if ($V.TurnTokens -gt 0) { $t += ('   ' + [string][char]0x00B7 + '   ' + [string][char]0x2193 + ' ' + (Dz-Kilo $V.TurnTokens)) }
        $null = $dzChips.Children.Add((Dz-Chip -Text $t -Fg $Pal.TextLow -Bg $bg -Stroke $stroke -Radius $radius))
    }
}

function Dz-Move { param($Src, $Dst)
    # Blocks is a LIVE collection: moving while enumerating it silently drops
    # every second block, hence the @() snapshot. And $null= on Remove is not
    # tidiness - it returns a bool, and an uncaptured value would be emitted.
    foreach ($blk in @($Src.Blocks)) { $null = $Src.Blocks.Remove($blk); $Dst.Blocks.Add($blk) }
}

function Dz-Sub { return (New-Object System.Windows.Documents.FlowDocument) }

# ===========================================================================
# A - QUIET DOCUMENT
# Nothing has a ground except code. The measure is capped, the leading is
# generous, speakers are named in tracked colour, and a run of tool calls
# collapses to one line. The bet: most of the "flood" is chrome, not text.
# ===========================================================================
function Dz-DocA {
    $d = Dz-Doc -PadL 40 -PadT 22
    Dz-Measure -Doc $d -Chars 78 -Size 15 -PadL 40
    foreach ($t in $script:dzTurns) {
        switch ($t.Kind) {
            'you' {
                Dz-Label -Doc $d -S 'you' -Brush $dzC.Out -Size 10 -Track -Top 26 -Bottom 7
                $s = Dz-Sub; Dz-Prose -Doc $s -Text $t.Body -Brush $Pal.TextMax -Size 15 -Line 26 -CodeBg $dzFilm.Out -CodeRadius 9
                Dz-Move $s $d
            }
            'said' {
                Dz-Label -Doc $d -S 'claude' -Brush $dzC.In -Size 10 -Track -Top 26 -Bottom 7
                $s = Dz-Sub; Dz-Prose -Doc $s -Text $t.Body -Brush $Pal.TextHigh -Size 15 -Line 26 -CodeBg $dzGlassLo -CodeRadius 9
                Dz-Move $s $d
            }
            'thinking' {
                $head = @((Dz-Clean $t.Body) -replace "`r", '' -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1) -join ' '
                if ($head.Length -gt 120) { $head = $head.Substring(0, 117) + [string][char]0x2026 }
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 0, 8, 0, 6
                $p.Inlines.Add((New-ReadRun -Text ('thinking   ') -Brush $Pal.TextLow -Size 11 -Weight 'SemiBold'))
                $p.Inlines.Add((New-ReadRun -Text $head -Brush $Pal.TextLow -Size 12.5 -Italic))
                $d.Blocks.Add($p)
            }
            'run' {
                $sp = New-Object System.Windows.Controls.StackPanel
                $sp.Orientation = 'Horizontal'
                $null = $sp.Children.Add((Dz-Text -S ([string][char]0x25B8 + '   ') -Brush $dzC.Tool -Size 12 -Semi))
                $null = $sp.Children.Add((Dz-Text -S (Dz-RunSummary $t.Calls) -Brush $Pal.TextMid -Size 12.5 -Mono))
                $d.Blocks.Add((Dz-Card -Child $sp -Bg $dzFilm.Tool -Radius 8 -PadL 12 -PadT 7 -PadR 14 -PadB 8 -Top 10 -Bottom 8))
            }
        }
    }
    return $d
}

# ===========================================================================
# B - TURN CARDS
# Every turn is a card with its own tinted ground, and yours is inset from the
# left. Direction is readable from the geometry before the colour arrives.
# ===========================================================================
function Dz-DocB {
    $d = Dz-Doc -PadL 26 -PadT 18
    Dz-Measure -Doc $d -Chars 86 -Size 14.5 -PadL 26
    foreach ($t in $script:dzTurns) {
        switch ($t.Kind) {
            'you' {
                $st = New-Object System.Windows.Controls.StackPanel
                $null = $st.Children.Add((Dz-Text -S (Dz-Track 'YOU') -Brush $dzC.Out -Size 9.5 -Semi))
                $inner = New-Object System.Windows.Controls.TextBlock
                $inner.Text = (Dz-Clean $t.Body).Trim()
                $inner.TextWrapping = 'Wrap'
                $inner.FontSize = 14.5
                $inner.LineHeight = 25; $inner.LineStackingStrategy = 'BlockLineHeight'
                $inner.Foreground = $Pal.TextMax
                $inner.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
                $null = $st.Children.Add($inner)
                $d.Blocks.Add((Dz-Card -Child $st -Bg $dzWash.Out -Stroke $dzEdge.Out -BW 1 -Radius 12 -PadL 16 -PadT 12 -PadR 16 -PadB 13 -Left 56 -Top 12 -Bottom 6))
            }
            'said' {
                $st = New-Object System.Windows.Controls.StackPanel
                $null = $st.Children.Add((Dz-Text -S (Dz-Track 'CLAUDE') -Brush $dzC.In -Size 9.5 -Semi))
                $st.Margin = New-Object System.Windows.Thickness 0
                $sub = Dz-Sub
                Dz-Prose -Doc $sub -Text $t.Body -Brush $Pal.TextHigh -Size 14.5 -Line 25 -CodeBg $dzGlassMid -CodeRadius 8
                $fdv = New-Object System.Windows.Controls.RichTextBox
                $fdv.Document = $sub
                $fdv.IsReadOnly = $true
                $fdv.BorderThickness = New-Object System.Windows.Thickness 0
                $fdv.Background = [System.Windows.Media.Brushes]::Transparent
                $fdv.Padding = New-Object System.Windows.Thickness 0
                $fdv.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
                $sub.PagePadding = New-Object System.Windows.Thickness 0
                $null = $st.Children.Add($fdv)
                $d.Blocks.Add((Dz-Card -Child $st -Bg $dzFilm.In -Stroke $dzEdge.In -BW 1 -Radius 12 -PadL 16 -PadT 12 -PadR 16 -PadB 12 -Top 12 -Bottom 6))
            }
            'thinking' {
                $head = @((Dz-Clean $t.Body) -replace "`r", '' -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1) -join ' '
                if ($head.Length -gt 110) { $head = $head.Substring(0, 107) + [string][char]0x2026 }
                $tb = Dz-Text -S ('thinking   ' + $head) -Brush $Pal.TextLow -Size 12 -Wrap
                $d.Blocks.Add((Dz-Card -Child $tb -Bg $null -Radius 0 -PadL 16 -PadT 0 -PadR 0 -PadB 0 -Top 4 -Bottom 2))
            }
            'run' {
                $wrap = New-Object System.Windows.Controls.WrapPanel
                foreach ($c in @($t.Calls) | Select-Object -First 8) {
                    $chip = New-Object System.Windows.Controls.Border
                    $chip.Background = $dzWash.Tool
                    $chip.CornerRadius = New-Object System.Windows.CornerRadius 6
                    $chip.Padding = New-Object System.Windows.Thickness 8, 3, 9, 4
                    $chip.Margin = New-Object System.Windows.Thickness 0, 0, 6, 6
                    $fg = $dzC.Tool; if ($c.Bad) { $fg = $dzC.Bad }
                    $chip.Child = (Dz-Text -S $c.Name -Brush $fg -Size 11.5 -Mono -Semi)
                    $null = $wrap.Children.Add($chip)
                }
                if (@($t.Calls).Count -gt 8) {
                    $more = New-Object System.Windows.Controls.Border
                    $more.Padding = New-Object System.Windows.Thickness 4, 3, 4, 4
                    $more.Child = (Dz-Text -S ('+' + (@($t.Calls).Count - 8)) -Brush $Pal.TextLow -Size 11.5 -Mono)
                    $null = $wrap.Children.Add($more)
                }
                $d.Blocks.Add((Dz-Card -Child $wrap -Bg $dzGlassLo -Radius 10 -PadL 12 -PadT 10 -PadR 12 -PadB 5 -Left 24 -Top 6 -Bottom 8))
            }
        }
    }
    return $d
}

# ===========================================================================
# C - TIMELINE
# A gutter carries who spoke and a running spine; the content flows beside it
# at a fixed measure. Tool traffic becomes a stop on the timeline rather than
# an interruption of the prose.
# ===========================================================================
function Dz-DocC {
    $d = Dz-Doc -PadL 28 -PadT 18
    Dz-Measure -Doc $d -Chars 92 -Size 14.5 -PadL 28
    # 🪤 A STAR COLUMN NEEDS A BOUNDED WIDTH TO BE A FRACTION OF. The document
    # sets ColumnWidth to PositiveInfinity so prose can run to the pane edge,
    # and a Table inside it therefore has infinite width to divide - the star
    # column collapsed and the whole transcript drew as one hairline. Both
    # columns are absolute here, sized off the live pane.
    $tbl = New-Object System.Windows.Documents.Table
    $tbl.CellSpacing = 0
    $body = [Math]::Max(360.0, $script:dzPaneW - 96 - 96)
    $c1 = New-Object System.Windows.Documents.TableColumn
    $c1.Width = New-Object System.Windows.GridLength 96
    $c2 = New-Object System.Windows.Documents.TableColumn
    $c2.Width = New-Object System.Windows.GridLength $body
    $tbl.Columns.Add($c1); $tbl.Columns.Add($c2)
    $rg = New-Object System.Windows.Documents.TableRowGroup
    $tbl.RowGroups.Add($rg)

    function Dz-CRow { param([string]$Gutter, $GutterBrush, $Dot, [scriptblock]$Fill, [double]$Top = 14)
        $row = New-Object System.Windows.Documents.TableRow
        $g = New-Object System.Windows.Documents.TableCell
        $g.Padding = New-Object System.Windows.Thickness 0, $Top, 16, 6
        $gp = New-Object System.Windows.Documents.Paragraph
        $gp.Margin = New-Object System.Windows.Thickness 0
        $gp.TextAlignment = 'Right'
        if ($Gutter) {
            $gp.Inlines.Add((New-ReadRun -Text (Dz-Track $Gutter.ToUpper()) -Brush $GutterBrush -Size 9.5 -Weight 'SemiBold'))
        }
        $g.Blocks.Add($gp)
        $row.Cells.Add($g)
        $b = New-Object System.Windows.Documents.TableCell
        $b.Padding = New-Object System.Windows.Thickness 0, $Top, 0, 6
        $b.BorderBrush = $Dot
        $b.BorderThickness = New-Object System.Windows.Thickness 2, 0, 0, 0
        $sub = Dz-Sub
        & $Fill $sub
        $sub.PagePadding = New-Object System.Windows.Thickness 0
        foreach ($blk in @($sub.Blocks)) {
            $null = $sub.Blocks.Remove($blk)
            if ($blk -is [System.Windows.Documents.Paragraph]) {
                $blk.Margin = New-Object System.Windows.Thickness ($blk.Margin.Left + 16), $blk.Margin.Top, 0, $blk.Margin.Bottom
            } else {
                $blk.Margin = New-Object System.Windows.Thickness ($blk.Margin.Left + 16), $blk.Margin.Top, 0, $blk.Margin.Bottom
            }
            $b.Blocks.Add($blk)
        }
        $row.Cells.Add($b)
        $rg.Rows.Add($row)
    }

    foreach ($t in $script:dzTurns) {
        switch ($t.Kind) {
            'you'  { Dz-CRow -Gutter 'you' -GutterBrush $dzC.Out -Dot $dzEdge.Out -Fill { param($s) Dz-Prose -Doc $s -Text $t.Body -Brush $Pal.TextMax -Size 14.5 -Line 25 -CodeBg $dzFilm.Out } }
            'said' { Dz-CRow -Gutter 'claude' -GutterBrush $dzC.In -Dot $dzEdge.In -Fill { param($s) Dz-Prose -Doc $s -Text $t.Body -Brush $Pal.TextHigh -Size 14.5 -Line 25 -CodeBg $dzGlassMid } }
            'thinking' {
                $head = @((Dz-Clean $t.Body) -replace "`r", '' -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1) -join ' '
                if ($head.Length -gt 110) { $head = $head.Substring(0, 107) + [string][char]0x2026 }
                Dz-CRow -Top 6 -Gutter '' -GutterBrush $Pal.TextLow -Dot $dzHair -Fill { param($s)
                    $p = New-Object System.Windows.Documents.Paragraph
                    $p.Margin = New-Object System.Windows.Thickness 0
                    $p.Inlines.Add((New-ReadRun -Text $head -Brush $Pal.TextLow -Size 12 -Italic))
                    $s.Blocks.Add($p)
                }
            }
            'run' {
                Dz-CRow -Top 8 -Gutter ('{0} steps' -f @($t.Calls).Count) -GutterBrush $dzC.Tool -Dot $dzEdge.Tool -Fill { param($s)
                    foreach ($c in @($t.Calls) | Select-Object -First 6) {
                        $p = New-Object System.Windows.Documents.Paragraph
                        $p.Margin = New-Object System.Windows.Thickness 0, 1, 0, 1
                        $fg = $dzC.Tool; if ($c.Bad) { $fg = $dzC.Bad }
                        $p.Inlines.Add((New-ReadRun -Text ($c.Name + '   ') -Brush $fg -Size 12 -Weight 'SemiBold' -Mono))
                        $p.Inlines.Add((New-ReadRun -Text (Compress-SRPath $c.Arg) -Brush $Pal.TextMid -Size 12 -Mono))
                        $s.Blocks.Add($p)
                    }
                    if (@($t.Calls).Count -gt 6) {
                        $p = New-Object System.Windows.Documents.Paragraph
                        $p.Margin = New-Object System.Windows.Thickness 0, 2, 0, 1
                        $p.Inlines.Add((New-ReadRun -Text ('and {0} more' -f (@($t.Calls).Count - 6)) -Brush $Pal.TextLow -Size 11.5 -Italic))
                        $s.Blocks.Add($p)
                    }
                }
            }
        }
    }
    $d.Blocks.Add($tbl)
    return $d
}

# ===========================================================================
# D - EDITORIAL
# The typographic answer: bigger body, a tighter measure, real hierarchy, and
# code blocks that carry a caption strip naming the tool that ran.
# ===========================================================================
function Dz-DocD {
    $d = Dz-Doc -PadL 44 -PadT 24
    Dz-Measure -Doc $d -Chars 70 -Size 16 -PadL 44
    foreach ($t in $script:dzTurns) {
        switch ($t.Kind) {
            'you' {
                Dz-Rule -Doc $d -Brush $dzEdge.Out -Top 24 -Bottom 0 -H 2
                Dz-Label -Doc $d -S 'you said' -Brush $dzC.Out -Size 10 -Track -Top 10 -Bottom 8
                $s = Dz-Sub; Dz-Prose -Doc $s -Text $t.Body -Brush $Pal.TextMax -Size 16 -Line 28 -CodeBg $dzFilm.Out -CodeRadius 10
                Dz-Move $s $d
            }
            'said' {
                Dz-Rule -Doc $d -Brush $dzHair -Top 24 -Bottom 0
                Dz-Label -Doc $d -S 'claude' -Brush $dzC.In -Size 10 -Track -Top 10 -Bottom 8
                $s = Dz-Sub; Dz-Prose -Doc $s -Text $t.Body -Brush $Pal.TextHigh -Size 16 -Line 28 -CodeBg $dzGlassMid -CodeRadius 10
                Dz-Move $s $d
            }
            'thinking' { }
            'run' {
                $st = New-Object System.Windows.Controls.StackPanel
                $cap = New-Object System.Windows.Controls.StackPanel
                $cap.Orientation = 'Horizontal'
                $cap.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
                $null = $cap.Children.Add((Dz-Text -S (Dz-Track (Dz-RunSummary $t.Calls)) -Brush $dzC.Tool -Size 9.5 -Semi))
                $null = $st.Children.Add($cap)
                foreach ($c in @($t.Calls) | Select-Object -First 3) {
                    $ln = New-Object System.Windows.Controls.StackPanel
                    $ln.Margin = New-Object System.Windows.Thickness 0, 0, 0, 6
                    $fg = $dzC.Tool; if ($c.Bad) { $fg = $dzC.Bad }
                    $h = Dz-Text -S ($c.Name + '   ' + (Compress-SRPath $c.Arg)) -Brush $Pal.TextHigh -Size 12.5 -Mono
                    $null = $ln.Children.Add($h)
                    if ($c.Res) {
                        $r = Dz-Text -S $c.Res -Brush $Pal.TextLow -Size 12 -Mono
                        $r.Margin = New-Object System.Windows.Thickness 16, 3, 0, 0
                        $null = $ln.Children.Add($r)
                    }
                    $null = $st.Children.Add($ln)
                }
                $d.Blocks.Add((Dz-Card -Child $st -Bg $dzGlassLo -Stroke $dzHair -BW 1 -Radius 12 -PadL 16 -PadT 12 -PadR 16 -PadB 10 -Top 12 -Bottom 10))
            }
        }
    }
    return $d
}

# ===========================================================================
# E - CONSOLE, DONE PROPERLY
# Keeps the terminal character the operator is used to, but gives it a real
# surface: one rounded block per run holding every call AND its result, ANSI
# stripped, results indented under the call that caused them.
# ===========================================================================
function Dz-DocE {
    $d = Dz-Doc -PadL 32 -PadT 18
    Dz-Measure -Doc $d -Chars 88 -Size 15 -PadL 32
    foreach ($t in $script:dzTurns) {
        switch ($t.Kind) {
            'you' {
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 0, 22, 0, 6
                $p.Inlines.Add((New-ReadRun -Text ([string][char]0x203A + '  ') -Brush $dzC.Out -Size 13 -Weight 'SemiBold' -Mono))
                $p.Inlines.Add((New-ReadRun -Text 'you' -Brush $dzC.Out -Size 11 -Weight 'SemiBold' -Mono))
                $d.Blocks.Add($p)
                $s = Dz-Sub; Dz-Prose -Doc $s -Text $t.Body -Brush $Pal.TextMax -Size 15 -Line 25 -CodeBg $dzFilm.Out -CodeRadius 7
                Dz-Move $s $d
            }
            'said' {
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 0, 22, 0, 6
                $p.Inlines.Add((New-ReadRun -Text ([string][char]0x2726 + '  ') -Brush $dzC.In -Size 13 -Weight 'SemiBold' -Mono))
                $p.Inlines.Add((New-ReadRun -Text 'claude' -Brush $dzC.In -Size 11 -Weight 'SemiBold' -Mono))
                $d.Blocks.Add($p)
                $s = Dz-Sub; Dz-Prose -Doc $s -Text $t.Body -Brush $Pal.TextHigh -Size 15 -Line 25 -CodeBg $dzGlassMid -CodeRadius 7
                Dz-Move $s $d
            }
            'thinking' {
                $head = @((Dz-Clean $t.Body) -replace "`r", '' -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1) -join ' '
                if ($head.Length -gt 110) { $head = $head.Substring(0, 107) + [string][char]0x2026 }
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 18, 6, 0, 4
                $p.Inlines.Add((New-ReadRun -Text $head -Brush $Pal.TextLow -Size 12 -Italic))
                $d.Blocks.Add($p)
            }
            'run' {
                $st = New-Object System.Windows.Controls.StackPanel
                foreach ($c in @($t.Calls) | Select-Object -First 5) {
                    $fg = $dzC.Tool; if ($c.Bad) { $fg = $dzC.Bad }
                    $h = New-Object System.Windows.Controls.StackPanel
                    $h.Orientation = 'Horizontal'
                    $h.Margin = New-Object System.Windows.Thickness 0, 0, 0, 2
                    $null = $h.Children.Add((Dz-Text -S ($c.Name.PadRight(10)) -Brush $fg -Size 12.5 -Mono -Semi))
                    $null = $h.Children.Add((Dz-Text -S (Compress-SRPath $c.Arg) -Brush $Pal.TextHigh -Size 12.5 -Mono))
                    $null = $st.Children.Add($h)
                    if ($c.Res) {
                        $r = Dz-Text -S $c.Res -Brush $Pal.TextLow -Size 12 -Mono
                        $r.Margin = New-Object System.Windows.Thickness 22, 0, 0, 8
                        $null = $st.Children.Add($r)
                    }
                }
                if (@($t.Calls).Count -gt 5) {
                    $null = $st.Children.Add((Dz-Text -S ('and {0} more' -f (@($t.Calls).Count - 5)) -Brush $Pal.TextLow -Size 11.5 -Mono))
                }
                $d.Blocks.Add((Dz-Card -Child $st -Bg $dzSunk -Stroke $dzHair -BW 1 -Radius 8 -PadL 14 -PadT 11 -PadR 14 -PadB 10 -Top 10 -Bottom 10))
            }
        }
    }
    return $d
}

# ===========================================================================
# F - MINIMAL AIR
# The most aggressive cut. No grounds, no cards, tool traffic reduced to a
# count beside the speaker. Whitespace and a hairline do all the separating.
# ===========================================================================
function Dz-DocF {
    $d = Dz-Doc -PadL 48 -PadT 26
    Dz-Measure -Doc $d -Chars 68 -Size 16 -PadL 48
    $pendingRun = 0
    foreach ($t in $script:dzTurns) {
        if ($t.Kind -eq 'run') { $pendingRun += @($t.Calls).Count; continue }
        if ($t.Kind -eq 'thinking') { continue }
        $who = 'claude'; $hue = $dzC.In; $fg = $Pal.TextHigh
        if ($t.Kind -eq 'you') { $who = 'you'; $hue = $dzC.Out; $fg = $Pal.TextMax }
        Dz-Rule -Doc $d -Brush $dzHair -Top 26 -Bottom 0
        $lab = New-Object System.Windows.Documents.Paragraph
        $lab.Margin = New-Object System.Windows.Thickness 0, 12, 0, 9
        $lab.Inlines.Add((New-ReadRun -Text (Dz-Track $who.ToUpper()) -Brush $hue -Size 10 -Weight 'SemiBold'))
        if ($pendingRun -gt 0) {
            $lab.Inlines.Add((New-ReadRun -Text ('          ' + $pendingRun + ' steps hidden') -Brush $Pal.TextLow -Size 10.5))
            $pendingRun = 0
        }
        $d.Blocks.Add($lab)
        $s = Dz-Sub
        Dz-Prose -Doc $s -Text $t.Body -Brush $fg -Size 16 -Line 29 -CodeBg $dzGlassLo -CodeRadius 10
        Dz-Move $s $d
    }
    return $d
}

# ===========================================================================
# THE QUESTION PANEL. Six treatments of the one element the operator singled
# out - and none of them is a white bar down the left side.
# ===========================================================================
function Dz-Option {
    param([int]$N, [string]$Label, [string]$Detail, $Bg, $Stroke, [double]$Radius = 10,
          [switch]$Badge, [switch]$Mono, [switch]$Lead)
    $bd = New-Object System.Windows.Controls.Border
    $bd.Background = $Bg
    if ($Stroke) { $bd.BorderBrush = $Stroke; $bd.BorderThickness = New-Object System.Windows.Thickness 1 }
    $bd.CornerRadius = New-Object System.Windows.CornerRadius $Radius
    $bd.Padding = New-Object System.Windows.Thickness 14, 10, 14, 11
    $bd.Margin = New-Object System.Windows.Thickness 0, 0, 0, 7
    $g = New-Object System.Windows.Controls.Grid
    $c0 = New-Object System.Windows.Controls.ColumnDefinition
    $c0.Width = New-Object System.Windows.GridLength 0, 'Auto'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1)
    if ($Badge) {
        $b = New-Object System.Windows.Controls.Border
        $b.Width = 22; $b.Height = 22
        $b.CornerRadius = New-Object System.Windows.CornerRadius 11
        $b.Background = $dzWash.Ask
        $b.VerticalAlignment = 'Top'
        $b.Margin = New-Object System.Windows.Thickness 0, 1, 12, 0
        $bt = Dz-Text -S "$N" -Brush $dzC.Ask -Size 11.5 -Semi
        $bt.HorizontalAlignment = 'Center'; $bt.VerticalAlignment = 'Center'
        $b.Child = $bt
        [System.Windows.Controls.Grid]::SetColumn($b, 0)
        $null = $g.Children.Add($b)
    }
    $st = New-Object System.Windows.Controls.StackPanel
    [System.Windows.Controls.Grid]::SetColumn($st, 1)
    $head = "$Label"
    if (-not $Badge) { $head = ('{0}.   {1}' -f $N, $Label) }
    $lt = Dz-Text -S $head -Brush $Pal.TextMax -Size 13.5 -Semi -Wrap
    if ($Mono) { $lt.FontFamily = $script:MonoFace; $lt.FontSize = 12.5 }
    if ($Lead) { $lt.Foreground = $dzC.Ask }
    $null = $st.Children.Add($lt)
    if ($Detail) {
        $dt = Dz-Text -S $Detail -Brush $Pal.TextMid -Size 12 -Wrap -Line 18
        $dt.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
        $null = $st.Children.Add($dt)
    }
    $null = $g.Children.Add($st)
    $bd.Child = $g
    return $bd
}

function Dz-Ask { param([string]$V)
    $box = $ui.AskBox
    $box.BorderThickness = New-Object System.Windows.Thickness 0
    $box.BorderBrush = $null
    $box.Effect = $null
    $box.Margin = New-Object System.Windows.Thickness 14, 0, 14, 14
    $box.Padding = New-Object System.Windows.Thickness 20, 16, 20, 16
    $box.CornerRadius = New-Object System.Windows.CornerRadius 14
    $box.Background = $dzGlassLo

    $ui.AskHeader.Foreground = $dzC.Ask
    $ui.AskHeader.FontSize = 10
    $ui.AskHeader.Text = Dz-Track 'IT IS ASKING'
    $ui.AskText.Foreground = $Pal.TextMax
    $ui.AskText.FontSize = 15.5
    $ui.AskText.FontWeight = $FW_Semi
    $ui.AskText.Text = "$($dzQ.Question)"
    $ui.AskFooter.Text = "$($dzQ.Footer)"
    $ui.AskFooter.Foreground = $Pal.TextLow
    $ui.AskFooter.Visibility = $V_Show
    $ui.AskNote.Visibility = $V_Hide

    $obg = $dzGlassMid; $ostroke = $null; $orad = 10.0
    $badge = $false; $mono = $false

    switch ($V) {
        'A' {
            $box.Background = $dzFilm.Ask
            $obg = $dzGlassLo; $ostroke = $dzHair; $orad = 10.0
        }
        'B' {
            $box.Background = $window.FindResource('Sheet')
            $box.BorderBrush = $dzEdge.Ask
            $box.BorderThickness = New-Object System.Windows.Thickness 1
            $sh = New-Object System.Windows.Media.Effects.DropShadowEffect
            $sh.BlurRadius = 34; $sh.ShadowDepth = 8; $sh.Opacity = 0.6
            $sh.Color = [System.Windows.Media.Colors]::Black
            $box.Effect = $sh
            $obg = $dzGlassMid; $orad = 10.0
        }
        'C' {
            $box.Background = $dzWash.Ask
            $box.CornerRadius = New-Object System.Windows.CornerRadius 14
            $obg = $dzSunk; $ostroke = $dzEdge.Ask; $orad = 10.0
        }
        'D' {
            $box.Background = $dzGlassLo
            $box.Padding = New-Object System.Windows.Thickness 24, 20, 24, 20
            $obg = $dzGlassMid; $orad = 12.0; $badge = $true
            $ui.AskText.FontSize = 17
        }
        'E' {
            $box.Background = $dzSunk
            $box.CornerRadius = New-Object System.Windows.CornerRadius 8
            $box.BorderBrush = $dzC.Ask
            $box.BorderThickness = New-Object System.Windows.Thickness 0, 2, 0, 0
            $ui.AskHeader.Text = Dz-Track 'IT IS ASKING'
            $obg = $dzGlassLo; $ostroke = $dzHair; $orad = 6.0; $mono = $true
        }
        'F' {
            $box.Background = $window.FindResource('Sheet')
            $box.CornerRadius = New-Object System.Windows.CornerRadius 18
            $box.Padding = New-Object System.Windows.Thickness 24, 20, 24, 20
            $sh = New-Object System.Windows.Media.Effects.DropShadowEffect
            $sh.BlurRadius = 48; $sh.ShadowDepth = 12; $sh.Opacity = 0.7
            $sh.Color = [System.Windows.Media.Colors]::Black
            $box.Effect = $sh
            $obg = $null; $ostroke = $dzHair; $orad = 12.0
        }
    }

    $list = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($o in @($dzQ.Options)) {
        $det = ''
        if ($n -lt @($dzQ.Details).Count) { $det = "$(@($dzQ.Details)[$n])" }
        $lead = ($n -eq 0)
        $list.Add((Dz-Option -N ($n + 1) -Label "$o" -Detail $det -Bg $obg -Stroke $ostroke -Radius $orad -Badge:$badge -Mono:$mono -Lead:$lead))
        $n++
    }
    $ui.AskOptions.ItemsSource = $list
    $ui.AskBox.Visibility = $V_Show
}

# ===========================================================================
# DRAWING
# ===========================================================================
function Dz-Arrange {
    $root = $window.Content
    foreach ($pass in 1, 2) {
        $root.Measure((New-Object System.Windows.Size $dzW, $dzH))
        $root.Arrange((New-Object System.Windows.Rect 0, 0, $dzW, $dzH))
        $root.UpdateLayout()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})
    }
}

# 🪤 THE TOP OF A TAIL IS NOT A REPRESENTATIVE SLICE. The first block in a
# tailed transcript is whatever the cut landed in the middle of - here a fenced
# block - so all six shots opened on a wall of monospace and said nothing about
# how prose, speaker labels or tool runs are treated. Scrolled to a fraction of
# the extent instead, the same fraction in every variant so the comparison is
# still like for like.
function Dz-ScrollTo { param([double]$Frac)
    $sv = Get-PaneScroller
    if (-not $sv) { return }
    if ($sv.ScrollableHeight -le 0) { return }
    $sv.ScrollToVerticalOffset($sv.ScrollableHeight * $Frac)
}

function Dz-Shot { param([string]$Path)
    $root = $window.Content
    Dz-Arrange
    $script:paneScroller = $null
    Dz-ScrollTo $script:dzScroll
    Dz-Arrange
    $mL = 0.0; $mT = 0.0
    if ($root -is [System.Windows.FrameworkElement]) { $mL = $root.Margin.Left; $mT = $root.Margin.Top }
    $content = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$dzW, [int]$dzH, 96, 96,
            [System.Windows.Media.PixelFormats]::Pbgra32)
    $content.Render($root)
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    try {
        $ground = $window.Background
        if (-not $ground) { $ground = [System.Windows.Media.Brushes]::Black }
        $dc.DrawRectangle($ground, $null, (New-Object System.Windows.Rect 0, 0, $dzW, $dzH))
        $dc.DrawImage($content, (New-Object System.Windows.Rect $mL, $mT, $dzW, $dzH))
    } finally { $dc.Close() }
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$dzW, [int]$dzH, 96, 96,
            [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [System.IO.File]::Create($Path)
    try { $enc.Save($fs) } finally { $fs.Dispose() }
}

$window.Width = $dzW; $window.Height = $dzH
Dz-Arrange
$script:dzPaneW = $ui.PaneDoc.ActualWidth
if ($script:dzPaneW -lt 200) { $script:dzPaneW = 900.0 }
Write-Host ("  pane   {0}px" -f [int]$script:dzPaneW)

$script:dzTurns = Dz-Turns $dzBlocks
Write-Host ("  turns  {0}" -f @($script:dzTurns).Count)

$script:dzScroll = 0.34
if ($env:SR_DESIGN_SCROLL) { $script:dzScroll = [double]$env:SR_DESIGN_SCROLL }

$dzVit = Dz-Vitals -JsonlPath $dzJsonl -Row $dzPick[0].Row
Write-Host ("  vitals model={0} ctx={1}/{2} branch={3} shells={4} agents={5} remote={6} diff=+{7}/-{8} effort={9} mode={10}" -f `
    $dzVit.Model, $dzVit.Tokens, $dzVit.Window, $dzVit.Branch, $dzVit.Shells, $dzVit.Agents, $dzVit.Remote,
    $dzVit.Added, $dzVit.Removed, $dzVit.Effort, $dzVit.Mode)

# The rail is rebuilt so the brighter project accents are in every shot.
Build-Rail

$dzPlan = @(
    @{ Key = 'A'; Name = 'quiet-document'; Chips = 'glass';   Doc = { Dz-DocA } },
    @{ Key = 'B'; Name = 'turn-cards';     Chips = 'pill';    Doc = { Dz-DocB } },
    @{ Key = 'C'; Name = 'timeline';       Chips = 'outline'; Doc = { Dz-DocC } },
    @{ Key = 'D'; Name = 'editorial';      Chips = 'glass';   Doc = { Dz-DocD } },
    @{ Key = 'E'; Name = 'console';        Chips = 'flat';    Doc = { Dz-DocE } },
    @{ Key = 'F'; Name = 'minimal-air';    Chips = 'outline'; Doc = { Dz-DocF } }
)

$dzFail = 0
foreach ($dzV in $dzPlan) {
    if ($env:SR_DESIGN_ONLY -and $env:SR_DESIGN_ONLY -ne $dzV.Key) { continue }
    $path = Join-Path $dzOut ('{0}-{1}.png' -f $dzV.Key, $dzV.Name)
    try {
        $doc = & $dzV.Doc
        $ui.PaneDoc.Document = $doc
        $ui.PaneEmpty.Visibility = $V_Hide
        Dz-BuildChips -V $dzVit -Style $dzV.Chips
        Dz-Ask -V $dzV.Key
        Dz-Shot -Path $path
        Write-Host ("  ok     {0}  {1}" -f $dzV.Key, $path)
    } catch {
        $dzFail++
        Write-Host ("  FAIL   {0}  {1}" -f $dzV.Key, $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host ''
if ($dzFail) { Write-Host ("{0} variant(s) failed to draw" -f $dzFail) -ForegroundColor Red; exit 1 }
Write-Host ("drew {0} into {1}" -f @($dzPlan).Count, $dzOut) -ForegroundColor Green
exit 0
