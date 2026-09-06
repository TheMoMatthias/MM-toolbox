#requires -Version 5.1
<#
    WHO WROTE THIS RECORD - CHECKED AGAINST THE REAL TRANSCRIPTS, NOT 8 FIXTURES.

    New-SRUserBlock now classifies a machine-authored `user` record as `system`
    instead of `you`. The unit tests prove the classifier does what its author
    meant. They cannot prove what it does to the operator's actual traffic,
    because they contain none of it.

    Two questions, and they are NOT symmetric:

      FALSE NEGATIVE  a `you` block that is really machinery. Cosmetic: the
                      wrong marker on something the operator can still read.

      FALSE POSITIVE  a `system` block that is really the operator's typing.
                      DESTRUCTIVE: a notice folds, and with Steps set to hidden
                      his own words are gone from the pane. This is the one the
                      sweep exists for.

    NOTHING HERE WRITES. It opens transcripts with FileShare ReadWrite (a live
    session holds them open) and never touches the registry or the config -
    both are redirected to throwaway copies anyway, and both are hashed either
    side so the claim is checked rather than asserted.
#>
[CmdletBinding()]
param(
    # 0 = every project directory. A number samples the most recently written.
    [int]$MaxFiles = 0,
    # Per transcript. The pane's own default is 2 MB; this reads more so the
    # sweep sees more than the last screenful.
    [int]$TailBytes = 4194304,
    [int]$MaxRecords = 4000,
    # Print every distinct `system` block in full rather than one example per
    # shape. This is the false-positive review.
    [switch]$ShowAllSystem
)

$ErrorActionPreference = 'Stop'

$zzHere = $PSScriptRoot
if (-not $zzHere) { $zzHere = Split-Path -Parent $MyInvocation.MyCommand.Path }
$zzTool = Split-Path -Parent $zzHere
$zzLib  = Join-Path $zzTool 'lib'

$here = $zzLib
. (Join-Path $zzLib '_common.ps1')

$fails = 0
$unsure = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }
function Inconclusive { param($m) Write-Host "  ????  $m" -ForegroundColor Magenta; $script:unsure++ }

# ===========================================================================
# THE SANDBOX. Nothing below calls a writer, and that is worth exactly as much
# as the guard behind it.
# ===========================================================================
$zzLiveCfg = Join-Path $zzTool 'session-restore.config.json'
$zzLiveReg = Join-Path $zzTool 'sessions-registry.json'
$zzCfgWas = (Get-FileHash -LiteralPath $zzLiveCfg -Algorithm SHA256).Hash
$zzRegWas = ''
try { $zzRegWas = (Get-FileHash -LiteralPath $zzLiveReg -Algorithm SHA256).Hash } catch { }

$zzState = Join-Path $zzTool '.state'
$zzCfgCopy = Join-Path $zzState 'audit-user-config.json'
Copy-Item -LiteralPath $zzLiveCfg -Destination $zzCfgCopy -Force -ErrorAction Stop
$SR_ConfigPath = $zzCfgCopy
# PROVEN, not asserted: one real write through the real writer, on a key that
# is not already there and a value nothing else could produce.
$zzProbeWas = (Get-FileHash -LiteralPath $zzCfgCopy -Algorithm SHA256).Hash
Save-SRConfigLater -Name 'auditUserSweepProbe' -Value ([guid]::NewGuid().ToString('N'))
$null = Save-SRConfigWrites
if ((Get-FileHash -LiteralPath $zzCfgCopy -Algorithm SHA256).Hash -eq $zzProbeWas) {
    Fail 'a config write through the real writer did NOT land in the redirected copy - the redirect is not armed. Refusing to run.'
    exit 1
}
if ((Get-FileHash -LiteralPath $zzLiveCfg -Algorithm SHA256).Hash -ne $zzCfgWas) {
    Fail 'the LIVE config moved during the arming write. Refusing to run.'
    exit 1
}
Note 'config redirected to .state\audit-user-config.json and proven to land there; the live file did not move'

