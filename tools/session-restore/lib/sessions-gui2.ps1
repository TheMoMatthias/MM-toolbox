#requires -Version 5.1
<#
.SYNOPSIS
    The session console, rebuilt session-centred. Phases 1 and 2: shell + sidebar.

.DESCRIPTION
    A REPLACEMENT for sessions-gui.ps1, built from scratch and living beside it
    until it passes the suites. Sessions.exe keeps launching the old window until
    the host's GuiScript is flipped in the final commit, so the machine this runs
    on every day always has a working window.

    TWO SURFACES, TOLD APART BY SHAPE.

      work surface     three columns: the projects rail, the sessions column,
                       the output pane. What is happening now.
      session manager  one full-width table with the tick column. What comes
                       back at logon.

    They differ structurally, never by colour, so the difference survives a
    screenshot, a monochrome screen and a colourblind reader. That was the
    complaint this redesign started from: two screens that looked alike.

    COLOUR IS NEW HERE and carries exactly one meaning: what a conversation needs
    from you. Every accent is twinned with a glyph and a band heading, so it is
    the fast path and never the only path.

    THE MODEL IS BUILT FROM _common.ps1 ALONE. The old window's gui\*.ps1 parts
    are deliberately not dot-sourced: they are written against that window's
    element names and script state, and pulling them in would tie a rebuilt
    surface to the shape it replaces. The logic is ported; the coupling is not.

    🔴 THE LAST LINE OF THIS FILE MUST STAY `$null = $window.ShowDialog()`.
    tests\run-tests.ps1 builds every headless driver by splicing the GUI at that
    literal line - it is how ~120 assertions get a fully wired window with
    nothing on screen. Move it, reword it or wrap it and the suite stops seeing
    this window at all, while still reporting green.

.PARAMETER NoScan
    Skip the scan on startup and show whatever the registry already holds.

.PARAMETER Relaunched
    Internal. Set when the script has already re-launched itself into STA.
#>
[CmdletBinding()]
param(
    [switch]$NoScan,
    [switch]$Relaunched
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty while a param() default is evaluated under
# `powershell.exe -File`, which is how the scheduled tasks run. Resolve in the
# body. That cost a silent morning failure once already (README trap 1).
$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }

$selfPath = Join-Path $here 'sessions-gui2.ps1'
$xamlPath = Join-Path $here 'window2.xaml'

# ---------------------------------------------------------------------------
# WPF needs a single-threaded apartment. Sessions.exe pins one; powershell.exe
# defaults to it; an MTA runspace does not and would fail deep inside XamlReader
# with an unhelpful message. Re-launch ourselves once.
# ---------------------------------------------------------------------------
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    if ($Relaunched) {
        Write-Error "Could not get an STA apartment for WPF. Start this with: powershell.exe -STA -File `"$selfPath`""
        exit 1
    }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $a = @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$selfPath`"", '-Relaunched')
    if ($NoScan) { $a += '-NoScan' }
    & $psExe @a
    exit $LASTEXITCODE
}

. (Join-Path $here '_common.ps1')

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---------------------------------------------------------------------------
# DPI, before the first top-level window exists: awareness is fixed when the
# first HWND is created and cannot be changed afterwards. Sessions.exe now makes
# this call itself before painting its splash, so this one returns false there
# and matters only when the script is run directly.
# ---------------------------------------------------------------------------
if (-not ('SRGui2.Dpi' -as [type])) {
    Add-Type -Namespace SRGui2 -Name Dpi -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
'@
}
try {
    [System.AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false)
    $null = [SRGui2.Dpi]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))
} catch { }

# ---------------------------------------------------------------------------
# Build the window
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $xamlPath)) {
    Write-SRLog "gui2: window2.xaml is missing from $here"
    Write-Error "window2.xaml is missing from $here - the window cannot be built without it."
    exit 1
}
try {
    $reader = [System.Xml.XmlReader]::Create((New-Object System.IO.StringReader ([System.IO.File]::ReadAllText($xamlPath))))
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
} catch {
    Write-SRLog ("gui2: the markup would not parse - " + $_.Exception.Message)
    Write-Error ("window2.xaml would not parse: " + $_.Exception.Message)
    exit 1
}

