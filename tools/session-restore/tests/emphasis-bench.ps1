#requires -Version 5.1
<#
 ==============================================================================
  THE INLINE-EMPHASIS PATTERN, TIMED AND THEN PROVOKED.

  Add-ReadProse runs this matcher on EVERY line of EVERY prose turn, so a
  pattern change here is a change to the cost of building the whole document.
  Convert-SRSpoken's guard cost 2.36x the day it started matching things it did
  not need to; this measures before, not after.

  Three variants:
    CURRENT      what ships:  `code` | **bold**            (bold refuses any * inside)
    REPLACEMENT  proposed:    `code` | **bold** | *italic* (bold lazy, italic guarded)
    GUARDED      the replacement behind an IndexOf gate, the same shape as the
                 '<' gate Convert-SRSpoken already uses

  Then the awkward lines, run through both, printing what each one actually
  emits - because a pattern that is fast and wrong is worse than the one it
  replaces.
 ==============================================================================
#>
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$lib  = Join-Path (Split-Path -Parent $here) 'lib'
. (Join-Path $lib '_common.ps1')
function ESay { param([string]$T) Write-Host $T }

$RX_CUR = '^(.*?)(`([^`]+)`|\*\*([^*]+)\*\*)(.*)$'
$RX_NEW = '^(.*?)(`([^`]+)`|\*\*(.+?)\*\*|\*([^*\s][^*]*)\*)(.*)$'
# 🔴 THE FLANKING RULE, because the bare version turns 2*3*4 into 2<i>3</i>4.
# An italic delimiter may not sit against an alphanumeric on its outer side -
# which is markdown's own left/right-flanking rule, reduced to the part that
# matters here.
$RX_TIGHT = '^(.*?)(`([^`]+)`|\*\*(.+?)\*\*|(?<![A-Za-z0-9])\*([^*\s][^*]*?)\*(?![A-Za-z0-9]))(.*)$'

# Faithful copies of Add-ReadProse's loop - the cost is the LOOP, not one match,
# and the loop re-runs the pattern on the remainder after every hit.
function Invoke-Cur { param([string]$Line)
    $n = 0; $rest = $Line
    while ($rest -match $script:RX_CUR) {
        $null = $Matches[1]; $null = $Matches[3]; $null = $Matches[4]; $rest = $Matches[5]
        $n++; if ($n -gt 64) { break }
    }
    return $n
}
function Invoke-New { param([string]$Line)
    $n = 0; $rest = $Line
    while ($rest -match $script:RX_NEW) {
        $null = $Matches[1]; $null = $Matches[3]; $null = $Matches[4]; $null = $Matches[5]; $rest = $Matches[6]
        $n++; if ($n -gt 64) { break }
    }
    return $n
}
function Invoke-Tight { param([string]$Line)
    $n = 0; $rest = $Line
    while ($rest -match $script:RX_TIGHT) {
        $null = $Matches[1]; $null = $Matches[3]; $null = $Matches[4]; $null = $Matches[5]; $rest = $Matches[6]
        $n++; if ($n -gt 64) { break }
    }
    return $n
}
# 🪤 THE GUARD IS INLINE, NOT A WRAPPER. The first version of this delegated to
# Invoke-New and measured the guard as 1.34x SLOWER than the thing it guards -
# which is a PowerShell function call per line, not a property of the guard. In
# Add-ReadProse the gate sits in the same scope as the loop, so it is measured
# that way here. (Measuring the observer: CONTEXT.md records this shape.)
function Invoke-Guarded { param([string]$Line)
    if ($Line.IndexOf('*', [System.StringComparison]::Ordinal) -lt 0 -and
        $Line.IndexOf('`', [System.StringComparison]::Ordinal) -lt 0) { return 0 }
    $n = 0; $rest = $Line
    while ($rest -match $script:RX_TIGHT) {
        $null = $Matches[1]; $null = $Matches[3]; $null = $Matches[4]; $null = $Matches[5]; $rest = $Matches[6]
        $n++; if ($n -gt 64) { break }
    }
    return $n
}

