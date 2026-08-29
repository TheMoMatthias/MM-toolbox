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
    'Shell','TitleBar','WinMin','WinMax','WinClose',
    'LiveCount','Search','Stamp','Rescan','NewSession',
    'ModeWork','ModeManage','Broadcast',
    'WorkSurface','RailCol','ListCol','RailPane','RailSplit','RailList','RailClear',
    'ListPane','ListSplit','ListCaption','ListSort','ListCount','SessionList',
    'OutputPane','PaneName','PaneState','PaneStateDot','PaneGoTo','PaneRelaunch','PaneSettings',
    'SettingsBox','SetName','SetModel','SetEffort','SetPerm','SetPermNote',
    'SetRemote','SetHidden','SetPending','SetCancel','SetApply',
    'SetToolsFold','SetAllow','SetDeny',
    'CastBox','CastWho','CastList','CastText','CastCancel','CastSend',
    'PaneDoc','PaneEmpty','AskBox','AskHeader','AskText','AskOptions','AskFooter','AskNote',
    'SendNote','SendBox','SendBtn','SkillPop','SkillList','SkillHint',
    'ManageSurface','ManageCaption','ManageList','ManageCount',
    'OpenNotRunning','RelaunchSessions',
    'HdrLogon','HdrName','HdrLane','HdrSaid','HdrAge',
    'Scrim','Sheet','SheetTitle','SheetBody','SheetB1','SheetB2','SheetB3',
    'Status','SaveBtn'
)) {
    $el = $window.FindName($n)
    if (-not $el) { throw "window2.xaml has no element named '$n' - the script and the markup disagree." }
    $ui[$n] = $el
}

$V_Show = [System.Windows.Visibility]::Visible
$V_Hide = [System.Windows.Visibility]::Collapsed

# ---------------------------------------------------------------------------
# The sheet - the window asking, in its own voice
#
# Every question used to be [System.Windows.MessageBox]::Show: a grey system
# dialog with a shield icon and Segoe UI, in front of a window that shares none
# of that. It was also the one surface that could not be restyled, so it grew
# more conspicuous the better the rest of the window got - and it appears at the
# moments that matter most, because those are the ones worth confirming.
#
# 🔴 THIS BLOCKS, AND IT HAS TO. Seven callers are written as `if (Confirm-Action
# ...) { do it }` - a non-blocking sheet would return before the operator had
# answered and every one of them would read the answer as "no". Blocking without
# freezing is what a nested DispatcherFrame is for: the dispatcher keeps pumping
# (so the sheet paints and its buttons respond) while the CALLER stays parked on
# its own line. It is exactly the mechanism MessageBox itself used, which is why
# swapping one for the other needs no change at any call site.
# ---------------------------------------------------------------------------
$script:sheetFrame  = $null
$script:sheetPick   = $null
$script:sheetEscape = $null
# 🔴 READ BY EVERY TIMER TICK. A sheet names the exact conversations an action
# will touch, and the caller is holding the row objects behind those names. The
# live probe re-adopts the registry and rebinds rows, so letting it run under an
# open sheet would hand the caller a list of ORPHANS the moment the operator
# pressed the button - the same defect class as the adoption bug, arriving by a
# different door. Everything that mutates the model stands still while it is up.
$script:sheetDepth  = 0

foreach ($bn in @('SheetB1', 'SheetB2', 'SheetB3')) {
    $ui[$bn].Add_Click({
        param($s, $e)
        $script:sheetPick = "$($s.Tag)"
        if ($script:sheetFrame) { $script:sheetFrame.Continue = $false }
    })
}

# Esc answers with whatever the caller nominated as the safe way out; Enter
# takes the primary. Preview, so the sheet gets the key before the list below
# it does - the transcript and the session list both bind arrows and Enter.
$window.Add_PreviewKeyDown({
    param($s, $e)
    if (-not $script:sheetFrame) { return }
    if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
        $script:sheetPick = $script:sheetEscape
        $script:sheetFrame.Continue = $false
        $e.Handled = $true
    } elseif ($e.Key -eq [System.Windows.Input.Key]::Enter) {
        $script:sheetPick = "$($ui.SheetB3.Tag)"
        $script:sheetFrame.Continue = $false
        $e.Handled = $true
    }
})

function Show-Sheet {
    param(
        [string]$Title,
        [string]$Body,
        # Ordered left to right. The LAST one is the primary - it lands on the
        # button carrying BtnPrimary, is focused, and is what Enter presses.
        [object[]]$Choices,
        # What Esc means. Never the destructive choice.
        [string]$Escape
    )
    $n = @($Choices).Count
    if ($n -lt 1 -or $n -gt 3) { throw "Show-Sheet takes one to three choices, not $n" }

    $ui.SheetTitle.Text = $Title
    $ui.SheetBody.Text  = $Body

    # Filled from the right, so the primary always lands on B3 whether there are
    # one, two or three of them and the row stays right-aligned either way.
    $slots = @($ui.SheetB3, $ui.SheetB2, $ui.SheetB1)
    foreach ($b in $slots) { $b.Visibility = $V_Hide; $b.Tag = $null }
    for ($i = 0; $i -lt $n; $i++) {
        $c = @($Choices)[$n - 1 - $i]
        $slots[$i].Content    = "$($c.Label)"
        $slots[$i].Tag        = "$($c.Key)"
        $slots[$i].Visibility = $V_Show
    }

    $prevFrame  = $script:sheetFrame
    $prevEscape = $script:sheetEscape
    $script:sheetPick   = $Escape
    $script:sheetEscape = $Escape
    $ui.Scrim.Visibility = $V_Show
    $ui.Sheet.Visibility = $V_Show
    $script:sheetDepth++
    $null = $ui.SheetB3.Focus()

    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $script:sheetFrame = $frame
    $pick = $Escape
    try {
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        $pick = $script:sheetPick
    } finally {
        $script:sheetFrame  = $prevFrame
        $script:sheetEscape = $prevEscape
        $script:sheetDepth--
        if ($script:sheetDepth -le 0) {
            $script:sheetDepth = 0
            $ui.Scrim.Visibility = $V_Hide
            $ui.Sheet.Visibility = $V_Hide
        }
    }
    return $pick
}

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
# The question currently on offer in the pane, so an answer record can say what
# was actually on screen when it was pressed. Never inferred, never stale.
$script:lastAsk   = $null
# How often the foreground path may spend a child process reading a console.
$script:AskEverySeconds = 5
$script:lastAskAt = $null
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

# 🔴 THE COLUMN HEADERS DO SOMETHING NOW. The operator clicked LOGON
# expecting the table to react and nothing happened - they were plain TextBlocks,
# and the band filter I had built lived on the OTHER surface entirely. A column
# header that looks like a column header and does nothing is worse than no
# header at all, because it teaches you the table is dead.
#
# 🩤 SORTING HAPPENS WITHIN EACH PROJECT, NOT ACROSS THE WHOLE TABLE. The
# manager is grouped by project and the grouping is what makes it navigable at
# 29 projects; a global sort by age would shuffle every conversation into one
# undifferentiated run and lose the thing the surface is organised around.
$script:mgrSort = 'age'
$script:mgrDesc = $true
$script:MgrKeys = @{
    'logon' = { param($r) $(if ([bool]$r.S.enabled) { 1 } else { 0 }) }
    'name'  = { param($r) (Get-Title $r.S $r.D).Text.ToLower() }
    'lane'  = { param($r) (Get-LaneLabel $r (Get-Title $r.S $r.D).Text).ToLower() }
    'said'  = { param($r) "$($r.Said.Said)".Trim().ToLower() }
    'age'   = { param($r) try { ([datetime]$r.S.lastActive).Ticks } catch { 0L } }
}

