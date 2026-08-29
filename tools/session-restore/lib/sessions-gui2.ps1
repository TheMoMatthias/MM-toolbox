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

# System.Windows.Forms is here for ONE thing: FolderBrowserDialog, which WPF has
# no equivalent of. Loading it lazily inside the handler would put an Add-Type on
# the click path, and a failure there would look like a dead Browse button.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

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
    'TitleBar','WinMin','WinMax','WinClose',
    'LiveCount','Search','Stamp','Rescan','NewSession',
    'ModeWork','ModeManage','Broadcast',
    'WorkSurface','RailCol','ListCol','RailPane','RailSplit','RailList','RailClear',
    'ListPane','ListSplit','ListCaption','ListCount','SessionList',
    'OutputPane','PaneName','PaneState','PaneStateDot','PaneGoTo','PaneRelaunch','PaneSettings',
    'SettingsBox','SetName','SetModel','SetEffort','SetPerm','SetPermNote',
    'SetRemote','SetHidden','SetPending','SetCancel','SetApply',
    'SetToolsFold','SetAllow','SetDeny',
    'CastBox','CastWho','CastList','CastText','CastCancel','CastSend',
    'PaneDoc','PaneEmpty','AskBox','AskHeader','AskText','AskOptions','AskFooter','AskNote',
    'SendNote','SendBox','SendBtn','SkillPop','SkillList','SkillHint',
    'ManageSurface','ManageCaption','ManageList','ManageCount',
    'OpenNotRunning','RelaunchSessions',
    'Status','SaveBtn'
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
# Which conversation the settings panel is editing. Pinned to an id, never to the
# selection: the list rebuilds on a timer, and a panel that followed the
# selection could apply your changes to whatever moved under it.
$script:setFor    = $null
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
        Set-Status 'Session manager: what comes back at the next logon. The ticks decide - and the two buttons act on exactly that set, now.'
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
        # A PROJECT THAT HOLDS A TICK OPENS ITSELF. The whole question this
        # surface answers is "what comes back at my next logon", and folding
        # every project by default meant the answer was never on screen - you
        # had to already know where to look to see what you had chosen.
        # Projects with nothing ticked stay folded: 188 conversations opened at
        # once is not a list, it is a wall.
        $shut = [bool]$script:fold[$k]
        if (-not $script:fold.ContainsKey($k)) {
            $shut = ($armed -eq 0)
            $script:fold[$k] = $shut
        }

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
                # A COLUMN THAT REPEATS THE COLUMN BESIDE IT IS AN EMPTY COLUMN.
                # Worktrees are usually named after the conversation in them, so
                # this printed "GOV-1  GOV-1" down the whole screen. It now says
                # the worktree only when that is news; when the names match it
                # still reports that the conversation is isolated, without
                # spending a column saying the same word twice.
                Lane = (Get-LaneLabel $r $t.Text)
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
    # SAY HOW TO TICK. The gesture is discoverable from nowhere else on this
    # surface, and not knowing it reads exactly like a list that cannot be
    # interacted with at all.
    $ui.ManageCount.Text = ('{0} ticked to reopen at the next logon   |   click a project to open it, click a box to tick it{1}' -f `
        $armedAll, $(if ($script:dirty) { '   |   UNSAVED' } else { '' }))
}

# A PROJECT OPENS ON ONE CLICK; A TICK NEEDS TWO.
#
# 🔴 THIS IS WHY THE MANAGER LOOKED EMPTY. Every project starts folded, and the
# only handler was MouseDoubleClick - so a single click on a project did nothing
# at all, no conversation row was ever reached, and with no conversation rows on
# screen there were no ticks to see, no lane, no last-said and no age. Four
# separate "broken" reports, one cause. Measured 2026-08-29 on the operator's
# own machine.
#
# Opening a fold is free and reversible, so it goes on the cheap gesture. A tick
# decides what reopens at your next logon, so it keeps the deliberate one.
# THE ONE PLACE A TICK CHANGES. Both the mouse and the keyboard come through
# here, so they cannot drift apart.
function Set-TickOn { param($Row)
    if (-not $Row) { return }
    $s = $Row.S
    $now = -not [bool]$s.enabled
    Set-Field $s 'enabled' $now
    # Touching a tick PINS it, or the hourly auto-tick roll takes it away again.
    Set-Field $s 'pinned' $true
    # 🔴 ARM THE PROJECT TOO, or the tick is a lie. Get-TickedPlan skips a whole
    # directory that is not enabled, so ticking a conversation inside a disabled
    # project would show a filled box and then launch nothing at all.
    if ($now -and $Row.D -and -not $Row.D.missing -and -not [bool]$Row.D.enabled) { $Row.D.enabled = $true }
    $script:dirty = $true

    # Build-Manager replaces ItemsSource, which drops the selection. Put the
    # caret back where it was so a run of keyboard ticks does not walk the list.
    $keep = $ui.ManageList.SelectedIndex
    Build-Manager
    if ($keep -ge 0 -and $keep -lt $ui.ManageList.Items.Count) { $ui.ManageList.SelectedIndex = $keep }

    Set-Status ("'{0}' {1} at your next logon - press Save to keep that" -f `
        (Get-Title $s $Row.D).Text, $(if ($now) { 'WILL reopen' } else { 'will NOT reopen' }))
}