# Every named element, bound once. A typo in this list is a $null reference
# hundreds of lines away, so it fails HERE, naming the element that is wrong.
$ui = @{}
foreach ($n in @(
    'LiveCount','Search','Stamp','Rescan',
    'ModeWork','ModeManage','BandChips','Broadcast',
    'WorkSurface','RailCol','ListCol','RailPane','RailSplit','RailList','RailClear',
    'ListPane','ListSplit','ListCaption','ListCount','SessionList',
    'OutputPane','PaneName','PaneState','PaneStateDot','PaneGoTo','PaneRelaunch',
    'PaneDoc','PaneEmpty','AskBox','AskHeader','AskText','AskOptions','AskNote',
    'SendNote','SendBox','SendBtn',
    'ManageSurface','ManageCaption','ManageList','ManageCount',
    'OpenNotRunning','RelaunchSessions',
    'Status','HelpBtn','CloseBtn','SaveBtn'
)) {
    $el = $window.FindName($n)
    if (-not $el) { throw "window2.xaml has no element named '$n' - the script and the markup disagree." }
    $ui[$n] = $el
}

$V_Show = [System.Windows.Visibility]::Visible
$V_Hide = [System.Windows.Visibility]::Collapsed

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:surface   = 'work'
$script:railPick  = $null
$script:selId     = $null
$script:exitMode  = 'closed'
$script:cfg       = $null
$script:reg       = $null
$script:dirs      = @()
$script:model     = @()
$script:agents    = @{}

# The widths the operator dragged to, remembered so a breakpoint restores what
# they chose rather than a default.
$script:railWidth = 208.0
$script:listWidth = 336.0
$script:squeezed  = ''

function Set-Status { param([string]$Text, [string]$Kind = 'info')
    $ui.Status.Text = $Text
    $ui.Status.Foreground = switch ($Kind) {
        'bad'   { $window.FindResource('AccNeeds') }
        'ok'    { $window.FindResource('AccDone') }
        'warn'  { $window.FindResource('TextHigh') }
        default { $window.FindResource('TextMid') }
    }
}

# ---------------------------------------------------------------------------
# ADAPTIVE LAYOUT
#
# Three columns is not a luxury that silently breaks when the window is small.
# Each column has a job, and the ones whose job is least urgent give up space
# first: the rail is a FILTER (you can filter by typing instead), the sessions
# column is an INDEX (what you selected is still on screen), and the output pane
# is the thing you came to read.
#
# Dragged widths survive a squeeze, so widening puts back what was chosen.
# ---------------------------------------------------------------------------
function Set-Breakpoint {
    $w = [double]$window.ActualWidth
    if ($w -le 0) { $w = [double]$window.Width }
    if ($w -le 0) { return }

    $want = $(if ($w -lt 900) { 'both' } elseif ($w -lt 1180) { 'rail' } else { '' })
    if ($want -eq $script:squeezed) { return }

    if ($script:squeezed -eq '' -and $ui.RailCol.Width.Value -gt 0) { $script:railWidth = [double]$ui.RailCol.Width.Value }
    if ($script:squeezed -ne 'both' -and $ui.ListCol.Width.Value -gt 0) { $script:listWidth = [double]$ui.ListCol.Width.Value }

    switch ($want) {
        'both' {
            $ui.RailPane.Visibility = $V_Hide; $ui.RailSplit.Visibility = $V_Hide
            $ui.ListPane.Visibility = $V_Hide; $ui.ListSplit.Visibility = $V_Hide
            $ui.RailCol.Width = New-Object System.Windows.GridLength 0
            $ui.ListCol.Width = New-Object System.Windows.GridLength 0
        }
        'rail' {
            $ui.RailPane.Visibility = $V_Hide; $ui.RailSplit.Visibility = $V_Hide
            $ui.ListPane.Visibility = $V_Show; $ui.ListSplit.Visibility = $V_Show
            $ui.RailCol.Width = New-Object System.Windows.GridLength 0
            $ui.ListCol.Width = New-Object System.Windows.GridLength $script:listWidth
        }
        default {
            $ui.RailPane.Visibility = $V_Show; $ui.RailSplit.Visibility = $V_Show
            $ui.ListPane.Visibility = $V_Show; $ui.ListSplit.Visibility = $V_Show
            $ui.RailCol.Width = New-Object System.Windows.GridLength $script:railWidth
            $ui.ListCol.Width = New-Object System.Windows.GridLength $script:listWidth
        }
    }
    $script:squeezed = $want
}

