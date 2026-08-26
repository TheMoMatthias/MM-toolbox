#requires -Version 5.1
<#
    JUMPING to a conversation's real terminal tab.

    Against the live machine, because the thing under test is whether a tab that
    actually exists can be found and activated. A fixture cannot answer that.

    The negative cases come FIRST and matter most: a jump that silently lands
    somewhere else is worse than one that refuses, because the next thing the
    operator does is type.

    Restores whichever tab was active when it started.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path (Split-Path -Parent $here) '_common.ps1')

$fails = 0
function Fail { param($m) Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fails++ }
function Pass { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Note { param($m) Write-Host "        $m" -ForegroundColor DarkGray }

# --- the glyph stripper -----------------------------------------------------
# Tab titles arrive with a status glyph in front, and it changes as the session
# works. Known answers, including the one that must NOT be stripped.
$cases = @(
    @{ In = '* RC-WORKFLOW';  Out = 'RC-WORKFLOW' }
    @{ In = 'RC-WORKFLOW';    Out = 'RC-WORKFLOW' }
    @{ In = '  spaced  ';     Out = 'spaced' }
    @{ In = '(bracketed)';    Out = '(bracketed)' }
    @{ In = '[square]';       Out = '[square]' }
    @{ In = 'C:\WINDOWS\system32\cmd.exe'; Out = 'C:\WINDOWS\system32\cmd.exe' }
)
foreach ($c in $cases) {
    $got = Get-SRTabName $c.In
    if ($got -eq $c.Out) { Pass "'$($c.In)' -> '$got'" }
    else { Fail "'$($c.In)' -> '$got', expected '$($c.Out)'" }
}
# The real glyphs off this machine, which are not ASCII.
foreach ($g in @([char]0x2733, [char]0x25D0, [char]0x25D1)) {
    $got = Get-SRTabName ("$g TEST-NAME")
    if ($got -eq 'TEST-NAME') { Pass "glyph U+$([int]$g | ForEach-Object { $_.ToString('X4') }) stripped" }
    else { Fail "glyph U+$([int]$g | ForEach-Object { $_.ToString('X4') }) left '$got'" }
}

# --- enumeration ------------------------------------------------------------
$tabs = Get-SRTerminalTabs
$tabs = @($tabs)
Write-Host ''
if (-not $tabs.Count) {
    Note 'no Windows Terminal tabs are visible - nothing further can be tested'
    Write-Host ''
    if ($fails) { Write-Host "$fails FAILURE(S)" -ForegroundColor Red; exit 1 }
    exit 2
}
Pass "enumerated $($tabs.Count) tab(s) across $(@($tabs | Select-Object -ExpandProperty Hwnd -Unique).Count) terminal window(s)"
foreach ($t in $tabs) { Note ("  '{0}'  (raw '{1}')" -f $t.Name, $t.Raw) }

# One process can own several windows. If this only ever finds one window's
# worth of tabs on a machine that has more, the enumeration has regressed to the
# FindFirst-on-RootElement bug that made the first probe report 1 tab for 13.
$wins = @($tabs | Select-Object -ExpandProperty Hwnd -Unique)
$wtProcs = @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue)
Note ("$($wtProcs.Count) WindowsTerminal process(es) own $($wins.Count) window(s)")

# --- the refusals -----------------------------------------------------------
Write-Host ''
$why = Invoke-SRJumpToSession -SessionId '00000000-0000-0000-0000-000000000000'
if ($why) { Pass "refuses an unknown session: $why" } else { Fail 'claimed to jump to a session that does not exist' }

$why = Invoke-SRJumpToSession -SessionId '00000000-0000-0000-0000-000000000000' -Title 'NO-SUCH-TAB-XYZZY'
if ($why) { Pass "refuses a title with no tab: $why" } else { Fail 'claimed to jump to a tab that does not exist' }

# A PREFIX of a real tab name must not match. "I6" is a prefix of "I6b", and
# landing in the neighbouring conversation is the failure worth preventing.
$prefixable = $null
foreach ($t in $tabs) {
    foreach ($u in $tabs) {
        if ($u.Name -ne $t.Name -and $u.Name.StartsWith($t.Name) -and $t.Name.Length -ge 2) { $prefixable = $t.Name; break }
    }
    if ($prefixable) { break }
}
if ($prefixable) {
    Note "'$prefixable' is a prefix of another tab on this machine - the exact-match rule is load-bearing here"
}
$why = Invoke-SRJumpToSession -SessionId '00000000-0000-0000-0000-000000000000' -Title (($tabs[0].Name) + '-NOT-REAL')
if ($why) { Pass 'a near-miss title does not match a real tab' } else { Fail 'a near-miss title matched something' }