# ---- real prose, off a real transcript --------------------------------------
$projRoot = Join-Path $env:USERPROFILE '.claude\projects'
$js = $env:SR_EB_JSONL
if (-not $js) {
    $js = @(Get-ChildItem -LiteralPath $projRoot -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending | Select-Object -First 1 -ExpandProperty FullName)[0]
}
# A FEW THOUSAND LINES, ACROSS PROJECTS. One transcript gave 340, which is
# too few to separate 1.1x from noise and too narrow to be representative of
# how much of the operator's prose carries emphasis at all.
$pool = @(Get-ChildItem -LiteralPath $projRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Get-ChildItem -LiteralPath $_.FullName -Filter *.jsonl -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | Select-Object -First 1
} | Sort-Object Length -Descending | Select-Object -First 14 -ExpandProperty FullName)
if ($env:SR_EB_JSONL) { $pool = @($env:SR_EB_JSONL) }
$lines = New-Object System.Collections.Generic.List[string]
$nBlocks = 0; $nFiles = 0
foreach ($f in $pool) {
    $blocks = @()
    try { $got = Get-SRTranscriptBlocks -JsonlPath $f -MaxRecords 4000 -MaxTailBytes 524288; $blocks = @($got) } catch { continue }
    if (-not $blocks.Count) { continue }
    $nFiles++
    foreach ($b in $blocks) {
        $k = "$($b.Kind)"
        if ($k -ne 'said' -and $k -ne 'you' -and $k -ne 'msgin') { continue }
        $nBlocks++
        foreach ($ln in (("$($b.Body)" -replace "`r", '') -split "`n")) { $lines.Add($ln) }
    }
    if ($lines.Count -gt 6000) { break }
}
ESay ("{0} transcript(s), {1} prose block(s), {2} prose line(s)" -f $nFiles, $nBlocks, $lines.Count)
if ($lines.Count -lt 200) { ESay 'FAIL  not enough prose to time anything'; exit 1 }