# ===========================================================================
# CALIBRATION. A classifier that has never been shown to answer BOTH ways on
# this machine, in this process, is an instrument nobody has checked.
# ===========================================================================
Write-Host ''
Write-Host '--- calibrating the classifier (it must go both ways) ---'
$zzCal = @(
    @{ N = 'plain typing';              T = 'have a look at the rail please';                                   Want = 'you' }
    @{ N = 'typing with a bracket';     T = 'the value is a[0] and it is wrong';                                Want = 'you' }
    @{ N = 'typing with an angle';      T = 'if (x < y) { fix it }';                                            Want = 'you' }
    @{ N = 'a bare task-notification';  T = "<task-notification>`nBash exit code 0`n</task-notification>";      Want = 'system' }
    @{ N = 'a bare system-reminder';    T = '<system-reminder>context follows</system-reminder>';               Want = 'system' }
    @{ N = 'an idle notice';            T = '[Cross-session idle notice] nothing has happened for a while';     Want = 'system' }
    @{ N = 'an interrupt line';         T = '[Request interrupted by user for tool use]';                       Want = 'system' }
    @{ N = 'HIS WORDS + a reminder';    T = "look at the rail`n<system-reminder>ignore this</system-reminder>"; Want = 'you' }
    @{ N = 'a reminder + HIS WORDS';    T = "<system-reminder>x</system-reminder>`nlook at the rail";           Want = 'you' }
    @{ N = 'two reminders + his words'; T = "<system-reminder>a</system-reminder> keep going <system-reminder>b</system-reminder>"; Want = 'you' }
)
# 🔴 THROUGH THE REAL PARSER, NOT THE CLASSIFIER ALONE - AND NOT BY CHOICE.
# New-SRUserBlock calls New-Block, which is a function defined INSIDE
# Get-SRTranscriptBlocks. It is therefore not callable on its own at all: a
# unit test that reaches it has had to build a shim, and a shim is a second
# implementation of the thing under test. So the calibration writes real jsonl
# records and reads them back through the shipped parser, which is also the
# only path the pane ever uses.
$zzTmp = Join-Path ([System.IO.Path]::GetTempPath()) ('sr-audit-user-' + [guid]::NewGuid().ToString('N'))
$zzCalBad = 0
try {
    $null = New-Item -ItemType Directory -Path $zzTmp -Force
    $zzCalFile = Join-Path $zzTmp 'calib.jsonl'
    $zzLines = New-Object System.Collections.Generic.List[string]
    foreach ($zzC in $zzCal) {
        $null = $zzLines.Add((@{
            type = 'user'
            timestamp = (Get-Date).ToUniversalTime().ToString('o')
            message = @{ role = 'user'; content = $zzC.T }
        } | ConvertTo-Json -Depth 6 -Compress))
    }
    [System.IO.File]::WriteAllLines($zzCalFile, $zzLines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    $zzCalGot = Get-SRTranscriptBlocks -JsonlPath $zzCalFile -MaxRecords 500 -MaxTailBytes 4194304
    $zzCalArr = @($zzCalGot)
    if ($zzCalArr.Count -ne $zzCal.Count) {
        Fail ('the parser returned {0} block(s) for {1} calibration record(s) - the calibration cannot be aligned' -f $zzCalArr.Count, $zzCal.Count)
        exit 1
    }
    for ($zzI = 0; $zzI -lt $zzCal.Count; $zzI++) {
        if ("$($zzCalArr[$zzI].Kind)" -ne $zzCal[$zzI].Want) {
            Fail ("calibration: '{0}' classified as {1}, expected {2}" -f $zzCal[$zzI].N, $zzCalArr[$zzI].Kind, $zzCal[$zzI].Want)
            $zzCalBad++
        }
    }
    if (-not $zzCalBad) {
        Pass ('the parser answered all {0} calibration cases correctly - it demonstrably reaches BOTH verdicts in this process' -f $zzCal.Count)
    }
    # And it must be able to go red. If a deliberately wrong expectation passes,
    # the harness is not reading the answer at all.
    if ("$($zzCalArr[0].Kind)" -ne 'you') {
        Fail 'the RED calibration failed - plain typing was called machinery. Everything below is meaningless.'
        exit 1
    }
    Note 'red check: plain typing came back as "you", so a "system" verdict below is a real verdict and not a stuck instrument'
} finally {
    try { Remove-Item -LiteralPath $zzTmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# ===========================================================================
# THE SWEEP
# ===========================================================================
Write-Host ''
Write-Host '--- sweeping the real transcripts ---'
if (-not (Test-Path -LiteralPath $SR_Projects)) {
    Inconclusive ("no project directory at {0} - nothing to sweep" -f $SR_Projects)
    exit 2
}
$zzFiles = @(Get-ChildItem -LiteralPath $SR_Projects -Directory -ErrorAction SilentlyContinue |
             ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue } |
             Sort-Object LastWriteTime -Descending)
if ($MaxFiles -gt 0) { $zzFiles = @($zzFiles | Select-Object -First $MaxFiles) }
if (-not $zzFiles.Count) { Inconclusive 'no transcripts found'; exit 2 }
Note ('{0} transcript(s), {1:N0} MB total on disk; reading the last {2:N0} KB of each' -f `
      $zzFiles.Count, (($zzFiles | Measure-Object -Property Length -Sum).Sum / 1MB), ($TailBytes / 1KB))

$zzYou = New-Object System.Collections.Generic.List[object]
$zzSys = New-Object System.Collections.Generic.List[object]
$zzMsg = 0
$zzRecSys = 0
$zzBlocks = 0
$zzRead = 0
$zzBroke = 0
$zzSw = [Diagnostics.Stopwatch]::StartNew()
foreach ($zzF in $zzFiles) {
    $zzGot = $null
    try {
        # Assign, THEN wrap - the function ends in a comma guard.
        $zzGot = Get-SRTranscriptBlocks -JsonlPath $zzF.FullName -MaxRecords $MaxRecords -MaxTailBytes $TailBytes
    } catch { $zzBroke++; continue }
    $zzArr = @($zzGot)
    $zzRead++
    foreach ($zzB in $zzArr) {
        $zzBlocks++
        switch ("$($zzB.Kind)") {
            'you'    { $null = $zzYou.Add([PSCustomObject]@{ File = $zzF.Name; Text = "$($zzB.Body)" }) }
            # 🔴 TWO DIFFERENT THINGS SHARE THE KIND 'system', AND CONFLATING
            # THEM MADE THIS SWEEP REPORT 251 FALSE POSITIVES THAT WERE NOT
            # USER RECORDS AT ALL. Get-SRTranscriptBlocks emits 'system' for a
            # Claude Code system RECORD (subtype away_summary, informational,
            # local_command, a stop-hook summary - "lane position 31,1s" is one
            # of those) as well as for a user record New-SRUserBlock has
            # reclassified. The record kind always carries a Head - the subtype,
            # or the literal 'hooks'; the reclassified user record is built with
            # Head = '' and is the ONLY one of the two this audit is about.
            'system' {
                if ("$($zzB.Head)") { $zzRecSys++ }
                else { $null = $zzSys.Add([PSCustomObject]@{ File = $zzF.Name; Text = "$($zzB.Body)"; Head = '' }) }
            }
            'msgin'  { $zzMsg++ }
            default  { }
        }
    }
}
$zzSw.Stop()
Note ('{0} transcript(s) parsed in {1:N1} s ({2} unreadable), {3:N0} blocks' -f $zzRead, $zzSw.Elapsed.TotalSeconds, $zzBroke, $zzBlocks)
Note ('blocks built by New-SRUserBlock: {0:N0} "you", {1:N0} reclassified to "system", {2:N0} "msgin"' -f $zzYou.Count, $zzSys.Count, $zzMsg)
Note ('(and {0:N0} "system" blocks came from Claude Code system RECORDS, which this fix never touched)' -f $zzRecSys)

# ---------------------------------------------------------------------------
# A SHAPE, not a guess. The leading token of a user record is what separates
# machinery from typing in every case the classifier was written for, so the
# histogram is the finding rather than a summary of it.
# ---------------------------------------------------------------------------
function Get-Shape { param([string]$T)
    $s = "$T".TrimStart()
    if (-not $s) { return '(empty)' }
    if ($s.StartsWith('<', [StringComparison]::Ordinal)) {
        $m = [regex]::Match($s, '^<\s*/?\s*([A-Za-z][\w:-]*)')
        if ($m.Success) { return ('<{0}>' -f $m.Groups[1].Value) }
        return '<?>'
    }
    if ($s.StartsWith('[', [StringComparison]::Ordinal)) {
        $m = [regex]::Match($s, '^\[([^\]]{0,40})\]')
        if ($m.Success) { return ('[{0}]' -f $m.Groups[1].Value) }
        return '[?]'
    }
    if ($s.StartsWith('Caveat:', [StringComparison]::Ordinal)) { return 'Caveat:' }
    return 'PLAIN TEXT'
}

Write-Host ''
Write-Host '--- what the pane still draws in the operator''s voice ("you") ---'
$zzShapes = @{}
$zzEx = @{}
foreach ($zzY in $zzYou) {
    $zzS = Get-Shape $zzY.Text
    if (-not $zzShapes.ContainsKey($zzS)) { $zzShapes[$zzS] = 0; $zzEx[$zzS] = $zzY }
    $zzShapes[$zzS] = $zzShapes[$zzS] + 1
}
foreach ($zzS in @($zzShapes.Keys | Sort-Object { -$zzShapes[$_] })) {
    $zzOne = "$($zzEx[$zzS].Text)" -replace '\s+', ' '
    if ($zzOne.Length -gt 110) { $zzOne = $zzOne.Substring(0, 110) + '...' }
    $zzMark = $(if ($zzS -eq 'PLAIN TEXT') { '   ' } else { '>> ' })
    Write-Host ("  {0}{1,-34} {2,6}   {3}" -f $zzMark, $zzS, $zzShapes[$zzS], $zzOne)
}
$zzSuspect = 0
foreach ($zzS in $zzShapes.Keys) { if ($zzS -ne 'PLAIN TEXT') { $zzSuspect += $zzShapes[$zzS] } }
Note ('{0:N0} of {1:N0} "you" blocks do not begin with plain prose - the >> rows are the false-negative candidates' -f $zzSuspect, $zzYou.Count)

# 🔴 AND THE SHAPE TEST IS NOT ENOUGH ON ITS OWN. Every regex in the classifier
# is anchored at the START of the record - SR_RxMsgIn is '^\s*<...>' and the
# envelope strip only ever clears whole wrappers - so a machine envelope with
# ANY prose in front of it is invisible to all of them and lands in the
# operator's voice. That is not a hypothetical: this is how a routed message
# announced with a sentence gets drawn as YOU SAID.
$zzInner = @{}
$zzInnerEx = @{}
foreach ($zzY in $zzYou) {
    foreach ($zzT in @('cross-session-message', 'teammate-message', 'task-notification',
                       'system-reminder', 'local-command-caveat', 'agent-message')) {
        if ("$($zzY.Text)".IndexOf('<' + $zzT, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            if (-not $zzInner.ContainsKey($zzT)) { $zzInner[$zzT] = 0; $zzInnerEx[$zzT] = $zzY }
            $zzInner[$zzT] = $zzInner[$zzT] + 1
        }
    }
}
if ($zzInner.Count) {
    Write-Host ''
    Write-Host '    a machine envelope somewhere INSIDE a block drawn as the operator:'
    foreach ($zzT in @($zzInner.Keys | Sort-Object { -$zzInner[$_] })) {
        $zzOne = "$($zzInnerEx[$zzT].Text)" -replace '\s+', ' '
        if ($zzOne.Length -gt 120) { $zzOne = $zzOne.Substring(0, 120) + '...' }
        Write-Host ("  !! <{0,-24} {1,6}   {2}" -f ($zzT + '>'), $zzInner[$zzT], $zzOne)
    }
}

Write-Host ''
Write-Host '--- what the pane now draws as a NOTICE ("system") - THE FALSE-POSITIVE REVIEW ---'
if (-not $zzSys.Count) {
    Note 'no user record in this sweep was reclassified. The fix changed nothing on this data - see the verdict below.'
} else {
    $zzSysShapes = @{}
    $zzSysEx = @{}
    foreach ($zzY in $zzSys) {
        $zzS = Get-Shape $zzY.Text
        if (-not $zzSysShapes.ContainsKey($zzS)) { $zzSysShapes[$zzS] = 0; $zzSysEx[$zzS] = $zzY }
        $zzSysShapes[$zzS] = $zzSysShapes[$zzS] + 1
    }
    foreach ($zzS in @($zzSysShapes.Keys | Sort-Object { -$zzSysShapes[$_] })) {
        $zzOne = "$($zzSysEx[$zzS].Text)" -replace '\s+', ' '
        if ($zzOne.Length -gt 150) { $zzOne = $zzOne.Substring(0, 150) + '...' }
        Write-Host ("     {0,-34} {1,6}   {2}" -f $zzS, $zzSysShapes[$zzS], $zzOne)
    }
    # 🔴 THE ONE TEST THAT CAN ACTUALLY CATCH A FALSE POSITIVE, RUN ON EVERY
    # RECLASSIFIED BLOCK. A record is machinery only if NOTHING survives the
    # envelope strip. So re-run the strip and demand the residue really is
    # empty; anything with prose left in it is the operator's words being
    # folded away, and that is the destructive failure this sweep is for.
    $zzLeak = 0
    foreach ($zzY in $zzSys) {
        $zzS1 = $script:SR_RxMachineWrap.Replace("$($zzY.Text)", '')
        $zzS1 = $script:SR_RxMachineLine.Replace($zzS1, '')
        if ("$zzS1".Trim()) {
            $zzLeak++
            if ($zzLeak -le 5) {
                Fail ("a block was called machinery but has {0} char(s) of real text left after the strip: {1}" -f `
                      "$zzS1".Trim().Length, (("$zzS1".Trim() -replace '\s+', ' ')))
            }
        }
    }
    if (-not $zzLeak) {
        Pass ('all {0:N0} reclassified blocks are EMPTY once the envelopes come off - no operator prose was folded into a notice' -f $zzSys.Count)
    } else {
        Fail ('{0} reclassified block(s) still carry text after the strip - the operator lost words' -f $zzLeak)
    }
    if ($ShowAllSystem) {
        Write-Host ''
        Write-Host '--- every reclassified block, in full ---'
        $zzI = 0
        foreach ($zzY in $zzSys) {
            $zzI++
            Write-Host ("  [{0}] {1}" -f $zzI, $zzY.File) -ForegroundColor DarkCyan
            Write-Host ("      " + (("$($zzY.Text)" -replace "`r", '') -replace "`n", "`n      "))
        }
    }
}