function Toggle-Tick {
    $it = $ui.ManageList.SelectedItem
    if (-not $it) { return }
    if ($it.Kind -eq 'project') { $script:fold[$it.Path] = -not [bool]$script:fold[$it.Path]; Build-Manager; return }
    if ($it.Kind -eq 'more')    { $script:showOlder = $true; Build-Manager; return }
    if ($it.Kind -ne 'conv')    { return }
    Set-TickOn $it.Row
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

function Get-LaneLabel { param($R, [string]$Title)
    $lane = "$($R.S.lane)"
    if (-not $lane -or $lane -eq 'main') { return 'main' }
    $wt = "$($R.S.worktree)".Trim()
    if (-not $wt) { return 'worktree' }
    if ($wt -eq "$Title".Trim()) { return 'worktree' }
    return $wt
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
    $script:lastAsk = $q     # kept so the answer record can say what was on offer
    if (-not $q -or -not @($q.Options).Count) { return }

    $ui.AskHeader.Text = $(if ("$($q.Header)") { "$($q.Header)".ToUpper() } else { 'IT IS ASKING' })
    $ui.AskText.Text   = "$($q.Question)"

    # AN OPTION IS A LABEL AND ITS REASONING, and the reasoning is why you would
    # pick it. Each button carries both: the label on top, what claude wrote
    # underneath it below, in the same order it was drawn on screen.
    $details = @($q.Details)
    $btns = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($o in @($q.Options)) {
        $stack = New-Object System.Windows.Controls.StackPanel
        $lab = New-Object System.Windows.Controls.TextBlock
        $lab.Text = ('{0}.  {1}' -f ($n + 1), $o)
        $lab.TextWrapping = 'Wrap'
        $lab.FontWeight = 'SemiBold'
        $null = $stack.Children.Add($lab)

        $d = $(if ($n -lt $details.Count) { "$($details[$n])".Trim() } else { '' })
        if ($d) {
            $sub = New-Object System.Windows.Controls.TextBlock
            $sub.Text = $d
            $sub.TextWrapping = 'Wrap'
            $sub.Margin = New-Object System.Windows.Thickness 0, 3, 0, 0
            $sub.Foreground = $window.FindResource('TextMid')
            $sub.FontSize = 12
            $null = $stack.Children.Add($sub)
        }

        $b = New-Object System.Windows.Controls.Button
        $b.Content = $stack
        $b.Style = $window.FindResource('Btn')
        $b.Margin = New-Object System.Windows.Thickness 0, 0, 0, 6
        $b.HorizontalContentAlignment = 'Left'
        $b.Tag = $n
        $b.Add_Click({ param($s, $e) Invoke-Answer ([int]$s.Tag) })
        $btns.Add($b)
        $n++
    }
    $ui.AskOptions.ItemsSource = $btns

    # The note that qualifies the WHOLE question rather than any one answer. It
    # sits under the buttons because that is where claude put it.
    $foot = "$($q.Footer)".Trim()
    if ($foot) {
        $ui.AskFooter.Text = $foot
        $ui.AskFooter.Visibility = $V_Show
    } else {
        $ui.AskFooter.Visibility = $V_Hide
    }

    if ($q.Multi) {
        $ui.AskNote.Text = 'Several answers. Ticking is wired on an INFERRED reading of the menu footer, and every send is recorded to .state so a wrong reading leaves evidence.'
        $ui.AskNote.Visibility = $V_Show
    } else {
        $ui.AskNote.Visibility = $V_Hide
    }
    $ui.AskBox.Visibility = $V_Show
}

# 🔴 THE SAFEGUARD THE CONTRACT SIGNED FOR AND NEVER GOT.
#
# Answering a menu works by reading the cursor off the screen, counting the
# distance and sending that many arrows. The multi-select reading is INFERRED
# from a menu footer rather than measured, and the deal was: wire it, but make
# every send leave evidence, so one real use converts the guess into a
# measurement.
#
# So each answer records what the screen said BEFORE, which option it believed
# it was choosing, and what the screen said AFTER. If it ever answers the wrong
# thing, the file says exactly what it saw and what it did - which is the only
# way to tell a misread from a mis-send afterwards.
function Write-SRAnswerRecord {
    param([string]$SessionId, [int]$Pid_, [int]$Index, $Question, [string]$Before, [string]$After, [string]$Why)
    try {
        $dir = Join-Path $SR_StateDir 'answers'
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $rec = [PSCustomObject]@{
            at        = (Get-Date).ToString('o')
            sessionId = $SessionId
            pid       = $Pid_
            index     = $Index
            chose     = $(if ($Question -and $Index -lt @($Question.Options).Count) { "$(@($Question.Options)[$Index])" } else { '' })
            options   = @($Question.Options)
            multi     = [bool]$Question.Multi
            cursorAt  = $(if ($Question) { $Question.CursorAt } else { -1 })
            failed    = "$Why"
            before    = $Before
            after     = $After
        }
        $f = Join-Path $dir ('answer-{0}-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), "$SessionId".Substring(0, 8))
        [System.IO.File]::WriteAllText($f, ($rec | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }   # evidence is never worth failing the answer over
}

function Invoke-Answer { param([int]$Index)
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return }
    $r = $it.Row
    if (-not $r.A -or -not $r.A.Pid) { Set-Status 'that conversation is not running any more' 'warn'; return }
    Set-Status 'answering...'
    $procId = [int]$r.A.Pid
    $before = $null
    try { $before = Get-SRScreenText -ProcessId $procId } catch { }
    $why = $null
    try { $why = Send-SRQuestionAnswer -SessionId $r.Id -Index $Index } catch { $why = $_.Exception.Message }
    $after = $null
    try { Start-Sleep -Milliseconds 400; $after = Get-SRScreenText -ProcessId $procId } catch { }
    Write-SRAnswerRecord -SessionId $r.Id -Pid_ $procId -Index $Index -Question $script:lastAsk `
                         -Before "$before" -After "$after" -Why "$why"
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

# 🔴 THE EXPENSIVE HALF ONLY RUNS WHEN THE SELECTION ACTUALLY MOVED.
#
# Build-Sessions rebuilds its rows as NEW objects and then restores the
# selection by id, which fires SelectionChanged even though the same
# conversation is still selected. That re-rendered the transcript AND spawned a
# child process to read the session's console - measured 2,336 ms for one
# repaint, more than a full model rebuild. Every search keystroke paid it, so
# typing in the search box froze the window for two seconds a time, and it is
# what would have made a 6-second refresh timer unusable.
#
# It also silently undid 'load earlier': tailBytes was reset on every repaint,
# so a conversation you had expanded snapped back to the budget on the next
# rebuild.
#
# -Force is for the caller that knows the CONTENT moved even though the
# selection did not - the periodic refresh.
function Show-Selected { param([switch]$Force)
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return }
    $same = ($script:selId -eq $it.Id)
    $script:selId = $it.Id
    $r = $it.Row
    $t = Get-Title $r.S $r.D
    $ui.PaneName.Text = $t.Text
    $b = @($script:Bands | Where-Object { $_.Key -eq "$($r.Band)" })
    $ui.PaneStateDot.Background = $(if ($b.Count) { $window.FindResource($b[0].Acc) } else { $window.FindResource('AccIdle') })
    $detail = $(if ($r.Conv -and "$($r.Conv.Detail)") { "$($r.Conv.Detail)" } else { 'no process is holding it' })
    $ui.PaneState.Text = ('{0}   |   {1}   |   {2}' -f $(if ($b.Count) { $b[0].Label } else { '' }), $detail, (Get-ProjectLabel "$($r.D.path)"))

    # Everything above is a few string assignments and is always safe to redo.
    # Everything below reads files and spawns a process.
    if ($same -and -not $Force) { return }

    $script:tailBytes = $script:TailBase     # a new conversation starts at the budget
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
# 🔴 UNSAVED TICKS ARE LOST SILENTLY OTHERWISE. The ticks decide what comes back
# at your next logon, and closing the window threw them away without a word -
# which matters far more now that ticking is reachable at all.
$window.Add_Closing({
    param($sender, $e)
    if (-not $script:dirty) { return }
    $r = [System.Windows.MessageBox]::Show(
        "Your ticks have not been saved. They decide which conversations reopen at your next logon.`n`nSave them before closing?",
        'Unsaved ticks',
        [System.Windows.MessageBoxButton]::YesNoCancel,
        [System.Windows.MessageBoxImage]::Warning)
    if ($r -eq [System.Windows.MessageBoxResult]::Cancel) { $e.Cancel = $true; return }
    if ($r -eq [System.Windows.MessageBoxResult]::Yes) {
        try { Save-SRRegistry -Registry $script:reg; $script:dirty = $false }
        catch {
            [void][System.Windows.MessageBox]::Show(
                ("Could not save: " + $_.Exception.Message), 'Not saved',
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            $e.Cancel = $true
        }
    }
})

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

# ===========================================================================
# EVERY MOUSE GESTURE ON THE MANAGER, IN ONE TUNNELLING HANDLER.
#
# 🔴 WHY NOT MouseDoubleClick. ListBoxItem marks the left-button-down HANDLED
# when it selects itself, so ListBox.MouseDoubleClick never fires and the
# handler that was bound to it could not tick anything - measured 2026-08-29,
# reported as "I cannot tick or untick any sessions". PreviewMouseLeftButtonDown
# TUNNELS: it reaches the ListBox on the way DOWN, before any item can swallow
# it, so it always arrives. There is exactly one mouse path now; binding the
# bubbling event as well would toggle twice and look like nothing happened.
#
# 🪤 RESOLVE THE ROW FROM WHAT WAS CLICKED, never from SelectedItem. A click on
# the empty space under the last row leaves SelectedItem pointing at whatever
# was selected before, and would tick a conversation the mouse never touched.
function Get-ClickedRow { param($Source)
    $d = $Source
    while ($d -and -not ($d -is [System.Windows.Controls.ListBoxItem])) {
        $d = [System.Windows.Media.VisualTreeHelper]::GetParent($d)
    }
    if ($d) { return $d.DataContext }
    return $null
}

# Was the tick box itself clicked, rather than the row it sits on?
function Test-ClickedTick { param($Source)
    $d = $Source
    while ($d) {
        if (($d -is [System.Windows.FrameworkElement]) -and $d.Name -eq 'TickBox') { return $true }
        if ($d -is [System.Windows.Controls.ListBoxItem]) { return $false }
        $d = [System.Windows.Media.VisualTreeHelper]::GetParent($d)
    }
    return $false
}

$ui.ManageList.Add_PreviewMouseLeftButtonDown({
    param($sender, $e)
    $it = Get-ClickedRow $e.OriginalSource
    if (-not $it) { return }
    switch ("$($it.Kind)") {
        'project' { $script:fold[$it.Path] = -not [bool]$script:fold[$it.Path]; Build-Manager; return }
        'more'    { $script:showOlder = $true; Build-Manager; return }
        'conv'    {
            # The box takes ONE click - that is what a checkbox is for, and it is
            # the only gesture on this surface anyone will guess. Double-clicking
            # anywhere on the row does the same thing, for the people who try that
            # instead.
            if ((Test-ClickedTick $e.OriginalSource) -or $e.ClickCount -eq 2) {
                Set-TickOn $it.Row
            }
            return
        }
    }
})
# ===========================================================================
# ACTING ON ONE ROW IN THE MANAGER
#
# The operator asked to "select any session or terminal for relaunch or for
# launching it" and looked for it HERE - the manager is the surface that lists
# everything, so it is where a per-conversation action is expected. It existed
# only on the work surface. Right-click, because the left button already does
# the two things this surface is for: opening a project and ticking a
# conversation.
# ===========================================================================
function New-ManageMenu {
    $m = New-Object System.Windows.Controls.ContextMenu
    $mk = {
        param([string]$Header, [scriptblock]$Do)
        $i = New-Object System.Windows.Controls.MenuItem
        $i.Header = $Header
        $i.Add_Click($Do)
        $null = $m.Items.Add($i)
        return $i
    }
    $null = & $mk 'Open it now' {
        $r = Get-ManageRow; if (-not $r) { return }
        if ($r.A -and $r.A.Pid) { Set-Status 'that conversation is already running' 'warn'; return }
        Start-LaunchQueue @($r)
    }
    $null = & $mk 'Relaunch it' {
        $r = Get-ManageRow; if (-not $r) { return }
        if (-not ($r.A -and $r.A.Pid)) { Set-Status 'that conversation is not running - use Open it now' 'warn'; return }
        $t = (Get-Title $r.S $r.D).Text
        if (Confirm-Action 'Relaunch this conversation' `
            ("'{0}' will be CLOSED and opened again." -f $t)) { Invoke-RelaunchOne $r }
    }
    $null = & $mk 'Go to its terminal' {
        $r = Get-ManageRow; if (-not $r) { return }
        $why = $null
        try { $why = Invoke-SRJumpToSession -SessionId $r.Id } catch { $why = $_.Exception.Message }
        if ($why) { Set-Status $why 'warn' } else { Set-Status 'jumped to its tab' 'ok' }
    }
    $null = $m.Items.Add((New-Object System.Windows.Controls.Separator))
    $null = & $mk 'Settings...' {
        $r = Get-ManageRow; if (-not $r) { return }
        # The settings panel lives on the work surface, so go there and select it
        # first - opening a panel on a surface you cannot see is not an action.
        $script:selId = $r.Id
        $ui.ModeWork.IsChecked = $true
        Set-Surface 'work'
        Build-Sessions
        Show-Settings
    }
    return $m
}

# The row the CONTEXT MENU was opened on, not whatever happens to be selected.
$script:manageMenuRow = $null
function Get-ManageRow {
    if ($script:manageMenuRow) { return $script:manageMenuRow }
    $it = $ui.ManageList.SelectedItem
    if ($it -and $it.Kind -eq 'conv') { return $it.Row }
    return $null
}

$ui.ManageList.ContextMenu = New-ManageMenu
$ui.ManageList.Add_PreviewMouseRightButtonDown({
    param($sender, $e)
    $it = Get-ClickedRow $e.OriginalSource
    # A project header and the "older conversations" row have no actions, so
    # they get no menu rather than a menu that does nothing.
    if (-not $it -or $it.Kind -ne 'conv') {
        $script:manageMenuRow = $null
        $ui.ManageList.ContextMenu.IsOpen = $false
        $e.Handled = $true
        return
    }
    $script:manageMenuRow = $it.Row
    # Select it too, so the menu and the highlight agree about the target.
    $ui.ManageList.SelectedItem = $it
})

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
$script:launchFailed = New-Object System.Collections.Generic.List[string]
$script:justLaunched = @{}
$script:launchTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:launchTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:launchTimer.Add_Tick({
    if (-not $script:launchQueue.Count) {
        $script:launchTimer.Stop()
        # WHAT DID NOT OPEN IS THE HALF THAT MATTERS. After a relaunch these
        # conversations have already been closed, so one that failed to reopen
        # is a conversation currently SHUT - saying only how many succeeded
        # hides exactly the case you need to act on.
        if ($script:launchFailed.Count) {
            Set-Status ('opened {0}, but {1} did NOT open: {2}   -   they are closed; press Open not running to retry' -f `
                $script:launchDone, $script:launchFailed.Count, (($script:launchFailed | Select-Object -First 6) -join ', ')) 'bad'
        } else {
            Set-Status ('opened {0} conversation(s)' -f $script:launchDone) 'ok'
        }
        Update-Model; Update-Surface
        if ($script:surface -eq 'manage') { Build-Manager }
        return
    }
    # 🔴 NOTHING IN THIS TICK MAY THROW. An unhandled exception out of a
    # DispatcherTimer tick takes the window down, and this tick runs immediately
    # after a relaunch has already CLOSED the conversations it is reopening -
    # losing the window here would leave the whole set shut with no way to
    # reopen it from the tool. So the title lookup is inside the try too.
    $r = $script:launchQueue.Dequeue()
    $t = '(unnamed)'
    try {
        $t = (Get-Title $r.S $r.D).Text
        $cwd = $(if ("$($r.S.cwd)") { "$($r.S.cwd)" } else { "$($r.D.path)" })
        # The conversation's own settings, applied at the only moment claude can
        # read them. This is what makes a settings change real.
        $boot = New-SRBootScript -Dir $cwd -SessionId "$($r.S.sessionId)" -Title $t `
                    -ClaudeArgs (Get-SRSessionArgs $r.S) -RemoteControl (Test-SRRemoteWanted $r.S)
        if (Test-SRHiddenWanted $r.S) {
            $null = Start-SRHiddenSession -Dir $cwd -BootScript $boot -Title $t
        } else {
            Start-SRSession -Dir $cwd -BootScript $boot -Title $t
        }
        Write-SRLog ('  [ok]   gui2 launch   {0}  {1}  {2}' -f $t, $r.Id, (Get-SRSessionArgsLabel $r.S))
        $script:justLaunched[$r.Id] = Get-Date
        $script:launchDone++
    } catch {
        Write-SRLog ('  [FAIL] gui2 launch   {0}  {1}' -f $t, $_.Exception.Message)
        $script:launchFailed.Add($t)
    }
    Set-Status ('opening... {0} left{1}' -f $script:launchQueue.Count,
        $(if ($script:launchFailed.Count) { ("   |   {0} failed so far" -f $script:launchFailed.Count) } else { '' }))
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
    $script:launchFailed.Clear()
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

# ===========================================================================
# THE SKILL PICKER
#
# '/' at the START of the composer opens it - the same gesture that opens it
# inside claude itself, so there is nothing new to learn - and it filters as you
# type. Up/Down move, Enter or Tab completes, Escape closes without touching
# what you typed.
#
# It only ever completes the NAME. What the skill does with its arguments is
# claude's business; this is a way of not having to remember 55 names.
# ===========================================================================
# 🪤 THE OPEN STATE IS OURS, NOT THE POPUP'S. A WPF Popup will not stay open
# while its placement target has never been rendered, so reading IsOpen back is
# reading the visual layer's opinion rather than the intent - and the key handler
# below has to know whether Down/Enter belong to the picker or to the composer.
# Asking a variable is also the only way this is testable headlessly.
$script:skillOpen = $false

function Close-SkillPop { $script:skillOpen = $false; $ui.SkillPop.IsOpen = $false }
function Open-SkillPop  { $script:skillOpen = $true;  $ui.SkillPop.IsOpen = $true }

function Update-SkillPop {
    $t = "$($ui.SendBox.Text)"
    # Only a line that BEGINS with '/'. A slash inside a sentence is a slash.
    if (-not $t.StartsWith('/')) { Close-SkillPop; return }
    # As soon as there is a space the name is finished and the rest is arguments.
    if ($t -match '\s') { Close-SkillPop; return }

    $r = Get-SelectedRow
    $dir = $(if ($r) { $(if ("$($r.S.cwd)") { "$($r.S.cwd)" } else { "$($r.D.path)" }) } else { '' })
    $skills = @()
    try { $skills = Get-SRSkills -Dir $dir } catch { }
    if (-not @($skills).Count) { Close-SkillPop; return }

    $hits = @(Select-SRSkills -Skills $skills -Query $t.Substring(1) -Limit 8)
    if (-not $hits.Count) {
        $ui.SkillHint.Text = ("NO SKILL MATCHES '{0}'" -f $t.Substring(1).ToUpper())
        $ui.SkillList.ItemsSource = $null
        Open-SkillPop
        return
    }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($s in $hits) {
        $b = "$($s.Description)"
        # The first sentence is the useful half; these descriptions run for
        # paragraphs and a row is one line high.
        $cut = $b.IndexOf('. ')
        if ($cut -gt 20) { $b = $b.Substring(0, $cut + 1) }
        $rows.Add([PSCustomObject]@{
            Label = ('/' + $s.Name); Blurb = ($b -replace '\s+', ' '); Source = $s.Source; Name = $s.Name
        })
    }
    $ui.SkillHint.Text = ('SKILLS   {0} of {1}' -f $rows.Count, @($skills).Count)
    $ui.SkillList.ItemsSource = $rows
    $ui.SkillList.SelectedIndex = 0
    Open-SkillPop
}

function Complete-Skill {
    $it = $ui.SkillList.SelectedItem
    if (-not $it) { return $false }
    # A trailing space, because a skill is nearly always followed by something.
    $ui.SendBox.Text = ('/{0} ' -f $it.Name)
    $ui.SendBox.CaretIndex = $ui.SendBox.Text.Length
    Close-SkillPop
    return $true
}

$ui.SendBox.Add_TextChanged({ Update-SendState; Update-SkillPop })
$ui.SendBtn.Add_Click({ Invoke-Send })
$ui.SkillList.Add_MouseLeftButtonUp({ $null = Complete-Skill; $null = $ui.SendBox.Focus() })

# 🪤 PreviewKeyDown, not KeyDown. The arrow keys and Enter have to be taken
# BEFORE the TextBox sees them, or Enter sends the half-typed '/name' into the
# session instead of completing it - which would be a keystroke you cannot take
# back.
$ui.SendBox.Add_PreviewKeyDown({
    param($sender, $e)
    if ($script:skillOpen) {
        switch ("$($e.Key)") {
            'Down'   { if ($ui.SkillList.Items.Count) { $ui.SkillList.SelectedIndex = [Math]::Min($ui.SkillList.SelectedIndex + 1, $ui.SkillList.Items.Count - 1) }; $e.Handled = $true; return }
            'Up'     { if ($ui.SkillList.Items.Count) { $ui.SkillList.SelectedIndex = [Math]::Max($ui.SkillList.SelectedIndex - 1, 0) }; $e.Handled = $true; return }
            'Escape' { Close-SkillPop; $e.Handled = $true; return }
            'Tab'    { $null = Complete-Skill; $e.Handled = $true; return }
            'Return' { if (Complete-Skill) { $e.Handled = $true; return } }
        }
    }
    if ($e.Key -eq 'Return' -and $ui.SendBtn.IsEnabled) { Invoke-Send; $e.Handled = $true }
})
# Losing focus closes it, or it hangs over the window after you click away.
$ui.SendBox.Add_LostKeyboardFocus({ Close-SkillPop })

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

# The row the output pane is currently showing.
function Get-SelectedRow {
    $it = $ui.SessionList.SelectedItem
    if ($it -and $it.Kind -eq 'session') { return $it.Row }
    if ($script:selId) {
        foreach ($x in $script:model) { if ($x.Id -eq $script:selId) { return $x } }
    }
    return $null
}

# ONE conversation, closed and opened again. The same three steps the bulk
# Relaunch takes - kill claude, kill its boot shell, close the dead tab - and
# then the queue, so a single relaunch and a bulk one cannot drift apart.
function Invoke-RelaunchOne { param($R)
    if (-not $R) { return }
    $t = (Get-Title $R.S $R.D).Text
    if ($R.A -and $R.A.Pid) {
        if ("$($R.A.Status)" -eq 'busy') {
            Set-Status ("'{0}' is mid-turn - closing it now would lose the reply it is writing" -f $t) 'warn'
            return
        }
        Set-Status ("closing '{0}'..." -f $t)
        $procId = [int]$R.A.Pid
        $proc = $null
        try { $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop } catch { }
        # A pid is reusable: confirm THIS one is still the claude that owns the
        # conversation before killing anything.
        if ($proc -and $proc.Name -eq 'claude.exe') {
            $parent = $null
            try { $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)" -ErrorAction Stop } catch { }
            try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch { }
            if ($parent -and $parent.Name -eq 'powershell.exe' -and "$($parent.CommandLine)" -like '*.state*boot-*') {
                try { Stop-Process -Id ([int]$parent.ProcessId) -Force -ErrorAction Stop } catch { }
            }
            Start-Sleep -Milliseconds 700
            $tab = $(if ("$($R.A.Name)") { "$($R.A.Name)" } else { $t })
            try { $null = Close-SRTabsByName -Names @($tab) } catch { }
        }
    }
    Start-LaunchQueue @($R)
}

$ui.PaneRelaunch.Add_Click({
    $r = Get-SelectedRow
    if (-not $r) { Set-Status 'select a conversation first' 'warn'; return }
    $t = (Get-Title $r.S $r.D).Text
    if (-not ($r.A -and $r.A.Pid)) {
        if (Confirm-Action 'Open this conversation' ("'{0}' is not running. Open it now?" -f $t)) {
            Start-LaunchQueue @($r)
        }
        return
    }
    if (Confirm-Action 'Relaunch this conversation' `
        ("'{0}' will be CLOSED and opened again. Anything it has written is on disk; a turn in progress is not." -f $t)) {
        Invoke-RelaunchOne $r
    }
})

# ===========================================================================
# THE CONTROL PLANE
#
# 🔴 EVERY SETTING HERE IS A LAUNCH FLAG. claude reads --model, --effort,
# --permission-mode and --remote-control ONCE, at startup; there is no way to
# change them on a running process. So Apply writes them down and then offers
# the relaunch that makes them real. A dropdown that silently did nothing would
# be worse than no dropdown at all.
# ===========================================================================

# What each mode actually does, in the words that matter when you are choosing
# one at speed. An operator picking 'bypassPermissions' should not have to
# remember what it costs.
$script:PermNotes = @{
    ''                  = 'Whatever this machine already defaults to.'
    'manual'            = 'Asks before every tool call. Slowest, and nothing happens without you.'
    'default'           = 'Asks before anything it has not been allowed.'
    'acceptEdits'       = 'Edits files without asking; still asks before running commands.'
    'auto'              = 'Decides for itself which calls need you. The usual choice for a session you leave running.'
    'dontAsk'           = 'Never stops to ask. It will not wait for you - and it will not warn you either.'
    'plan'              = 'Reads and plans, changes nothing. Safe for a session you want to think, not act.'
    'bypassPermissions' = 'NO permission checks at all. Every command runs. Only for a sandbox you can afford to lose.'
}

function Show-Settings {
    $r = Get-SelectedRow
    if (-not $r) { Set-Status 'select a conversation first' 'warn'; return }
    $script:setFor = $r.Id

    $ui.SetName.Text = (Get-Title $r.S $r.D).Text
    Set-DropValue $ui.SetModel  "$(Get-SRSessionPref $r.S 'model')"
    Set-DropValue $ui.SetEffort "$(Get-SRSessionPref $r.S 'effort')"
    Set-DropValue $ui.SetPerm   "$(Get-SRSessionPref $r.S 'permissionMode')"
    $ui.SetRemote.IsChecked = (Test-SRRemoteWanted $r.S)
    $ui.SetHidden.IsChecked = (Test-SRHiddenWanted $r.S)
    $ui.SetAllow.Text = ((@(Get-SRSessionPref $r.S 'allowedTools')    | Where-Object { "$_".Trim() }) -join ' ')
    $ui.SetDeny.Text  = ((@(Get-SRSessionPref $r.S 'disallowedTools') | Where-Object { "$_".Trim() }) -join ' ')
    # Open the fold only when there is something in it, so the panel stays short
    # for the common case and cannot hide a limit you forgot you set.
    $ui.SetToolsFold.IsExpanded = [bool]("$($ui.SetAllow.Text)$($ui.SetDeny.Text)".Trim())
    Update-PermNote

    # Say up front whether anything changed here can take effect without a
    # relaunch. For a conversation that is not running, the answer is "it just
    # will", and that is worth knowing too.
    if ($r.A -and $r.A.Pid) {
        $ui.SetPending.Text = 'This conversation is running. claude reads these once, at startup, so Apply will offer to close and reopen it.'
        $ui.SetPending.Visibility = $V_Show
    } else {
        $ui.SetPending.Visibility = $V_Hide
    }
    $ui.SettingsBox.Visibility = $V_Show
    $null = $ui.SetName.Focus()
}

function Hide-Settings { $ui.SettingsBox.Visibility = $V_Hide; $script:setFor = $null }

function Set-DropValue { param($Combo, [string]$Value)
    foreach ($it in @($Combo.Items)) {
        if ("$($it.Tag)" -eq "$Value") { $Combo.SelectedItem = $it; return }
    }
    if ($Combo.Items.Count) { $Combo.SelectedIndex = 0 }
}
function Get-DropValue { param($Combo)
    $it = $Combo.SelectedItem
    if (-not $it) { return '' }
    return "$($it.Tag)"
}

function Update-PermNote {
    $v = Get-DropValue $ui.SetPerm
    $ui.SetPermNote.Text = $(if ($script:PermNotes.ContainsKey($v)) { $script:PermNotes[$v] } else { '' })
    # The one mode that can cost you the machine gets said in the accent colour
    # that means "this needs you".
    $ui.SetPermNote.Foreground = $(if ($v -eq 'bypassPermissions' -or $v -eq 'dontAsk') {
        $window.FindResource('AccNeeds') } else { $window.FindResource('TextLow') })
}

# The dropdown contents. Tag carries the value claude wants; Content carries what
# a person reads.
function Build-SettingDrops {
    $mk = {
        param($pairs)
        $l = New-Object System.Collections.Generic.List[object]
        foreach ($p in $pairs) {
            $i = New-Object System.Windows.Controls.ComboBoxItem
            $i.Content = $p[1]; $i.Tag = $p[0]
            $l.Add($i)
        }
        return ,$l.ToArray()
    }
    $ui.SetModel.ItemsSource = (& $mk @(
        @('',              'Default for this machine'),
        @('opus',          'Opus - the hard ones'),
        @('sonnet',        'Sonnet - fast and capable'),
        @('haiku',         'Haiku - cheap watchers')))
    $ui.SetEffort.ItemsSource = (& $mk @(
        @('',       'Default'),
        @('low',    'Low'),
        @('medium', 'Medium'),
        @('high',   'High'),
        @('xhigh',  'Extra high'),
        @('max',    'Max')))
    $ui.SetPerm.ItemsSource = (& $mk @(
        @('',                  'Default for this machine'),
        @('manual',            'Manual - ask every time'),
        @('acceptEdits',       'Accept edits'),
        @('auto',              'Auto'),
        @('plan',              'Plan only - change nothing'),
        @('dontAsk',           'Never ask'),
        @('bypassPermissions', 'Bypass all checks')))
}
Build-SettingDrops

$ui.SetPerm.Add_SelectionChanged({ Update-PermNote })
$ui.PaneSettings.Add_Click({ if ($ui.SettingsBox.Visibility -eq $V_Show) { Hide-Settings } else { Show-Settings } })
$ui.SetCancel.Add_Click({ Hide-Settings; Set-Status 'nothing changed' })

$ui.SetApply.Add_Click({
    $r = $null
    foreach ($x in $script:model) { if ($x.Id -eq $script:setFor) { $r = $x; break } }
    if (-not $r) { Hide-Settings; Set-Status 'that conversation is gone' 'warn'; return }

    $newName = "$($ui.SetName.Text)".Trim()
    if (-not $newName) { Set-Status 'a conversation needs a name' 'warn'; return }

    $was = (Get-SRSessionArgsLabel $r.S) + '|' + (Get-Title $r.S $r.D).Text
    Set-Field $r.S 'title' $newName
    Set-SRSessionPref $r.S 'model'          (Get-DropValue $ui.SetModel)
    Set-SRSessionPref $r.S 'effort'         (Get-DropValue $ui.SetEffort)
    Set-SRSessionPref $r.S 'permissionMode' (Get-DropValue $ui.SetPerm)
    Set-SRSessionPref $r.S 'remoteControl'  ([bool]$ui.SetRemote.IsChecked)
    Set-SRSessionPref $r.S 'hidden'         ([bool]$ui.SetHidden.IsChecked)
    # 🪤 SPLIT ON WHITESPACE, and drop the empties. A trailing space would
    # otherwise become an EMPTY RULE on the command line, and claude reads an
    # empty --allowedTools as "allow nothing" - a session that can do nothing at
    # all, from a stray keystroke.
    Set-SRSessionPref $r.S 'allowedTools'    (@("$($ui.SetAllow.Text)" -split '\s+' | Where-Object { "$_".Trim() }))
    Set-SRSessionPref $r.S 'disallowedTools' (@("$($ui.SetDeny.Text)"  -split '\s+' | Where-Object { "$_".Trim() }))
    $script:dirty = $true
    $now = (Get-SRSessionArgsLabel $r.S) + '|' + $newName

    try { Save-SRRegistry -Registry $script:reg; $script:dirty = $false } catch {
        Set-Status ('saved nothing: ' + $_.Exception.Message) 'bad'; return
    }
    Hide-Settings
    Update-Model; Update-Surface

    if ($was -eq $now) { Set-Status 'nothing changed' ; return }

    # It is written down. Now the only thing that can make it real.
    $live = $null
    foreach ($x in $script:model) { if ($x.Id -eq $script:setFor) { $live = $x; break } }
    if (-not ($live -and $live.A -and $live.A.Pid)) {
        Set-Status 'saved - it takes effect the next time this conversation opens' 'ok'
        return
    }
    if ("$($live.A.Status)" -eq 'busy') {
        Set-Status 'saved, but this conversation is mid-turn - relaunch it yourself when it stops' 'warn'
        return
    }
    if (Confirm-Action 'Relaunch to apply' `
        ("claude reads these settings once, at startup, so '{0}' has to be closed and reopened for them to take effect.`n`nDo that now?" -f $newName)) {
        Invoke-RelaunchOne $live
    } else {
        Set-Status 'saved - it takes effect the next time this conversation opens' 'ok'
    }
})

# ===========================================================================
# SPAWNING A NEW CONVERSATION
#
# A small window rather than another overlay, because it is a decision you make
# once and then leave: it can be moved, and it holds still while you look at
# something behind it.
#
# 🔑 IT REMEMBERS. The fields come back as you last left them, and the project
# defaults to wherever you were working most recently - which is almost always
# the answer, so the common case is press-Enter.
# ===========================================================================
$script:spawnLast = $null

function Get-SpawnDefaults {
    if ($script:spawnLast) { return $script:spawnLast }
    # First time: read whatever the last session was configured with, so a new
    # conversation inherits the shape of the work already in flight.
    $newest = $null
    foreach ($r in $script:model) {
        if (-not $newest) { $newest = $r; continue }
        try { if ([datetime]$r.S.lastActive -gt [datetime]$newest.S.lastActive) { $newest = $r } } catch { }
    }
    $d = [PSCustomObject]@{
        Dir = ''; Model = ''; Effort = ''; Perm = ''
        Remote = $true; Hidden = $false; Worktree = $false
    }
    if ($newest) {
        $d.Dir    = "$($newest.D.path)"
        $d.Model  = "$(Get-SRSessionPref $newest.S 'model')"
        $d.Effort = "$(Get-SRSessionPref $newest.S 'effort')"
        $d.Perm   = "$(Get-SRSessionPref $newest.S 'permissionMode')"
        $d.Remote = (Test-SRRemoteWanted $newest.S)
    }
    return $d
}

function Show-Spawn {
    $xp = Join-Path $here 'spawn2.xaml'
    if (-not (Test-Path -LiteralPath $xp)) { Set-Status 'spawn2.xaml is missing from lib' 'bad'; return }
    $sp = $null
    try {
        $sr = New-Object System.Xml.XmlNodeReader ([xml](Get-Content -LiteralPath $xp -Raw))
        $sp = [Windows.Markup.XamlReader]::Load($sr)
    } catch { Set-Status ('the new-session window would not load: ' + $_.Exception.Message) 'bad'; return }
    $sp.Owner = $window

    $s = @{}
    foreach ($n in @('SpTitleBar','SpClose','SpDir','SpBrowse','SpDirPath','SpName','SpModel','SpEffort',
                     'SpPerm','SpPermNote','SpRemote','SpHidden','SpWorktree','SpWarn','SpHint',
                     'SpCancel','SpStart')) {
        $el = $sp.FindName($n)
        if (-not $el) { Set-Status "spawn2.xaml has no element named '$n'" 'bad'; return }
        $s[$n] = $el
    }

    # 🪤 THE DIALOG HAS NO STYLES OF ITS OWN. Without this every control renders
    # as stock WPF grey with a 3D bevel next to a dark window. The Style objects
    # already have their brushes resolved, so handing them across windows is safe.
    foreach ($c in @('SpDir','SpModel','SpEffort','SpPerm')) { $s[$c].Style = $window.FindResource('Drop') }
    foreach ($c in @('SpRemote','SpHidden','SpWorktree'))    { $s[$c].Style = $window.FindResource('Check') }
    $s.SpName.Style   = $window.FindResource('Search')
    $s.SpName.Tag     = 'What this conversation will be called'
    $s.SpBrowse.Style = $window.FindResource('Btn')
    $s.SpCancel.Style = $window.FindResource('Btn')
    $s.SpStart.Style  = $window.FindResource('BtnPrimary')

    $mk = {
        param($pairs)
        $l = New-Object System.Collections.Generic.List[object]
        foreach ($p in $pairs) {
            $i = New-Object System.Windows.Controls.ComboBoxItem
            $i.Content = $p[1]; $i.Tag = $p[0]
            $l.Add($i)
        }
        return ,$l.ToArray()
    }
    $s.SpModel.ItemsSource = (& $mk @(
        @('','Default for this machine'), @('opus','Opus - the hard ones'),
        @('sonnet','Sonnet - fast and capable'), @('haiku','Haiku - cheap watchers')))
    $s.SpEffort.ItemsSource = (& $mk @(
        @('','Default'), @('low','Low'), @('medium','Medium'),
        @('high','High'), @('xhigh','Extra high'), @('max','Max')))
    $s.SpPerm.ItemsSource = (& $mk @(
        @('','Default for this machine'), @('manual','Manual - ask every time'),
        @('acceptEdits','Accept edits'), @('auto','Auto'),
        @('plan','Plan only - change nothing'), @('dontAsk','Never ask'),
        @('bypassPermissions','Bypass all checks')))

    # The projects you already work in, newest first - the answer is nearly
    # always one of them, and Browse is there for when it is not.
    $seen = @{}
    $dirs = New-Object System.Collections.Generic.List[object]
    foreach ($d in $script:dirs) {
        if ($d.missing) { continue }
        $p = "$($d.path)"
        if (-not $p -or $seen.ContainsKey($p)) { continue }
        $seen[$p] = $true
        $i = New-Object System.Windows.Controls.ComboBoxItem
        $i.Content = (Get-ProjectLabel $p); $i.Tag = $p
        $dirs.Add($i)
    }
    $s.SpDir.ItemsSource = $dirs.ToArray()

    $def = Get-SpawnDefaults
    Set-DropValue $s.SpDir    $def.Dir
    Set-DropValue $s.SpModel  $def.Model
    Set-DropValue $s.SpEffort $def.Effort
    Set-DropValue $s.SpPerm   $def.Perm
    $s.SpRemote.IsChecked   = [bool]$def.Remote
    $s.SpHidden.IsChecked   = [bool]$def.Hidden
    $s.SpWorktree.IsChecked = [bool]$def.Worktree
    $s.SpName.Text = ''

    $refresh = {
        $dir = Get-DropValue $s.SpDir
        $s.SpDirPath.Text = $dir
        $v = Get-DropValue $s.SpPerm
        $s.SpPermNote.Text = $(if ($script:PermNotes.ContainsKey($v)) { $script:PermNotes[$v] } else { '' })
        $s.SpPermNote.Foreground = $(if ($v -eq 'bypassPermissions' -or $v -eq 'dontAsk') {
            $window.FindResource('AccNeeds') } else { $window.FindResource('TextLow') })
        # A worktree needs a git repository, and saying so here beats a launch
        # that fails in a terminal you then have to go and read.
        $warn = ''
        if ($s.SpWorktree.IsChecked -and $dir) {
            if (-not (Test-Path -LiteralPath (Join-Path $dir '.git'))) {
                $warn = 'That folder is not a git repository, so a worktree cannot be made there.'
            }
        }
        if ($warn) { $s.SpWarn.Text = $warn; $s.SpWarn.Visibility = $V_Show }
        else { $s.SpWarn.Visibility = $V_Hide }
        $s.SpHint.Text = $(if ($s.SpHidden.IsChecked) { 'It will run with no window. You can still read and answer it here.' } else { 'It opens in its own terminal tab.' })
    }
    & $refresh
    $s.SpDir.Add_SelectionChanged($refresh)
    $s.SpPerm.Add_SelectionChanged($refresh)
    $s.SpWorktree.Add_Click($refresh)
    $s.SpHidden.Add_Click($refresh)

    $s.SpTitleBar.Add_MouseLeftButtonDown({ try { $sp.DragMove() } catch { } })
    $s.SpClose.Add_Click({ $sp.DialogResult = $false })
    $s.SpCancel.Add_Click({ $sp.DialogResult = $false })
    $sp.Add_KeyDown({ param($a, $e) if ($e.Key -eq 'Escape') { $sp.DialogResult = $false } })

    $s.SpBrowse.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = 'Where should this conversation run?'
        $cur = Get-DropValue $s.SpDir
        if ($cur -and (Test-Path -LiteralPath $cur)) { $fb.SelectedPath = $cur }
        if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $p = $fb.SelectedPath
            $i = New-Object System.Windows.Controls.ComboBoxItem
            $i.Content = (Split-Path -Leaf $p); $i.Tag = $p
            $items = @(@($s.SpDir.ItemsSource) + @($i))
            $s.SpDir.ItemsSource = $items
            $s.SpDir.SelectedItem = $i
            & $refresh
        }
    })

    $script:spawnGo = $null
    $s.SpStart.Add_Click({
        $dir = Get-DropValue $s.SpDir
        if (-not $dir) { $s.SpWarn.Text = 'Choose a project first.'; $s.SpWarn.Visibility = $V_Show; return }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            $s.SpWarn.Text = "That folder does not exist: $dir"; $s.SpWarn.Visibility = $V_Show; return
        }
        $nm = "$($s.SpName.Text)".Trim()
        if (-not $nm) { $s.SpWarn.Text = 'Give it a name - it is how you will find it again.'; $s.SpWarn.Visibility = $V_Show; return }
        $script:spawnGo = [PSCustomObject]@{
            Dir = $dir; Name = $nm
            Model = (Get-DropValue $s.SpModel); Effort = (Get-DropValue $s.SpEffort)
            Perm  = (Get-DropValue $s.SpPerm)
            Remote = [bool]$s.SpRemote.IsChecked
            Hidden = [bool]$s.SpHidden.IsChecked
            Worktree = [bool]$s.SpWorktree.IsChecked
        }
        $sp.DialogResult = $true
    })

    $null = $s.SpName.Focus()
    $ok = $sp.ShowDialog()
    if (-not $ok -or -not $script:spawnGo) { Set-Status 'no new session started'; return }
    $g = $script:spawnGo

    # Remember it for next time, including the project.
    $script:spawnLast = [PSCustomObject]@{
        Dir = $g.Dir; Model = $g.Model; Effort = $g.Effort; Perm = $g.Perm
        Remote = $g.Remote; Hidden = $g.Hidden; Worktree = $g.Worktree
    }

    Start-NewSession $g
}

# A BRAND NEW CONVERSATION HAS NO SESSION ID, and that is the whole difference:
# there is nothing to --resume, so claude makes one, and the registry learns
# about it on the next scan rather than from here. Anything written against a
# guessed id would be written against nothing.
function Start-NewSession { param($G)
    $flags = New-Object System.Collections.Generic.List[string]
    if ($G.Model)  { $flags.Add('--model');           $flags.Add($G.Model) }
    if ($G.Effort) { $flags.Add('--effort');          $flags.Add($G.Effort) }
    if ($G.Perm)   { $flags.Add('--permission-mode'); $flags.Add($G.Perm) }
    if ($G.Worktree) { $flags.Add('--worktree'); $flags.Add($G.Name) }
    try {
        $boot = New-SRBootScript -Dir $G.Dir -Title $G.Name `
                    -ClaudeArgs $flags.ToArray() -RemoteControl $G.Remote
        if ($G.Hidden) { $null = Start-SRHiddenSession -Dir $G.Dir -BootScript $boot -Title $G.Name }
        else { Start-SRSession -Dir $G.Dir -BootScript $boot -Title $G.Name }
        Write-SRLog ('  [ok]   gui2 new session  {0}  {1}  {2}' -f $G.Name, $G.Dir, ($flags -join ' '))
        Set-Status ("started '{0}'{1} - it appears here once it has written its first line" -f `
            $G.Name, $(if ($G.Hidden) { ' (hidden)' } else { '' })) 'ok'
    } catch {
        Write-SRLog ('  [FAIL] gui2 new session  {0}  {1}' -f $G.Name, $_.Exception.Message)
        Set-Status ("could not start '{0}': {1}" -f $G.Name, $_.Exception.Message) 'bad'
    }
}