function Set-Surface { param([string]$Mode)
    $script:surface = $Mode
    if ($Mode -eq 'manage') {
        $ui.WorkSurface.Visibility   = $V_Hide
        $ui.ManageSurface.Visibility = $V_Show
        Set-Status 'Session manager: what comes back at the next logon. The ticks decide.'
    } else {
        $ui.ManageSurface.Visibility = $V_Hide
        $ui.WorkSurface.Visibility   = $V_Show
        Set-Status 'Work surface: what each conversation last said, and which of them are waiting on you.'
    }
}

# ===========================================================================
# THE MODEL
# ===========================================================================

# The five bands in the order they appear. Every one has an accent AND a label,
# because colour is the fast path and never the only path.
$script:Bands = @(
    @{ Key = 'needs';   Label = 'NEEDS YOU';   Acc = 'AccNeeds' }
    @{ Key = 'working'; Label = 'WORKING';     Acc = 'AccWorking' }
    @{ Key = 'done';    Label = 'FINISHED';    Acc = 'AccDone' }
    @{ Key = 'idle';    Label = 'IDLE';        Acc = 'AccIdle' }
    @{ Key = 'quiet';   Label = 'NOT RUNNING'; Acc = 'AccQuiet' }
)

# A hand-back: nothing pending, and the last thing it SAID is substantial enough
# to be worth reading. A heuristic, deliberately - claude reports busy / idle /
# waiting and has no word for finished.
$script:HandbackMinChars = 40

function Get-Band { param($Row)
    $cv = $Row.Conv
    if (-not $cv) { return 'quiet' }
    if ($cv.Stuck) { return 'quiet' }
    if ($cv.Needs) { return 'needs' }
    if ($cv.Stale) { return 'quiet' }
    switch ("$($cv.State)") {
        'working'     { return 'working' }
        'summarising' { return 'working' }
        'waiting'     { return 'needs' }
        'idle' {
            $sd = $Row.Said
            if ($sd -and -not "$($sd.Pending)".Trim() -and
                "$($sd.Said)".Trim().Length -ge $script:HandbackMinChars) { return 'done' }
            return 'idle'
        }
    }
    return 'quiet'
}

function Get-Title { param($S, $D)
    $t = "$($S.title)".Trim()
    if ($t -and $t -ne '(untitled)') { return @{ Text = $t; Derived = $false } }
    $a = "$($S.autoTitle)".Trim()
    if ($a) { return @{ Text = $a; Derived = $true } }
    $leaf = Split-Path -Leaf "$($D.path)"
    if ($leaf) { return @{ Text = $leaf; Derived = $true } }
    return @{ Text = '(untitled)'; Derived = $true }
}

function Get-Age { param($When)
    if (-not $When) { return '' }
    try { $d = ((Get-Date) - [datetime]$When) } catch { return '' }
    if ($d.TotalSeconds -lt 90) { return 'now' }
    if ($d.TotalMinutes -lt 60) { return ('{0}m' -f [int]$d.TotalMinutes) }
    if ($d.TotalHours   -lt 24) { return ('{0}h' -f [int]$d.TotalHours) }
    return ('{0}d' -f [int]$d.TotalDays)
}