$noMark = 0
foreach ($l in $lines) { if ($l.IndexOf('*') -lt 0 -and $l.IndexOf('`') -lt 0) { $noMark++ } }
ESay ("{0} of {1} lines ({2:N1}%) contain neither an asterisk nor a backtick - the guard's whole case" -f `
    $noMark, $lines.Count, (100.0 * $noMark / $lines.Count))

# ---- timing -----------------------------------------------------------------
# 🔴 INTERLEAVED, AND A WARM PASS FIRST. Sequential runs on this machine have
# produced an impossible result before (see the IsOptimalParagraphEnabled note
# in lib\), so each variant is timed in every round and the MEDIAN is reported
# rather than one run's number.
$null = Invoke-Cur 'warm `up` and **bold**'
$null = Invoke-New 'warm `up` and **bold** and *ital*'
$rounds = 5
$t = @{ CURRENT = New-Object System.Collections.Generic.List[double]
        REPLACEMENT = New-Object System.Collections.Generic.List[double]
        TIGHTENED = New-Object System.Collections.Generic.List[double]
        GUARDED = New-Object System.Collections.Generic.List[double] }
foreach ($r in 1..$rounds) {
    foreach ($v in @('CURRENT', 'REPLACEMENT', 'TIGHTENED', 'GUARDED')) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        foreach ($l in $lines) {
            switch ($v) {
                'CURRENT'     { $null = Invoke-Cur $l }
                'REPLACEMENT' { $null = Invoke-New $l }
                'TIGHTENED'   { $null = Invoke-Tight $l }
                'GUARDED'     { $null = Invoke-Guarded $l }
            }
        }
        $sw.Stop()
        $t[$v].Add($sw.Elapsed.TotalMilliseconds)
    }
}
function Med { param($L) $a = @($L | Sort-Object); return $a[[int]($a.Count / 2)] }
ESay ''
ESay ("=== cost over {0} real prose lines, median of {1} interleaved rounds ===" -f $lines.Count, $rounds)
ESay ('{0,-14} {1,12} {2,14} {3,12}' -f 'VARIANT', 'total ms', 'per line us', 'vs CURRENT')
ESay ('-' * 56)
$base = Med $t['CURRENT']
foreach ($v in @('CURRENT', 'REPLACEMENT', 'TIGHTENED', 'GUARDED')) {
    $m = Med $t[$v]
    ESay ('{0,-14} {1,12:N2} {2,14:N3} {3,12}' -f $v, $m, (1000.0 * $m / $lines.Count),
        $(if ($v -eq 'CURRENT') { '-' } else { ('{0:N2}x' -f ($m / $base)) }))
}
ESay ''
foreach ($v in @('REPLACEMENT', 'TIGHTENED', 'GUARDED')) {
    $d = (Med $t[$v]) - $base
    ESay ('   {0,-12} {1,8:N2} ms difference over the same {2} lines' -f $v, $d, $lines.Count)
}

# ---- what each pattern actually emits ---------------------------------------
function Segment { param([string]$Line, [string]$Rx, [switch]$New)
    $out = New-Object System.Collections.Generic.List[string]
    $rest = $Line; $n = 0
    while ($rest -match $Rx) {
        $n++; if ($n -gt 32) { $out.Add('<<runaway>>'); break }
        $before = $Matches[1]
        if ($New) { $code = $Matches[3]; $bold = $Matches[4]; $ital = $Matches[5]; $rest = $Matches[6] }
        else      { $code = $Matches[3]; $bold = $Matches[4]; $ital = $null;       $rest = $Matches[5] }
        if ($before) { $out.Add('txt[' + $before + ']') }
        if ($code)   { $out.Add('CODE[' + $code + ']') }
        elseif ($bold) { $out.Add('BOLD[' + $bold + ']') }
        elseif ($ital) { $out.Add('ITAL[' + $ital + ']') }
    }
    if ($rest) { $out.Add('txt[' + $rest + ']') }
    return ($out -join ' ')
}

$cases = @(
    @('2 * 3',                                   'bare asterisk with spaces - multiplication'),
    @('2*3*4',                                   'bare asterisks with NO spaces'),
    @('a line ending in a bare *',               'trailing lone asterisk'),
    @('**bold** and *italic* in one line',       'both forms on one line'),
    @('this is *unclosed and carries on',        'unclosed italic'),
    @('***',                                     'three asterisks alone'),
    @('****',                                    'four asterisks alone'),
    @('**Then the tick prompt opened with *"keep this tick CHEAP."* A `git grep` is 3 seconds.**', 'the real line from the render - bold containing italic AND code'),
    @('the line read *compliant* at 7%',         'the other real line from the render'),
    @('a * b * c',                               'two spaced asterisks'),
    @('* a list item that reached this loop',    'a bullet that was NOT consumed earlier'),
    @('`code` then **bold** then *ital*',        'all three in order'),
    @('nothing special here at all',             'the common case - no marks'),
    @('an *italic* with `code` inside *it*',     'interleaved'),
    @('5 * 4 = 20 and 6 * 3 = 18',               'two multiplications, four asterisks')
)
ESay ''
ESay '=== what each pattern emits for the awkward lines ======================'
$diff = 0
foreach ($c in $cases) {
    $a = Segment -Line $c[0] -Rx $RX_CUR
    $b = Segment -Line $c[0] -Rx $RX_NEW -New
    $c2 = Segment -Line $c[0] -Rx $RX_TIGHT -New
    $same = ($a -eq $b)
    if (-not $same) { $diff++ }
    ESay ''
    ESay ('  LINE       ' + $c[0])
    ESay ('  why        ' + $c[1])
    ESay ('  CURRENT    ' + $a)
    ESay ('  LOOSE      ' + $b + $(if ($same) { '   (unchanged)' } else { '   <-- CHANGED' }))
    ESay ('  TIGHTENED  ' + $c2 + $(if ($c2 -eq $b) { '' } else { '   <-- and differs from LOOSE' }))
}
ESay ''
ESay ("{0} of {1} awkward lines render differently under the replacement" -f $diff, $cases.Count)
exit 0