function Sort-ManagerRows { param($Rows)
    $key = $script:MgrKeys[$script:mgrSort]
    if (-not $key) { $key = $script:MgrKeys['age'] }
    $sorted = @($Rows | Sort-Object { & $key $_ })
    if ($script:mgrDesc) { [array]::Reverse($sorted) }
    # 🔴 NO LEADING COMMA. `return ,$a` on an EMPTY array returns a
    # one-element array holding the empty one, so a band or project with nothing
    # in it renders a phantom row - which is exactly what happened: "1
    # conversation from other bands survived the filter", against a row that was
    # not a conversation at all. Both callers wrap this in @(), which re-collects
    # an unrolled array correctly, so the comma buys nothing and costs that.
    return $sorted
}

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
        $kids = @(Sort-ManagerRows $byProj[$k])
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
# The sorted project set the identity colours are dealt against. Rebuilt with
# the labels because it answers the same question - which projects exist - and
# the accent cache is dropped with it, or a project would keep a colour dealt
# against a set it is no longer a member of.
$script:accentOrder = @()
function Update-ProjectLabels {
    $script:projLabel = @{}
    $order = @(@($script:dirs | ForEach-Object { "$($_.path)".ToLower() } |
                Where-Object { $_ } | Sort-Object -Unique))
    if (($order -join '|') -ne ($script:accentOrder -join '|')) {
        $script:accentOrder = $order
        $script:accentCache = @{}
    }
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
# 🩤 Split-Path THROWS ON AN EMPTY STRING - it does not return ''. A
# conversation whose directory record has no path is rare but real (a registry
# entry written before the cwd was known), and both of these helpers walked
# straight into it: "Cannot bind argument to parameter 'Path' because it is an
# empty string", thrown out of a list rebuild, which takes the whole surface
# down rather than one row. Latent for as long as nothing asked; guarded here
# rather than at each of the dozen call sites.
function Get-ProjectLabel { param([string]$Path)
    if (-not "$Path") { return '' }
    if ($script:projLabel.ContainsKey($Path)) { return $script:projLabel[$Path] }
    return (Split-Path -Leaf $Path)
}

function Get-Title { param($S, $D)
    $t = "$($S.title)".Trim()
    if ($t -and $t -ne '(untitled)') { return @{ Text = $t; Derived = $false } }
    $a = "$($S.autoTitle)".Trim()
    if ($a) { return @{ Text = $a; Derived = $true } }
    $dp = "$($D.path)"
    $leaf = $(if ($dp) { Split-Path -Leaf $dp } else { '' })
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

# One definition of what an age READS AS, driven by a tick delta so it can be
# called in a tight loop without touching the clock or parsing a date. Both the
# painted row and the change-detection fingerprint go through it, so they can
# never disagree about whether an age moved.
function Get-AgeLabel { param([long]$Delta)
    if ($Delta -le 0) { return '' }
    $s = [long]($Delta / 10000000)
    if ($s -lt 90)     { return 'now' }
    if ($s -lt 3600)   { return ([string][int]($s / 60) + 'm') }
    if ($s -lt 86400)  { return ([string][int]($s / 3600) + 'h') }
    return ([string][int]($s / 86400) + 'd')
}

function Get-Age { param($When)
    if (-not $When) { return '' }
    $t = 0L
    try { $t = ([datetime]$When).Ticks } catch { return '' }
    return (Get-AgeLabel ([DateTime]::Now.Ticks - $t))
}

function Test-Warm { param($S)
    try { return ([datetime]$S.lastActive -gt (Get-Date).AddHours(-24)) } catch { return $false }
}

# Every conversation the work surface could show, with what it is doing.
#
# 🪤 THE SAID-LINE IS READ ONLY FOR THE LIVE AND THE RECENT. Get-SRLastSaid opens
# a file per conversation; doing that for all 215 on every rebuild is seconds,
# not milliseconds, and the rebuild runs on a timer.
# 🔴 THE MODEL AND THE REGISTRY ARE ONE THING, AND THEY ARE REPLACED TOGETHER.
#
# Every row holds a LIVE REFERENCE to a session object ($r.S) and a directory
# object ($r.D) inside $script:reg. Ticking mutates $r.S; Save writes
# $script:reg. Those two only agree while the rows came from THAT registry.
#
# The background probe used to swap $script:reg for a fresh read from disk and
# leave the rows pointing into the OLD graph. After that, every tick and every
# per-session setting was written to an orphaned object and then not saved -
# the box stayed filled on screen and the file on disk never heard about it.
# Silent, and on a 45-second timer.
#
# So there is exactly one place a registry is adopted, and it rebuilds the rows
# in the same breath. -Registry / -Agents / -Said let the probe hand in work it
# already did on a background thread, so this costs no I/O when it is called
# from there.
function Update-Model {
    param($Registry, $Agents, [hashtable]$Said)

    $script:cfg = Get-SRConfig
    if ($Registry) { $script:reg = $Registry } else { $script:reg = Get-SRRegistry }
    $script:dirs = @($script:reg.directories)

    if ($null -ne $Agents) { $script:agents = $Agents }
    else {
        $a = @{}
        try { $a = Get-SRAgentStatus -Refresh } catch { }
        $script:agents = $a
    }
    $agents = $script:agents

    $rows = New-Object System.Collections.Generic.List[object]
    $warmCut = [DateTime]::Now.AddHours(-24).Ticks
    foreach ($d in $script:dirs) {
        if ($d.missing) { continue }
        foreach ($s in @($d.sessions)) {
            if ($s.gone) { continue }
            $id = "$($s.sessionId)".ToLower()
            $a  = $agents[$id]
            $conv = $null
            try { $conv = Resolve-SRSessionState -Agent $a -Conv $null } catch { }
            $live = [bool]$a
            # 🔴 $line, NOT $said. The parameter above is [hashtable]$Said, and
            # PowerShell IS CASE-INSENSITIVE: a local called $said was the SAME
            # VARIABLE as the parameter, and this feature never worked once
            # because of it. `$said = $null` wiped the caller's hashtable, so the
            # probe's handed-in work was discarded on the spot; then assigning
            # the record from Get-SRLastSaid to a variable still constrained to
            # [hashtable] threw a cast error, which the catch below swallowed.
            # Both paths dead, silently, and the column sat empty - reported by
            # the operator, and a blank 'what it last said' is indistinguishable
            # from a machine with nothing running, which is why it survived a
            # fix and a green suite. The suite now asserts it against the LIVE
            # set, where a blank cell can only mean this.
            $line = $null
            if ($live -or (Test-Warm $s)) {
                # Handed in by the probe when it read them off the background
                # thread; read here only when nobody did it for us.
                if ($null -ne $Said) { $line = $Said[$id] }
                else { try { $line = Get-SRLastSaid -JsonlPath $s.jsonl } catch { } }
            }
            # lastActive is parsed ONCE, here, and carried as ticks. The 6-second
            # pass reads it for every conversation; re-parsing a string 184 times
            # per tick was most of what that pass cost.
            $at = 0L
            try { $at = ([datetime]$s.lastActive).Ticks } catch { }
            $rows.Add([PSCustomObject]@{
                Id = $id; S = $s; D = $d; A = $a; Conv = $conv; Said = $line; Live = $live; Band = 'quiet'
                At = $at; Warm = ($at -gt $warmCut)
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
    # $R.Warm is the same 24-hour question, decided once when the model was
    # built. Test-Warm re-parses a date string and is kept only for callers
    # holding a bare session object.
    if ($null -ne $R.Warm) {
        if ($R.Warm) { return $true }
        return ($script:selId -and $R.Id -eq $script:selId)
    }
    # 🔴 WHAT YOU ARE READING STAYS ON SCREEN. A conversation drops off this
    # surface once it stops being live and its last activity passes 24 hours -
    # and the refresh runs every six seconds, so it could vanish from under the
    # pane mid-read and Build-Sessions would silently select a DIFFERENT
    # conversation in its place. Whatever is selected is pinned until you
    # select something else.
    if ($script:selId -and $R.Id -eq $script:selId) { return $true }
    return (Test-Warm $R.S)
}

# ===========================================================================
# THE RAIL - a filter, never the grouping
# ===========================================================================
# ===========================================================================
# PROJECT IDENTITY - the only hue in the window, and it is deliberately tiny
#
# 🔴 THE GREYSCALE RULE STILL HOLDS: grey carries STATE, hue carries IDENTITY,
# and they never trade places. The ladder from white (needs you) down to
# #3A3D43 (quiet) is how the window says what is happening, and a coloured
# surface would compete with it - so this colour is spent on a 3px bar and
# nothing else. It says WHICH project at a glance across 29 of them; it never
# says how a project is doing.
#
# The hue is derived from the path, so it is stable across restarts, needs no
# storage, and never has to be assigned by hand. Saturation and lightness are
# fixed and low: at S=0.42 these read as tinted graphite next to the greys,
# not as a highlight competing with the white of NEEDS YOU.
$script:accentCache = @{}
function Get-ProjectAccent { param([string]$Path)
    $k = "$Path".ToLower()
    if ($script:accentCache.ContainsKey($k)) { return $script:accentCache[$k] }
    # FNV-1a over the path. Any stable hash does; this one needs no library and
    # spreads adjacent names (AlgoTrader / AlgoTrader-tps) to different hues,
    # which a simple character sum does not.
    # 🪤 Int64 AND AN 'L'-SUFFIXED MASK, not [uint32]. PowerShell parses the
    # literal 0xFFFFFFFF as an Int32, which is -1: the mask was a no-op, the
    # product ran past 32 bits unchecked, and the cast then threw "value was
    # either too large or too small for a UInt32". Keeping the whole thing in
    # Int64 and masking with 0xFFFFFFFFL is the arithmetic that was intended.
    $h = 2166136261L
    foreach ($c in $k.ToCharArray()) {
        $h = ((($h -bxor [int]$c) * 16777619L) -band 0xFFFFFFFFL)
    }
    # 🔴 A RANDOM HUE PER PROJECT IS NOT A DISTRIBUTED ONE. This used to be
    # `$h % 300` with a skip band, which gives every project an INDEPENDENT
    # uniform draw - and independent draws cluster. With eight projects the
    # operator got mostly greens and blues, reported as "the coloring could be
    # more versatile, as I only see green and blue mostly", which is exactly the
    # birthday problem showing up as a design defect.
    #
    # The fix is to stop drawing and start CHOOSING: a fixed wheel of hues that
    # are already far apart, indexed by the hash. Collisions become possible in
    # principle - two projects can land on one slot - but the SPREAD is
    # guaranteed, which the eye notices and a collision it does not. Saturation
    # and lightness alternate slightly too, so even a collision is rarely exact.
    #
    # \U0001fa64 The muddy band around 55-85 (olive/khaki) is simply not on the wheel,
    # rather than skipped arithmetically: at this saturation those hues go
    # grey-brown and stop reading as identity at all.
    $wheel = @(
        @(206, 0.52, 0.64),   # azure
        @(  8, 0.55, 0.66),   # coral
        @(150, 0.44, 0.62),   # jade
        @(276, 0.44, 0.70),   # violet
        @( 34, 0.58, 0.62),   # amber
        @(188, 0.46, 0.60),   # teal
        @(330, 0.46, 0.70),   # rose
        @(102, 0.40, 0.62),   # moss
        @(248, 0.46, 0.72),   # indigo
        @( 18, 0.48, 0.60),   # rust
        @(168, 0.42, 0.66),   # spring
        @(300, 0.38, 0.68)    # magenta
    )
    # 🪤 AND HASH-MOD-WHEEL WAS STILL NOT ENOUGH: FNV's low bits are weak, and
    # `% 12` off them gave FOUR distinct colours across SEVEN projects - worse
    # than the clustering it was meant to fix. Distinctness cannot be left to
    # chance at this size, so the slot is CHOSEN, not drawn: projects are sorted
    # and dealt consecutive slots off the wheel, which makes the spread exact
    # rather than probable. The hash is not consulted for the slot at all - an
    # offset derived per project is just the random draw again, wearing an
    # index's clothes. It stays only as the stable cache key above.
    #
    # The cost is that adding a project can re-deal the others. That is the
    # right trade at 29 projects: the set changes rarely, and a colour you have
    # to hunt for is worth less than a set you can tell apart at a glance.
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

function Convert-HslToColor { param([double]$H, [double]$S, [double]$L)
    $c = (1 - [math]::Abs(2 * $L - 1)) * $S
    $x = $c * (1 - [math]::Abs((($H / 60) % 2) - 1))
    $m = $L - $c / 2
    $r = 0.0; $g = 0.0; $b = 0.0
    switch ([int][math]::Floor($H / 60)) {
        0 { $r = $c; $g = $x }
        1 { $r = $x; $g = $c }
        2 { $g = $c; $b = $x }
        3 { $g = $x; $b = $c }
        4 { $r = $x; $b = $c }
        default { $r = $c; $b = $x }
    }
    return [System.Windows.Media.Color]::FromRgb(
        [byte][math]::Round(($r + $m) * 255),
        [byte][math]::Round(($g + $m) * 255),
        [byte][math]::Round(($b + $m) * 255))
}

function Build-Rail {
    # 🔴 THE RAIL OBEYS THE SEARCH BOX. It did not, so typing a project name
    # narrowed the sessions column while the rail went on listing all 29 - the
    # half of "in the projects and sessions I would like to be able to search"
    # that was missing. A project whose every conversation has been filtered out
    # is not a project you can pick, so it goes.
    $q = "$($ui.Search.Text)".Trim().ToLower()
    $byProj = @{}
    foreach ($r in $script:model) {
        if (-not (Test-OnSurface $r)) { continue }
        if ($q) {
            $t = (Get-Title $r.S $r.D).Text
            # 🩤 NOT EVERY ROW HAS A PATH. Get-ProjectLabel splits one and throws
            # on an empty string, and the rail had never called it per-row before
            # - only per project key, which is non-empty by construction.
            $pl = ''
            if ("$($r.D.path)") { $pl = Get-ProjectLabel "$($r.D.path)" }
            $hay = ('{0} {1} {2}' -f $t, $pl, $r.D.path).ToLower()
            if ($hay -notlike "*$q*") { continue }
        }
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
        $kids = $byProj[$k]
        # WHAT IS HAPPENING IN THERE, not just how many are in there. A count of
        # 13 is the same number whether every one of them is asleep or one is
        # waiting on you, and the whole point of the rail is choosing where to
        # look next. The tile says the two things that decide that.
        $needs = 0; $working = 0
        foreach ($r in $kids) {
            if ("$($r.Band)" -eq 'needs') { $needs++ }
            elseif ($r.Live) { $working++ }
        }
        $bits = New-Object System.Collections.Generic.List[string]
        if ($needs)   { $bits.Add("$needs waiting") }
        if ($working) { $bits.Add("$working working") }
        if (-not $bits.Count) { $bits.Add("$($kids.Count) idle") }
        # 🪤 [char], NOT A LITERAL '·'. The test harness writes a combined script
        # and runs it, and a non-ASCII byte in a STRING LITERAL does not survive
        # that round trip - it arrived as 'Ã‚Â·' and took the whole file's parse
        # down with it. The same character in a COMMENT is harmless, which is why
        # the emoji markers throughout this file are fine and this was not. The
        # rest of the window already follows this convention (see Caret above).
        $dot = ' ' + [string][char]0x00B7 + ' '
        $items.Add([PSCustomObject]@{
            Path   = $k
            Label  = (Get-ProjectLabel $k)
            Count  = $kids.Count
            State  = ($bits -join $dot)
            # 🔴 THE CAST, AGAIN. A brush handed back from a PowerShell
            # function arrives PSObject-WRAPPED, and WPF cannot convert that to a
            # Brush: the binding fails SILENTLY, Background stays null, and the
            # mark draws as nothing. Identical to the PSObject-wrapped FontFamily
            # that killed the typeface - and just as invisible, because a missing
            # brush looks exactly like a design choice. The suite now measures
            # the mark on screen rather than trusting the colour behind it.
            Accent = [System.Windows.Media.Brush](Get-ProjectAccent $k)
            # The accent bar is always drawn; it just goes nearly transparent
            # when the project has nothing live, so a busy project's identity is
            # what catches the eye rather than every project shouting at once.
            AccentOpacity = $(if ($needs) { 1.0 } elseif ($working) { 0.85 } else { 0.35 })
            NeedsVis = $(if ($needs) { $V_Show } else { $V_Hide })
            PickBg = [System.Windows.Media.Brush]$(if ($picked) { $window.FindResource('SelBg') } else { [System.Windows.Media.Brushes]::Transparent })
            PickEdge = [System.Windows.Media.Brush]$(if ($picked) { $window.FindResource('EdgeLit') } else { [System.Windows.Media.Brushes]::Transparent })
            Fg     = [System.Windows.Media.Brush]$(if ($picked) { $window.FindResource('TextMax') } else { $window.FindResource('TextHigh') })
        })
    }
    $ui.RailList.ItemsSource = $items
    $ui.RailClear.Visibility = $(if ($script:railPick) { $V_Show } else { $V_Hide })
}

# ===========================================================================
# THE SESSIONS COLUMN - grouped by BAND, two lines per row
# ===========================================================================
# 🔴 SORTED WITHIN THE BAND, never across it. The band IS the ordering that
# matters - what wants you, then what is working - and a sort that ignored it
# would bury a waiting conversation among forty idle ones. So this decides the
# order inside each band only, exactly as the manager sorts inside a project.
$script:listSort = 'recent'
$script:ListSorts = @(
    @{ Key = 'recent';  Label = 'newest first' },
    @{ Key = 'name';    Label = 'by name' },
    @{ Key = 'project'; Label = 'by project' }
)
# No leading comma on any of these - see Sort-ManagerRows.
function Sort-SessionRows { param($Rows)
    switch ($script:listSort) {
        'name'    { return @($Rows | Sort-Object { (Get-Title $_.S $_.D).Text.ToLower() }) }
        'project' { return @($Rows | Sort-Object {
                                    $pp = "$($_.D.path)"
                                    $(if ($pp) { (Get-ProjectLabel $pp).ToLower() } else { '' })
                                 }, { (Get-Title $_.S $_.D).Text.ToLower() }) }
        default   { return @($Rows | Sort-Object { try { [datetime]$_.S.lastActive } catch { [datetime]0 } } -Descending) }
    }
}

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
        $inBand = @(Sort-SessionRows @($keep | Where-Object { $_.Band -eq $b.Key }))
        if (-not $inBand.Count) { continue }
        $acc = $window.FindResource($b.Acc)
        $picked = ($script:bandPick -eq $b.Key)
        $items.Add([PSCustomObject]@{
            Kind = 'band'; Id = $null; Row = $null; BandKey = $b.Key
            BandVis = $V_Show; RowVis = $V_Hide; DotVis = $V_Hide
            BandLabel = $b.Label; BandCount = $inBand.Count; Accent = $acc
            # A heading you can press has to look pressable, and look pressed.
            BandBg = [System.Windows.Media.Brush]$(if ($picked) { $window.FindResource('SelBg') } else { [System.Windows.Media.Brushes]::Transparent })
            BandHint = $(if ($picked) { 'only this' } else { '' })
            Name = ''; Age = ''; Said = ''; NameWeight = 'Normal'; NameStyle = 'Normal'; BarOpacity = 0.0
        })
        # 🔴 THE HEADINGS ALL STAY WHEN ONE IS PICKED. Hiding the others
        # would leave no way back except a control that is now off screen, and
        # the counts beside them are the reason to switch in the first place.
        if ($script:bandPick -and $script:bandPick -ne $b.Key) { continue }
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
# ===========================================================================
# THE TYPEFACE, LOADED FROM A FILE BESIDE THIS SCRIPT.
#
# Manrope ships with the tool (lib\fonts\, SIL OFL - see the README there).
# Everything Windows provides is either the system UI face, which reads as "no
# decision was made", or has a flaw at these sizes: Corbel's old-style numerals
# drop the 1 and 9 below the cap line, which makes a counter look broken.
#
# 🔴 IT IS A VARIABLE FONT AND THAT WAS CHECKED BEFORE SHIPPING IT. WPF cannot
# interpolate a variable axis - but it does read the font's NAMED INSTANCES, and
# Manrope carries seven (ExtraLight to ExtraBold). Verified on this machine via
# GetFontFamilies().GetTypefaces(). Had it exposed only one, every weight would
# have rendered Regular with a synthesised bold - worse than the system font it
# replaces, and silent.
#
# 🪤 If the file is missing the window keeps the Segoe UI Variable stack the
# markup declares. A deleted font degrades to the PREVIOUS look, never to Arial,
# and the log says which one was used.
function Install-SRTypeface {
    $dir = Join-Path $here 'fonts'
    $ttf = Join-Path $dir 'Manrope.ttf'
    if (-not (Test-Path -LiteralPath $ttf)) {
        Write-SRLog '  [skip] lib\fonts\Manrope.ttf is not there - keeping the system face'
        return $false
    }
    try {
        # The trailing separator matters: GetFontFamilies wants the DIRECTORY,
        # and './#Family' is how WPF names a face inside a loose folder.
        $base = [Uri]('file:///' + $dir.Replace('\', '/').TrimEnd('/') + '/')
        $fams = [System.Windows.Media.Fonts]::GetFontFamilies($base)
        # 🔴 THE CAST IS LOAD-BEARING, not tidiness. Anything that comes out of a
        # PowerShell pipeline arrives wrapped in a PSObject, and putting that
        # wrapper straight into a ResourceDictionary stores the WRAPPER. Nothing
        # noticed while the styles held static references and never read the key
        # again; the moment they became dynamic and WPF actually resolved it,
        # layout died with "Unable to cast PSObject to FontFamily" - on the first
        # Measure, so the window never appeared at all.
        $fam = [System.Windows.Media.FontFamily](@($fams | Where-Object { "$($_.Source)" -like '*#Manrope*' })[0])
        if (-not $fam) { Write-SRLog '  [skip] no Manrope family in lib\fonts - keeping the system face'; return $false }
        $faces = @($fam.GetTypefaces())
        if ($faces.Count -lt 2) {
            # One face means no named instances survived, and every weight would
            # be synthesised. The system font is the better outcome.
            Write-SRLog ('  [skip] Manrope exposes only {0} face - keeping the system face' -f $faces.Count)
            return $false
        }
        foreach ($k in @('FontText', 'FontDisplay', 'FontSmall')) { $window.Resources[$k] = $fam }
        Write-SRLog ('  [ok]   typeface Manrope loaded from lib\fonts ({0} faces)' -f $faces.Count)
        return $true
    } catch {
        Write-SRLog ('  [skip] Manrope would not load ({0}) - keeping the system face' -f $_.Exception.Message)
        return $false
    }
}
$script:hasManrope = Install-SRTypeface

# The faces the TRANSCRIPT is drawn in - the biggest block of text in the window.
# Resolved AFTER the typeface is installed, or the document would keep the system
# face while everything around it changed.
$script:UiFace   = $window.FindResource('FontText')
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
            $p.Inlines.Add((New-ReadRun -Text ($code -join "`n") -Brush $Pal.TextHigh -Size 13 -Mono))
            $Doc.Blocks.Add($p)
            continue
        }
        $p = New-Object System.Windows.Documents.Paragraph
        $p.Margin = New-Object System.Windows.Thickness 0, 3, 0, 3
        $p.LineHeight = 23
        $p.LineStackingStrategy = 'BlockLineHeight'
        $body = $ln; $size = 15; $weight = 'Normal'; $indent = 0
        if ($body -match '^\s*#{1,6}\s+(.*)$') { $body = $Matches[1]; $weight = 'SemiBold'; $size = 17 }
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
                $p.Inlines.Add((New-ReadRun -Text 'thinking   ' -Brush $Pal.TextDim -Size 11.5 -Weight 'SemiBold'))
                $p.Inlines.Add((New-ReadRun -Text $head -Brush $Pal.TextDim -Size 13 -Italic))
                $doc.Blocks.Add($p)
            }
            'tool' {
                # 🔴 CONTAINED, AND AT A READABLE SIZE. This was a raw inline run
                # at 11.5px with no ground under it, and when the rest of the
                # window's scale went up it did not - so the transcript kept the
                # cramped monospace density that reads as a console log rather
                # than as a document with code in it. Same treatment as a fenced
                # code block, because that is what it is.
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 0, 3, 0, 3
                $p.Padding = New-Object System.Windows.Thickness 12, 7, 12, 7
                $p.Background = $Pal.Raised
                $p.BorderBrush = $Pal.HairlineHi
                $p.BorderThickness = New-Object System.Windows.Thickness 2, 0, 0, 0
                $p.Inlines.Add((New-ReadRun -Text ($b.Head + '   ') -Brush $Pal.TextMid -Size 12.5 -Weight 'SemiBold' -Mono))
                $p.Inlines.Add((New-ReadRun -Text (Compress-SRPath $b.Body) -Brush $Pal.TextHigh -Size 12.5 -Mono))
                $doc.Blocks.Add($p)
            }
            'tools' {
                # The summary of a RUN of calls. Quieter than a single call on
                # purpose - it is a count, not content.
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 0, 4, 0, 4
                $p.Padding = New-Object System.Windows.Thickness 12, 6, 12, 6
                $p.Background = $Pal.Raised
                $p.Inlines.Add((New-ReadRun -Text ($b.Head + '   ') -Brush $Pal.TextMid -Size 12 -Weight 'SemiBold'))
                $p.Inlines.Add((New-ReadRun -Text (Compress-SRPath $b.Body) -Brush $Pal.TextDim -Size 12 -Mono))
                $doc.Blocks.Add($p)
            }
            'result' {
                $first = "$(@($b.Body -replace "`r", '' -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1))"
                if ($first.Length -gt 150) { $first = $first.Substring(0, 147) + [string][char]0x2026 }
                # It belongs to the call above it, so it is indented under that
                # block rather than given a ground of its own.
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 14, 1, 0, 6
                $p.Inlines.Add((New-ReadRun -Text ($b.Head + '   ') -Brush $Pal.TextDim -Size 12 -Weight 'SemiBold' -Mono))
                $p.Inlines.Add((New-ReadRun -Text (Compress-SRPath $first) -Brush $Pal.TextDim -Size 12 -Mono))
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
# READING the question and SHOWING it are two jobs, and only one of them is
# slow. Get-SRScreenQuestion spawns a child process with a 3-second budget and a
# retry, so the background probe does the reading and hands the result to
# Show-Ask; Update-Ask is the foreground path, for the moment you select a
# conversation and want an answer now.
function Update-Ask { param($R)
    if (-not $R -or -not $R.A -or -not $R.A.Pid) { Show-Ask $null; return }
    $q = $null
    try { $q = Get-SRScreenQuestion -ProcessId ([int]$R.A.Pid) } catch { }
    Show-Ask $q
}

function Show-Ask { param($q)
    $ui.AskBox.Visibility = $V_Hide
    $ui.AskOptions.ItemsSource = $null
    # 🔴 CLEARED ON EVERY PATH. It used to be set only after the early return, so
    # selecting a conversation that was not running left the PREVIOUS one's
    # question in it - and the answer record then filed another conversation's
    # options against this answer. That record exists to settle a wrong reading;
    # one that names the wrong menu is worse than none at all.
    $script:lastAsk = $q
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
# Fire-and-forget: the record is written on its own runspace so the operator
# never waits for evidence. It is not tracked or collected - there is nothing to
# come back for, and a failure to record must never surface as a failure to
# answer.
function Start-AnswerRecord {
    param([string]$SessionId, [int]$Pid_, [int]$Index, $Question, [string]$Why)
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('SRHere', $here)
        $rs.SessionStateProxy.SetVariable('SRA', @{
            SessionId = $SessionId; Pid_ = $Pid_; Index = $Index; Why = $Why
            Options = @($Question.Options); Multi = [bool]$Question.Multi
            CursorAt = $(if ($Question) { $Question.CursorAt } else { -1 })
            # The screen as it was when these options were put on screen. The
            # contract asked for BEFORE and after, and a version of this shipped
            # with only the after - which is the half that cannot tell a misread
            # from a mis-send. It rides along on the question at no cost.
            Before = "$($Question.Screen)"
            Chose = $(if ($Question -and $Index -lt @($Question.Options).Count) { "$(@($Question.Options)[$Index])" } else { '' })
            Dir = (Join-Path $SR_StateDir 'answers')
        })
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript({
            . (Join-Path $SRHere '_common.ps1')
            Start-Sleep -Milliseconds 500
            $after = $null
            try { $after = Get-SRScreenText -ProcessId ([int]$SRA.Pid_) } catch { }
            try {
                if (-not (Test-Path -LiteralPath $SRA.Dir)) { $null = New-Item -ItemType Directory -Path $SRA.Dir -Force }
                $rec = [PSCustomObject]@{
                    at = (Get-Date).ToString('o'); sessionId = $SRA.SessionId; pid = $SRA.Pid_
                    index = $SRA.Index; chose = $SRA.Chose; options = $SRA.Options
                    multi = $SRA.Multi; cursorAt = $SRA.CursorAt; failed = $SRA.Why
                    before = $SRA.Before
                    after = "$after"
                }
                $f = Join-Path $SRA.Dir ('answer-{0}-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), "$($SRA.SessionId)".Substring(0, 8))
                [System.IO.File]::WriteAllText($f, ($rec | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
            } catch { }
        })
        $null = $ps.BeginInvoke()
    } catch { }
}

# 🔴 THE BAND LAGGED THE ACTION BY UP TO 45 SECONDS. The band is derived from
# the agent map, and the agent map is only refreshed by the live probe - so a
# conversation you had just answered sat in NEEDS YOU, unchanged, for most of a
# minute. The operator's words: "the sessions are not updating from needs you,
# which is not desirable". Answering something and watching it not move is the
# single most disconcerting thing this window could do, because the whole point
# of the surface is telling you what still wants you.
#
# 🩤 THE OPTIMISTIC MOVE IS NOT A GUESS ABOUT THE FUTURE, it is a statement
# about the past: keys have just been delivered to that session, so it is no
# longer waiting on you whatever it does next. The probe is kicked in the same
# breath and overwrites this with measured truth within a second or two; if it
# comes back still waiting - because it asked something new - the real state
# wins. Nothing here fakes a state that is not about to be confirmed.
function Move-RowToWorking { param($Row)
    if (-not $Row) { return }
    $Row.Band = 'working'
    try { Build-Sessions } catch { }
    # Restart rather than merely start, so the next scheduled probe is a full
    # interval after THIS one instead of arriving on top of it.
    try {
        $script:liveTimer.Stop()
        Start-LiveProbe
        $script:liveTimer.Start()
    } catch { }
}

function Invoke-Answer { param([int]$Index)
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return }
    $r = $it.Row
    if (-not $r.A -or -not $r.A.Pid) { Set-Status 'that conversation is not running any more' 'warn'; return }
    Set-Status 'answering...'
    $procId = [int]$r.A.Pid
    # 🪤 THE "BEFORE" IS ALREADY IN HAND. Reading the console again here cost a
    # second before the keystroke even left - Send-SRQuestionAnswer reads the
    # screen itself to find the cursor, and $script:lastAsk holds what was drawn
    # when the buttons were built. Answering must feel immediate.
    $why = $null
    try { $why = Send-SRQuestionAnswer -SessionId $r.Id -Index $Index } catch { $why = $_.Exception.Message }
    if ($why) { Set-Status $why 'bad' } else {
        Set-Status 'answered' 'ok'
        $ui.AskBox.Visibility = $V_Hide
        $script:lastAsk = $null
        Move-RowToWorking $r
    }

    # The AFTER shot is the evidence, and it is taken on a background thread so
    # it costs the operator nothing. It is still the same measurement: what the
    # screen said once the keys had landed.
    Start-AnswerRecord -SessionId $r.Id -Pid_ $procId -Index $Index -Question $script:lastAsk -Why "$why"
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
    if ($why) { Set-Status $why 'bad' } else {
        $ui.SendBox.Text = ''
        Set-Status 'sent' 'ok'
        # Typed into, so it is not waiting on you any more - same reasoning as
        # answering a question. See Move-RowToWorking.
        Move-RowToWorking $r
    }
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
    # 🔴 STICK TO THE BOTTOM, BUT NEVER FIGHT THE READER.
    #
    # The newest line is the one you want, so a fresh conversation opens at the
    # end and a refresh that arrives while you are AT the end keeps you there.
    # The moment you scroll up you are reading something, and nothing may drag
    # you back down - a log window that yanks you to the bottom mid-sentence is
    # the single most irritating thing this pane could do.
    #
    # Whether we were at the bottom has to be sampled BEFORE the document is
    # replaced, because replacing it resets the extent and the answer with it.
    $stick = Test-AtBottom
    $ui.PaneDoc.Document = $doc
    $ui.PaneEmpty.Visibility = $V_Hide
    if ($stick) { Move-ToBottom }
}

# The ScrollViewer inside a FlowDocumentScrollViewer is part of its template, so
# it does not exist until the control has been through a layout pass and cannot
# be found by name from outside. Walked once and remembered.
$script:paneScroller = $null
function Get-PaneScroller {
    if ($script:paneScroller) { return $script:paneScroller }
    $sv = $null
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($ui.PaneDoc)
    while ($stack.Count -and -not $sv) {
        $el = $stack.Pop()
        if ($el -is [System.Windows.Controls.ScrollViewer]) { $sv = $el; break }
        $n = 0
        try { $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($el) } catch { }
        for ($i = 0; $i -lt $n; $i++) { $stack.Push([System.Windows.Media.VisualTreeHelper]::GetChild($el, $i)) }
    }
    $script:paneScroller = $sv
    return $sv
}

# "At the bottom" with a tolerance, because a partly-visible last line leaves a
# fractional gap that never reaches exactly zero - and demanding exactness would
# quietly turn the feature off.
function Test-AtBottom {
    $sv = Get-PaneScroller
    if (-not $sv) { return $true }        # nothing rendered yet: a new pane starts at the end
    if ($sv.ScrollableHeight -le 0) { return $true }
    return (($sv.ScrollableHeight - $sv.VerticalOffset) -le 24)
}

function Move-ToBottom {
    $sv = Get-PaneScroller
    if (-not $sv) {
        # First paint: the template has not been built yet, so there is nothing
        # to scroll. Ask again once WPF has laid it out.
        $null = $window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded,
            [action]{ $s = Get-PaneScroller; if ($s) { $s.ScrollToEnd() } })
        return
    }
    # Also deferred: the new document has been assigned but not measured, so its
    # extent is still the OLD one and ScrollToEnd would stop short.
    $null = $window.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Loaded,
        [action]{ $s = Get-PaneScroller; if ($s) { $s.ScrollToEnd() } })
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

    # 🔴 ONLY A DIFFERENT CONVERSATION STARTS AT THE BUDGET. -Force means "the
    # content moved", not "this is a new conversation", and resetting here undid
    # 'load earlier' on every forced refresh - the exact defect the $same guard
    # above was added to fix, reintroduced one line below it.
    if (-not $same) { $script:tailBytes = $script:TailBase }
    Update-Document
    # A DIFFERENT conversation always opens at its newest line. Update-Document
    # only STICKS to the bottom - and "were we at the bottom" was answered about
    # the conversation you just left, which says nothing about this one.
    if (-not $same) { Move-ToBottom }
    if (-not $same) {
        $script:lastAskAt = Get-Date
        Update-Ask $r
    }
    Update-SendState
    if (-not $same) { $script:followStamp = $null }
}

# FOLLOW ONLY THE SELECTED SESSION. One file, checked once a second, rather than
# a watcher per conversation: 14 run today and the cost has to stay flat in that
# number. Polling one file also has nothing to leak when the selection changes,
# which a FileSystemWatcher does.
$script:followStamp = $null
$script:followTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:followTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:followTimer.Add_Tick({
    # Nothing moves under an open sheet - see the gate on the model timers.
    if ($script:sheetDepth -gt 0) { return }
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
    try { Update-Document; Update-SendState } catch { }

    # 🔴 A TRANSCRIPT THAT IS GROWING IS A SESSION THAT IS WORKING, and this
    # tick already knows it grew - it just compared the bytes. Bands used to wait
    # for the 45-second probe to say so, which is why a conversation could sit in
    # NEEDS YOU while visibly writing on screen. Only ever moves a row OUT of
    # needing you, never into it: claiming something wants you is a claim that
    # has to be measured, and the probe is the thing that measures it.
    if ("$($r.Band)" -eq 'needs') {
        $r.Band = 'working'
        try { Build-Sessions } catch { }
    }

    # 🔴 THE CONSOLE READ IS NOT FREE AND THIS TICK IS EVERY SECOND.
    # Update-Ask spawns a child process with a 3-second budget and a retry. A
    # session that is working writes its transcript constantly, so this fired on
    # almost every tick and blocked the dispatcher for over a second each time -
    # the window would stutter for exactly as long as you watched something work.
    # Two gates: a conversation that is MID-TURN has no menu up to read, and no
    # more often than the interval below however busy it is.
    if ("$($r.A.Status)" -eq 'busy') { return }
    if ($script:lastAskAt -and ((Get-Date) - $script:lastAskAt).TotalSeconds -lt $script:AskEverySeconds) { return }
    $script:lastAskAt = Get-Date
    try { Update-Ask $r } catch { }
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
    # The only three-way question in the window. Esc keeps the window open,
    # because the one answer you can never take back is the one that throws the
    # ticks away, and a key pressed by accident must not be able to reach it.
    $r = Show-Sheet -Title 'Your ticks have not been saved' -Escape 'stay' -Body `
        ("They decide which conversations reopen at your next logon. " +
         "Closing now leaves that list exactly as it was.") -Choices @(
        @{ Key = 'stay';    Label = 'Keep working' },
        @{ Key = 'discard'; Label = 'Close anyway' },
        @{ Key = 'save';    Label = 'Save and close' }
    )
    if ($r -eq 'stay') { $e.Cancel = $true; return }
    if ($r -eq 'save') {
        try { Save-SRRegistry -Registry $script:reg; $script:dirty = $false }
        catch {
            Show-Notice 'Not saved' ("The ticks could not be written, so the window is staying open " +
                "rather than losing them.`n`n" + $_.Exception.Message)
            $e.Cancel = $true
        }
    }
})

# 🔴 THE STATE FILTER, BACK. The retired window had three clickable count
# pills; the rewrite dropped them and nothing replaced them, so there was no way
# to say "show me only what is waiting on me" - reported as "the filter option
# and logic is gone as well". It returns on the band headings rather than as new
# chrome: they already say the state and the count, and they are already where
# you are looking when you want to narrow the list.
#
# 🩤 PreviewMouseLeftButtonDown, NOT SelectionChanged or a click on the row.
# ListBoxItem marks the button-down HANDLED when it selects, which is the same
# trap that stopped the session manager ticking anything at all; and selecting a
# heading is meaningless, so SelectionChanged already steps PAST it - by the
# time that runs, the heading is no longer what is selected.
$script:bandPick = $null
$ui.SessionList.Add_PreviewMouseLeftButtonDown({
    param($s, $e)
    $it = Get-ClickedRow $e.OriginalSource
    if (-not $it -or $it.Kind -ne 'band') { return }
    $script:bandPick = $(if ($script:bandPick -eq $it.BandKey) { $null } else { "$($it.BandKey)" })
    Build-Sessions
    Set-Status $(if ($script:bandPick) {
        "showing only $($it.BandLabel.ToLower()) - click the heading again for all of them"
    } else { 'showing every conversation again' })
    $e.Handled = $true
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
    # 🔴 THE STYLE IS ASSIGNED, NOT INHERITED. A ContextMenu is not in the
    # window's visual tree - it lives in its own popup with its own presentation
    # source - so an implicit style sitting in Window.Resources is not something
    # to rely on reaching it. Without the template it keeps the OPERATING
    # SYSTEM's chrome: a white slab with a blue highlight, in the middle of a
    # black window, on the gesture the operator uses most on this surface.
    # Assigned explicitly here, and asserted in the suite.
    $m = New-Object System.Windows.Controls.ContextMenu
    $m.Style = [System.Windows.Style]$window.FindResource([System.Windows.Controls.ContextMenu])
    $itemStyle = [System.Windows.Style]$window.FindResource([System.Windows.Controls.MenuItem])
    $mk = {
        param([string]$Header, [scriptblock]$Do)
        $i = New-Object System.Windows.Controls.MenuItem
        $i.Header = $Header
        $i.Style = $itemStyle
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
            ("'{0}' will be CLOSED and opened again." -f $t) -Verb 'Relaunch') { Invoke-RelaunchOne $r }
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
#
# 🪤 TAKEN ONCE AND CLEARED. Leaving it set meant the NEXT invocation - a
# keyboard one, or a menu opened over a project header - could act on a
# conversation the mouse had pointed at minutes earlier. An action that targets
# something you cannot see is the worst kind on this surface.
$script:manageMenuRow = $null
function Get-ManageRow {
    if ($script:manageMenuRow) {
        $r = $script:manageMenuRow
        $script:manageMenuRow = $null
        return $r
    }
    $it = $ui.ManageList.SelectedItem
    if ($it -and $it.Kind -eq 'conv') { return $it.Row }
    return $null
}

# The header labels carry their own base text, so the arrow can be appended and
# stripped without a second copy of the wording drifting away from the markup.
$script:mgrHdrText = @{}
foreach ($hn in @('HdrLogon', 'HdrName', 'HdrLane', 'HdrSaid', 'HdrAge')) {
    $script:mgrHdrText[$hn] = "$($ui[$hn].Text)"
}

function Update-ManagerHeaders {
    foreach ($hn in @('HdrLogon', 'HdrName', 'HdrLane', 'HdrSaid', 'HdrAge')) {
        $el = $ui[$hn]
        $base = $script:mgrHdrText[$hn]
        if ("$($el.Tag)" -eq $script:mgrSort) {
            # ▾ down / ▴ up - the direction the VALUES run, which is what a
            # sort arrow means everywhere else.
            $el.Text = $base + '  ' + [string][char]$(if ($script:mgrDesc) { 0x25BE } else { 0x25B4 })
            $el.Foreground = $window.FindResource('TextMax')
        } else {
            $el.Text = $base
            $el.Foreground = $window.FindResource('TextLow')
        }
    }
}

foreach ($hn in @('HdrLogon', 'HdrName', 'HdrLane', 'HdrSaid', 'HdrAge')) {
    $ui[$hn].Add_MouseLeftButtonDown({
        param($s, $e)
        $key = "$($s.Tag)"
        if (-not $key) { return }
        # Clicking the column you are already sorted by reverses it; clicking a
        # different one starts that column at its most useful end - newest first
        # for age, A-Z for the text columns, ticked first for the logon boxes.
        if ($script:mgrSort -eq $key) { $script:mgrDesc = -not $script:mgrDesc }
        else {
            $script:mgrSort = $key
            $script:mgrDesc = ($key -eq 'age' -or $key -eq 'logon')
        }
        Update-ManagerHeaders
        Build-Manager
        $e.Handled = $true
    })
}
Update-ManagerHeaders

function Update-ListSortLabel {
    $cur = @($script:ListSorts | Where-Object { $_.Key -eq $script:listSort })
    $ui.ListSort.Text = $(if ($cur.Count) { "$($cur[0].Label)" } else { 'newest first' })
}
$ui.ListSort.Add_MouseLeftButtonDown({
    param($s, $e)
    $keys = @($script:ListSorts | ForEach-Object { $_.Key })
    $at = [array]::IndexOf($keys, $script:listSort)
    $script:listSort = $keys[($at + 1) % $keys.Count]
    Update-ListSortLabel
    Build-Sessions
    $e.Handled = $true
})
Update-ListSortLabel

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

# -Adopt is what makes this WRITE. Without it the plan is a pure read, which is
# what a name beginning with Get- has to mean: it is called to paint a
# confirmation and by the tests, and neither should be able to dirty the
# registry. Only the two buttons that are about to launch pass -Adopt.
function Get-TickedPlan { param([switch]$Adopt)
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
            if ($Adopt -and $ln -and $ln -ne '(untitled)' -and $ln -ne "$($r.S.title)") {
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
# -Already counts what a CALLER has ALREADY committed to launching in the same
# action, so two calls can share one cap. Relaunch needs it: it restarts the
# running set and opens the not-running set in one press, and the cap is about
# how many sessions the machine ends up with - not how many each half started.
function Limit-ToCap { param($Items, [int]$Already = 0)
    $cap = 0
    try { $cap = [int]$script:cfg.maxSessions } catch { }
    $go = @($Items)
    if ($cap -gt 0) {
        $room = $cap - $Already
        if ($room -lt 0) { $room = 0 }
        if ($go.Count -gt $room) {
            return [PSCustomObject]@{ Go = @($go | Select-Object -First $room); Over = ($go.Count - $room); Cap = $cap }
        }
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

# 🪤 THE VERB IS NOT DECORATION. 'OK' beside a list of twelve live conversations
# does not say what pressing it does, and these confirmations exist precisely
# because the action is hard to take back. Every caller names it.
function Confirm-Action { param([string]$Title, [string]$Body, [string]$Verb = 'Continue')
    return ((Show-Sheet -Title $Title -Body $Body -Escape 'no' -Choices @(
        @{ Key = 'no';  Label = 'Cancel' },
        @{ Key = 'yes'; Label = $Verb }
    )) -eq 'yes')
}

# One button, nothing to decide: something went wrong and you are being told.
function Show-Notice { param([string]$Title, [string]$Body)
    $null = Show-Sheet -Title $Title -Body $Body -Escape 'ok' -Choices @(
        @{ Key = 'ok'; Label = 'Close' }
    )
}

$ui.OpenNotRunning.Add_Click({
    $plan = Get-TickedPlan -Adopt
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
            $go.Count, $names, $(if ($note.Count) { "`n`n" + ($note -join '  ') } else { '' })) -Verb ('Open {0}' -f $go.Count))) {
        Set-Status 'nothing opened'; return
    }
    Start-LaunchQueue $go
})

$ui.RelaunchSessions.Add_Click({
    $plan = Get-TickedPlan -Adopt
    # 🔴 IT RESTARTS WHAT IS RUNNING AND OPENS WHAT IS NOT, and the count of
    # each is on the confirmation before anything happens.
    #
    # This used to take only the running ones, on the reasoning that pressing it
    # to fix the names on 12 conversations should not hand you 29 tabs. That
    # reasoning was about SURPRISE, and the confirmation below now removes the
    # surprise by naming both numbers - while the old rule had a far worse
    # failure of its own: after a reboot NOTHING is running, so the button that
    # obviously means "bring my sessions back" planned zero work and appeared
    # completely dead. Reported on 2026-08-29 after a restart, and it is the
    # tool's whole purpose.
    $lim = Limit-ToCap $plan.Restart
    $go = @($lim.Go)
    # The not-running ones come next, and share the same cap: the cap is about
    # how many sessions the machine ends up with, not how they got there.
    $freshLim = Limit-ToCap $plan.Fresh -Already $go.Count
    $open = @($freshLim.Go)
    if (-not $go.Count -and -not $open.Count) {
        Set-Status 'nothing to relaunch - nothing is ticked, or every ticked conversation is mid-turn' 'warn'; return
    }
    # 🔴 NAME WHAT WILL BE CLOSED. This kills live processes, and one of them may
    # be the conversation you are talking to right now. A count cannot be checked
    # against that; a list can.
    $names = (@($go | ForEach-Object { (Get-Title $_.S $_.D).Text }) | Sort-Object) -join ', '
    $note = @()
    if (@($plan.Busy).Count) {
        $bn = (@($plan.Busy) | ForEach-Object { (Get-Title $_.S $_.D).Text } | Select-Object -First 6) -join ', '
        $note += ('{0} are mid-turn and will be LEFT ALONE: {1}. They keep the old login - run this again once they finish.' -f @($plan.Busy).Count, $bn)
    }
    if ($open.Count) {
        $on = (@($open | ForEach-Object { (Get-Title $_.S $_.D).Text }) | Sort-Object) -join ', '
        $note += ('{0} are ticked but NOT running, so they are simply opened rather than closed first: {1}' -f $open.Count, $on)
    }
    if ($lim.Over -or $freshLim.Over) {
        $note += ('{0} more are ticked but over the maxSessions cap of {1}, so they are skipped.' -f ($lim.Over + $freshLim.Over), $lim.Cap)
    }
    # The title says both numbers, because they are two different things
    # happening to two different sets and only one of them destroys anything.
    $what = @()
    if ($go.Count)   { $what += ('restart {0}' -f $go.Count) }
    if ($open.Count) { $what += ('open {0}' -f $open.Count) }
    $head = $(if ($go.Count) {
        "The {0} already running are CLOSED and opened again - a running session reads your login AND its remote name at startup, so neither can be picked up without a restart.`n`nClosing: {1}" -f $go.Count, $names
    } else {
        'None of the ticked conversations are running, so nothing is closed - they are just opened.'
    })
    if (-not (Confirm-Action ('Relaunch: ' + ($what -join ' and ')) `
        ($head + $(if ($note.Count) { "`n`n" + ($note -join '  ') } else { '' })) -Verb (($what -join ' and ')))) {
        Set-Status 'nothing relaunched'; return
    }

    Set-Status $(if ($go.Count) { 'closing...' } else { 'opening...' })
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
    # One queue for both sets: the ones just killed and the ones that were never
    # running go through the same half-second-apart launch.
    Start-LaunchQueue (@($go) + @($open))
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
#
# 🔴 UNLESS FOCUS WENT INTO THE PICKER ITSELF. Clicking a skill moves focus to
# that ListBoxItem, which raised this event, which closed the popup - tearing
# down the very item mid-click, so the mouse never completed and only the
# keyboard could pick a skill. The new focus target decides.
$ui.SendBox.Add_LostKeyboardFocus({
    param($sender, $e)
    $to = $e.NewFocus
    while ($to) {
        if ([object]::ReferenceEquals($to, $ui.SkillList) -or [object]::ReferenceEquals($to, $ui.SkillPop)) { return }
        $p = $null
        try { if ($to -is [System.Windows.DependencyObject]) { $p = [System.Windows.Media.VisualTreeHelper]::GetParent($to) } } catch { }
        if (-not $p -and ($to -is [System.Windows.FrameworkElement])) { $p = $to.Parent }
        $to = $p
    }
    Close-SkillPop
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
        if (Confirm-Action 'Open this conversation' ("'{0}' is not running." -f $t) -Verb 'Open') {
            Start-LaunchQueue @($r)
        }
        return
    }
    if (Confirm-Action 'Relaunch this conversation' `
        ("'{0}' will be CLOSED and opened again. Anything it has written is on disk; a turn in progress is not." -f $t) -Verb 'Relaunch') {
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
        ("claude reads these settings once, at startup, so '{0}' has to be closed and reopened for them to take effect." -f $newName) -Verb 'Relaunch now') {
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

    # 🔴 ONE PALETTE, MERGED - NOT A SECOND ONE COPIED. This used to be nine
    # lines reaching across to hand individual Style objects to individual
    # controls, which worked but covered only the controls: every colour and
    # every font in spawn2.xaml was written out again by hand, and had already
    # drifted a whole redesign behind the window it opens from. The dialog now
    # asks for the same keys the window uses and gets the window's own
    # dictionary, so a token changed in one place changes both surfaces - and
    # the typeface swap in Install-SRTypeface reaches this window for free,
    # because it rewrites the very entries being merged here.
    $sp.Resources.MergedDictionaries.Add($window.Resources)
    $s.SpName.Tag = 'What this conversation will be called'

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
    # A worktree name becomes a DIRECTORY NAME on disk, so it cannot carry what a
    # conversation name happily can. Spaces and punctuation are folded to dashes
    # rather than refused: the session keeps the name you typed, its worktree
    # gets a workable version of it.
    if ($G.Worktree) {
        $wt = (("$($G.Name)" -replace '[^A-Za-z0-9._-]', '-') -replace '-{2,}', '-').Trim('-')
        if (-not $wt) { $wt = 'session' }
        $flags.Add('--worktree'); $flags.Add($wt)
    }
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
        ("Each one receives, as if you had typed it:`n`n    {0}`n`nInto: {1}" -f $msg, $names) -Verb ('Send to {0}' -f $go.Count))) {
        Set-Status 'nothing sent'; return
    }
    # 🪤 ONE PER TICK, NOT A LOOP. Each send reads the target's console to find
    # the cursor and then writes keys; a loop over ten of them with a settle
    # pause between froze the window for several seconds with no sign of
    # progress. The queue keeps the dispatcher free and reports as it goes.
    Hide-Cast
    $script:castQueue.Clear()
    $script:castOk = 0
    $script:castBad.Clear()
    $script:castMsg = $msg
    foreach ($r in $go) { $script:castQueue.Enqueue($r) }
    Set-Status ('sending to {0}...' -f $script:castQueue.Count)
    $script:castTimer.Start()
})

$script:castQueue = New-Object System.Collections.Generic.Queue[object]
$script:castBad = New-Object System.Collections.Generic.List[string]
$script:castOk = 0
$script:castMsg = ''
$script:castTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:castTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:castTimer.Add_Tick({
    if (-not $script:castQueue.Count) {
        $script:castTimer.Stop()
        if ($script:castBad.Count) {
            Set-Status ('sent to {0}; {1} refused: {2}' -f $script:castOk, $script:castBad.Count,
                (($script:castBad | Select-Object -First 4) -join '; ')) 'bad'
        } else { Set-Status ('sent to {0} conversation(s)' -f $script:castOk) 'ok' }
        return
    }
    $r = $script:castQueue.Dequeue()
    $t = '(unnamed)'
    try {
        $t = (Get-Title $r.S $r.D).Text
        # Re-checked per send: a conversation can start a turn while the queue
        # is draining, and a keystroke arriving mid-reply is not undoable.
        if ("$($r.A.Status)" -eq 'busy') {
            $script:castBad.Add(('{0} (started a turn)' -f $t))
        } else {
            $why = Send-SRSessionInput -SessionId $r.Id -Text $script:castMsg
            if ($why) { $script:castBad.Add(('{0} ({1})' -f $t, $why)); Write-SRLog ('  [FAIL] cast to {0}: {1}' -f $t, $why) }
            else { $script:castOk++; Write-SRLog ('  [ok]   cast to {0}' -f $t) }
        }
    } catch {
        $script:castBad.Add(('{0} ({1})' -f $t, $_.Exception.Message))
    }
    Set-Status ('sending... {0} left' -f $script:castQueue.Count)
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

# WINDOWS DRAGS THIS, NOT US. WindowChrome's CaptionHeight now covers the header,
# so the OS moves, snaps, shakes and double-click-maximises it exactly as it does
# any other window - and the system menu is back on Alt+Space and right-click.
# There is deliberately no DragMove handler: it only ever reimplemented a
# fraction of that, and badly.

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

# The app is an inset card, so the window's own margin is what creates the ground
# around it - and the maximised overhang has to be ADDED to that inset rather
# than replacing it, or maximising squares the card off against the screen edge.
$script:ShellInset = 14.0

function Update-Frame {
    Update-MaxGlyph
    $m = $script:ShellInset
    if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
        $ui.Shell.Margin = New-Object System.Windows.Thickness `
            ($m + $script:maxPad.Left), ($m + $script:maxPad.Top), `
            ($m + $script:maxPad.Right), ($m + $script:maxPad.Bottom)
    } else {
        $ui.Shell.Margin = New-Object System.Windows.Thickness $m
    }
}

# 🪤 A Clip DOES NOT FOLLOW ITS ELEMENT. The rounded card is clipped so its
# corners actually cut the content - without that the radius is painted and the
# children square it off again, which reads as a rendering bug. But the geometry
# is a fixed Rect, so it has to be re-cut on every resize or the card clips to
# its old size and the bottom-right of the window goes blank.
function Update-ShellClip {
    $b = $ui.Shell
    if (-not $b -or $b.ActualWidth -le 0 -or $b.ActualHeight -le 0) { return }
    $g = $b.Clip
    if ($g -is [System.Windows.Media.RectangleGeometry]) {
        $g.Rect = New-Object System.Windows.Rect 0, 0, $b.ActualWidth, $b.ActualHeight
    }
}
$window.Add_StateChanged({ Update-Frame })
$ui.Shell.Add_SizeChanged({ Update-ShellClip })
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
# 🪤 THIS RUNS EVERY SIX SECONDS OVER EVERY CONVERSATION, so it is written for
# that and not for elegance. The first version cost 294 ms because it called
# Get-Date and re-parsed $s.lastActive from a string once PER ROW - 184 DateTime
# parses and 184 clock reads to decide whether anything had moved. The clock is
# read once, the timestamp is parsed once when the model is built ($r.At), and
# the age is derived by integer arithmetic on ticks.
function Get-ModelFingerprint {
    $sb = New-Object System.Text.StringBuilder
    $nowTicks = [DateTime]::Now.Ticks
    foreach ($r in $script:model) {
        if (-not $r.Live -and -not $r.Warm -and $r.Id -ne $script:selId) { continue }
        $said = ''
        if ($r.Said) {
            $s = "$($r.Said.Said)"
            if ($s.Length -gt 40) { $said = $s.Substring(0, 40) } else { $said = $s }
        }
        # 🔑 THE LABEL, NOT THE ELAPSED TIME. Fingerprinting raw minutes would
        # differ every single minute for a row that displays "3d" and has not
        # changed in any visible way - a guaranteed repaint per minute, which is
        # the scroll-stealing this whole comparison exists to prevent.
        $null = $sb.Append($r.Id).Append('|').Append($r.Band).Append('|').
                    Append((Get-AgeLabel ($nowTicks - $r.At))).Append('|').Append($said).Append("`n")
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

# The slow half, off the UI thread. EVERYTHING that touches a file or spawns a
# process happens in here - the registry, the agent list, the last-said lines,
# and the pending question for the one conversation on screen. The UI side then
# only walks object graphs.
#
# 🪤 THE LAST-SAID READS BELONG HERE TOO. Leaving them on the UI side cost ~580 ms
# of frozen window per probe; the pending-question read cost up to another 6 s,
# because Get-SRScreenQuestion has a 3-second budget AND a retry. Both used to
# run on the dispatcher every 45 seconds.
$script:ProbeJob = {
    . (Join-Path $SRHere '_common.ps1')
    $out = @{ Reg = $null; Agents = @{}; Said = @{}; Ask = $null; AskFor = '' }
    try { $out.Reg = Get-SRRegistry } catch { }
    try { $out.Agents = Get-SRAgentStatus -Refresh } catch { }

    # Only the live and the recent, exactly as the foreground pass decides it:
    # opening a file per conversation for all 218 is seconds, not milliseconds.
    if ($out.Reg) {
        $cut = (Get-Date).AddHours(-24)
        foreach ($d in $out.Reg.directories) {
            if ($d.missing) { continue }
            foreach ($s in @($d.sessions)) {
                if ($s.gone) { continue }
                $id = "$($s.sessionId)".ToLower()
                $warm = $false
                try { $warm = ([datetime]$s.lastActive -gt $cut) } catch { }
                if (-not ($out.Agents[$id] -or $warm)) { continue }
                try { $out.Said[$id] = Get-SRLastSaid -JsonlPath $s.jsonl } catch { }
            }
        }
    }

    # The pending question for whatever the pane is showing. SRSelPid is 0 when
    # nothing is selected or it is not running.
    if ($SRData.SelPid -gt 0) {
        try { $out.Ask = Get-SRScreenQuestion -ProcessId ([int]$SRData.SelPid) } catch { }
        $out.AskFor = "$($SRData.SelId)"
    }
    $out
}

function Start-LiveProbe {
    if ($script:probePs) { return }        # one at a time; a queue would pile up
    try {
        # What the pane is showing, so the job can read its pending question
        # while it is out there anyway.
        $selPid = 0; $selId = ''
        $selRow = Get-SelectedRow
        if ($selRow -and $selRow.A -and $selRow.A.Pid) { $selPid = [int]$selRow.A.Pid; $selId = "$($selRow.Id)" }

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('SRHere', $here)
        $rs.SessionStateProxy.SetVariable('SRData', @{ SelPid = $selPid; SelId = $selId })
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
    # disk; adopting it while there are unsaved changes would discard what you
    # just ticked. With unsaved work in hand, only the agent map is taken - and
    # then the ROWS ARE NOT REBOUND EITHER, because the rows must always point
    # into whichever registry $script:reg is.
    if (-not $script:dirty -and $res.Reg) {
        Update-Model -Registry $res.Reg -Agents $res.Agents -Said $res.Said
    } elseif ($res.Agents) {
        $script:agents = $res.Agents
        foreach ($r in $script:model) {
            $a = $script:agents["$($r.Id)"]
            $r.A = $a
            $r.Live = [bool]$a
            try { $r.Conv = Resolve-SRSessionState -Agent $a -Conv $null } catch { }
            if ($res.Said -and $res.Said.ContainsKey("$($r.Id)")) { $r.Said = $res.Said["$($r.Id)"] }
            $r.Band = Get-Band $r
        }
    }

    if ($script:surface -eq 'work') { Build-Sessions } else { Build-Manager }
    $ui.LiveCount.Text = ('{0} live of {1} conversations across {2} projects' -f `
        @($script:model | Where-Object { $_.Live }).Count, $script:model.Count, @($script:dirs).Count)

    # The pending question the job read for us, applied only if the pane is
    # still showing the same conversation - the selection can move while a probe
    # is in flight, and showing one session's menu under another's name would be
    # the worst possible bug in this window.
    if ("$($res.AskFor)" -and "$($res.AskFor)" -eq "$($script:selId)") { Show-Ask $res.Ask }
    $script:probeAt = Get-Date
}

# Re-derive the bands from the fresh agent map, WITHOUT re-reading transcripts:
# that is what makes a conversation move into NEEDS YOU, and it is the reason
# this tier exists at all.
$script:fastTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:fastTimer.Interval = [TimeSpan]::FromSeconds($script:FastSeconds)
# 🔴 THE $sheetDepth GATE ON ALL THREE IS LOAD-BEARING, not tidiness. A sheet
# blocks its CALLER on a nested dispatcher frame, but the dispatcher itself
# keeps pumping - so without this the model would carry on rebuilding underneath
# an open confirmation. The caller is parked mid-function holding the very rows
# the sheet is naming, and a rebuild replaces those objects: press the button
# and the action lands on orphans that are no longer in the model. The window
# simply stands still while it is asking, and picks up on the next tick.
$script:fastTimer.Add_Tick({
    if ($script:sheetDepth -gt 0) { return }
    try { Invoke-FastPass } catch { Write-SRLog ('fast pass failed: ' + $_.Exception.Message) } })

$script:liveTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:liveTimer.Interval = [TimeSpan]::FromSeconds($script:LiveSeconds)
$script:liveTimer.Add_Tick({
    if ($script:sheetDepth -gt 0) { return }
    try { Start-LiveProbe } catch { Write-SRLog ('live probe failed: ' + $_.Exception.Message) } })

# The collector. Cheap enough to run often; it does nothing until the job ends.
# Gated too: it is the half that actually WRITES the probe's findings into the
# model, so letting it through would defeat the gate on the starter above.
$script:pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:pollTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:pollTimer.Add_Tick({
    if ($script:sheetDepth -gt 0) { return }
    try { Complete-LiveProbe } catch { Write-SRLog ('probe collect failed: ' + $_.Exception.Message) } })

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