function Test-Warm { param($S)
    try { return ([datetime]$S.lastActive -gt (Get-Date).AddHours(-24)) } catch { return $false }
}

# Every conversation the work surface could show, with what it is doing.
#
# 🪤 THE SAID-LINE IS READ ONLY FOR THE LIVE AND THE RECENT. Get-SRLastSaid opens
# a file per conversation; doing that for all 215 on every rebuild is seconds,
# not milliseconds, and the rebuild runs on a timer.
function Update-Model {
    $script:cfg  = Get-SRConfig
    $script:reg  = Get-SRRegistry
    $script:dirs = @($script:reg.directories)

    $agents = @{}
    try { $agents = Get-SRAgentStatus -Refresh } catch { }
    $script:agents = $agents

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($d in $script:dirs) {
        if ($d.missing) { continue }
        foreach ($s in @($d.sessions)) {
            if ($s.gone) { continue }
            $id = "$($s.sessionId)".ToLower()
            $a  = $agents[$id]
            $conv = $null
            try { $conv = Resolve-SRSessionState -Agent $a -Conv $null } catch { }
            $live = [bool]$a
            $said = $null
            if ($live -or (Test-Warm $s)) {
                try { $said = Get-SRLastSaid -JsonlPath $s.jsonl } catch { }
            }
            $rows.Add([PSCustomObject]@{
                Id = $id; S = $s; D = $d; A = $a; Conv = $conv; Said = $said; Live = $live; Band = 'quiet'
            })
        }
    }
    foreach ($r in $rows) { $r.Band = Get-Band $r }
    $script:model = $rows
}

# What the work surface shows: live, or spoke in the last day. It is not a
# browser for all 215 - that is what the session manager is for.
function Test-OnSurface { param($R)
    if ($R.Live) { return $true }
    return (Test-Warm $R.S)
}

# ===========================================================================
# THE RAIL - a filter, never the grouping
# ===========================================================================
function Build-Rail {
    $byProj = @{}
    foreach ($r in $script:model) {
        if (-not (Test-OnSurface $r)) { continue }
        $k = "$($r.D.path)"
        if (-not $byProj.ContainsKey($k)) { $byProj[$k] = New-Object System.Collections.Generic.List[object] }
        $byProj[$k].Add($r)
    }
    $order = @($byProj.Keys | Sort-Object {
        $newest = [datetime]0
        foreach ($x in $byProj[$_]) { try { $t = [datetime]$x.S.lastActive; if ($t -gt $newest) { $newest = $t } } catch { } }
        - $newest.Ticks
    })
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($k in $order) {
        $picked = ($script:railPick -eq $k)
        $items.Add([PSCustomObject]@{
            Path   = $k
            Label  = (Split-Path -Leaf $k)
            Count  = $byProj[$k].Count
            PickBg = $(if ($picked) { $window.FindResource('SelBg') } else { [System.Windows.Media.Brushes]::Transparent })
            Fg     = $(if ($picked) { $window.FindResource('TextMax') } else { $window.FindResource('TextHigh') })
        })
    }
    $ui.RailList.ItemsSource = $items
    $ui.RailClear.Visibility = $(if ($script:railPick) { $V_Show } else { $V_Hide })
}