$ui.NewSession.Add_Click({ Show-Spawn })

# ===========================================================================
# SEND TO MANY
#
# 🔴 THE MOST DANGEROUS BUTTON IN THE WINDOW. It types into live conversations -
# several at once, unattended - so three rules, and none is optional:
#   1. only what is RUNNING and can actually be typed into
#   2. never one that is MID-TURN; a keystroke arriving mid-reply is not
#      undoable and lands in whatever the session does next
#   3. it NAMES every conversation it will type into, before it does
# ===========================================================================
$script:castPick = @{}

function Build-Cast {
    $rows = New-Object System.Collections.Generic.List[object]
    $ready = 0
    foreach ($r in $script:model) {
        if (-not ($r.A -and $r.A.Pid)) { continue }
        $busy = ("$($r.A.Status)" -eq 'busy')
        $id = $r.Id
        if ($busy) { $script:castPick.Remove($id) }
        $rows.Add([PSCustomObject]@{
            Id = $id; Row = $r
            Name = (Get-Title $r.S $r.D).Text
            Why  = $(if ($busy) { 'mid-turn - left alone' } else { '' })
            Busy = $busy
            TickBg = $(if (-not $busy -and $script:castPick[$id]) { $window.FindResource('TextMax') }
                       else { [System.Windows.Media.Brushes]::Transparent })
        })
        if (-not $busy) { $ready++ }
    }
    $ui.CastList.ItemsSource = @($rows | Sort-Object Busy, Name)
    $n = @($script:castPick.Keys).Count
    $ui.CastWho.Text = $(if ($n) {
        ('{0} of {1} ready conversation(s) ticked: {2}' -f $n, $ready,
            ((@($rows | Where-Object { $script:castPick[$_.Id] } | ForEach-Object { $_.Name }) | Sort-Object) -join ', '))
    } else { ("Tick the conversations to type into. {0} are running and ready." -f $ready) })
    $ui.CastSend.IsEnabled = ($n -gt 0 -and "$($ui.CastText.Text)".Trim().Length -gt 0)
}

