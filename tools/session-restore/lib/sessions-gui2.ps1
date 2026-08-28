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
        Build-Manager
        Set-Status 'Session manager: what comes back at the next logon. The ticks decide, and nothing here launches anything.'
    } else {
        $ui.ManageSurface.Visibility = $V_Hide
        $ui.WorkSurface.Visibility   = $V_Show
        Set-Status 'Work surface: what each conversation last said, and which of them are waiting on you.'
    }
}

# ===========================================================================
# THE SESSION MANAGER
#
# One full-width table, and the shape IS the distinction: nothing here shares a
# silhouette with the work surface, so the two cannot read as the same screen.
#
# IT OPENS FOLDED. Ordering by recency alone could not fix the endless list,
# because the project worked in most recently is also the one holding half the
# conversations. Folded, the whole thing is 27 rows on one screen, each carrying
# its count and how many are armed - which is the question it is opened to ask.
# ===========================================================================
$script:fold      = @{}
$script:showOlder = $false
$script:dirty     = $false

function Build-Manager {
    $cut = (Get-Date).AddDays(-7)
    $items = New-Object System.Collections.Generic.List[object]
    $older = 0

    $byProj = @{}
    foreach ($r in $script:model) {
        $k = "$($r.D.path)"
        if (-not $byProj.ContainsKey($k)) { $byProj[$k] = New-Object System.Collections.Generic.List[object] }
        $byProj[$k].Add($r)
    }
    $order = @($byProj.Keys | Sort-Object {
        $newest = [datetime]0
        foreach ($x in $byProj[$_]) { try { $t = [datetime]$x.S.lastActive; if ($t -gt $newest) { $newest = $t } } catch { } }
        - $newest.Ticks
    })

    foreach ($k in $order) {
        $kids = @($byProj[$k] | Sort-Object { try { [datetime]$_.S.lastActive } catch { [datetime]0 } } -Descending)
        $inWindow = @($kids | Where-Object {
            if ($script:showOlder) { return $true }
            try { return ([datetime]$_.S.lastActive -gt $cut) } catch { return $false }
        })
        $older += ($kids.Count - $inWindow.Count)
        if (-not $inWindow.Count) { continue }

        $armed = @($kids | Where-Object { [bool]$_.S.enabled }).Count
        $shut  = [bool]$script:fold[$k]
        if (-not $script:fold.ContainsKey($k)) { $shut = $true; $script:fold[$k] = $true }

        $items.Add([PSCustomObject]@{
            Kind = 'project'; Path = $k; Row = $null
            ProjVis = $V_Show; ConvVis = $V_Hide
            Caret = $(if ($shut) { [string][char]0x25B8 } else { [string][char]0x25BE })
            Label = (Get-ProjectLabel $k)
            Meta  = ('{0}   |   {1} armed' -f $kids.Count, $armed)
            Name = ''; Lane = ''; Said = ''; Age = ''; TickBg = $null; NameStyle = 'Normal'
        })
        if ($shut) { continue }

        foreach ($r in $inWindow) {
            $t = Get-Title $r.S $r.D
            $saidText = ''
            if ($r.Said -and "$($r.Said.Said)".Trim()) { $saidText = ("$($r.Said.Said)".Trim() -replace '\s+', ' ') }
            $items.Add([PSCustomObject]@{
                Kind = 'conv'; Path = $k; Row = $r
                ProjVis = $V_Hide; ConvVis = $V_Show
                Caret = ''; Label = ''; Meta = ''
                Name = $t.Text
                NameStyle = $(if ($t.Derived) { 'Italic' } else { 'Normal' })
                Lane = $(if ("$($r.S.lane)" -and "$($r.S.lane)" -ne 'main') { "$($r.S.worktree)" } else { 'main' })
                Said = $saidText
                Age  = (Get-Age $r.S.lastActive)
                # The tick is a FILLED SQUARE or an empty one - a shape, not a
                # colour, so it survives everything the accents do not.
                TickBg = $(if ([bool]$r.S.enabled) { $window.FindResource('TextMax') } else { [System.Windows.Media.Brushes]::Transparent })
            })
        }
    }

    # THE AGE WINDOW, SAID OUT LOUD. A list that quietly stops at seven days
    # reads exactly like a complete one.
    if ($older -gt 0 -and -not $script:showOlder) {
        $items.Add([PSCustomObject]@{
            Kind = 'more'; Path = $null; Row = $null
            ProjVis = $V_Show; ConvVis = $V_Hide
            Caret = ''; Label = ('{0} older conversations not shown' -f $older)
            Meta = 'press O to show them'
            Name = ''; Lane = ''; Said = ''; Age = ''; TickBg = $null; NameStyle = 'Normal'
        })
    }

    $ui.ManageList.ItemsSource = $items
    $armedAll = @($script:model | Where-Object { [bool]$_.S.enabled }).Count
    $ui.ManageCount.Text = ('{0} ticked to reopen at the next logon{1}' -f $armedAll, $(if ($script:dirty) { '   |   unsaved' } else { '' }))
}