# ===========================================================================
# THE SESSIONS COLUMN - grouped by BAND, two lines per row
# ===========================================================================
function Build-Sessions {
    $q = "$($ui.Search.Text)".Trim().ToLower()

    $keep = New-Object System.Collections.Generic.List[object]
    foreach ($r in $script:model) {
        if (-not (Test-OnSurface $r)) { continue }
        if ($script:railPick -and "$($r.D.path)" -ne $script:railPick) { continue }
        if ($q) {
            $t = (Get-Title $r.S $r.D).Text
            $hay = ('{0} {1} {2} {3}' -f $t, $r.S.autoTitle, $r.D.path, $r.Id).ToLower()
            if ($hay -notlike "*$q*") { continue }
        }
        $keep.Add($r)
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($b in $script:Bands) {
        $inBand = @($keep | Where-Object { $_.Band -eq $b.Key } |
                    Sort-Object { try { [datetime]$_.S.lastActive } catch { [datetime]0 } } -Descending)
        if (-not $inBand.Count) { continue }
        $acc = $window.FindResource($b.Acc)
        $items.Add([PSCustomObject]@{
            Kind = 'band'; Id = $null; Row = $null
            BandVis = $V_Show; RowVis = $V_Hide; DotVis = $V_Hide
            BandLabel = $b.Label; BandCount = $inBand.Count; Accent = $acc
            Name = ''; Age = ''; Said = ''; NameWeight = 'Normal'; NameStyle = 'Normal'; BarOpacity = 0.0
        })
        foreach ($r in $inBand) {
            $t = Get-Title $r.S $r.D
            $saidText = ''
            if ($r.Said -and "$($r.Said.Said)".Trim()) { $saidText = ("$($r.Said.Said)".Trim() -replace '\s+', ' ') }
            elseif ($r.Conv -and "$($r.Conv.Detail)") { $saidText = "$($r.Conv.Detail)" }
            $items.Add([PSCustomObject]@{
                Kind = 'session'; Id = $r.Id; Row = $r
                BandVis = $V_Hide; RowVis = $V_Show
                DotVis = $(if ($b.Key -eq 'needs') { $V_Show } else { $V_Hide })
                BandLabel = ''; BandCount = ''; Accent = $acc
                Name = $t.Text
                NameWeight = $(if ($b.Key -eq 'needs') { 'SemiBold' } else { 'Normal' })
                NameStyle  = $(if ($t.Derived) { 'Italic' } else { 'Normal' })
                Age  = (Get-Age $r.S.lastActive)
                Said = $saidText
                BarOpacity = $(if ($b.Key -eq 'quiet') { 0.25 } else { 0.85 })
            })
        }
    }

    $ui.SessionList.ItemsSource = $items
    $sessions = @($items | Where-Object { $_.Kind -eq 'session' })
    $ui.ListCount.Text = ('{0}' -f $sessions.Count)
    $ui.ListCaption.Text = $(if ($script:railPick) { 'SESSIONS  ' + (Split-Path -Leaf $script:railPick).ToUpper() } else { 'SESSIONS' })

    # 🔴 SELECTION IS PINNED TO THE CONVERSATION ID, never to a row index. A
    # rebuild moves rows between bands - which happens more now that FINISHED
    # exists - and an index would silently change what is being read.
    if ($script:selId) {
        $again = @($items | Where-Object { $_.Id -eq $script:selId })
        if ($again.Count) { $ui.SessionList.SelectedItem = $again[0]; return }
    }
    # AUTO-SELECT THE TOP OF NEEDS YOU: the window answers its own question
    # before anything is clicked, and falls through to the newest thing that
    # spoke on a quiet morning.
    if ($sessions.Count) { $ui.SessionList.SelectedItem = $sessions[0] }
}

function Update-Surface {
    Build-Rail
    Build-Sessions
    # 🪤 $script:model.Count, NOT @($script:model).Count. The array subexpression
    # @() throws "Argument types do not match" when applied to a
    # System.Collections.Generic.List[object] on PowerShell 5.1 - full or empty,
    # either way. Piping is fine, .Count is fine, @() is not. It is the trap this
    # repo documents and it cost the first render of this window.
    $live = @($script:model | Where-Object { $_.Live }).Count
    $ui.LiveCount.Text = ('{0} live of {1} conversations across {2} projects' -f `
        $live, $script:model.Count, @($script:dirs).Count)
    $ui.Stamp.Text = ('as of {0}' -f (Get-Date).ToString('HH:mm:ss'))
}

# ===========================================================================
# Selection
# ===========================================================================
function Show-Selected {
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return }
    $script:selId = $it.Id
    $r = $it.Row
    $t = Get-Title $r.S $r.D
    $ui.PaneName.Text = $t.Text
    $b = @($script:Bands | Where-Object { $_.Key -eq "$($r.Band)" })
    $ui.PaneStateDot.Background = $(if ($b.Count) { $window.FindResource($b[0].Acc) } else { $window.FindResource('AccIdle') })
    $detail = $(if ($r.Conv -and "$($r.Conv.Detail)") { "$($r.Conv.Detail)" } else { 'no process is holding it' })
    $ui.PaneState.Text = ('{0}   |   {1}' -f $(if ($b.Count) { $b[0].Label } else { '' }), $detail)
    # Phase 3 fills the document. Until then the pane SAYS it is not built, so a
    # blank surface does not read as a bug.
    $ui.PaneEmpty.Text = 'The transcript renders here in phase 3.'
    $ui.PaneEmpty.Visibility = $V_Show
}

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------
$ui.ModeWork.Add_Checked({   Set-Surface 'work' })
$ui.ModeManage.Add_Checked({ Set-Surface 'manage' })
$window.Add_SizeChanged({ Set-Breakpoint })
$ui.CloseBtn.Add_Click({ $script:exitMode = 'closed'; $window.Close() })

$ui.SessionList.Add_SelectionChanged({
    $it = $ui.SessionList.SelectedItem
    if ($it -and $it.Kind -eq 'band') {
        # A heading is not a target. Step past it rather than arming nothing.
        $i = $ui.SessionList.SelectedIndex + 1
        if ($i -lt @($ui.SessionList.Items).Count) { $ui.SessionList.SelectedIndex = $i }
        return
    }
    Show-Selected
})

$ui.RailList.Add_SelectionChanged({
    $it = $ui.RailList.SelectedItem
    if (-not $it) { return }
    $script:railPick = $(if ($script:railPick -eq $it.Path) { $null } else { $it.Path })
    Build-Rail
    Build-Sessions
})
$ui.RailClear.Add_MouseLeftButtonUp({ $script:railPick = $null; Build-Rail; Build-Sessions })

# Typing filters, but not on every keystroke: a rebuild over 215 rows per letter
# is a visibly laggy search box.
$script:searchTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:searchTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$script:searchTimer.Add_Tick({ $script:searchTimer.Stop(); Build-Sessions })
$ui.Search.Add_TextChanged({ $script:searchTimer.Stop(); $script:searchTimer.Start() })

$ui.Rescan.Add_Click({
    Set-Status 'rescanning...'
    try { $null = Update-SRRegistry -Config $script:cfg -Quiet } catch { }
    Update-Model; Update-Surface
    Set-Status 'rescanned' 'ok'
})

# / focuses the search from anywhere; ESC clears it, then hands focus back to
# the list. The three panes are Tab stops in reading order.
$window.Add_PreviewKeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Escape') {
        if ($ui.Search.IsKeyboardFocusWithin -and $ui.Search.Text) { $ui.Search.Text = ''; $e.Handled = $true; return }
        $null = $ui.SessionList.Focus(); $e.Handled = $true; return
    }
    if ($ui.Search.IsKeyboardFocusWithin -or $ui.SendBox.IsKeyboardFocusWithin) { return }
    if ($e.Key -eq 'Oem2') { $null = $ui.Search.Focus(); $e.Handled = $true; return }
})

# ---------------------------------------------------------------------------
# First paint
# ---------------------------------------------------------------------------
Update-Model
Update-Surface
Set-Surface 'work'
Set-Breakpoint

$window.Add_ContentRendered({
    Set-Breakpoint
    $null = $ui.SessionList.Focus()
})

$null = $window.ShowDialog()