function Show-Cast {
    $script:castPick = @{}
    $ui.CastText.Text = ''
    Build-Cast
    $ui.CastBox.Visibility = $V_Show
    $null = $ui.CastText.Focus()
}
function Hide-Cast { $ui.CastBox.Visibility = $V_Hide }

$ui.Broadcast.Add_Click({
    if ($ui.CastBox.Visibility -eq $V_Show) { Hide-Cast; return }
    if ($script:surface -ne 'work') { $ui.ModeWork.IsChecked = $true; Set-Surface 'work' }
    Show-Cast
})
$ui.CastCancel.Add_Click({ Hide-Cast; Set-Status 'nothing sent' })
$ui.CastText.Add_TextChanged({ $ui.CastSend.IsEnabled = (@($script:castPick.Keys).Count -gt 0 -and "$($ui.CastText.Text)".Trim().Length -gt 0) })
$ui.CastList.Add_PreviewMouseLeftButtonDown({
    param($sender, $e)
    $it = Get-ClickedRow $e.OriginalSource
    if (-not $it) { return }
    if ($it.Busy) { Set-Status ("'{0}' is mid-turn - it cannot be typed into" -f $it.Name) 'warn'; return }
    if ($script:castPick[$it.Id]) { $script:castPick.Remove($it.Id) } else { $script:castPick[$it.Id] = $true }
    Build-Cast
})