function Toggle-Tick {
    $it = $ui.ManageList.SelectedItem
    if (-not $it) { return }
    if ($it.Kind -eq 'project') { $script:fold[$it.Path] = -not [bool]$script:fold[$it.Path]; Build-Manager; return }
    if ($it.Kind -eq 'more')    { $script:showOlder = $true; Build-Manager; return }
    if ($it.Kind -ne 'conv')    { return }
    $s = $it.Row.S
    $now = -not [bool]$s.enabled
    if ($s.PSObject.Properties.Name -contains 'enabled') { $s.enabled = $now }
    else { $s | Add-Member -NotePropertyName enabled -NotePropertyValue $now -Force }
    # Touching a tick PINS it, or the hourly auto-tick roll takes it away again.
    if ($s.PSObject.Properties.Name -contains 'pinned') { $s.pinned = $true }
    else { $s | Add-Member -NotePropertyName pinned -NotePropertyValue $true -Force }
    $script:dirty = $true
    Build-Manager
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

# 🔴 THE LEAF NAME IS NOT UNIQUE. Eight projects on this machine are called
# "repo" - each an R-numbered run directory under Millwright-experiments. A
# print the leaf show eight identical rows, and the operator cannot tell which
# repository is which - the exact defect CONTEXT.md records as solved for the old
# window and which this rebuild reintroduced by taking Split-Path -Leaf.
#
# Widen by ONE path segment at a time until every label on screen is unique.
$script:projLabel = @{}
function Update-ProjectLabels {
    $script:projLabel = @{}
    $paths = @($script:dirs | ForEach-Object { "$($_.path)" } | Where-Object { $_ })
    foreach ($p in $paths) { $script:projLabel[$p] = (Split-Path -Leaf $p) }
    for ($depth = 1; $depth -le 4; $depth++) {
        $dupes = @($script:projLabel.GetEnumerator() | Group-Object Value | Where-Object { $_.Count -gt 1 })
        if (-not $dupes.Count) { break }
        foreach ($g in $dupes) {
            foreach ($e in $g.Group) {
                $parts = @("$($e.Key)" -split '[\\/]' | Where-Object { $_ })
                $take = [Math]::Min($depth + 1, $parts.Count)
                $script:projLabel[$e.Key] = (@($parts[-$take..-1]) -join ' / ')
            }
        }
    }
}
function Get-ProjectLabel { param([string]$Path)
    if ($script:projLabel.ContainsKey($Path)) { return $script:projLabel[$Path] }
    return (Split-Path -Leaf $Path)
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
    Update-ProjectLabels
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
            Label  = (Get-ProjectLabel $k)
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
    $ui.ListCaption.Text = $(if ($script:railPick) { 'SESSIONS  ' + (Get-ProjectLabel $script:railPick).ToUpper() } else { 'SESSIONS' })

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
# THE OUTPUT PANE
#
# It renders the TRANSCRIPT, not a mirror of the terminal. 215 conversations
# exist and 14 run, so a pane that only works while a session is live is a pane
# that is blank most of the time. That is the constraint the whole surface is
# built around, and the suite enforces it.
#
# The four rendering helpers below are PORTED from gui\gui-read.ps1 rather than
# re-derived: they carry six shipped bugs' worth of comments, and reinventing
# markdown handling and tool-run folding would earn every one of them again.
# What is NOT ported is the coupling - they take a palette and return a
# document, and know nothing about either window.
# ===========================================================================

$Pal = @{
    Ink        = $window.FindResource('Ink')
    Raised     = $window.FindResource('PanelHi')
    HairlineHi = $window.FindResource('Hairline')
    TextMax    = $window.FindResource('TextMax')
    TextHigh   = $window.FindResource('TextHigh')
    TextMid    = $window.FindResource('TextMid')
    TextLow    = $window.FindResource('TextLow')
    TextDim    = $window.FindResource('AccQuiet')
}
$script:UiFace   = $window.FindResource('FontUi')
$script:MonoFace = $window.FindResource('FontMono')
$FW_Semi   = [System.Windows.FontWeights]::SemiBold
$FW_Normal = [System.Windows.FontWeights]::Normal

# THE TAIL BUDGET. The biggest transcript on this machine is 2.5 MB and
# FlowDocumentScrollViewer does not virtualize its blocks, so rendering a whole
# conversation is a multi-second freeze on every selection. Start at the same
# 256 KB Get-SRLastSaid uses; "load earlier" doubles it, and the pane says out
# loud when it is showing only part.
$script:TailBase = 262144
$script:tailBytes = $script:TailBase

function New-ReadRun {
    param([string]$Text, $Brush, [double]$Size = 13, [string]$Weight = 'Normal', [switch]$Mono, [switch]$Italic)
    $r = New-Object System.Windows.Documents.Run ([string]$Text)
    if ($Brush) { $r.Foreground = $Brush }
    $r.FontSize = $Size
    if ($Mono)   { $r.FontFamily = $script:MonoFace }
    if ($Italic) { $r.FontStyle = [System.Windows.FontStyles]::Italic }
    $r.FontWeight = $(if ($Weight -eq 'SemiBold') { $FW_Semi } else { $FW_Normal })
    return $r
}

# Markdown, but only the parts that change how a line READS: fenced code, a
# heading, a bullet, and inline `code`. Anything more would be a markdown
# engine, which is not what this needs to be.
function Add-ReadProse {
    param($Doc, [string]$Text, $Brush)
    $lines = @($Text -replace "`r", '' -split "`n")
    $i = 0
    while ($i -lt $lines.Count) {
        $ln = $lines[$i]
        if ($ln.TrimStart().StartsWith('```')) {
            $code = New-Object System.Collections.Generic.List[string]
            $i++
            while ($i -lt $lines.Count -and -not $lines[$i].TrimStart().StartsWith('```')) { $code.Add($lines[$i]); $i++ }
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
        $body = $ln; $size = 14.5; $weight = 'Normal'; $indent = 0
        if ($body -match '^\s*#{1,6}\s+(.*)$') { $body = $Matches[1]; $weight = 'SemiBold'; $size = 16 }
        elseif ($body -match '^\s*[-*]\s+(.*)$') { $body = [char]0x2022 + '  ' + $Matches[1]; $indent = 14 }
        elseif ($body -match '^\s*(\d+)\.\s+(.*)$') { $body = $Matches[1] + '.  ' + $Matches[2]; $indent = 14 }
        if ($indent) { $p.Margin = New-Object System.Windows.Thickness $indent, 2, 0, 2 }
        $rest = $body
        while ($rest -match '^(.*?)(`([^`]+)`|\*\*([^*]+)\*\*)(.*)$') {
            $before = $Matches[1]; $codeTxt = $Matches[3]; $boldTxt = $Matches[4]; $rest = $Matches[5]
            if ($before)  { $p.Inlines.Add((New-ReadRun -Text $before -Brush $Brush -Size $size -Weight $weight)) }
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
# text 50, thinking 84, tool_use 129, tool_result 130. A RUN of them becomes ONE
# line saying how many and naming the last, because the question a reader has
# about a wall of tool calls is "how much of this is there, and where does the
# conversation start again". Two or fewer are left alone: two lines are cheaper
# to read than a summary of two lines.
function Compress-ToolRuns { param($Blocks)
    $out = New-Object System.Collections.Generic.List[object]
    $arr = @($Blocks)
    $i = 0
    while ($i -lt $arr.Count) {
        if ($arr[$i].Kind -ne 'tool' -and $arr[$i].Kind -ne 'result') { $out.Add($arr[$i]); $i++; continue }
        $j = $i; $calls = 0; $lastHead = ''
        while ($j -lt $arr.Count -and ($arr[$j].Kind -eq 'tool' -or $arr[$j].Kind -eq 'result')) {
            if ($arr[$j].Kind -eq 'tool') { $calls++; $lastHead = "$($arr[$j].Head)" }
            $j++
        }
        if ($calls -le 2) { for ($k = $i; $k -lt $j; $k++) { $out.Add($arr[$k]) } }
        else {
            $out.Add([PSCustomObject]@{ Kind = 'tools'; Head = "$calls tool calls"
                                        Body = $(if ($lastHead) { "last: $lastHead" } else { '' }); Meta = '' })
        }
        $i = $j
    }
    # 🪤 A PLAIN ARRAY, never comma-wrapped. Wrapping makes @(f) at every call
    # site a ONE-element array holding everything, and for an empty result a
    # single empty array - so "nothing to render" becomes one phantom row. This
    # codebase has shipped that bug six times.
    return $out.ToArray()
}

function Build-ReadDocument {
    param($Blocks, [bool]$Truncated = $false)
    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.FontFamily  = $script:UiFace
    $doc.Background  = $Pal.Ink
    $doc.Foreground  = $Pal.TextHigh
    $doc.PagePadding = New-Object System.Windows.Thickness 26, 18, 26, 26
    $doc.ColumnWidth = [double]::PositiveInfinity
    $doc.IsOptimalParagraphEnabled = $false

    if (-not @($Blocks).Count) {
        $p = New-Object System.Windows.Documents.Paragraph
        $p.Inlines.Add((New-ReadRun -Text 'Nothing readable in this transcript yet.' -Brush $Pal.TextMid -Size 13))
        $doc.Blocks.Add($p)
        return $doc
    }

    # SAY WHEN IT IS PARTIAL. A pane that silently shows the last slice of a
    # conversation reads as the whole of a short one.
    if ($Truncated) {
        $p = New-Object System.Windows.Documents.Paragraph
        $p.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
        $p.Inlines.Add((New-ReadRun -Text ('showing the last {0} KB of a longer conversation - press L to load earlier' -f [int]($script:tailBytes / 1KB)) -Brush $Pal.TextDim -Size 11 -Italic))
        $doc.Blocks.Add($p)
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
                # silently drops every second one, hence the @() snapshot. And
                # $null = on Remove is not tidiness - it returns a BOOL, and an
                # uncaptured value would be emitted, so the function would return
                # an array of $true with the document buried inside it.
                foreach ($blk in @($inner.Blocks)) { $null = $inner.Blocks.Remove($blk); $s.Blocks.Add($blk) }
                $doc.Blocks.Add($s)
            }
            'said' {
                $lab = New-Object System.Windows.Documents.Paragraph
                $lab.Margin = New-Object System.Windows.Thickness 0, 14, 0, 4
                $lab.Inlines.Add((New-ReadRun -Text 'CLAUDE' -Brush $Pal.TextLow -Size 10.5 -Weight 'SemiBold'))
                $doc.Blocks.Add($lab)
                $inner = New-Object System.Windows.Documents.FlowDocument
                Add-ReadProse -Doc $inner -Text $b.Body -Brush $Pal.TextHigh
                foreach ($blk in @($inner.Blocks)) { $null = $inner.Blocks.Remove($blk); $doc.Blocks.Add($blk) }
            }
            'thinking' {
                $head = @($b.Body -replace "`r", '' -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' '
                if ($head.Length -gt 170) { $head = $head.Substring(0, 167) + '...' }
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 18, 3, 0, 6
                $p.Inlines.Add((New-ReadRun -Text 'thinking   ' -Brush $Pal.TextDim -Size 10.5 -Weight 'SemiBold'))
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
                $first = "$(@($b.Body -replace "`r", '' -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1))"
                if ($first.Length -gt 120) { $first = $first.Substring(0, 117) + '...' }
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 22, 0, 0, 4
                $p.Inlines.Add((New-ReadRun -Text ($b.Head + '   ') -Brush $Pal.TextDim -Size 10.5 -Mono))
                $p.Inlines.Add((New-ReadRun -Text $first -Brush $Pal.TextDim -Size 11 -Mono))
                $doc.Blocks.Add($p)
            }
        }
    }
    return $doc
}

# ===========================================================================
# THE PINNED QUESTION
#
# It sits at the FOOT of the pane, above the composer, and never inline in the
# transcript: on a long conversation an inline question is a question you have
# to go looking for.
#
# The options come off the LIVE CONSOLE, not the transcript - a question is only
# answerable while something is sitting on it.
# ===========================================================================
function Update-Ask { param($R)
    $ui.AskBox.Visibility = $V_Hide
    $ui.AskOptions.ItemsSource = $null
    if (-not $R -or -not $R.A -or -not $R.A.Pid) { return }

    $q = $null
    try { $q = Get-SRScreenQuestion -ProcessId ([int]$R.A.Pid) } catch { }
    if (-not $q -or -not @($q.Options).Count) { return }

    $ui.AskHeader.Text = $(if ("$($q.Header)") { "$($q.Header)".ToUpper() } else { 'IT IS ASKING' })
    $ui.AskText.Text   = "$($q.Question)"

    $btns = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($o in @($q.Options)) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = ('{0}.  {1}' -f ($n + 1), $o)
        $b.Style = $window.FindResource('Btn')
        $b.Margin = New-Object System.Windows.Thickness 0, 0, 0, 5
        $b.HorizontalContentAlignment = 'Left'
        $b.Tag = $n
        $b.Add_Click({ param($s, $e) Invoke-Answer ([int]$s.Tag) })
        $btns.Add($b)
        $n++
    }
    $ui.AskOptions.ItemsSource = $btns

    if ($q.Multi) {
        $ui.AskNote.Text = 'Several answers. Ticking is wired on an INFERRED reading of the menu footer, and every send is recorded to .state so a wrong reading leaves evidence.'
        $ui.AskNote.Visibility = $V_Show
    } else {
        $ui.AskNote.Visibility = $V_Hide
    }
    $ui.AskBox.Visibility = $V_Show
}

function Invoke-Answer { param([int]$Index)
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return }
    $r = $it.Row
    if (-not $r.A -or -not $r.A.Pid) { Set-Status 'that conversation is not running any more' 'warn'; return }
    Set-Status 'answering...'
    $why = $null
    try { $why = Send-SRQuestionAnswer -SessionId $r.Id -Index $Index } catch { $why = $_.Exception.Message }
    if ($why) { Set-Status $why 'bad' } else { Set-Status 'answered' 'ok'; $ui.AskBox.Visibility = $V_Hide }
}

# ===========================================================================
# THE COMPOSER - honest about when it cannot send
#
# It LOOKS like chat and is not: it synthesises keystrokes into a real terminal.
# So it says why it is disabled rather than silently dropping what was typed,
# which is the worst outcome available here.
# ===========================================================================
function Update-SendState {
    $it = $ui.SessionList.SelectedItem
    $why = ''
    if (-not $it -or $it.Kind -ne 'session') { $why = 'nothing is selected' }
    else {
        $r = $it.Row
        if (-not $r.A -or -not $r.A.Pid) { $why = 'this conversation is not running, so there is nothing to type into' }
        elseif ("$($r.A.Status)" -eq 'busy') { $why = 'it is mid-turn - wait for it to stop before typing' }
        elseif ($r.A.Kind -and $r.A.Kind -ne 'interactive') { $why = 'a background agent has no console to type into' }
    }
    $ui.SendBtn.IsEnabled = (-not $why) -and "$($ui.SendBox.Text)".Trim()
    $ui.SendBox.IsEnabled = (-not $why)
    if ($why) { $ui.SendNote.Text = $why; $ui.SendNote.Visibility = $V_Show }
    else { $ui.SendNote.Visibility = $V_Hide }
}

function Invoke-Send {
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return }
    $r = $it.Row
    $msg = "$($ui.SendBox.Text)".Trim()
    if (-not $msg -or -not $r.A -or -not $r.A.Pid) { return }
    Set-Status 'typing it in...'
    $why = $null
    try { $why = Send-SRSessionInput -SessionId $r.Id -Text $msg } catch { $why = $_.Exception.Message }
    if ($why) { Set-Status $why 'bad' } else { $ui.SendBox.Text = ''; Set-Status 'sent' 'ok' }
}

# ===========================================================================
# Selection, and following the selected transcript
# ===========================================================================
function Update-Document {
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return }
    $r = $it.Row
    $j = "$($r.S.jsonl)"
    if (-not $j -or -not (Test-Path -LiteralPath $j)) {
        $ui.PaneDoc.Document = $null
        $ui.PaneEmpty.Text = 'This conversation has no transcript left on disk.'
        $ui.PaneEmpty.Visibility = $V_Show
        return
    }
    $truncated = $false
    try { $truncated = ((Get-Item -LiteralPath $j).Length -gt $script:tailBytes) } catch { }
    $blocks = @()
    try { $blocks = Get-SRTranscriptBlocks -JsonlPath $j -MaxRecords 220 -MaxTailBytes $script:tailBytes } catch { }
    $doc = Build-ReadDocument -Blocks $blocks -Truncated $truncated
    if ($doc -isnot [System.Windows.Documents.FlowDocument]) {
        throw ('Build-ReadDocument returned {0}, not a FlowDocument - something in it emitted to the pipeline' -f $doc.GetType().Name)
    }
    $ui.PaneDoc.Document = $doc
    $ui.PaneEmpty.Visibility = $V_Hide
}

function Show-Selected {
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return }
    $script:selId = $it.Id
    $script:tailBytes = $script:TailBase     # a new conversation starts at the budget
    $r = $it.Row
    $t = Get-Title $r.S $r.D
    $ui.PaneName.Text = $t.Text
    $b = @($script:Bands | Where-Object { $_.Key -eq "$($r.Band)" })
    $ui.PaneStateDot.Background = $(if ($b.Count) { $window.FindResource($b[0].Acc) } else { $window.FindResource('AccIdle') })
    $detail = $(if ($r.Conv -and "$($r.Conv.Detail)") { "$($r.Conv.Detail)" } else { 'no process is holding it' })
    $ui.PaneState.Text = ('{0}   |   {1}   |   {2}' -f $(if ($b.Count) { $b[0].Label } else { '' }), $detail, (Get-ProjectLabel "$($r.D.path)"))
    Update-Document
    Update-Ask $r
    Update-SendState
    $script:followStamp = $null
}

# FOLLOW ONLY THE SELECTED SESSION. One file, checked once a second, rather than
# a watcher per conversation: 14 run today and the cost has to stay flat in that
# number. Polling one file also has nothing to leak when the selection changes,
# which a FileSystemWatcher does.
$script:followStamp = $null
$script:followTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:followTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:followTimer.Add_Tick({
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return }
    $r = $it.Row
    if (-not $r.Live) { return }
    $j = "$($r.S.jsonl)"
    if (-not $j -or -not (Test-Path -LiteralPath $j)) { return }
    $now = $null
    try { $fi = Get-Item -LiteralPath $j; $now = ('{0}|{1}' -f $fi.Length, $fi.LastWriteTimeUtc.Ticks) } catch { return }
    if ($now -eq $script:followStamp) { return }
    $script:followStamp = $now
    try { Update-Document; Update-Ask $r; Update-SendState } catch { }
})

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

$ui.ManageList.Add_MouseDoubleClick({ Toggle-Tick })
$ui.SaveBtn.Add_Click({
    try {
        Save-SRRegistry -Registry $script:reg
        $script:dirty = $false
        if ($script:surface -eq 'manage') { Build-Manager }
        Set-Status 'saved - those ticks decide what comes back at the next logon' 'ok'
    } catch { Set-Status ("could not save: " + $_.Exception.Message) 'bad' }
})
# ===========================================================================
# THE TWO LOGON BUTTONS
#
# Both stay inside the TICKED set, and they do different things to it:
#   Open not running  starts the ticked conversations nothing is holding.
#   Relaunch sessions CLOSES the ticked ones that ARE running, then opens them
#                     again - which is what you do after signing in, because a
#                     session reads your login and its remote name at startup.
#
# A conversation mid-turn is never taken. The whole promise of relaunch is that
# it does not interrupt work.
# ===========================================================================
function Set-Field { param($Obj, [string]$Name, $Value)
    if ($null -eq $Obj.PSObject.Properties[$Name]) {
        $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    } else { $Obj.$Name = $Value }
}

# Ported from gui-model.ps1 Get-LaunchBlock. Every check is one the logon restore
# already applies, so this button and restore-sessions.ps1 can never disagree
# about what is launchable. $null means it would go; anything else is the reason.
function Get-LaunchBlock { param($R)
    $s = $R.S
    if ($s.gone) { return 'its transcript is gone from disk' }
    $cwd = $(if ("$($s.cwd)") { "$($s.cwd)" } else { "$($R.D.path)" })
    if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { return "its directory no longer exists: $cwd" }
    $jsonl = $null
    try { $jsonl = Get-SRTranscriptPath -Dir $cwd -SessionId $s.sessionId -Recorded $s.jsonl } catch { }
    if (-not $jsonl -or -not (Test-Path -LiteralPath $jsonl)) { return 'its transcript is missing - press Rescan' }
    # A session opened seconds ago has no claude.exe yet: the boot shell is still
    # starting one. Without this, pressing the button twice opens everything twice.
    if ($script:justLaunched.ContainsKey($R.Id)) {
        if (((Get-Date) - $script:justLaunched[$R.Id]).TotalSeconds -lt 90) { return 'it was launched a moment ago' }
    }
    return $null
}

function Get-TickedPlan {
    $fresh = @(); $restart = @(); $busy = @(); $blocked = @()
    foreach ($r in $script:model) {
        if ($r.D.missing -or -not [bool]$r.D.enabled) { continue }
        if (-not [bool]$r.S.enabled) { continue }
        if ($r.A -and $r.A.Pid) {
            # 🔴 THE LIVE NAME OUTRANKS THE REGISTRY, and getting this wrong UNDOES
            # your own work. A conversation renamed by hand reports the new name
            # through claude while the registry still holds whatever discovery last
            # read. Relaunching from the registry would pass the stale title to -n
            # and rename it BACK - silently, inside an action pressed to FIX names.
            $ln = "$($r.A.Name)".Trim()
            if ($ln -and $ln -ne '(untitled)' -and $ln -ne "$($r.S.title)") {
                Write-SRLog ("  [ok]   adopting the live name '{0}' over the recorded '{1}'" -f $ln, $r.S.title)
                Set-Field $r.S 'title' $ln
                $script:dirty = $true
            }
            # 'busy' is claude's own word for a turn in progress. Anything else that
            # is running - idle, waiting, at a login prompt - is safe to take.
            if ("$($r.A.Status)" -eq 'busy') { $busy += $r } else { $restart += $r }
            continue
        }
        $why = Get-LaunchBlock $r
        if ($why) { $blocked += ([PSCustomObject]@{ R = $r; Why = $why }) } else { $fresh += $r }
    }
    $newest = { try { [datetime]$_.S.lastActive } catch { [datetime]0 } }
    return [PSCustomObject]@{
        Fresh   = @($fresh   | Sort-Object $newest -Descending)
        Restart = @($restart | Sort-Object $newest -Descending)
        Busy    = @($busy)
        Blocked = @($blocked)
    }
}

# The maxSessions cap, applied here and SAID OUT LOUD rather than silently - a
# truncated list reads exactly like a complete one.
function Limit-ToCap { param($Items)
    $cap = 0
    try { $cap = [int]$script:cfg.maxSessions } catch { }
    $go = @($Items)
    if ($cap -gt 0 -and $go.Count -gt $cap) {
        return [PSCustomObject]@{ Go = @($go | Select-Object -First $cap); Over = ($go.Count - $cap); Cap = $cap }
    }
    return [PSCustomObject]@{ Go = $go; Over = 0; Cap = $cap }
}

# Launched ONE PER TICK rather than in a loop: Windows Terminal needs breathing
# room between tabs, and a 500 ms sleep per conversation would freeze the window
# for nine seconds over seventeen of them. This keeps the UI alive and reports
# progress as it goes.
$script:launchQueue = New-Object System.Collections.Generic.Queue[object]
$script:launchDone = 0
$script:justLaunched = @{}
$script:launchTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:launchTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:launchTimer.Add_Tick({
    if (-not $script:launchQueue.Count) {
        $script:launchTimer.Stop()
        Set-Status ('opened {0} conversation(s)' -f $script:launchDone) 'ok'
        Update-Model; Update-Surface
        if ($script:surface -eq 'manage') { Build-Manager }
        return
    }
    $r = $script:launchQueue.Dequeue()
    $t = (Get-Title $r.S $r.D).Text
    try {
        $cwd = $(if ("$($r.S.cwd)") { "$($r.S.cwd)" } else { "$($r.D.path)" })
        $boot = New-SRBootScript -Dir $cwd -SessionId "$($r.S.sessionId)" -Title $t
        Start-SRSession -Dir $cwd -BootScript $boot -Title $t
        Write-SRLog ('  [ok]   gui2 launch   {0}  {1}' -f $t, $r.Id)
        $script:justLaunched[$r.Id] = Get-Date
        $script:launchDone++
    } catch {
        Write-SRLog ('  [FAIL] gui2 launch   {0}  {1}' -f $t, $_.Exception.Message)
        Set-Status ('{0} would not open: {1}' -f $t, $_.Exception.Message) 'bad'
    }
    Set-Status ('opening... {0} left' -f $script:launchQueue.Count)
})

function Start-LaunchQueue { param($Items)
    # The ticks decide what comes back at the next logon, and the plan may have
    # just adopted live names. Both belong on disk BEFORE anything is opened.
    if ($script:dirty) {
        try { Save-SRRegistry -Registry $script:reg; $script:dirty = $false }
        catch { Write-SRLog ('  [FAIL] could not save before launching: {0}' -f $_.Exception.Message) }
    }
    $script:launchQueue.Clear()
    $script:launchDone = 0
    foreach ($r in @($Items)) { $script:launchQueue.Enqueue($r) }
    if (-not $script:launchQueue.Count) { Set-Status 'nothing to open' 'warn'; return }
    $script:launchTimer.Start()
}

function Confirm-Action { param([string]$Title, [string]$Body)
    $r = [System.Windows.MessageBox]::Show($Body, $Title,
            [System.Windows.MessageBoxButton]::OKCancel,
            [System.Windows.MessageBoxImage]::Question)
    return ($r -eq [System.Windows.MessageBoxResult]::OK)
}

$ui.OpenNotRunning.Add_Click({
    $plan = Get-TickedPlan
    $lim = Limit-ToCap $plan.Fresh
    $go = @($lim.Go)
    if (-not $go.Count) {
        if (@($plan.Blocked).Count) {
            Set-Status ('nothing to open - {0} ticked conversation(s) cannot be launched: {1}' -f `
                @($plan.Blocked).Count, (@($plan.Blocked)[0].Why)) 'warn'
        } else { Set-Status 'nothing to open - every ticked conversation is already running' 'warn' }
        return
    }
    $names = (@($go | ForEach-Object { (Get-Title $_.S $_.D).Text }) | Sort-Object) -join ', '
    $note = @()
    if ($lim.Over) { $note += ('{0} more are ticked but over the maxSessions cap of {1}, so they are skipped.' -f $lim.Over, $lim.Cap) }
    if (@($plan.Blocked).Count) { $note += ('{0} are ticked but cannot be launched (first: {1}).' -f @($plan.Blocked).Count, (@($plan.Blocked)[0].Why)) }
    if (-not (Confirm-Action 'Open the ticked conversations that are not running' `
        ("{0} will be opened, each in its own tab, half a second apart:`n`n{1}{2}" -f `
            $go.Count, $names, $(if ($note.Count) { "`n`n" + ($note -join '  ') } else { '' })))) {
        Set-Status 'nothing opened'; return
    }
    Start-LaunchQueue $go
})

$ui.RelaunchSessions.Add_Click({
    $plan = Get-TickedPlan
    # 🔴 RELAUNCH RESTARTS; IT DOES NOT OPEN. Taking Fresh as well would mean
    # pressing this to fix the names on 12 running conversations and getting 29
    # tabs. Opening the rest is what the other button is for.
    $lim = Limit-ToCap $plan.Restart
    $go = @($lim.Go)
    if (-not $go.Count) { Set-Status 'nothing to relaunch - no ticked conversation is running, or every one that is is mid-turn' 'warn'; return }
    # 🔴 NAME WHAT WILL BE CLOSED. This kills live processes, and one of them may
    # be the conversation you are talking to right now. A count cannot be checked
    # against that; a list can.
    $names = (@($go | ForEach-Object { (Get-Title $_.S $_.D).Text }) | Sort-Object) -join ', '
    $note = @()
    if (@($plan.Busy).Count) {
        $bn = (@($plan.Busy) | ForEach-Object { (Get-Title $_.S $_.D).Text } | Select-Object -First 6) -join ', '
        $note += ('{0} are mid-turn and will be LEFT ALONE: {1}. They keep the old login - run this again once they finish.' -f @($plan.Busy).Count, $bn)
    }
    # NOT a skip, and said as such: these are simply not running, so a relaunch has
    # nothing to do to them.
    if (@($plan.Fresh).Count) { $note += ("{0} more are ticked but not running - use 'Open not running' for those." -f @($plan.Fresh).Count) }
    if ($lim.Over) { $note += ('{0} more are running but over the maxSessions cap of {1}, so they are skipped.' -f $lim.Over, $lim.Cap) }
    if (-not (Confirm-Action ('Relaunch {0} running conversations' -f $go.Count) `
        ("Each one is CLOSED and then opened again. Use this after signing in, or after reconnecting Remote Control: a running session reads your login AND its remote name at startup, so neither can be picked up without a restart.`n`nClosing: {0}{1}" -f `
            $names, $(if ($note.Count) { "`n`n" + ($note -join '  ') } else { '' })))) {
        Set-Status 'nothing relaunched'; return
    }

    Set-Status 'closing...'
    $killed = 0
    $tabs = New-Object System.Collections.Generic.List[string]
    foreach ($r in $go) {
        $procId = [int]$r.A.Pid
        $proc = $null
        try { $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop } catch { }
        if (-not $proc -or $proc.Name -ne 'claude.exe') { continue }
        $tabName = $(if ("$($r.A.Name)") { "$($r.A.Name)" } else { (Get-Title $r.S $r.D).Text })
        $parent = $null
        try { $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)" -ErrorAction Stop } catch { }
        try { Stop-Process -Id $procId -Force -ErrorAction Stop; $killed++ } catch { continue }
        if ("$tabName".Trim()) { $tabs.Add("$tabName") }
        if ($parent -and $parent.Name -eq 'powershell.exe' -and "$($parent.CommandLine)" -like '*.state*boot-*') {
            try { Stop-Process -Id ([int]$parent.ProcessId) -Force -ErrorAction Stop }
            catch { Write-SRLog ("  [skip] the boot shell for '{0}' would not close: {1}" -f $tabName, $_.Exception.Message) }
        }
    }
    Write-SRLog ('  [ok]   closed {0} session(s) for a relaunch' -f $killed)
    Start-Sleep -Milliseconds 700
    # KILLING THE PROCESSES DOES NOT CLOSE THE TAB. Measured 2026-08-28: 40 tabs
    # for 18 live sessions after one relaunch. Close them explicitly, here,
    # between the kill and the relaunch - a title only identifies a dead tab
    # while the session that owned it is dead.
    try { $null = Close-SRTabsByName -Names $tabs } catch { }
    Start-LaunchQueue $go
})

$ui.SendBox.Add_TextChanged({ Update-SendState })
$ui.SendBtn.Add_Click({ Invoke-Send })
$ui.SendBox.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Return' -and $ui.SendBtn.IsEnabled) { Invoke-Send; $e.Handled = $true }
})