# ---------------------------------------------------------------------------
# 🔴 AND THE OTHER DIRECTION THE UNIT TESTS CANNOT REACH: WHAT THE STRIP COSTS.
# Test-SRMachineUserRecord runs a dot-all non-greedy regex over EVERY user
# record in the tail. An opening tag with no closing tag makes the engine scan
# to the end of the record before failing, so a big record with several of
# those is quadratic-ish. This is on the selection path.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- what the classifier costs on the biggest real records ---'
$zzBig = @($zzYou | Sort-Object { -("$($_.Text)".Length) } | Select-Object -First 5)
foreach ($zzY in $zzBig) {
    $zzBest = [double]::MaxValue
    for ($zzR = 0; $zzR -lt 7; $zzR++) {
        $zzS2 = [Diagnostics.Stopwatch]::StartNew()
        $null = Test-SRMachineUserRecord "$($zzY.Text)"
        $zzS2.Stop()
        if ($zzS2.Elapsed.TotalMilliseconds -lt $zzBest) { $zzBest = $zzS2.Elapsed.TotalMilliseconds }
    }
    $zzOpens = ([regex]::Matches("$($zzY.Text)", '<(task-notification|system-reminder|local-command-caveat)\b')).Count
    Write-Host ("     {0,9:N0} chars, {1,3} envelope open-tag(s)   {2,8:N3} ms" -f "$($zzY.Text)".Length, $zzOpens, $zzBest)
}
# 🔴 AND WHAT IT COSTS ALL TOGETHER, because one record is not the question.
# This runs on EVERY user record in the tail, on the selection path, and it is
# work that did not exist before the reclassification landed. A per-record
# figure that looks like rounding error is a different number once it is
# multiplied by the tail.
$zzTot = 0.0
foreach ($zzY in $zzYou) {
    $zzS3 = [Diagnostics.Stopwatch]::StartNew()
    $null = Test-SRMachineUserRecord "$($zzY.Text)"
    $zzS3.Stop()
    $zzTot += $zzS3.Elapsed.TotalMilliseconds
}
Note ('across all {0:N0} "you" records in this sweep the classifier cost {1:N0} ms in total ({2:N3} ms each on average)' -f `
      $zzYou.Count, $zzTot, $(if ($zzYou.Count) { $zzTot / $zzYou.Count } else { 0 }))
Note ('that is per PARSE, and a parse happens on every selection and on every growth tick of a watched conversation')

# ---------------------------------------------------------------------------
# THE LIVE FILES, RE-HASHED.
# ---------------------------------------------------------------------------
Write-Host ''
if ((Get-FileHash -LiteralPath $zzLiveCfg -Algorithm SHA256).Hash -ne $zzCfgWas) {
    Fail 'session-restore.config.json CHANGED during this sweep.'
} else { Pass 'the live config did not move' }
$zzRegNow = ''
try { $zzRegNow = (Get-FileHash -LiteralPath $zzLiveReg -Algorithm SHA256).Hash } catch { }
if (-not $zzRegWas -or -not $zzRegNow) {
    Inconclusive 'the registry could not be hashed at one end - that guard was not armed for this run'
} elseif ($zzRegNow -ne $zzRegWas) {
    # The operator's own window writes this file on its own tick. A changed
    # hash here is genuinely ambiguous and must not be reported as either.
    Inconclusive 'sessions-registry.json moved during this sweep. This script calls no save path, and the operator window writes it on its own tick - so this check cannot tell the two apart.'
} else { Pass 'the live registry did not move' }

Write-Host ''
if ($fails) { Write-Host ("{0} FAILURE(S)" -f $fails) -ForegroundColor Red; exit 1 }
if ($unsure) { Write-Host ("{0} inconclusive" -f $unsure) -ForegroundColor Magenta; exit 2 }
Write-Host 'sweep clean' -ForegroundColor Green
exit 0