# --- the real jump ----------------------------------------------------------
Write-Host ''
function SelectedNames {
    $out = @()
    # ASSIGN, THEN WRAP. "@(Get-SRTerminalTabs)" in one step is an array of ONE
    # element holding every tab, whose .Name is all sixteen names joined -- which
    # is exactly what made the first run of this driver report every tab as the
    # active one and then jump at a title that had drifted.
    $all = Get-SRTerminalTabs
    foreach ($t in @($all)) {
        try {
            $sp = $t.Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            if ($sp.Current.IsSelected) { $out += $t.Name }
        } catch { }
    }
    return ,@($out)
}
$before = SelectedNames
Note ("active before: " + ($before -join ', '))

# Pick a tab that is NOT currently active, so a pass cannot be a no-op.
$target = $null
foreach ($t in $tabs) { if ($before -notcontains $t.Name) { $target = $t; break } }
if (-not $target) {
    Note 'every tab is already the active one in its own window - cannot prove a switch'
} else {
    $why = Invoke-SRJumpToSession -SessionId '00000000-0000-0000-0000-000000000000' -Title $target.Name
    if ($why) { Fail "jump to '$($target.Name)' refused: $why" }
    else {
        Start-Sleep -Milliseconds 350
        $after = SelectedNames
        if ($after -contains $target.Name) { Pass "jumped to '$($target.Name)' and it is now the active tab" }
        else { Fail "reported success but '$($target.Name)' is not active (active: $($after -join ', '))" }
    }

    # Put every window back on the tab it was showing. Each window has its own
    # active tab, so this is one call per window, not one overall.
    foreach ($n in $before) { $null = Invoke-SRJumpToSession -SessionId '00000000-0000-0000-0000-000000000000' -Title $n }
    Start-Sleep -Milliseconds 300
    $restored = SelectedNames
    Note ("active after restore: " + ($restored -join ', '))
}

# --- the cache, which is what makes a renamed tab still reachable -----------
Write-Host ''
# 🪤 A TAB WHOSE TITLE IS UNIQUE, not simply the first one enumerated.
#
# Update-SRTabIndex remembers a tab only when EXACTLY ONE carries the title --
# two tabs sharing one are not an identification, which is deliberate and is
# measured behaviour. This picked $tabs[0], and on this machine five terminal
# tabs are called "C:\WINDOWS\SYSTEM32\cmd.exe": whenever one of them happened
# to enumerate first, the suite reported "remembered nothing" and the next
# assertion failed with it. Nothing was wrong either time; the test was asserting
# an accident of enumeration order.
$byName = @{}
foreach ($t in @($tabs)) { $byName["$($t.Name)"] = [int]$byName["$($t.Name)"] + 1 }
$probe = @($tabs | Where-Object { $byName["$($_.Name)"] -eq 1 })[0]
if (-not $probe) {
    Note 'no terminal tab has a title of its own right now - the cache cannot be tested'
} else {
    Note "probing with '$($probe.Name)', the first tab whose title is unique"
    $fake = '11111111-2222-3333-4444-555555555555'
    $n = Update-SRTabIndex -Titles @{ $fake = $probe.Name }
    if ($n -ge 1) { Pass "Update-SRTabIndex remembered $n tab(s) by title" }
    else { Fail 'Update-SRTabIndex remembered nothing' }

# Now ask for a title that does NOT exist, for a session whose element IS
# cached. It must still land, via the remembered element, and say that it did.
    $why = Invoke-SRJumpToSession -SessionId $fake -Title 'THIS-TITLE-DOES-NOT-EXIST'
    if ($why) { Fail "the cached element did not save a drifted title: $why" }
    elseif ($script:SR_JumpNote -match 'last seen') { Pass "a renamed tab is still reachable: $($script:SR_JumpNote)" }
    else { Fail 'it landed but did not say it used the remembered tab' }
}

# And an UNCACHED session with a bad title must still refuse.
$why = Invoke-SRJumpToSession -SessionId '99999999-8888-7777-6666-555555555555' -Title 'ALSO-NOT-REAL'
if ($why) { Pass 'an uncached session with no matching tab is still refused' }
else { Fail 'jumped somewhere for a session it knows nothing about' }

foreach ($n2 in $before) { $null = Invoke-SRJumpToSession -SessionId '00000000-0000-0000-0000-000000000000' -Title $n2 }

Write-Host ''
if ($fails) { Write-Host "$fails FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host 'the jump holds' -ForegroundColor Green
exit 0