$ui.PaneGoTo.Add_Click({
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return }
    $r = $it.Row
    if (-not $r.A) { Set-Status 'that conversation is not running - there is no terminal to go to' 'warn'; return }
    Set-Status 'finding its tab...'
    $why = $null
    try { $why = Invoke-SRJumpToSession -SessionId $r.S.sessionId -Title "$($r.A.Name)" -RaiseAnyway } catch { $why = $_.Exception.Message }
    if ($why) { Set-Status $why 'warn' } else { Set-Status ('went to {0}' -f $ui.PaneName.Text) 'ok' }
})

$ui.PaneRelaunch.Add_Click({
    Set-Status 'relaunching one conversation is phase 4 work - use the session manager for now' 'warn'
})

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
    if ($script:surface -eq 'manage') {
        if ($e.Key -eq 'Space') { Toggle-Tick; $e.Handled = $true; return }
        if ($e.Key -eq 'O') { $script:showOlder = -not $script:showOlder; Build-Manager; $e.Handled = $true; return }
        if ($e.Key -eq 'Right' -or $e.Key -eq 'Left') {
            $it = $ui.ManageList.SelectedItem
            if ($it -and $it.Kind -eq 'project') {
                $script:fold[$it.Path] = ($e.Key -eq 'Left')
                Build-Manager; $e.Handled = $true; return
            }
        }
    }
    if ($e.Key -eq 'L') {
        # LOAD EARLIER. The pane starts at a tail budget because a 2.5 MB
        # conversation is a multi-second freeze; this doubles it on demand.
        $script:tailBytes = $script:tailBytes * 2
        Update-Document
        Set-Status ('loaded the last {0} KB' -f [int]($script:tailBytes / 1KB))
        $e.Handled = $true; return
    }
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
    $script:followTimer.Start()
})
$window.Add_Closed({ try { $script:followTimer.Stop() } catch { } })

$null = $window.ShowDialog()