$ui.CastSend.Add_Click({
    $msg = "$($ui.CastText.Text)".Trim()
    if (-not $msg) { Set-Status 'nothing to send' 'warn'; return }
    $go = New-Object System.Collections.Generic.List[object]
    foreach ($r in $script:model) {
        if (-not $script:castPick[$r.Id]) { continue }
        if (-not ($r.A -and $r.A.Pid)) { continue }
        # Re-checked HERE, not just when the list was drawn: a conversation can
        # start a turn between ticking it and pressing Send.
        if ("$($r.A.Status)" -eq 'busy') { continue }
        $go.Add($r)
    }
    if (-not $go.Count) { Set-Status 'nothing left to send to - they are all mid-turn now' 'warn'; return }
    $names = ((@($go | ForEach-Object { (Get-Title $_.S $_.D).Text }) | Sort-Object) -join ', ')
    if (-not (Confirm-Action ('Type this into {0} conversations' -f $go.Count) `
        ("Each one receives, as if you had typed it:`n`n    {0}`n`nInto: {1}" -f $msg, $names))) {
        Set-Status 'nothing sent'; return
    }
    $ok = 0; $bad = New-Object System.Collections.Generic.List[string]
    foreach ($r in $go) {
        $t = (Get-Title $r.S $r.D).Text
        $why = $null
        try { $why = Send-SRSessionInput -SessionId $r.Id -Text $msg } catch { $why = $_.Exception.Message }
        if ($why) { $bad.Add(('{0} ({1})' -f $t, $why)); Write-SRLog ('  [FAIL] cast to {0}: {1}' -f $t, $why) }
        else { $ok++; Write-SRLog ('  [ok]   cast to {0}' -f $t) }
        Start-Sleep -Milliseconds 250
    }
    Hide-Cast
    if ($bad.Count) { Set-Status ('sent to {0}; {1} refused: {2}' -f $ok, $bad.Count, (($bad | Select-Object -First 4) -join '; ')) 'bad' }
    else { Set-Status ('sent to {0} conversation(s)' -f $ok) 'ok' }
})

$ui.Rescan.Add_Click({
    Set-Status 'rescanning...'
    try { $null = Update-SRRegistry -Config $script:cfg -Quiet } catch { }
    Update-Model; Update-Surface
    Set-Status 'rescanned' 'ok'
})

# ===========================================================================
# THE CAPTION. There is no OS title bar any more, so the window's own header
# has to do everything the frame used to.
# ===========================================================================

# The maximise glyph is not one glyph: Segoe MDL2 has a separate "restore" mark,
# and leaving the square showing while maximised is how an app tells you it does
# not know its own state.
function Update-MaxGlyph {
    if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
        $ui.WinMax.Content = [string][char]0xE923   # restore
        $ui.WinMax.ToolTip = 'Restore down'
    } else {
        $ui.WinMax.Content = [string][char]0xE922   # maximise
        $ui.WinMax.ToolTip = 'Maximise'
    }
}

$ui.TitleBar.Add_MouseLeftButtonDown({
    param($sender, $e)
    # Double-click the caption to maximise, exactly as the OS one did.
    if ($e.ClickCount -eq 2) {
        $window.WindowState = $(if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
            [System.Windows.WindowState]::Normal } else { [System.Windows.WindowState]::Maximized })
        Update-MaxGlyph
        return
    }
    # 🪤 DragMove THROWS if the button is no longer down by the time it runs -
    # a fast click can get here after the release. An unhandled throw from an
    # input handler takes the window down, and this handler fires on every
    # single click on the header.
    try { $window.DragMove() } catch { }
})

$ui.WinMin.Add_Click({ $window.WindowState = [System.Windows.WindowState]::Minimized })
$ui.WinMax.Add_Click({
    $window.WindowState = $(if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
        [System.Windows.WindowState]::Normal } else { [System.Windows.WindowState]::Maximized })
    Update-MaxGlyph
})
$ui.WinClose.Add_Click({ $window.Close() })

# 🔴 A MAXIMISED WindowChrome WINDOW OVERHANGS THE SCREEN by the resize border on
# every edge - Windows really does size it that way - which hides the top row of
# pixels and pushes the caption buttons partly off screen. The fix is to put the
# border back as padding while maximised, and to take the number from the SYSTEM
# rather than guess it: it changes with DPI and with the user's border setting.
# The RESIZE BORDER only. WindowNonClientFrameThickness would look like the
# right number and is not: its Top includes the caption height, which would pad
# ~30px of dead space above a header that IS the caption.
$script:maxPad = New-Object System.Windows.Thickness 7
try {
    $b = [System.Windows.SystemParameters]::WindowResizeBorderThickness
    $script:maxPad = New-Object System.Windows.Thickness $b.Left, $b.Top, $b.Right, $b.Bottom
} catch { }

function Update-Frame {
    Update-MaxGlyph
    $window.Content.Margin = $(if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
        $script:maxPad } else { New-Object System.Windows.Thickness 0 })
}
$window.Add_StateChanged({ Update-Frame })
Update-Frame

# / focuses the search from anywhere; ESC clears it, then hands focus back to
# the list. The three panes are Tab stops in reading order.
$window.Add_PreviewKeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Escape') {
        if ($ui.Search.IsKeyboardFocusWithin -and $ui.Search.Text) { $ui.Search.Text = ''; $e.Handled = $true; return }
        $null = $ui.SessionList.Focus(); $e.Handled = $true; return
    }
    # Ctrl+N is checked BEFORE the typing guard: a new session is worth starting
    # even when the cursor happens to be in the search box, and no text field
    # wants Ctrl+N for itself.
    if ($e.Key -eq 'N' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
        Show-Spawn; $e.Handled = $true; return
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

# ===========================================================================
# KEEPING THE WINDOW HONEST WHILE IT SITS THERE
#
# 🔴 THE WINDOW DID NOT REFRESH AT ALL. Update-Model ran once at startup and
# then only on Rescan or an action, so the "as of" stamp froze, ages froze, and
# a conversation that started waiting on you NEVER moved into NEEDS YOU. That is
# the whole job of the work surface, and it is a regression against the retired
# window, which said so in its own comment: "A window that sits open all day
# would go stale."
#
# TWO TIERS, and the split is chosen from measurements on this machine rather
# than from a feeling:
#
#   Update-Model (full)        1,681 ms   <- far too slow for a short timer
#     of which agents --json   1,100 ms   <- a subprocess; the dominant cost
#   agent status, cached           4 ms
#   Build-Sessions repaint     2,336 ms   <- was the SELECTION side-effect, now fixed
#
#   FAST  6s   no subprocess, no transcript reads. Recomputes ages and the
#              stamp, and repaints ONLY if a visible string actually changed -
#              a repaint that changes nothing still steals your scroll position.
#   LIVE  45s  the full pass, run on a BACKGROUND RUNSPACE so the 1.7 seconds
#              never lands on the UI thread. A poll timer picks the result up.
#
# 🪤 THE JOB MAY NOT TOUCH THE UI. It runs on another thread; every result is
# handed back and applied here, on the dispatcher.
# ===========================================================================
$script:FastSeconds = 6
$script:LiveSeconds = 45
$script:probeAt = Get-Date
$script:probePs = $null
$script:probeRs = $null
$script:probeHandle = $null

# 🔴 COMPARE BEFORE REBUILDING, NEVER AFTER. Build-Sessions replaces
# ItemsSource, which throws away the scroll position - so a repaint that changes
# nothing still yanks the list back to the top under your hand. Every six
# seconds. The fingerprint is computed from the MODEL, which costs string
# formatting and no I/O, and the rebuild only happens when it moved.
function Get-ModelFingerprint {
    $sb = New-Object System.Text.StringBuilder
    foreach ($r in $script:model) {
        if (-not (Test-OnSurface $r)) { continue }
        $said = ''
        if ($r.Said -and "$($r.Said.Said)") { $said = "$($r.Said.Said)".Substring(0, [Math]::Min(40, "$($r.Said.Said)".Length)) }
        $null = $sb.Append("$($r.Id)|$($r.Band)|$(Get-Age $r.S.lastActive)|$said`n")
    }
    return $sb.ToString()
}

function Invoke-FastPass {
    # The stamp is the one thing that must move every tick: it is how you know
    # the window is still watching rather than frozen.
    $ui.Stamp.Text = ('as of {0}' -f $script:probeAt.ToString('HH:mm:ss'))
    if ($script:surface -ne 'work') { return }
    $fp = Get-ModelFingerprint
    if ($fp -eq $script:lastFp) { return }
    $script:lastFp = $fp
    Build-Sessions
}
$script:lastFp = $null

# The slow half, off the UI thread. It returns the registry and the agent map;
# nothing is drawn from in here.
$script:ProbeJob = {
    . (Join-Path $SRHere '_common.ps1')
    $out = @{}
    try { $out.Reg = Get-SRRegistry } catch { $out.Reg = $null }
    try { $out.Agents = Get-SRAgentStatus -Refresh } catch { $out.Agents = @{} }
    $out
}

function Start-LiveProbe {
    if ($script:probePs) { return }        # one at a time; a queue would pile up
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('SRHere', $here)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($script:ProbeJob)
        $script:probeRs = $rs
        $script:probePs = $ps
        $script:probeHandle = $ps.BeginInvoke()
    } catch {
        Write-SRLog ('  [FAIL] the live probe would not start: {0}' -f $_.Exception.Message)
        $script:probePs = $null
    }
}

function Complete-LiveProbe {
    if (-not $script:probePs -or -not $script:probeHandle -or -not $script:probeHandle.IsCompleted) { return }
    $res = $null
    try { $res = @($script:probePs.EndInvoke($script:probeHandle)) | Select-Object -Last 1 } catch { }
    try { $script:probePs.Dispose() } catch { }
    try { $script:probeRs.Close(); $script:probeRs.Dispose() } catch { }
    $script:probePs = $null; $script:probeHandle = $null; $script:probeRs = $null
    if (-not $res) { return }

    # 🔴 NEVER OVERWRITE UNSAVED TICKS. The probe carries a registry read from
    # disk; adopting it while there are unsaved changes would silently discard
    # what you just ticked. The agent map is safe either way.
    if (-not $script:dirty -and $res.Reg) { $script:reg = $res.Reg; $script:dirs = @($res.Reg.directories) }
    if ($res.Agents) { $script:agents = $res.Agents }
    Rebuild-FromProbe
    $script:probeAt = Get-Date
}

# Re-derive the bands from the fresh agent map, WITHOUT re-reading transcripts:
# that is what makes a conversation move into NEEDS YOU, and it is the reason
# this tier exists at all.
function Rebuild-FromProbe {
    foreach ($r in $script:model) {
        $a = $script:agents["$($r.Id)"]
        $r.A = $a
        $r.Live = [bool]$a
        try { $r.Conv = Resolve-SRSessionState -Agent $a -Conv $null } catch { }
        $r.Band = Get-Band $r
    }
    if ($script:surface -eq 'work') { Build-Sessions } else { Build-Manager }
    $ui.LiveCount.Text = ('{0} live of {1} conversations across {2} projects' -f `
        @($script:model | Where-Object { $_.Live }).Count, $script:model.Count, @($script:dirs).Count)
    # The pane is showing ONE conversation and its state may have moved too -
    # the pending question especially, which is the thing you are waiting for.
    Show-Selected -Force
}

$script:fastTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:fastTimer.Interval = [TimeSpan]::FromSeconds($script:FastSeconds)
$script:fastTimer.Add_Tick({ try { Invoke-FastPass } catch { Write-SRLog ('fast pass failed: ' + $_.Exception.Message) } })

$script:liveTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:liveTimer.Interval = [TimeSpan]::FromSeconds($script:LiveSeconds)
$script:liveTimer.Add_Tick({ try { Start-LiveProbe } catch { Write-SRLog ('live probe failed: ' + $_.Exception.Message) } })

# The collector. Cheap enough to run often; it does nothing until the job ends.
$script:pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:pollTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:pollTimer.Add_Tick({ try { Complete-LiveProbe } catch { Write-SRLog ('probe collect failed: ' + $_.Exception.Message) } })

$window.Add_ContentRendered({
    Set-Breakpoint
    $null = $ui.SessionList.Focus()
    $script:followTimer.Start()
    $script:fastTimer.Start()
    $script:liveTimer.Start()
    $script:pollTimer.Start()
})
$window.Add_Closed({
    foreach ($t in @($script:followTimer, $script:fastTimer, $script:liveTimer, $script:pollTimer)) {
        try { $t.Stop() } catch { }
    }
    # A runspace left open holds a thread after the window is gone.
    try { if ($script:probePs) { $script:probePs.Dispose() } } catch { }
    try { if ($script:probeRs) { $script:probeRs.Close(); $script:probeRs.Dispose() } } catch { }
})

$null = $window.ShowDialog()
