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

$selfPath = Join-Path $here 'sessions-window.ps1'
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

# ---------------------------------------------------------------------------
# 🔴 THE YELLOW LINE ROUND THE WINDOW IS NOT OURS. Reported as "when the tool is
# in a windowed mode, I am seeing a yellow border around it", and nothing in
# window2.xaml draws one - the Shell's border is EdgeLit, white at 14%.
#
# It is Windows 11 painting the ACCENT COLOUR on the active window's border,
# which it does for every window whose personalisation setting allows it. It
# only shows windowed because a maximised window has no border to paint, which
# is exactly the shape of the report.
#
# DWMWA_BORDER_COLOR (34) with DWMWA_COLOR_NONE turns it off for THIS window
# only - it changes no setting and affects nothing else the operator runs. On
# anything before Windows 11 22000 the call simply fails and the border stays,
# which is why the result is ignored rather than checked.
#
# 🪤 IT NEEDS AN HWND, so it cannot run here - the handle does not exist until
# the source is initialised. Called from Add_SourceInitialized below.
if (-not ('SRGui2.Dwm' -as [type])) {
    Add-Type -Namespace SRGui2 -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll", PreserveSig = true)]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
'@
}
function Hide-SRAccentBorder { param($Win)
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($Win)).Handle
        if ($h -eq [IntPtr]::Zero) { return }
        # DWMWA_COLOR_NONE is 0xFFFFFFFE, which as a signed 32-bit value is -2.
        # Written as -2 because that is what the API takes and what the marshaller
        # sends; spelling it 0xFFFFFFFE needs an unchecked cast to say the same
        # thing less clearly.
        $none = -2
        $null = [SRGui2.Dwm]::DwmSetWindowAttribute($h, 34, [ref]$none, 4)
    } catch { }
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
    'WorkSurface','RailCol','ListCol','RailPane','RailSplit','RailList','RailClear','RailSearch','RailSort','RailOnlyLive','RailShelved','RailSuggest',
    'ListPane','ListSplit','ListCaption','ListSort','ListSearch','ListCount','SessionList',
    'AskTabs','AskFreeBox','AskFree','AskFreeSend','AskFreeLabel','AskReview',
    'OutputPane','PaneName','PaneState','PaneStateDot','PaneStop','PaneGoTo','PaneRelaunch','PaneSettings',
    'SettingsBox','SetName','SetModel','SetEffort','SetPerm','SetPermNote',
    'SetRemote','SetHidden','SetPending','SetCancel','SetApply',
    'SetToolsFold','SetAllow','SetDeny',
    'CastBox','CastWho','CastList','CastText','CastCancel','CastSend','CastCompact',
    'PaneDoc','PaneEmpty','PaneChips','PaneTools','PaneZoom','ShellBox','ShellHead','ShellList','ShellFold','PaneWorktree','PaneCompact','AskBox','AskHeader','AskText','AskOptions','AskFooter','AskNote',
    'LivePane','LiveMark','LiveHead','LiveText',
    'RailFold','ListFold','RailStrip','RailOpen','ListOpen','ListStrip','StripList','StripCount','AskScroll',
    'SendNote','SendBox','SendBtn','SkillPop','SkillList','SkillHint',
    'QueueBox','QueueHead','QueueList',
    'ManageSurface','ManageCaption','ManageList','ManageCount',
    'OpenNotRunning','RelaunchSessions','SignIn','BridgeNote',
    'HdrLogon','HdrName','HdrLane','HdrSaid','HdrAge',
    'MgrAll','MgrTicked','MgrRunning','MgrNeeds','MgrFilterNote',
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

# 🔴 IS THE KEYBOARD IN A PLACE WHERE LETTERS ARE LETTERS?
#
# A FUNCTION, NOT AN EXPRESSION, BECAUSE THE SUITE COULD NOT SEE THE OLD ONE. The
# window's bare-letter shortcuts stood down for two named boxes while the window
# had nine, and `hello` typed into the broadcast box arrived as `heo` with each
# swallowed `l` doubling the transcript tail budget. Nothing caught it, because
# the decision lived inline inside a PreviewKeyDown handler that a headless
# suite cannot raise an event into - there is no PresentationSource on a window
# that has never been shown, so a KeyEventArgs cannot even be constructed.
#
# 🔑 SO THE DECISION MOVES SOMEWHERE CALLABLE. The handler still owns WHEN to
# ask; this owns WHAT the answer is, and gui2 asserts it against real controls.
# That is the difference between a defect the suite can catch and one that has
# to be reported by a person typing into a box.
#
# 🪤 ASK THE ELEMENT WHAT IT IS, NEVER LIST THE BOXES. A list was correct when
# there were two text boxes and has been silently wrong for every one added
# since. TextBoxBase covers TextBox and RichTextBox; PasswordBox is not a
# TextBoxBase and has to be named. An editable ComboBox hosts a TextBox as its
# focused element, so it is covered by the first test rather than needing a
# third.
function Test-SRTypingTarget { param($Element)
    if ($null -eq $Element) { return $false }
    if ($Element -is [System.Windows.Controls.Primitives.TextBoxBase]) { return $true }
    if ($Element -is [System.Windows.Controls.PasswordBox]) { return $true }
    return $false
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
# Bumped every time Update-Model replaces the model. Nothing else adds to or
# removes from that list, so this changes exactly when MEMBERSHIP does.
$script:modelGen  = 0
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
# 🔴 AND THE OPERATOR'S CHOICE OVERRIDES ALL OF IT, ALWAYS. Decided 2026-09-03,
# asked as: if you collapse a column by hand and then resize across 1180px, what
# wins? The width rule stops touching a column the moment you set it yourself,
# until you set it back. The alternative - width wins below the breakpoints -
# means the window silently undoes something you just did, and the rule for when
# it will is written down nowhere the operator can see. On a wide monitor, which
# is where this was asked for, the width rule never fires anyway.
#
# 🪤 $null IS A THIRD STATE AND IT IS LOAD-BEARING: unset means "follow the
# width", which is not the same as "open". A [bool] here would make every
# freshly-installed window behave as though the operator had pinned both columns
# open, and the adaptive layout would be dead on a narrow screen.
$SR_StripWidth = 44.0
# The projects rail keeps only its caret: no count, no dots, nothing to read.
$SR_RailStripWidth = 26.0
$script:foldRail = $null
$script:foldList = $null
# What Update-Columns last actually applied, so a resize that changes nothing
# costs two property reads instead of a rebind. Deliberately not a bool pair:
# '' can never equal a real key, so the first call always applies.
$script:foldApplied = ''
# Absent from the config means AUTO, not open - so a fresh install keeps the
# adaptive behaviour and only a deliberate press pins a column either way.
try {
    $cfgFold = Get-SRConfig
    if ($null -ne $cfgFold.PSObject.Properties['foldProjects']) { $script:foldRail = [bool]$cfgFold.foldProjects }
    if ($null -ne $cfgFold.PSObject.Properties['foldSessions']) { $script:foldList = [bool]$cfgFold.foldSessions }
} catch { }

function Get-ColumnFold {
    $w = [double]$window.ActualWidth
    if ($w -le 0) { $w = [double]$window.Width }
    # A window that has not been measured yet must not read as narrow, or the
    # first layout would collapse both columns and then never put them back.
    $autoRail = ($w -gt 0 -and $w -lt 1180)
    $autoList = ($w -gt 0 -and $w -lt 900)
    return @{
        Rail = $(if ($null -ne $script:foldRail) { [bool]$script:foldRail } else { $autoRail })
        List = $(if ($null -ne $script:foldList) { [bool]$script:foldList } else { $autoList })
    }
}

function Update-Columns {
    $s = Get-ColumnFold
    # Capture a dragged width before it is collapsed away - but only while the
    # column is actually showing, or the strip's 44px would be remembered as the
    # sessions column's width and it would come back that wide.
    if ("$($ui.RailPane.Visibility)" -eq 'Visible' -and $ui.RailCol.Width.Value -gt 0) {
        $script:railWidth = [double]$ui.RailCol.Width.Value
    }
    if ("$($ui.ListPane.Visibility)" -eq 'Visible' -and $ui.ListCol.Width.Value -gt 0) {
        $script:listWidth = [double]$ui.ListCol.Width.Value
    }

    # 🪤 THE EARLY RETURN IS NOT AN OPTIMISATION, IT IS THE POINT. This runs on
    # every SizeChanged, and SizeChanged fires continuously while a window or a
    # splitter is being dragged - so without this, Update-Strip would filter the
    # whole model and rebind a list on every frame of a drag. The width capture
    # above stays OUTSIDE the guard, because remembering a dragged width is
    # exactly what happens while the state is NOT changing.
    $key = ('{0}{1}' -f [int][bool]$s.Rail, [int][bool]$s.List)
    if ($key -eq $script:foldApplied) { return }
    $script:foldApplied = $key

    if ($s.Rail) {
        # The rail is a FILTER, not a status surface - nothing in it says a
        # conversation needs you - so nearly all of it goes. 🪤 But not ALL of
        # it: a control that collapses its own column and leaves nothing behind
        # has removed the only way back, and a keyboard shortcut is not
        # discoverable enough to be that way. 26px is the caret and nothing else.
        $ui.RailPane.Visibility  = $V_Hide
        $ui.RailSplit.Visibility = $V_Hide
        $ui.RailStrip.Visibility = $V_Show
        $ui.RailCol.Width = New-Object System.Windows.GridLength $SR_RailStripWidth
    } else {
        $ui.RailStrip.Visibility = $V_Hide
        $ui.RailPane.Visibility  = $V_Show
        $ui.RailSplit.Visibility = $V_Show
        $ui.RailCol.Width = New-Object System.Windows.GridLength $script:railWidth
    }

    if ($s.List) {
        $ui.ListPane.Visibility  = $V_Hide
        $ui.ListSplit.Visibility = $V_Hide
        $ui.ListStrip.Visibility = $V_Show
        $ui.ListCol.Width = New-Object System.Windows.GridLength $SR_StripWidth
        Update-Strip
    } else {
        $ui.ListStrip.Visibility = $V_Hide
        $ui.ListPane.Visibility  = $V_Show
        $ui.ListSplit.Visibility = $V_Show
        $ui.ListCol.Width = New-Object System.Windows.GridLength $script:listWidth
    }

    # The carets do not need re-labelling - each one only ever appears on the
    # state it acts from, and points the way the column will move.
}

function Set-Breakpoint { Update-Columns; Set-AskCap }

# 🔴 THE QUESTION CARD NEVER TAKES MORE THAN A THIRD OF THE WINDOW.
#
# Reported: "the question card is taking up a lot of space, which isn't
# necessarily wrong, but we still need to be able to obtain information from the
# conversation at all times." It sits in its own grid row, so every pixel it
# takes comes straight off the transcript - and its cap was a FIXED 380px, which
# is a third of a tall window and nearly half of a short one. A fixed number
# cannot mean "a third" on two different screens, and this operator has two.
#
# 🪤 A FLOOR AS WELL AS A FRACTION. A third of a very short window is not enough
# to show a question and its options at all, and a card too small to read is
# worse than one that crowds the transcript - so it never goes below 220px, and
# on a window that short the operator has bigger problems than the ratio.
$SR_AskMaxFrac = 0.34
function Set-AskCap {
    if (-not $ui.AskScroll) { return }
    $h = 0.0
    try { $h = [double]$window.ActualHeight } catch { }
    if ($h -le 0) { try { $h = [double]$window.Height } catch { } }
    if ($h -le 0) { return }
    $cap = [Math]::Round($h * $SR_AskMaxFrac, 0)
    if ($cap -lt 220) { $cap = 220.0 }
    if ($cap -gt 620) { $cap = 620.0 }
    try { $ui.AskScroll.MaxHeight = $cap } catch { }
}

# THE FLUSH LANE FOR Save-SRConfigLater (_common.ps1).
#
# ApplicationIdle rather than a timer: the write should happen as soon as the
# window has nothing better to do - usually a frame or two after the click -
# not on a fixed delay that widens the window in which a kill loses the setting.
#
# 🪤 COALESCED, WHICH IS THE POINT. Stepping the zoom four times queues four
# values and ONE flush, so it is one read-modify-write of the config instead of
# four. The flag is what makes that true; without it each click queues its own
# callback and the saving is only that they land off the gesture.
#
# 🪤 AND IT IS STILL THE UI THREAD. A runspace would take the write off the
# thread entirely, and would also mean two threads doing read-modify-write on
# one file - on Windows the Move-Item then fails outright when the other holds
# it open, which is a reproducible failure in place of a cost. Idle is the
# cheaper correct answer: the gesture is free and the write is single-threaded.
$script:cfgFlushQueued = $false

function Request-SRConfigFlush {
    if ($script:cfgFlushQueued) { return }
    $script:cfgFlushQueued = $true
    try {
        $null = $window.Dispatcher.BeginInvoke([Action]{
            # Cleared FIRST: a throw below must not strand the flag, or every
            # later click would queue nothing and the settings would stop being
            # written at all until the close.
            $script:cfgFlushQueued = $false
            try { $null = Save-SRConfigWrites }
            catch { Write-SRLog ('  [skip] could not remember a setting: ' + $_.Exception.Message) }
        }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    } catch { $script:cfgFlushQueued = $false }
}

function Invoke-ColumnFold { param([string]$Which)
    $s = Get-ColumnFold
    if ($Which -eq 'rail') {
        $script:foldRail = -not $s.Rail
        try { Save-SRConfigLater -Name 'foldProjects' -Value ([bool]$script:foldRail) } catch { }
    } else {
        $script:foldList = -not $s.List
        try { Save-SRConfigLater -Name 'foldSessions' -Value ([bool]$script:foldList) } catch { }
    }
    Request-SRConfigFlush
    Update-Columns
}

# THE STRIP'S CONTENT - one dot per conversation that is waiting on you.
#
# Built from $script:model, which the sweep already maintains, so this costs a
# filter over rows that are in memory and nothing on disk. Rebuilt only while
# the strip is the thing on screen: a collapsed column that keeps re-binding a
# list nobody can see is the kind of cost that shows up later as "the window
# feels heavy".
function Update-Strip {
    if ("$($ui.ListStrip.Visibility)" -ne 'Visible') { return }
    # 🔴 TWO BANDS, IN THIS ORDER. Waiting first, in the NEEDS accent, because
    # that is the question the strip exists to answer. Working below it in the
    # working accent, because "nothing is waiting on me" and "nothing is
    # happening at all" are different states and an empty rail said both.
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($band in @('needs', 'working')) {
        $rows = @()
        try { $rows = @(Sort-SessionRows @($script:model | Where-Object { "$($_.Band)" -eq $band -and (Test-OnSurface $_) })) }
        catch { $rows = @() }
        $acc = $window.FindResource($(if ($band -eq 'needs') { 'AccNeeds' } else { 'AccWorking' }))
        foreach ($r in $rows) {
            $t = ''
            try { $t = (Get-Title $r.S $r.D).Text } catch { $t = "$($r.Id)" }
            $items.Add([PSCustomObject]@{
                Id     = "$($r.Id)"
                Band   = $band
                Accent = $acc
                Tip    = ("{0} - {1}. Click to open it." -f $t,
                          $(if ($band -eq 'needs') { 'waiting on you' } else { 'working' }))
            })
        }
    }
    $ui.StripList.ItemsSource = $items
    # 🪤 THE COUNT IS THE WAITING ONES, NOT THE DOTS. The dots show two states
    # now, and a number over them that meant "both" would answer a question
    # nobody asked - the strip is here to say whether anything wants you. Stated
    # even at zero: an empty rail with no number reads as broken rather than as
    # quiet, and the tooltip says which number this is.
    $waiting = @($items | Where-Object { $_.Band -eq 'needs' }).Count
    $ui.StripCount.Text = $(if ($waiting) { "$waiting" } else { [string][char]0x00B7 })
    $ui.StripCount.ToolTip = ("{0} waiting on you, {1} working" -f $waiting, ($items.Count - $waiting))
}

function Set-Surface { param([string]$Mode)
    $script:surface = $Mode
    if ($Mode -eq 'manage') {
        $ui.WorkSurface.Visibility   = $V_Hide
        $ui.ManageSurface.Visibility = $V_Show
        # 🔴 THE ASYMMETRY WAS ONE FUNCTION CALL, AND IT WAS THIS ONE. Audited:
        # switching to the manager is two Visibility assignments (0.18 ms), a
        # Set-Status (0.18) and a full Build-Manager (80.00). Switching BACK is
        # the same 0.36 and nothing else - because the work surface is kept
        # current by the six-second passes, so it can simply SHOW what was last
        # built. The manager had no such pass and no dirty flag, so the only way
        # it could be right on arrival was to rebuild it every single time.
        # Measured repeated (87.75) and alternating (79.92): nothing was cached
        # between presses.
        #
        # 🔒 WHAT MAKES THE FLAG SAFE HERE. Everything that changes what this
        # surface shows while it is VISIBLE - a sort, a filter, a fold, showing
        # older - calls Build-Manager itself and is gated on being on this
        # surface, so it clears the flag on the way past. The only thing that can
        # go stale is the model changing while the manager is HIDDEN, and that is
        # exactly where the three cache drops already are: Update-Model,
        # Set-TickOn and Toggle-Tick. The flag is set beside each of them.
        if ($script:mgrDirty) { Build-Manager }
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
# 🪤 SORTING HAPPENS WITHIN EACH PROJECT, NOT ACROSS THE WHOLE TABLE. The
# manager is grouped by project and the grouping is what makes it navigable at
# 29 projects; a global sort by age would shuffle every conversation into one
# undifferentiated run and lose the thing the surface is organised around.
$script:mgrSort = 'age'
$script:mgrDesc = $true
$script:MgrKeys = @{
    'logon' = { param($r) $(if ([bool]$r.S.enabled) { 1 } else { 0 }) }
    'name'  = { param($r) "$($r.T.Text)".ToLower() }
    # $r.Lane, already computed once per model pass - this recomputed it for
    # every row on every sort, which is why 'lane' was the last manager gesture
    # still over budget after the others came in.
    'lane'  = { param($r) "$($r.Lane)".ToLower() }
    'said'  = { param($r) "$($r.Said.Said)".Trim().ToLower() }
    # Already parsed once per pass and carried on the row; see Build-Manager.
    'age'   = { param($r) $r.At }
}

# 🔴 THE FILTER IS APPLIED BEFORE THE PROJECT COUNTS ARE TAKEN, so a project
# with nothing matching disappears entirely rather than sitting there as an
# empty heading you can open to find nothing. It reads as a shorter list, which
# is what a filter is for.
$script:mgrFilter = 'all'
function Select-ManagerRows { param($Rows)
    # 🪤 .ToArray() FIRST, NEVER @($Rows). The caller hands in a
    # List[object], and @() over one throws "Argument types do not match" in
    # PowerShell 5.1 - which PowerShell then reports against whatever OUTER
    # property assignment set the whole chain going, in this case
    # "Exception setting IsChecked". The error names a control that has nothing
    # to do with it, which is most of why this trap costs an hour every time.
    $arr = $(if ($Rows -is [System.Collections.Generic.List[object]]) { $Rows.ToArray() } else { @($Rows) })
    switch ($script:mgrFilter) {
        'ticked'  { return @($arr | Where-Object { [bool]$_.S.enabled }) }
        'running' { return @($arr | Where-Object { $_.Live }) }
        'needs'   { return @($arr | Where-Object { "$($_.Band)" -eq 'needs' }) }
        default   { return $arr }
    }
}

function Sort-ManagerRows { param($Rows)
    $key = $script:MgrKeys[$script:mgrSort]
    if (-not $key) { $key = $script:MgrKeys['age'] }
    # 🔴 THE KEY IS COMPUTED ONCE PER ROW, NOT ONCE PER COMPARISON.
    # `Sort-Object { & $key $_ }` invokes a script block through the pipeline
    # every time the sort looks at an element - and a comparison sort looks at
    # each one repeatedly. Measured over the same rows: 24.28 ms that way
    # against 3.15 ms for a plain -Property sort. Computing the key up front and
    # sorting on that gives the identical order for a fraction of the work.
    # 🪤 The pairs are unwrapped with a foreach, not ForEach-Object: that would
    # put a script block back in the pipeline per element and hand most of the
    # saving straight back.
    $keyed = New-Object System.Collections.Generic.List[object]
    foreach ($kr in $Rows) {
        $null = $keyed.Add([PSCustomObject]@{ K = (& $key $kr); R = $kr })
    }
    $paired = @($keyed.ToArray() | Sort-Object -Property K)
    $bag = New-Object System.Collections.Generic.List[object]
    foreach ($kp in $paired) { $null = $bag.Add($kp.R) }
    $sorted = $bag.ToArray()
    if ($script:mgrDesc) { [array]::Reverse($sorted) }
    # 🔴 NO LEADING COMMA. `return ,$a` on an EMPTY array returns a
    # one-element array holding the empty one, so a band or project with nothing
    # in it renders a phantom row - which is exactly what happened: "1
    # conversation from other bands survived the filter", against a row that was
    # not a conversation at all. Both callers wrap this in @(), which re-collects
    # an unrolled array correctly, so the comma buys nothing and costs that.
    return $sorted
}

# Built manager rows, keyed by conversation id. Dropped by Update-Model and by
# Toggle-Tick - the only two things that change what a row says.
$script:mgrItems = @{}
# Does the manager need rebuilding before it is shown? True until it has been
# built once, then set wherever the cache above is dropped. See Set-Surface for
# why this is safe and what it is worth.
$script:mgrDirty = $true

function Build-Manager {
    # 🪤 THE BRUSH IS LOOKED UP ONCE, NOT PER ROW. FindResource walks the
    # resource tree, and this was doing it for every ticked conversation on
    # every sort - 200 tree walks behind a click that has 50 ms to answer in.
    $tickOn  = $window.FindResource('TextMax')
    $tickOff = [System.Windows.Media.Brushes]::Transparent
    $cut = (Get-Date).AddDays(-7)
    $cutTicks = $cut.Ticks
    $items = New-Object System.Collections.Generic.List[object]
    $older = 0

    $byProj = @{}
    foreach ($r in $script:model) {
        $k = "$($r.D.path)"
        if (-not $byProj.ContainsKey($k)) { $byProj[$k] = New-Object System.Collections.Generic.List[object] }
        $byProj[$k].Add($r)
    }
    # 🔴 $r.At, NOT [datetime]$r.S.lastActive. Update-Model already parses
    # lastActive ONCE and carries it as ticks for exactly this reason, and this
    # sort re-parsed the string for all 202 conversations on every build - then
    # the window filter below did it again. Measured: Build-Manager 41.5 ms, and
    # the sorts and filters that call it 42-52 ms, over the 50 ms a gesture is
    # allowed. Parsing a date is not the work; doing it twice per row per
    # keystroke is.
    $order = @($byProj.Keys | Sort-Object {
        $newest = 0L
        foreach ($x in $byProj[$_]) { if ($x.At -gt $newest) { $newest = $x.At } }
        - $newest
    })

    foreach ($k in $order) {
        # 🔴 SELECTED HERE, SORTED LATER, AND THE GAP IS THE POINT. This read
        # `Sort-ManagerRows (Select-ManagerRows ...)` - so every project's rows
        # were put in order BEFORE anything asked whether that project is even
        # open. Measured: all-FOLDED (14 visible rows) cost 66.95 ms against
        # all-OPEN (160 rows) at 91.88. Nearly the whole cost of a screen you
        # cannot see. Nothing above the fold check needs the order: the counts,
        # the window filter and the armed tally are all order-independent, and
        # only the child rows are ever displayed in it.
        $kids = @(Select-ManagerRows $byProj[$k])

        # ONE PASS, NOT TWO PIPELINES. These were two Where-Object walks over
        # the same rows - 7.80 ms of the build between them - to answer two
        # questions a single foreach answers at once. Where-Object is a pipeline
        # with a script block per element; a foreach is neither.
        $inWindow = New-Object System.Collections.Generic.List[object]
        $armed = 0
        foreach ($x in $kids) {
            if ([bool]$x.S.enabled) { $armed++ }
            if ($script:showOlder -or $x.At -gt $cutTicks) { $null = $inWindow.Add($x) }
        }
        $older += ($kids.Count - $inWindow.Count)
        if (-not $inWindow.Count) { continue }
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

        # 🔑 AND ONLY NOW DOES ORDER MATTER - for the rows that will actually be
        # drawn, which is fewer than $kids once the window filter has run.
        # 🪤 .ToArray(), NEVER @($list): @() on a List[object] in PS 5.1 throws
        # "Argument types do not match".
        foreach ($r in @(Sort-ManagerRows $inWindow.ToArray())) {
            # 🔴 THE ROW OBJECT IS BUILT ONCE AND REUSED. Sorting and filtering
            # the manager change WHICH rows appear and in what ORDER - they never
            # change what a row says - yet every sort click reconstructed all ~230
            # PSCustomObjects from scratch at about 0.2 ms each, which is where
            # Build-Manager's 55 ms went. Measured: the cost tracked the row count
            # exactly, 'filter manager: needs' at 12 ms against 'all' at 52 ms.
            #
            # 🪤 The cache is dropped whenever the MODEL is rebuilt or a tick is
            # toggled - the only two things that change what a row says. A cache
            # that outlives the truth behind it is worse than no cache, and on
            # this surface it would mean showing a tick that is not set.
            $cached = $script:mgrItems[$r.Id]
            if ($cached) { $items.Add($cached); continue }
            $t = $r.T
            # 🔴 THE SAME FALLBACK THE WORK SURFACE ALREADY HAD, and its absence
            # here is why the manager showed a blank cell for a RUNNING
            # conversation. Measured on this machine: a live session with 158
            # records - 24 user prompts, 44 inter-session messages and ZERO
            # assistant turns. It has genuinely never spoken, so Get-SRLastSaid
            # is right to return nothing; the row was still blank, which reads
            # as the broken column this assertion was written for rather than as
            # a session that has not answered yet. Build-Sessions falls through
            # to Conv.Detail for exactly this case and this path did not.
            $saidText = ''
            if ($r.Said -and "$($r.Said.Said)".Trim()) { $saidText = ("$($r.Said.Said)".Trim() -replace '\s+', ' ') }
            elseif ($r.Conv -and "$($r.Conv.Detail)".Trim()) { $saidText = "$($r.Conv.Detail)".Trim() }
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
                Lane = $r.Lane
                Said = $saidText
                Age  = (Get-AgeTicks $r.At)
                # The tick is a FILLED SQUARE or an empty one - a shape, not a
                # colour, so it survives everything the accents do not.
                TickBg = $(if ([bool]$r.S.enabled) { $tickOn } else { $tickOff })
            })
            $script:mgrItems[$r.Id] = $items[$items.Count - 1]
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

    # 🔴 A FILTERED LIST MUST SAY IT IS FILTERED. This surface decides what comes
    # back at the next logon, and a filter left on silently is a list you will
    # read as complete - the exact way to tick the wrong set with confidence.
    $shown = @($items | Where-Object { $_.Kind -eq 'conv' }).Count
    $total = @($script:model | Where-Object { -not $_.S.gone }).Count
    if ($script:mgrFilter -eq 'all') { $ui.MgrFilterNote.Text = '' }
    else { $ui.MgrFilterNote.Text = ('showing {0} of {1} - the rest are hidden by this filter' -f $shown, $total) }
    # What is on screen now matches what the model says. See Set-Surface.
    $script:mgrDirty = $false
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
    # 🔴 ONE ROW CHANGED, SO ONE ROW IS DROPPED. This cleared the WHOLE cache to
    # change a single brush, which forced the Build-Manager below to rebuild
    # every conversation row from scratch: audited at 141.90 ms for a tick, of
    # which the cold rebuild is 132 against 80 warm. Ticking is the most repeated
    # gesture on this surface - it is how the operator says what reopens - and it
    # was paying for 298 rows that had not changed.
    #
    # 🔒 DROPPING JUST THIS ONE IS SUFFICIENT, and the reason is worth stating:
    # the only OTHER thing a tick changes is the project's "N armed" line, and
    # project rows are not cached at all - Build-Manager builds those fresh on
    # every pass. So there is nothing else stale to catch.
    $script:mgrDirty = $true
    if (-not $Row) { $script:mgrItems = @{}; return }
    $null = $script:mgrItems.Remove("$($Row.Id)")
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
    $script:mgrItems = @{}
    $script:mgrDirty = $true
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

# 🔴 A MENU SEEN ON SCREEN IS AN INPUT TO THE BAND, NOT A CORRECTION AFTER IT.
#
# This is what made a conversation flip between NEEDS YOU and WORKING every few
# seconds. The quiet check reads a session's screen, sees a menu, and used to
# write $r.Band = 'needs' directly - but the band is DERIVED, and every
# recompute (Update-Model, and the live probe's light path) calls Get-Band again
# and overwrote it with whatever the agent probe thought. The probe says
# 'working' for a session sitting on a menu, so the two took turns: screen says
# needs, probe says working, screen says needs. Neither was wrong; the screen's
# answer simply had nowhere durable to live.
#
# So it lives here, keyed by session, and Get-Band consults it. A recompute is
# now idempotent - it reads the same evidence and reaches the same band - and
# the flag is cleared only by EVIDENCE, never by a recompute: the transcript
# growing (that session is working again) or a later screen read finding no
# menu. See Set-AskSeen.
$script:askSeen = @{}

function Set-AskSeen { param([string]$Id, [bool]$Asking)
    if (-not $Id) { return $false }
    $was = [bool]$script:askSeen[$Id]
    if ($was -eq $Asking) { return $false }
    if ($Asking) { $script:askSeen[$Id] = $true } else { $null = $script:askSeen.Remove($Id) }
    return $true
}

function Get-Band { param($Row)
    $cv = $Row.Conv
    if (-not $cv) { return 'quiet' }
    if ($cv.Stuck) { return 'quiet' }
    if ($cv.Needs) { return 'needs' }
    if ($cv.Stale) { return 'quiet' }
    $band = 'quiet'
    switch ("$($cv.State)") {
        'working'     { $band = 'working' }
        'summarising' { $band = 'working' }
        'waiting'     { $band = 'needs' }
        'idle' {
            $sd = $Row.Said
            if ($sd -and -not "$($sd.Pending)".Trim() -and
                "$($sd.Said)".Trim().Length -ge $script:HandbackMinChars) { $band = 'done' }
            else { $band = 'idle' }
        }
    }
    # 🔴 ANY LIVE BAND, NOT JUST 'working' - see the note on Test-QuietVerdict for
    # why this reversed. In short: the one-way rule was containing a parser that
    # could not tell prose from a menu, and the structural test removed that
    # weakness, so the containment was costing ~26 s of notice on the rows most
    # likely to be asking.
    #
    # 🪤 'quiet' IS STILL EXCLUDED, and it is the one exclusion that is about a
    # fact rather than a policy. Get-Band reaches 'quiet' for a conversation that
    # is stuck, stale, or has no process at all - none of which has a screen a
    # menu could have been seen on. A flag surviving on such a row is stale by
    # definition, so it must not decide anything.
    if ($band -ne 'quiet' -and $script:askSeen["$($Row.Id)"]) { return 'needs' }
    return $band
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
# 🪤 Split-Path THROWS ON AN EMPTY STRING - it does not return ''. A
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

# Ticks in, no parse. Get-Age still takes a string for the callers that only
# have one; this is for the two list builders, which have $r.At already.
# 🔑 $Now IS OPTIONAL, AND THE CALLERS IN A LOOP PASS IT. [DateTime]::Now is a
# system call, and this made one PER ROW - 52 per rebuild, 22,3 ms, 11,5% of the
# whole build - so that every row could ask what time it is during a pass that
# cannot last long enough for the answer to change. The list builders hoist one
# reading and hand it down; every other caller is a one-off and omits it.
function Get-AgeTicks { param([long]$Ticks, [long]$Now = 0)
    if ($Ticks -le 0) { return '' }
    if ($Now -le 0) { $Now = [DateTime]::Now.Ticks }
    return (Get-AgeLabel ($Now - $Ticks))
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
    param($Registry, $Agents, [hashtable]$Said, [hashtable]$Queue, [switch]$KeepAgents, [switch]$NoSaid)

    $script:cfg = Get-SRConfig
    if ($Registry) { $script:reg = $Registry } else { $script:reg = Get-SRRegistry }
    $script:dirs = @($script:reg.directories)

    if ($null -ne $Agents) { $script:agents = $Agents }
    elseif ($KeepAgents) {
        # 🔴 THE SECOND IS ALL IN ONE CALL. Measured: the full path is 1,091 ms,
        # the same work with the agent list handed in is 78, and reading the
        # registry off disk is 7 - so a full THOUSAND milliseconds of it is
        # `claude agents --json`, spawned and waited for on the UI thread.
        #
        # Four gestures paid it and every one of them is a gesture somebody is
        # waiting on: opening the window, Rescan, saving settings, and the
        # refresh after a relaunch. None of them needs to: the live probe
        # refreshes that list in the background every fifteen seconds anyway, so
        # these reuse what it last brought back and kick it to correct them.
        # Worst case a row's liveness is a few seconds stale and then right,
        # instead of the window being frozen for a second and then right.
        if ($null -eq $script:agents) { $script:agents = @{} }
    }
    else {
        $a = @{}
        try { $a = Get-SRAgentStatus -Refresh } catch { }
        $script:agents = $a
    }
    # 🪤 $agentMap, NOT $agents. PowerShell is case-insensitive, so a local
    # called $agents IS the $Agents parameter above - the same collision that
    # made 'what it last said' dead for the whole life of the window ($Said vs
    # $said). It happens to be harmless here only because the parameter is read
    # before the local overwrites it; move either line and it breaks silently.
    # Not a bug today, and exactly the shape of one tomorrow.
    $agentMap = $script:agents

    $rows = New-Object System.Collections.Generic.List[object]
    $warmCut = [DateTime]::Now.AddHours(-24).Ticks
    foreach ($d in $script:dirs) {
        if ($d.missing) { continue }
        foreach ($s in @($d.sessions)) {
            if ($s.gone) { continue }
            $id = "$($s.sessionId)".ToLower()
            $a  = $agentMap[$id]
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
            # lastActive is parsed ONCE, here, and carried as ticks. The 6-second
            # pass reads it for every conversation; re-parsing a string 184 times
            # per tick was most of what that pass cost.
            #
            # 🔴 AND THE WARM QUESTION IS ANSWERED ONCE FROM IT. This sat BELOW
            # the two reads that ask it, so both called Test-Warm instead - which
            # re-parses the same date string AND re-reads the clock, twice per
            # row. Measured 2026-09-04: 51 ms of a 274 ms pass to answer a
            # question the next two lines already answer for 0.8 ms.
            #
            # 🪤 It is also STRICTLY more correct this way. Test-Warm calls
            # Get-Date per row, so a pass over 292 conversations compared each
            # against a slightly different cut-off; $warmCut is one instant for
            # the whole pass, which is what "recent" is supposed to mean.
            $at = 0L
            try { $at = ([datetime]$s.lastActive).Ticks } catch { }
            $warm = ($at -gt $warmCut)

            $line = $null
            if ($live -or $warm) {
                # Handed in by the probe when it read them off the background
                # thread; read here only when nobody did it for us.
                # 🪤 ContainsKey, NOT merely "was a table handed in". A table
                # covering most rows but not all blanked the rest outright: the
                # probe and this pass each decide "live or warm" against their
                # own clock a moment apart, so a row can be in one set and not
                # the other, and the column went empty for it instead of being
                # read. Handed in when it is there, read when it is not.
                if ($null -ne $Said -and $Said.ContainsKey($id)) { $line = $Said[$id] }
                elseif (-not $NoSaid) { try { $line = Get-SRLastSaid -JsonlPath $s.jsonl } catch { } }
            }
            # 🔴 HANDED IN, NEVER READ HERE. Unlike the last-said line above there
            # is no fall-back read: Get-SRQueue takes a 4 MB tail and 42.8 ms cold,
            # and doing that for every live conversation on the model pass is the
            # exact mistake the note above records having already made once. No
            # queue from the probe means no badge until the next probe, which is
            # fifteen seconds and costs nothing but a slightly late number.
            #
            # 🪤 $qrec, NOT $queue - PowerShell is case-insensitive and a local
            # called $queue IS the [hashtable]$Queue parameter. Same collision
            # that killed 'what it last said' for the life of the window.
            $qrec = $null
            if ($live -and $null -ne $Queue) { $qrec = $Queue[$id] }
            $rows.Add([PSCustomObject]@{
                Id = $id; S = $s; D = $d; A = $a; Conv = $conv; Said = $line; Live = $live; Band = 'quiet'
                # What this conversation has waiting behind the turn it is on.
                Q = $qrec
                # 🔴 READ HERE, NOT IN Build-Sessions. Build-Sessions runs on
                # every keystroke in either filter box; this pass runs on a
                # timer and already reads every transcript. Putting the row
                # signals here costs the slow pass a little and the responsive
                # one nothing - the opposite arrangement would put a file read
                # per row behind every character typed.
                #
                # 🪤 AND ONLY FOR THE LIVE ONES. Reading all 202 took this pass
                # from 978 ms to 1,578 ms and tripped its own budget, to put a
                # context bar on conversations that finished days ago and whose
                # bar cannot move again. The marks exist to triage what is
                # RUNNING; the other 190 rows are answered by not asking.
                #
                # 🔴 `$live -or (Test-Warm $s)`, NOT `$live` ALONE - the same
                # predicate the last-said read four lines below already uses.
                # Liveness comes from the WMI agent probe, which lags a launch;
                # a conversation relaunched from this window was therefore built
                # with no signals at all and showed a bare row until the probe
                # caught up. Warm means "its transcript moved recently", which a
                # session that just started satisfies immediately.
                Sig = $(if ($live -or $warm) { try { Get-SRRowSignals "$($s.jsonl)" } catch { $null } } else { $null })
                # Filled below, once the project labels exist. See the note there.
                Hay = ''; HayProj = ''
                At = $at; Warm = $warm
                # 🔴 THE TITLE, COMPUTED ONCE PER PASS. It depends only on S and D,
                # neither of which changes between builds, and it was being
                # recomputed for every row by every list build AND by two of the
                # manager's sort keys - which is why 'sort manager: name' and
                # 'sort manager: lane' were the last two gestures over 50 ms.
                # Same reasoning as At above.
                T = (Get-Title $s $d)
                # The lane label too: it is a pure function of the row and its title,
                # and Build-Manager was recomputing it for all 200 rows on every
                # sort click. Same reasoning as T and At.
                Lane = ''
            })
        }
    }
    # Band, and the lane label - both pure functions of a finished row, both
    # wanted by every list build, so both are answered once here rather than
    # per row per keystroke.
    $script:mgrItems = @{}
    # 🔒 THE MODEL CHANGING WHILE THE MANAGER IS HIDDEN is the one case the
    # dirty flag exists for - every other thing that changes that surface
    # rebuilds it on the spot. See Set-Surface.
    $script:mgrDirty = $true
    foreach ($r in $rows) {
        $r.Band = Get-Band $r
        $r.Lane = (Get-LaneLabel $r "$($r.T.Text)")
    }
    $script:model = $rows; $script:modelGen++
    # 🔑 THE INVALIDATION KEY FOR ANYTHING CACHED OFF THE MODEL'S MEMBERSHIP.
    # Explicit rather than a reference-equality check on the list, because a
    # counter is a thing a test can bump and watch: see Get-RailGrouping.
    Update-ProjectLabels

    # 🔴 THE SEARCH HAYSTACK IS BUILT ONCE, HERE. Typing in the header box cost
    # 338 ms per rebuild - over budget for a gesture that happens on a KEYSTROKE
    # - because both builders composed the same string per row: a Get-Title and
    # a Get-ProjectLabel across 191 conversations, twice over. None of the
    # inputs change between rebuilds; they change when the MODEL changes, which
    # is exactly here. Two haystacks, because the two boxes ask different
    # questions - the rail's matches the project only.
    foreach ($r in $rows) {
        # 🪤 $r.T, NOT Get-Title AGAIN. The note above says the title is computed
        # ONCE PER PASS - and then this loop computed it a second time for every
        # row, which is the exact cost that note exists to prevent. It reads the
        # value the loop above already stored.
        $t = "$($r.T.Text)"
        $pl = ''
        if ("$($r.D.path)") { $pl = Get-ProjectLabel "$($r.D.path)" }
        $r.Hay     = ('{0} {1} {2} {3} {4}' -f $t, $r.S.autoTitle, $r.D.path, $r.Id, $pl).ToLower()
        $r.HayProj = ('{0} {1}' -f $pl, $r.D.path).ToLower()
    }
    Update-ShelveSuggestions
}

# ===========================================================================
# WHICH PROJECTS THE RAIL WOULD SUGGEST PUTTING AWAY.
#
# 🔴 COMPUTED HERE, NOT IN Build-Rail, AND OVER THE WHOLE REGISTRY. Two reasons,
# and the second is the important one.
#
# The cheap reason: Build-Rail runs on every keystroke in either search box, and
# this walks all 36 projects and every conversation in them parsing dates. That
# is the exact cost the note beside $r.At records already having paid once.
# Update-Model runs on a timer and already reads far more than this.
#
# 🔑 THE REAL REASON: THE RAIL CANNOT SEE THE PROJECTS THIS IS ABOUT. The work
# surface is live-or-spoke-in-the-last-day - Test-OnSurface, deliberately - so
# every project the rail holds was touched within 24 hours, and a project quiet
# for fourteen DAYS is by definition not on it. A suggestion computed from the
# rail's own contents could never fire even once. So it is computed from the
# registry, which knows about all of them, and the rail reports the COUNT in its
# header; the per-tile mark still exists for the rare project that is on the
# surface only because something in it is selected.
$script:shelveSuggest = @{}
$script:shelveSuggestNames = @()

function Update-ShelveSuggestions {
    $found = @{}
    $names = New-Object System.Collections.Generic.List[string]
    $now = [datetime]::Now
    $agentMap2 = $script:agents
    foreach ($d in $script:dirs) {
        $running = $false
        foreach ($s in @($d.sessions)) {
            if ($agentMap2 -and $agentMap2["$($s.sessionId)".ToLower()]) { $running = $true; break }
        }
        $why = ''
        try { $why = Get-SRShelveSuggestion -Dir $d -Config $script:cfg -AnythingRunning $running -Now $now } catch { $why = '' }
        if ($why) {
            $found["$($d.path)"] = $why
            $names.Add((Get-ProjectLabel "$($d.path)"))
        }
    }
    $script:shelveSuggest = $found
    $script:shelveSuggestNames = $names.ToArray()
}

# What the CONVERSATION surface shows: live, or spoke in the last day. It is not
# a browser for all 215 - that is what the session manager is for.
#
# 🔑 THAT STILL HOLDS FOR CONVERSATIONS, AND NO LONGER HOLDS FOR PROJECTS. When
# this was written the rail asked it too, and the consequence went unnoticed
# until the age bands went in: the rail carried 12 of 36 projects, so three of
# its four bands could never fill and a project quiet long enough to be worth
# shelving could not be right-clicked, because it had no tile. The operator's
# own words for the rail were "click on further-away filtered projects to expand
# all of the projects who are in there, and continue working on them if needed",
# which this gate made impossible.
#
# So Build-Rail no longer calls this - see the note there. The reasoning above
# is unchanged for the two callers that remain, Build-Sessions and Update-Strip,
# and it is why the fix was made rail-local rather than by widening this: a
# sessions column listing all 319 conversations is exactly what this prevents.
# The one place Build-Sessions now lets an older conversation through is when
# the rail is FILTERED to its project, which is the operator asking for it by
# name.
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
    # AND THEN THEY WERE TOO DARK TO READ AS COLOUR. The spread is right - it is
    # why twenty-seven projects are still tellable apart - but at S 0.38-0.58 on
    # a #0F0F11 ground these arrived as grey with a suggestion of hue in it,
    # reported as "the colors for the projects seem a little bit dark". Same
    # twelve hues, same dealt-by-index slot; saturation and lightness raised
    # until they are actually colours. Nothing about the DISTINCTNESS argument
    # above changes - only how much of each hue survives the ground.
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

# ===========================================================================
# THE RAIL'S AGE BANDS - the same shape the sessions column already has.
#
# 🔑 THE SESSIONS LIST SOLVED THIS FIRST. $script:Bands groups conversations by
# STATE and its headings are clickable; this groups projects by AGE and its
# headings fold. The item shape, the heading-click gesture and the rule that
# every heading stays on screen are all copied from there deliberately - two
# lists in one window that group differently but behave differently as well is
# two things to learn instead of one.
#
# 🪤 ROLLING DAYS, NOT CALENDAR WEEKS. "This week" on a Monday morning would
# hold almost nothing under a calendar reading, and the rail would say a project
# touched yesterday is older than one touched an hour ago on the same Monday.
# Everything else in this tool that bounds by time - recencyDays, listDays,
# sessionWindowDays - counts backwards from now for the same reason. TODAY is
# still a real day boundary though, because "today" is the one of the four that
# a person reads as a date rather than as a duration.
$script:RailBands = @(
    @{ Key = 'today'; Label = 'TODAY';      Days = 0  },
    @{ Key = 'week';  Label = 'THIS WEEK';  Days = 7  },
    @{ Key = 'month'; Label = 'THIS MONTH'; Days = 30 },
    # The catch-all. Days is unused on it - nothing falls past the last cut.
    @{ Key = 'older'; Label = 'OLDER';      Days = 0  }
)

# Which bands are folded shut, by key. Read from the config at startup and
# written back through the queue - see Toggle-RailBand.
$script:railBandShut = @{}
try {
    $cfgBands = Get-SRConfig
    foreach ($k in ("$($cfgBands.railBandsShut)" -split ',')) {
        $kk = "$k".Trim().ToLower()
        if ($kk) { $script:railBandShut[$kk] = $true }
    }
} catch { }

# The three cut-off ticks, taken ONCE per build rather than per project. Same
# reasoning as $warmCut in Update-Model: a pass that re-reads the clock for
# every row compares each one against a slightly different "now", which is not
# what any of these four words mean.
function Get-RailBandCuts {
    $midnight = [datetime]::Today
    return @{
        Today = $midnight.Ticks
        Week  = $midnight.AddDays(-7).Ticks
        Month = $midnight.AddDays(-30).Ticks
    }
}

function Get-RailBandKey { param([long]$At, $Cuts)
    if ($At -ge $Cuts.Today) { return 'today' }
    if ($At -ge $Cuts.Week)  { return 'week' }
    if ($At -ge $Cuts.Month) { return 'month' }
    return 'older'
}

# The rail's own ordering and its own filter, independent of the sessions column.
$script:railSort = 'recent'
$script:RailSorts = @(
    # 🪤 SHORT ENOUGH FOR THE FACE THEY ARE DRAWN IN. These sit beside the
    # only-live toggle in a 248px rail, and when the chrome went monospaced at
    # 13px "recent first  ·  all projects" stopped fitting and clipped to
    # "all proje" - a control cut off mid-word. The words carry the same meaning
    # with fewer characters; the alternative was a size step, which is the thing
    # that was just removed on purpose.
    @{ Key = 'recent';  Label = 'recent' },
    @{ Key = 'name';    Label = 'name' },
    @{ Key = 'waiting'; Label = 'waiting' },
    @{ Key = 'busiest'; Label = 'busiest' }
)
$script:railOnlyLive = $false
# Projects put away, and whether the rail is currently showing them anyway. The
# COUNT is recomputed by every build; the toggle is a view state and deliberately
# not remembered - "show me the shelved ones" is something you do for a minute,
# and a rail that came back showing them would have un-shelved them in effect.
$script:railShowShelved = $false
$script:railShelved = 0

# ===========================================================================
# THE PER-PROJECT GROUPING, COMPUTED ONCE PER MODEL RATHER THAN PER REBUILD.
#
# 🔴 MEASURED: THE WALK IS THE COST, NOT THE SORT. Profiled over the operator's
# 322 conversations - grouping walk 19.95 ms, and the default 'recent' sort
# 1.46 ms. The walk is ~8 PowerShell operations a row with no hotspot: walking
# the rows and reading one property is 0.54 ms, and the tightest hand-optimised
# version of the loop still cost 16.92 ms. There is no cheap win inside it.
#
# 🪤 AND THE OBVIOUS FIX WAS THE WRONG ONE. Sort-ManagerRows records a real
# measurement of a scriptblock sort key - 24.28 ms against 3.15 ms for a plain
# -Property sort - and it looked like this sort's twin. It is not: THAT sorts 319
# ROWS and this sorts 36 KEYS, and at 36 the keyed-list construction costs about
# what the scriptblock overhead saves. Measured here: 'recent' 1.46 -> 2.62 ms
# and 'busiest' 12.58 -> 15.34 ms, i.e. WORSE in three modes of four. A cited
# measurement's SCALE is part of the measurement; quoting it correctly is not
# enough. Do not re-try the keyed sort here without re-measuring the count.
#
# 🔑 SO THE LEVER IS NOT REPEATING WORK WHOSE INPUTS HAVE NOT CHANGED. This is
# NOT the same as moving the cost onto Update-Model: that pass already pays this
# walk and still does. What stops paying is every OTHER rebuild - folding a band,
# stepping the sort, picking a project, each debounced keystroke - which is where
# the operator actually feels it.
#
# 🔴 EVERY INPUT IS IN THE KEY, and they were enumerated rather than assumed.
# The grouping reads exactly three things: which rows are in the model, and the
# two search strings. It reads $r.D.path, $r.At, $r.Hay and $r.HayProj, and all
# four are written once in Update-Model and never touched again.
#
# 🪤 IT DELIBERATELY DOES NOT DEPEND ON .Live OR .Band, and that is the part that
# would have bitten. The light probe branch of the collector mutates $r.A,
# $r.Live, $r.Conv, $r.Said, $r.Q and $r.Band IN PLACE on the existing rows
# WITHOUT replacing the model - so a cache keyed on the model alone would be
# stale for anything reading those. This one is safe because it stores ROW
# REFERENCES: the counts on a tile are recomputed from those rows on every build,
# so a band that changed under the cache is still read fresh. What is cached is
# only which project a row belongs to and when that project was last touched -
# neither of which the probe can change without a new model.
$script:railGroupKey = ''
$script:railGroupBy = $null
$script:railGroupNewest = $null

function Get-RailGrouping { param([string]$Q, [string]$QR)
    $key = '{0}|{1}|{2}' -f $script:modelGen, $Q, $QR
    if ($key -eq $script:railGroupKey -and $null -ne $script:railGroupBy) {
        return @{ ByProj = $script:railGroupBy; Newest = $script:railGroupNewest }
    }
    $byProj = @{}
    $newest = @{}
    foreach ($r in $script:model) {
        if ($Q -and "$($r.Hay)" -notlike "*$Q*") { continue }
        if ($QR -and "$($r.HayProj)" -notlike "*$QR*") { continue }
        $k = "$($r.D.path)"
        $lst = $byProj[$k]
        if ($null -eq $lst) { $lst = New-Object System.Collections.Generic.List[object]; $byProj[$k] = $lst }
        $lst.Add($r)
        $n = $newest[$k]
        if ($null -eq $n -or [long]$r.At -gt [long]$n) { $newest[$k] = [long]$r.At }
    }
    $script:railGroupKey = $key
    $script:railGroupBy = $byProj
    $script:railGroupNewest = $newest
    return @{ ByProj = $byProj; Newest = $newest }
}

function Build-Rail {
    # 🔴 TWO SEARCHES, AND THEY ARE NOT THE SAME QUESTION. The header box is
    # GLOBAL and narrows both panes at once; this pane's own box narrows only
    # the projects. Being able to hold "AlgoTrader" in one and "KERNEL" in the
    # other is the whole reason for having both, and is what "I am still missing
    # the search in the work surface projects and sessions" meant after the
    # global box already reached here.
    $q = "$($ui.Search.Text)".Trim().ToLower()
    $qr = "$($ui.RailSearch.Text)".Trim().ToLower()
    # 🔴 THE RAIL CARRIES EVERY PROJECT, AND DELIBERATELY DOES NOT ASK
    # Test-OnSurface. That gate is live-or-spoke-in-the-last-day, and against it
    # this rail held 12 of 36 projects - so three of the four age bands could
    # never fill, and a project quiet long enough to be worth shelving was by
    # definition not a tile you could right-click. What the operator asked for
    # was the opposite: "filter for only the most latest used projects, and if
    # necessary click on further-away filtered projects to expand all of the
    # projects who are in there, and continue working on them if needed".
    #
    # 🪤 RAIL-LOCAL, NOT A CHANGE TO THE GATE. Test-OnSurface has two other
    # callers - Build-Sessions and Update-Strip - and widening it there would
    # turn the sessions column into a browser for all 322 conversations, which
    # is what the note beside it exists to prevent.
    #
    # The walk itself now lives in Get-RailGrouping, which does it once per
    # model rather than once per rebuild - see the measurements there.
    $grp = Get-RailGrouping -Q $q -QR $qr
    $byProj = $grp.ByProj
    $newest = $grp.Newest
    # 🔴 THE RAIL ORDERS ITSELF. 'recent' is the default and was the only
    # one; the others exist because at 29 projects "which has something waiting"
    # and "which is busiest" are different questions from "which did I touch
    # last", and only the first was answerable.
    $order = @($byProj.Keys | Sort-Object {
        $k2 = $_
        $kids2 = $byProj[$k2]
        switch ($script:railSort) {
            'name'    { (Get-ProjectLabel $k2).ToLower() }
            'waiting' { - @($kids2 | Where-Object { "$($_.Band)" -eq 'needs' }).Count }
            'busiest' { - @($kids2 | Where-Object { $_.Live }).Count }
            default   { - [long]$newest[$k2] }
        }
    })
    if ($script:railOnlyLive) {
        # A project with nothing running is not somewhere you are going to look
        # next, which is the only thing this rail is for.
        $order = @($order | Where-Object { @($byProj[$_] | Where-Object { $_.Live }).Count -gt 0 })
    }
    # 🔴 PUT AWAY, AND SAID SO. A shelved project leaves the rail - that is the
    # whole gesture - but the number of them is COUNTED whether or not they are
    # being shown, because a list that silently omits things is a list whose
    # length you cannot trust. The header says how many, and clicking it brings
    # them back; see Update-RailShelved.
    #
    # 🪤 $byProj[$k][0].D IS THE REGISTRY'S OWN DIRECTORY OBJECT, not a copy -
    # Update-Model files the entry itself on every row it builds. That is what
    # makes Set-ProjectShelved's write reach the registry, and it is also why the
    # question is asked off a row rather than by looking the path up again.
    $shelvedPaths = @{}
    foreach ($k in $order) {
        if (Test-SRProjectShelved $byProj[$k][0].D) { $shelvedPaths[$k] = $true }
    }
    $script:railShelved = $shelvedPaths.Count
    if (-not $script:railShowShelved -and $script:railShelved) {
        $order = @($order | Where-Object { -not $shelvedPaths[$_] })
    }
    $items = New-Object System.Collections.Generic.List[object]
    # THE BANDS, IN ORDER, EACH HOLDING WHATEVER THE CHOSEN SORT PUT IN IT.
    # Grouping happens OUTSIDE the sort exactly as it does in the sessions column:
    # the band is the ordering that matters and the sort decides the order WITHIN
    # one, so switching to 'name' still cannot bury today's work under a project
    # untouched since July.
    $cuts = Get-RailBandCuts
    $inBand = @{}
    foreach ($k in $order) {
        $bk = Get-RailBandKey -At ([long]$newest[$k]) -Cuts $cuts
        if (-not $inBand.ContainsKey($bk)) { $inBand[$bk] = New-Object System.Collections.Generic.List[object] }
        $inBand[$bk].Add($k)
    }
    # 🪤 EVERY BINDING IN THE TEMPLATE MUST RESOLVE ON BOTH SHAPES. A heading and
    # a tile go through one DataTemplate, and a binding to a property that is not
    # on the object is a SILENT trace error and an empty cell - the same trap the
    # sessions list records beside its own heading item. So each shape carries
    # the other's properties, named and switched off, rather than omitting them.
    $blank = [System.Windows.Media.Brush][System.Windows.Media.Brushes]::Transparent
    foreach ($b in $script:RailBands) {
        if (-not $inBand.ContainsKey($b.Key)) { continue }
        $paths = $inBand[$b.Key]
        $shut = [bool]$script:railBandShut["$($b.Key)"]
        $items.Add([PSCustomObject]@{
            Kind = 'band'; BandKey = "$($b.Key)"
            BandVis = $V_Show; RowVis = $V_Hide
            BandLabel = $b.Label; BandCount = $paths.Count
            BandCaret = [string][char]$(if ($shut) { 0x25B8 } else { 0x25BE })
            # The tile half of the template, off.
            Path = ''; Label = ''; Count = 0; State = ''; Tip = $null
            Accent = $blank; AccentOpacity = 0.0; NeedsVis = $V_Hide
            PickBg = $blank; PickEdge = $blank; Fg = $blank
        })
        foreach ($k in $paths) {
            $picked = ($script:railPick -eq $k)
            # 🔴 A FOLDED BAND NEVER HIDES THE PROJECT YOU ARE FILTERED TO. The
            # pick keeps narrowing the sessions column whether or not its tile is
            # on screen, so folding the band it lives in would leave the list
            # showing one project's conversations with nothing anywhere saying
            # which - and the only way back a control (RailClear) that is easy to
            # read as "clear the search". Same principle as Test-OnSurface
            # pinning whatever is selected onto the work surface.
            if ($shut -and -not $picked) { continue }
            $kids = $byProj[$k]
            $items.Add((New-RailTile -Path $k -Kids $kids -Picked $picked -Blank $blank `
                            -Suggest "$($script:shelveSuggest[$k])"))
        }
    }
    $ui.RailList.ItemsSource = $items
    $ui.RailClear.Visibility = $(if ($script:railPick) { $V_Show } else { $V_Hide })
    Update-RailShelved
    Update-RailSuggest
}

# WHAT COULD BE SHELVED, said once for the whole registry.
#
# 🪤 IT COUNTS PROJECTS THE RAIL CANNOT SHOW, and that is the point rather
# than a bug: see the note on Update-ShelveSuggestions. A count that only ever
# reported the tiles on screen would be permanently zero, because a tile on
# screen was touched today and a suggestion needs a fortnight of silence.
# Absent when there is nothing to suggest - the rail is 248px wide and a line
# saying 'nothing to put away' is a line spent on the usual case.
function Update-RailSuggest {
    if (-not $ui.RailSuggest) { return }
    $n = @($script:shelveSuggestNames).Count
    if (-not $n) { $ui.RailSuggest.Visibility = $V_Hide; return }
    $ui.RailSuggest.Visibility = $V_Show
    $ui.RailSuggest.Text = ('{0} quiet project(s) could be shelved' -f $n)
    # Named in the tooltip, because the rail has nowhere to draw them: the
    # operator finds them in the session manager, or waits for one to surface.
    $some = @($script:shelveSuggestNames | Sort-Object | Select-Object -First 12)
    $ui.RailSuggest.ToolTip = ((($some -join "`n") +
        $(if ($n -gt $some.Count) { "`n...and $($n - $some.Count) more" } else { '' })) +
        "`n`nNothing is shelved for you. Right-click a project to shelve it.")
}

# HOW MANY PROJECTS ARE SHELVED, and the way back to them. Absent entirely when
# there are none: a control that says "0 shelved" is chrome explaining a state
# nobody is in, on a 248px rail that already carries two other toggles.
function Update-RailShelved {
    if (-not $ui.RailShelved) { return }
    if (-not $script:railShelved) { $ui.RailShelved.Visibility = $V_Hide; return }
    $ui.RailShelved.Visibility = $V_Show
    $ui.RailShelved.Text = $(if ($script:railShowShelved) {
        ('{0} shelved, shown' -f $script:railShelved)
    } else { ('{0} shelved' -f $script:railShelved) })
    $ui.RailShelved.Foreground = $window.FindResource($(if ($script:railShowShelved) { 'TextMax' } else { 'TextLow' }))
    $ui.RailShelved.ToolTip = $(if ($script:railShowShelved) {
        'Shelved projects are on the rail. Click to put them away again.'
    } else {
        ('{0} project(s) are shelved: off this rail, and not restored at logon. Click to see them.' -f $script:railShelved)
    })
}

# One project's tile. Lifted out of Build-Rail unchanged when the age bands went
# in: the loop that emits it now has a band loop around it, and a tile built
# three indents deep inside two loops is a tile nobody can read.
function New-RailTile { param([string]$Path, $Kids, [bool]$Picked, $Blank, [string]$Suggest = '')
    # WHAT IS HAPPENING IN THERE, not just how many are in there. A count of
    # 13 is the same number whether every one of them is asleep or one is
    # waiting on you, and the whole point of the rail is choosing where to
    # look next. The tile says the two things that decide that.
    $needs = 0; $working = 0
    foreach ($r in $Kids) {
        if ("$($r.Band)" -eq 'needs') { $needs++ }
        # 🔴 THE BAND, NOT .Live - THE TILE WAS COUNTING RUNNING AND SAYING
        # WORKING.
        #
        # This read `elseif ($r.Live)`, so the number beside the word "working"
        # was every session with a live agent entry that was not waiting on the
        # operator - which sweeps in every session sitting at its prompt with
        # nothing pending. Reported and then reproduced exactly from the same
        # inputs the window uses: AlgoTrader drew "19 working" against 7 busy,
        # and MM-toolbox drew "2 working" against 1.
        #
        # 🪤 $r.Band ALREADY HOLDS THE ANSWER AND THE TILE NEVER READ IT.
        # Get-Band maps the agent status: busy -> working, idle -> idle/done,
        # waiting/blocked -> needs. The correct predicate is used twice more in
        # this same file - Update-Strip filters on `Band -eq $band` over
        # @('needs','working'), and Start-QuietCheck tests
        # `-not $r.Live -or $r.Band -ne 'working'`. So the collapsed strip and
        # the rail tile disagreed about the same word, in the same window.
        #
        # 🪤 THE HEADER IS NOT WRONG AND IS NOT CHANGED. It prints '{0} live of
        # {1}' off this same .Live set and calls it LIVE, which is what it is.
        # The defect was never the set; it was the label on it.
        #
        # Corroborated independently of the agent status, by transcript tail age
        # read in the same instant so staleness cannot explain the split:
        # busy n=7 median 16 s, idle n=22 median 1.999 s, and six sessions
        # counted as "working" had last written 11,3 hours earlier.
        elseif ("$($r.Band)" -eq 'working') { $working++ }
    }
    $bits = New-Object System.Collections.Generic.List[string]
    if ($needs)   { $bits.Add("$needs waiting") }
    if ($working) { $bits.Add("$working working") }
    # 🪤 $Kids.Count, NOT @($Kids).Count. Kids is a List[object] and @() over
    # one THROWS on PS 5.1 - "Argument types do not match" from inside a
    # PSCustomObject literal, which names neither the list nor the wrap. The
    # list answers .Count itself. [[feedback-array-wrap-trap]]
    if (-not $bits.Count) { $bits.Add("$($Kids.Count) idle") }
    # 🪤 [char], NOT A LITERAL '·'. The test harness writes a combined script
    # and runs it, and a non-ASCII byte in a STRING LITERAL does not survive
    # that round trip - it arrived as 'Ã‚Â·' and took the whole file's parse
    # down with it. The same character in a COMMENT is harmless, which is why
    # the emoji markers throughout this file are fine and this was not. The
    # rest of the window already follows this convention (see Caret above).
    $dot = ' ' + [string][char]0x00B7 + ' '
    # 🔴 A SUGGESTION IS A SENTENCE ON THE TILE, NOT A BADGE. It is advice about
    # something that is nobody's emergency, so it goes in the line that already
    # says what is happening in there rather than earning a mark of its own -
    # the rail's marks are for what is WAITING, and spending one here would
    # teach the eye to ignore them. Nothing about it hides anything: the only
    # write is behind the right-click and its confirm sheet.
    $state = ($bits -join $dot)
    if ($Suggest) { $state = $state + $dot + 'could be shelved' }
    return [PSCustomObject]@{
        Kind   = 'project'
        BandVis = $V_Hide; RowVis = $V_Show
        BandKey = ''; BandLabel = ''; BandCount = 0; BandCaret = ''
        Path   = $Path
        Label  = (Get-ProjectLabel $Path)
        Count  = $Kids.Count
        State  = $state
        Tip    = $(if ($Suggest) { 'Right-click to shelve it: ' + $Suggest } else { $null })
        # 🔴 THE CAST, AGAIN. A brush handed back from a PowerShell
        # function arrives PSObject-WRAPPED, and WPF cannot convert that to a
        # Brush: the binding fails SILENTLY, Background stays null, and the
        # mark draws as nothing. Identical to the PSObject-wrapped FontFamily
        # that killed the typeface - and just as invisible, because a missing
        # brush looks exactly like a design choice. The suite now measures
        # the mark on screen rather than trusting the colour behind it.
        Accent = [System.Windows.Media.Brush](Get-ProjectAccent $Path)
        # The accent bar is always drawn; it just goes nearly transparent
        # when the project has nothing live, so a busy project's identity is
        # what catches the eye rather than every project shouting at once.
        AccentOpacity = $(if ($needs) { 1.0 } elseif ($working) { 0.85 } else { 0.35 })
        NeedsVis = $(if ($needs) { $V_Show } else { $V_Hide })
        PickBg = [System.Windows.Media.Brush]$(if ($Picked) { $window.FindResource('SelBg') } else { $Blank })
        PickEdge = [System.Windows.Media.Brush]$(if ($Picked) { $window.FindResource('EdgeLit') } else { $Blank })
        Fg     = [System.Windows.Media.Brush]$(if ($Picked) { $window.FindResource('TextMax') } else { $window.FindResource('TextHigh') })
    }
}

# 🪤 THE HEADING IS THE ONLY WAY BACK TO WHAT IT FOLDED, so it is never itself
# folded away and the count beside it is what makes folding safe to do: a shut
# band still says how many projects are behind it. Queued rather than written on
# the click - see Invoke-ColumnFold, which had the synchronous write taken off
# it for costing 23.8 ms on the gesture that set it.
function Toggle-RailBand { param([string]$Key)
    $k = "$Key".ToLower()
    if (-not $k) { return }
    if ($script:railBandShut[$k]) { $null = $script:railBandShut.Remove($k) }
    else { $script:railBandShut[$k] = $true }
    $shut = @($script:RailBands | Where-Object { $script:railBandShut["$($_.Key)"] } | ForEach-Object { "$($_.Key)" })
    try { Save-SRConfigLater -Name 'railBandsShut' -Value ($shut -join ',') } catch { }
    Request-SRConfigFlush
    Build-Rail
}

# ===========================================================================
# SHELVING A PROJECT - putting it away without losing anything.
#
# 🔴 THE REGISTRY, NOT THE CONFIG. Everything else about a project already lives
# on its `directories` entry - path, enabled, firstSeen, missing, sessions - and
# a second home for a sixth fact about the same thing is how the two drift.
#
# 🪤 AND THE WRITE CAN FAIL. Save-SRRegistry has a staleness check and now throws
# when the file cannot be replaced, so this cannot set the flag and assume it
# stuck: another Sessions window, or the hourly scan, may have written since this
# one read. Save-RegistryOrAsk puts that to the operator - and if they decline,
# THE FLAG IS PUT BACK. A rail that showed a project as shelved while the file on
# disk still said otherwise would come back with it visible at the next restart
# and no explanation, which is worse than the gesture simply not taking.
function Set-ProjectShelved { param($Dir, [bool]$Shelved)
    if (-not $Dir) { return $false }
    $was = [bool]$Dir.shelved
    if ($was -eq $Shelved) { return $true }
    Set-Field $Dir 'shelved' $Shelved
    $script:dirty = $true
    if (-not (Save-RegistryOrAsk $(if ($Shelved) { 'shelving that project' } else { 'putting that project back' }))) {
        Set-Field $Dir 'shelved' $was
        Build-Rail
        return $false
    }
    return $true
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
        # 🔴 THE ROW ALREADY CARRIES THIS AS TICKS. This parsed
        # $_.S.lastActive - a DATE STRING - once per row, inside a Sort-Object
        # scriptblock, and Build-Sessions calls this five times, once per band.
        # Measured 35,5 ms per rebuild - 18,3% of the whole build - for a value
        # Update-Model already computed and stored on the row as $r.At.
        #
        # 🪤 IT IS AN EQUIVALENT SORT, NOT A SIMILAR ONE. $r.At is the ticks of
        # that same lastActive, and a row whose date would not parse gets At = 0,
        # which sorts last descending exactly as [datetime]0 did. The try/catch
        # goes because reading a long cannot throw.
        default   { return @($Rows | Sort-Object -Property At -Descending) }
    }
}

function Build-Sessions {
    $q  = "$($ui.Search.Text)".Trim().ToLower()
    $ql = "$($ui.ListSearch.Text)".Trim().ToLower()

    $keep = New-Object System.Collections.Generic.List[object]
    # 🔴 FILTERING TO A PROJECT SHOWS THAT PROJECT, ALL OF IT. The rail now
    # carries every project rather than only the last day's, so clicking a tile
    # in THIS MONTH or OLDER was the first gesture that could land on a project
    # with nothing on the surface at all - and the sessions column answered it
    # with an empty list. "Expand the further-away projects and continue working
    # on them" cannot mean an empty list.
    #
    # 🪤 ONE RULE, NOT A SPECIAL CASE FOR OLD ONES. Keeping the 24-hour cut for
    # recent projects and lifting it only for old ones would mean a filter that
    # shows you everything or some of it depending on a date you cannot see.
    # A pick is the operator naming a project; the answer is its conversations.
    # Nothing is widened while no project is picked, which is the ordinary case.
    $pick = "$($script:railPick)"
    foreach ($r in $script:model) {
        if ($pick) {
            if ("$($r.D.path)" -ne $pick) { continue }
        # 🔴 INLINED, AND IT IS THE CALL THAT COSTS, NOT THE TEST.
        # This ran Test-OnSurface for all 327 conversations to keep 52, and
        # measured 34,7 ms of a 194 ms Build-Sessions - 17,9%, the second largest
        # item in the rebuild that sits behind almost every slow gesture in the
        # window: every search keystroke, every sort, every project pick, every
        # band click, and the live lane's own tick. Nearly all of it is per-call
        # overhead; the body it reaches is three property reads.
        #
        # 🪤 THIS IS EXACTLY Test-OnSurface FOR A MODEL ROW, NOT AN APPROXIMATION
        # OF IT. Update-Model writes `Warm = $warm` on every row it builds, so
        # `$null -ne $R.Warm` is always true here and the function can only take
        # its first branch - Live, else Warm, else the pinned selection.
        # Test-Warm's date re-parse is unreachable from this loop. The function
        # stays for the callers that hold a bare session object.
        #
        # 🔴 AND IT IS NOT CACHED - deliberately, not by omission. It reads
        # $r.Live, which the probe mutates IN PLACE without replacing the model,
        # and $script:selId, which changes on every click. Its invalidation rate
        # is near-continuous, so a cache would rebuild constantly and cost more
        # than it saves. Same reason it is not merged with the rail's grouping
        # walk: merging drags the stable cache down to the volatile one's rate.
        } elseif (-not ($r.Live -or $r.Warm -or ($script:selId -and $r.Id -eq $script:selId))) { continue }
        # 🔴 ONCE PER ROW, NOT THREE TIMES. Get-Title was called for the global
        # search, again for this pane's search, and a third time when the item
        # was built - up to 573 calls over 191 conversations on a pass that runs
        # every six seconds. It depends only on S and D, neither of which
        # changes inside this loop.
        # Both haystacks were composed once in Update-Model - see the note there.
        if ($q -and "$($r.Hay)" -notlike "*$q*") { continue }
        if ($ql) {
            $t = (Get-Title $r.S $r.D).Text
            # This pane's own box. Deliberately does NOT match the project path:
            # narrowing projects is the other pane's job, and matching both here
            # would make typing a project name in the sessions box silently do
            # what the rail box does.
            if (('{0} {1}' -f $t, $r.S.autoTitle).ToLower() -notlike "*$ql*") { continue }
        }
        $keep.Add($r)
    }

    # 🪤 RESOLVED ONCE, NOT PER ROW. FindResource walks the resource dictionary,
    # and these two are constants - the same reasoning as Get-Title and the
    # haystack in Update-Model. Cheap individually and pointless 300 times.
    # 🔑 ONE CLOCK PER REBUILD, NOT ONE PER ROW. Both of these were system calls
    # made inside the row loop - [DateTime]::Now for the age label and Get-Date
    # for the screen-signature TTL - and a rebuild cannot last long enough for
    # either answer to change. Together they were 36,8 ms of a 194 ms build.
    # Same reasoning as the two brushes resolved just below.
    $nowTicks = [DateTime]::Now.Ticks
    $nowDate  = Get-Date
    $qGrey  = [System.Windows.Media.Brush]$window.FindResource('TextLow')
    $qAmber = [System.Windows.Media.Brush]$window.FindResource('HueOut')

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
            # A heading is not a session, but it goes through the same template,
            # and a binding to a property that is not there is a silent error in
            # the trace and an empty cell on screen. Named, so it is off.
            CtxVis = $V_Hide; CtxWidth = 0.0; AgentVis = $V_Hide; AgentText = ''
            ShellVis = $V_Hide; ShellText = ''
            QVis = $V_Hide; QText = ''; QTip = ''; QBrush = $qGrey
            SubVis = $V_Hide; SubName = ''; SubDesc = ''; SubTag = ''; SubAge = ''
            SubOpacity = 1.0; SubTip = ''
            CtxBrush = [System.Windows.Media.Brush][System.Windows.Media.Brushes]::Transparent
        })
        # 🔴 THE HEADINGS ALL STAY WHEN ONE IS PICKED. Hiding the others
        # would leave no way back except a control that is now off screen, and
        # the counts beside them are the reason to switch in the first place.
        if ($script:bandPick -and $script:bandPick -ne $b.Key) { continue }
        foreach ($r in $inBand) {
            $t = $r.T
            $saidText = ''
            if ($r.Said -and "$($r.Said.Said)".Trim()) { $saidText = ("$($r.Said.Said)".Trim() -replace '\s+', ' ') }
            elseif ($r.Conv -and "$($r.Conv.Detail)") { $saidText = "$($r.Conv.Detail)" }
            # What this conversation has out, from the two readers that can each
            # answer half of it. See the note beside the marks below.
            # 🔑 INLINED, for the reason WO-2 proved and WO-4/7 disproved:
            # what costs here is the invocation, not the work. With $nowDate
            # hoisted this function is a dictionary read and a TTL compare, and
            # it still measured 13,3 ms per rebuild over 52 calls. The function
            # stays - four other callers hold a bare id and are not in a loop.
            #
            # 🪤 THE TTL IS THE POINT AND MUST NOT BE DROPPED. A count read four
            # minutes ago describes a session that has since done anything at
            # all; past its life it is not evidence and must not draw. Kept
            # identical to Get-RowScreenSig, and gui2 asserts they agree.
            $scr = $null
            $scrV = $script:rowScreen["$($r.Id)"]
            if ($scrV -and ($nowDate - $scrV.At).TotalSeconds -le $SR_RowScreenTTL) { $scr = $scrV }
            $rowShells = $(if ($scr) { [int]$scr.Shells } else { 0 })
            # 🔴 ACTIVE, ON EVIDENCE - NOT "A TASK ID THE TAIL NEVER SAW
            # ANSWERED". The count came from $r.Sig.Agents, which is an open
            # `Task` tool_use with no tool_result quoting it back in the read
            # window. That is a fine way to spot an agent going out and a
            # terrible way to know one is still there: once the answering
            # result scrolls past the end of the tail, the call looks open
            # FOREVER and the row claims an agent that finished hours ago.
            # Reported on F2-SPINE, which showed a sub-agent with none running.
            #
            # A sub-agent has no process to ask about, so the evidence is its
            # own transcript still being written - see $SR_SubAgentLiveSecs.
            # The session's own status line still outranks that when it
            # actually named a number, because that is first-party and live.
            #
            # 🪤 `-ge 0` IS HOW THIS CACHE SAYS "THE SCREEN NAMED A NUMBER" -
            # Set-RowScreenSig files -1 for "the status line did not say" and
            # carries no SawAgents flag of its own. Testing a flag that is not
            # on the object made every screen-supplied count fall through to the
            # fallback, and the suite caught it: a staged session with a shell
            # AND a sub-agent drew neither mark.
            $subsAll = @(Get-RowSubAgents $r)
            $subsLive = @($subsAll | Where-Object { $_.Live })
            $rowAgents = $subsLive.Count
            if ($scr -and [int]$scr.Agents -ge 0) { $rowAgents = [int]$scr.Agents }
            # The context, from the session's own bar where we have it. The
            # transcript reader has to INFER the window from the token count, so
            # a 1M conversation under 200k was drawn against the wrong scale -
            # and after a compact its count is stale until the next reply.
            # The bar the session prints, or no bar at all - see the note in
            # Update-Chips. An inferred window drew the wrong scale for every 1M
            # conversation until it passed 200k.
            $rowTok = 0; $rowWin = 0
            if ($scr -and [int]$scr.CtxWindow -gt 0) { $rowTok = [int]$scr.CtxTokens; $rowWin = [int]$scr.CtxWindow }
            $rowFrac = $(if ($rowWin -gt 0) { [double]$rowTok / [double]$rowWin } else { 0.0 })

            # 🔴 WHAT IS QUEUED BEHIND IT. Read off the transcript's own
            # queue-operation records by the background probe - see Get-SRQueue.
            #
            # 🪤 THE COUNT IS YOURS WHEN YOU HAVE ANY, and only falls back to the
            # total when you have none. A row showing "14" that turns out to be
            # fourteen cross-session messages teaches you to ignore the mark; a
            # row showing "2" when two of your own are waiting is the only number
            # worth interrupting yourself for. Both are in the tooltip, so the
            # machine traffic is available without being shouted.
            $qRec = $r.Q
            $qVis = $V_Hide; $qTxt = ''; $qTip = ''
            $qBrush = $qGrey
            # 🔴 AND ONLY IF THE CONVERSATION HAS DONE ANYTHING RECENTLY.
            # The records say what they say, but Claude Code does not always
            # write the one that CANCELS an enqueue - see $SR_QueueStaleHours.
            # Four of the six marks on this machine were orphans between 2,9 and
            # 136,8 hours old, one of them on a session that had not written a
            # record in five and a half days. A mark that says work is waiting
            # when nothing is waiting is worse than no mark: it is the reason
            # the strip stops being believed.
            #
            # 🪤 MinValue MEANS "COULD NOT TELL" AND STILL DRAWS. The staleness
            # test only ever HIDES something, so it must fire on positive
            # evidence of age and never on the absence of evidence.
            # 🔴 THE AGE THAT MATTERS IS THE MESSAGE'S, NOT THE FILE'S - AND
            # THE FIRST VERSION OF THIS GATE MEASURED THE FILE. It tested
            # $qRec.LastWrite, the transcript's own LastWriteTime, so it could
            # only ever fire on a session that had stopped writing. A LIVE
            # session writes constantly, which means the gate was structurally
            # incapable of firing on precisely the conversations that show a
            # phantom mark. Reported with a screenshot an hour after the fix
            # shipped: "1 OF YOURS WAITING - OLDEST HAS WAITED 1H", on a message
            # that had long since been read.
            #
            # 🪤 ANY ITEM STILL YOUNG KEEPS THE WHOLE MARK, and the counts are
            # left alone. $qRec.Items is what the panel dates, and there is no
            # guarantee it holds every item the count covers - so it is used to
            # answer "is anything here still current?" and never to re-derive a
            # number, which is how a conservative gate stays conservative.
            #
            # 🪤 NO DATE ANYWHERE MEANS "COULD NOT TELL" AND STILL DRAWS. The
            # test only ever HIDES something, so it must fire on positive
            # evidence of age and never on the absence of evidence.
            # 🔴 INLINED, AND THE MEASUREMENT IS WHY. This was a call to
            # Test-SRQueueFresh for exactly one hour - extracted so the suite
            # could see it, which was right, and then left in the one loop that
            # runs per row, which was not. Measured directly at high repetition
            # rather than by subtraction: 0,096 ms a call, 12,1 ms across 126
            # rows - of which 8,6 ms is the INVOCATION, because an empty
            # PowerShell function call measures 0,068 ms. 71% of the cost is the
            # act of calling it.
            #
            # 🔑 THE SAME RESULT THIS FILE ALREADY RECORDED, twice: Test-OnSurface
            # was inlined here for it ("nearly all of it is per-call overhead;
            # the body it reaches is three property reads"), and WO-2 proved that
            # removing an invocation moved 35 ms while removing the work inside
            # three others moved nothing. Measured a third time, independently.
            #
            # 🪤 THE FUNCTION STAYS AND IS NOT A DEAD COPY. It is what the panel
            # above the composer calls - once per redraw, where 0,096 ms is
            # nothing - and what gui2 tests. This is the per-row copy, exactly
            # the arrangement Get-RowScreenSig has a few lines above, and gui2
            # asserts the two agree on every row so they cannot drift apart.
            $qFresh = $true
            if ($qRec) {
                $qDated = 0
                $qYoung = 0
                foreach ($qi in @($qRec.Items)) {
                    if (-not $qi.At) { continue }
                    $qAt = $null
                    try { $qAt = [datetime]$qi.At } catch { continue }
                    $qDated++
                    $qLim = $SR_QueueStaleHours
                    if (-not $qi.Mine) { $qLim = $SR_QueueMachineStaleMins / 60.0 }
                    if (($nowDate - $qAt).TotalHours -le $qLim) { $qYoung++ }
                }
                if ($qDated -gt 0) { $qFresh = ($qYoung -gt 0) }
            }
            if ($qRec -and [int]$qRec.Count -gt 0 -and $qFresh) {
                $qVis = $V_Show
                if ([int]$qRec.Mine -gt 0) {
                    $qTxt = "$([int]$qRec.Mine)"
                    $qBrush = $qAmber
                    $qTip = ('{0} message(s) of yours waiting to be read' -f [int]$qRec.Mine)
                    if ([int]$qRec.Machine -gt 0) {
                        $qTip = $qTip + (', behind {0} from the machine' -f [int]$qRec.Machine)
                    }
                    # The oldest of yours is the one that has been waiting
                    # longest, and how long is the whole question.
                    foreach ($qi in @($qRec.Items)) {
                        if (-not $qi.Mine) { continue }
                        if ($qi.At) { $qTip = $qTip + ("`nwaiting {0}: " -f (Get-AgeTicks ([datetime]$qi.At).Ticks)) + "$($qi.First)" }
                        else { $qTip = $qTip + "`n" + "$($qi.First)" }
                        break
                    }
                } else {
                    $qTxt = "$([int]$qRec.Count)"
                    $qTip = ('{0} queued, none of them yours - cross-session messages and task notifications' -f [int]$qRec.Count)
                }
            }
            $items.Add([PSCustomObject]@{
                Kind = 'session'; Id = $r.Id; Row = $r
                BandVis = $V_Hide; RowVis = $V_Show
                DotVis = $(if ($b.Key -eq 'needs') { $V_Show } else { $V_Hide })
                BandLabel = ''; BandCount = ''; Accent = $acc
                QVis = $qVis; QText = $qTxt; QTip = $qTip; QBrush = $qBrush
                Name = $t.Text
                NameWeight = $(if ($b.Key -eq 'needs') { 'SemiBold' } else { 'Normal' })
                NameStyle  = $(if ($t.Derived) { 'Italic' } else { 'Normal' })
                # 🔑 Get-AgeLabel DIRECTLY - Get-AgeTicks is a guard and a
                # subtraction, and with $nowTicks hoisted there is nothing else
                # left in it. Two invocations per row became one and no logic
                # is duplicated: the ladder still lives in exactly one place.
                Age  = $(if ($r.At -gt 0) { Get-AgeLabel ($nowTicks - $r.At) } else { '' })
                Said = $saidText
                BarOpacity = $(if ($b.Key -eq 'quiet') { 0.25 } else { 0.85 })
                # 🔴 TWO MARKS, AND ONLY WHEN THEY MEAN SOMETHING. This list was
                # asked to get LESS dense, so a signal that is present on every
                # row is a signal that has cost density and bought nothing: the
                # context bar appears once a conversation is past half its
                # window, and the sub-agent dot only while one is actually out.
                # A quiet row looks exactly as it did before.
                CtxVis = $(if ($rowFrac -gt 0.5) { $V_Show } else { $V_Hide })
                CtxWidth = [Math]::Max(2.0, 34.0 * [Math]::Min(1.0, $rowFrac))
                # Green, amber, red - on the token count, not on the fraction.
                # See Get-CtxBrush: 85% of a 200k window and 85% of a 1M window
                # are not the same situation and must not be the same colour.
                CtxBrush = [System.Windows.Media.Brush](Get-CtxBrush $rowTok)
                # 🔴 SHAPE FIRST, HUE SECOND. A sub-agent is a ROUND amber dot -
                # another mind working on your behalf. A background shell is a
                # SQUARE violet mark - machinery still running. They answer
                # different questions ("who is working" vs "what is still going")
                # and a session can have both, so they must never be one badge
                # with a total on it. Shape carries the distinction so it also
                # survives a greyscale screenshot and colour blindness, which is
                # the rule the rest of this window is built on.
                #
                # 🪤 THE SHELL COUNT DOES NOT COME FROM Sig AND CANNOT. The
                # transcript answers a background Bash immediately, so the row's
                # own reader can only ever say zero; the true figure is the one
                # the session prints on its status line, filed per session by
                # the screen read. Sub-agents are the other way round - the
                # transcript sees them reliably and the status line may not name
                # them at all - so the screen only overrides there when it
                # actually said a number.
                # 🪤 THE COUNT ONLY WHEN IT IS NOT ONE. "1" beside a single mark
                # is a digit that says what the mark already said; the number
                # earns its place at two.
                AgentVis = $(if ($rowAgents -gt 0) { $V_Show } else { $V_Hide })
                AgentText = $(if ($rowAgents -gt 1) { "$rowAgents" } else { '' })
                ShellVis = $(if ($rowShells -gt 0) { $V_Show } else { $V_Hide })
                ShellText = $(if ($rowShells -gt 1) { "$rowShells" } else { '' })
                SubVis = $V_Hide; SubName = ''; SubDesc = ''; SubTag = ''; SubAge = ''
                SubOpacity = 1.0; SubTip = ''
            })
            # 🔑 ITS SUB-AGENTS, NESTED UNDER IT. Each one is a real conversation
            # with its own transcript beside the parent's, so it goes in this
            # list and is selected the same way - the pane then opens it with no
            # special path at all, because a sub-agent transcript uses the same
            # record shape as any other.
            #
            # 🪤 THE MARKS ABOVE AND THESE ROWS COUNT DIFFERENT THINGS, and both
            # are right. The amber dot says how many agents are out RIGHT NOW
            # (an open Task id, or the session's own status line). These rows are
            # every agent this conversation has EVER spawned, because the
            # question they answer is "what did it have working on this?" - a
            # finished agent's findings are the thing you most often want back.
            # 🔴 UNDER THE SELECTED CONVERSATION ONLY, and that is a density
            # decision with history behind it. Rendering every conversation's
            # agents took this list from 36 rows to 106 in review - a 3x list on
            # a surface that was explicitly asked to get LESS dense, and one
            # session on this machine has 31 agents on its own. CONTEXT.md
            # already records the answer to "an endless list": the roster opens
            # folded. Same rule here. The amber dot still says, on every row,
            # that a session has agents out right now.
            #
            # 🪤 THE PARENT STAYS OPEN WHILE ONE OF ITS AGENTS IS SELECTED, or
            # selecting an agent would remove the row that is selected on the
            # very next rebuild - the list would fight the click.
            # 🔴 ONLY WHAT IS ACTUALLY RUNNING. These rows listed every
            # sub-agent a conversation had EVER spawned - my call, and the wrong
            # one: the operator reported seeing sub-agent sessions with none
            # deployed, twice. The list answers "what is happening now", and a
            # row for an agent that finished last week is not an answer to that.
            #
            # 🪤 THE SELECTION IS CHECKED AGAINST ALL OF THEM, not just the live
            # ones. An agent that is being READ has usually just gone quiet, and
            # filtering before the check would delete the row under the cursor
            # on the next rebuild.
            # 🔴 THE EXPANDED LIST IS BUILT FOR THE ONE ROW THAT EXPANDS. This
            # ran BEFORE the `$expand` test, so every visible row composed a
            # Where-Object pipeline over its sub-agents - 45 of them per rebuild
            # - to answer a question only the SELECTED row ever asks. And the
            # filter it ran is the one $subsLive twenty lines up already holds,
            # so it was the same pipeline twice on the same input.
            #
            # Two pipelines per row on a rebuild that runs on every keystroke,
            # every sort click and every 2.5s sweep. Measured 2026-09-04: the
            # rebuild's parts summed to 24 ms of a 45 ms whole, and this is what
            # was in the gap.
            $expand = ($script:selId -eq $r.Id)
            $pickedSub = $null
            if (-not $expand -and "$($script:selId)".StartsWith('agent:')) {
                foreach ($sa in $subsAll) {
                    if (('agent:' + $sa.Id) -eq "$($script:selId)") {
                        $expand = $true
                        $pickedSub = $sa
                        break
                    }
                }
            }
            if (-not $expand) { continue }
            $subsShow = @($subsLive)
            # Keep the one being read on screen even once it stops writing, or
            # selecting it would close it.
            if ($pickedSub -and ($subsShow.Count -eq 0 -or -not @($subsShow | Where-Object { $_.Id -eq $pickedSub.Id }).Count)) {
                $subsShow = @($subsShow) + @($pickedSub)
            }
            foreach ($sa in $subsShow) {
                $tag = $(if ($sa.IsTeammate) { 'teammate' } else { 'task' })
                $tip = ('{0} - {1}' -f $sa.Label, $(if ($sa.Description) { $sa.Description } else { 'no description recorded' }))
                # 🔑 IS IT STILL WORKING? A sub-agent has no process of its own
                # to ask - `claude agents --json` does not report them - so the
                # evidence is its TRANSCRIPT: a file written in the last minute
                # is a conversation that is still writing. The same rule the
                # rest of this tool uses for an inferred-live session, and it
                # refreshes for free because Build-Sessions already runs on the
                # 2.5s vitals sweep. No second poller; one was removed for
                # doubling the view and is not coming back.
                # One definition of live, in Get-SRSubAgents, used by both the
                # row and the count on the parent. Two would drift.
                if ($sa.Live) { $tag = $tag + '  -  working' }
                else { $tag = $tag + '  -  finished' }
                if (-not $sa.HasTranscript) {
                    # A real state, said out loud. 45 of 374 sub-agents on this
                    # machine have metadata and no transcript - showing them as
                    # an empty conversation would read as a broken reader.
                    $tag = $tag + '  -  no transcript'
                    $tip = $tip + ' (this agent left no transcript on disk)'
                }
                $items.Add([PSCustomObject]@{
                    Kind = 'agent'; Id = ('agent:' + $sa.Id); Row = $r; Sub = $sa
                    BandVis = $V_Hide; RowVis = $V_Hide; SubVis = $V_Show
                    DotVis = $V_Hide; BandLabel = ''; BandCount = ''; Accent = $acc
                    Name = ''; Age = ''; Said = ''; NameWeight = 'Normal'; NameStyle = 'Normal'
                    BarOpacity = 0.0
                    CtxVis = $V_Hide; CtxWidth = 0.0
                    CtxBrush = [System.Windows.Media.Brush][System.Windows.Media.Brushes]::Transparent
                    AgentVis = $V_Hide; AgentText = ''; ShellVis = $V_Hide; ShellText = ''
                    QVis = $V_Hide; QText = ''; QTip = ''; QBrush = $qGrey
                    SubName = $sa.Label
                    SubDesc = $(if ($sa.Description) { $sa.Description } else { $sa.AgentType })
                    SubTag  = $tag
                    SubAge  = (Get-AgeTicks $sa.When.Ticks)
                    # Dimmed, not hidden: it still says what it was asked to do,
                    # which is often the only thing you needed.
                    SubOpacity = $(if ($sa.HasTranscript) { 1.0 } else { 0.55 })
                    SubTip = $tip
                })
            }
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
    # The strip is a second view of the same rows, so it refreshes on the same
    # pass. It returns immediately when it is not the thing on screen.
    Update-Strip
    # 🪤 $script:model.Count, NOT @($script:model).Count. The array subexpression
    # @() throws "Argument types do not match" when applied to a
    # System.Collections.Generic.List[object] on PowerShell 5.1 - full or empty,
    # either way. Piping is fine, .Count is fine, @() is not. It is the trap this
    # repo documents and it cost the first render of this window.
    # 🪤 A foreach, not a pipeline. Where-Object invokes a scriptblock per item
    # through the pipeline machinery, and this runs over every conversation in
    # the registry - 240 of them here - on a function that is already the sum of
    # two list builds and sits within a millisecond of the gesture budget. Same
    # cost class as the ForEach-Object in Get-TrackedText, which was 6.9x.
    $live = 0
    foreach ($m in $script:model) { if ($m.Live) { $live++ } }
    $ui.LiveCount.Text = ('{0} live of {1} in {2} projects' -f `
        $live, $script:model.Count, @($script:dirs).Count)
    # Also here, not only on the 6-second pass: the window has to be right the
    # moment it opens, and the fast pass has not run yet at first paint. Cheap -
    # Get-SRBridgeState caches on the file's timestamp.
    try { Update-BridgeNote } catch { }
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
    In         = $window.FindResource('HueIn')
    Out        = $window.FindResource('HueOut')
    Tool       = $window.FindResource('HueTool')
    Bad        = $window.FindResource('HueBad')
    Ask        = $window.FindResource('HueAsk')
    Warn       = $window.FindResource('HueWarn')
    Ok         = $window.FindResource('HueOk')
}

# ===========================================================================
# HOW FULL IS TOO FULL, IN TOKENS RATHER THAN IN PERCENT.
#
# 🔴 THE THRESHOLDS ARE ABSOLUTE ON PURPOSE. They used to be fractions of the
# window - amber past 60%, red past 85% - which means the same bar colour
# describes two completely different situations: 85% of a 200k window is 170k
# and perfectly comfortable, while 85% of a 1M window is 850k and nearly out.
# What actually matters is how many tokens are in there, so that is what is
# measured. Green below 200k, amber past it, red past 600k.
$SR_CtxWarnTokens = 200000
$SR_CtxBadTokens  = 600000

# 🔴 IS ANYTHING IN THIS QUEUE STILL WORTH A MARK?
#
# 🪤 THE AGE THAT MATTERS IS THE MESSAGE'S, NOT THE FILE'S - and the first
# version of this test measured the file. It read the transcript's own
# LastWriteTime, so it could only ever fire on a session that had STOPPED
# writing, which is precisely never for the live ones that show a phantom mark.
# Reported with a screenshot an hour after that fix shipped: "1 OF YOURS WAITING
# - OLDEST HAS WAITED 1H", on a message long since read.
#
# 🪤 ANY ITEM STILL YOUNG KEEPS THE WHOLE MARK, and the counts are never
# re-derived here. Items is what the panel dates and there is no guarantee it
# holds every item the count covers, so it answers "is anything here still
# current?" and nothing else. That is what keeps a conservative gate
# conservative.
#
# 🪤 NO DATE ANYWHERE MEANS "COULD NOT TELL" AND STILL DRAWS. This test only
# ever HIDES something, so it must fire on positive evidence of age and never on
# the absence of evidence.
#
# A function rather than eleven lines inside Build-Sessions, so the suite can
# put a stale record and an undated one in front of it and see what it says.
function Test-SRQueueFresh {
    param($Rec, [datetime]$Now, [double]$MaxHours, [double]$MachineMins = 0)
    if (-not $Rec) { return $true }
    $dated = 0
    $young = 0
    foreach ($qi in @($Rec.Items)) {
        if (-not $qi.At) { continue }
        $at = $null
        try { $at = [datetime]$qi.At } catch { continue }
        $dated++
        # 🪤 THE WINDOW DEPENDS ON WHOSE MESSAGE IT IS. An item that is not
        # yours is machine traffic the session eats on its next turn, so it is
        # stale in minutes; one of yours can wait an hour. Passing 0 keeps the
        # single-window behaviour, which is what the row mark used before the
        # panel needed this.
        $limit = $MaxHours
        if ($MachineMins -gt 0 -and -not $qi.Mine) { $limit = $MachineMins / 60.0 }
        if (($Now - $at).TotalHours -le $limit) { $young++ }
    }
    if ($dated -le 0) { return $true }
    return ($young -gt 0)
}


function Get-CtxBrush { param([int]$Tokens)
    if ($Tokens -gt $SR_CtxBadTokens)  { return $Pal.Bad }
    if ($Tokens -gt $SR_CtxWarnTokens) { return $Pal.Warn }
    return $Pal.Ok
}

# Translucent grounds, derived rather than declared: six hues times three
# strengths is eighteen resources nobody would keep in step by hand.
#
# A BRUSH IS CLONED BEFORE ITS OPACITY IS TOUCHED. The resource brushes are
# shared by everything in the window that names them, so setting .Opacity on one
# would dim every other use of it - and a frozen brush throws instead.
function New-SRTint { param($Brush, [double]$Alpha)
    $c = $Brush.Color
    $c.A = [byte][math]::Round(255 * $Alpha)
    $b = New-Object System.Windows.Media.SolidColorBrush $c
    $b.Freeze()
    return $b
}
$PalWash = @{}   # 10% - a ground you notice
$PalFilm = @{}   #  5% - a ground you do not
$PalEdge = @{}   # 34% - a stroke
foreach ($hueKey in @('In', 'Out', 'Tool', 'Bad', 'Ask', 'Warn')) {
    $PalWash[$hueKey] = New-SRTint $Pal[$hueKey] 0.10
    $PalFilm[$hueKey] = New-SRTint $Pal[$hueKey] 0.05
    $PalEdge[$hueKey] = New-SRTint $Pal[$hueKey] 0.34
}
$PalGlass   = New-SRTint $Pal.TextMax 0.035
$PalGlassHi = New-SRTint $Pal.TextMax 0.055
# 🔴 THE GROUND BEHIND YOUR OWN WORDS. Reported as "I cannot see any noticeable
# difference between what I prompted and what the session is", with the terminal
# named as the reference: there, what you typed sits on a ground and everything
# else does not.
#
# 🪤 NEUTRAL, NOT THE `Out` HUE. Orange is already saying "you" twice - in the
# gutter marker and in the label above - and a third orange device sits BEHIND
# the text rather than beside it, so it tints the words themselves. White at 8%
# reads as a surface, not as a colour, which is what a ground is for.
$PalYouGround = New-SRTint $Pal.TextMax 0.08
$PalHair    = New-SRTint $Pal.TextMax 0.07
$PalSunk    = New-SRTint $Pal.Ink 0.55
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

# THE TRANSCRIPT'S FACE, on the same terms as Manrope above.
#
# 🔴 IT IS MONOSPACED AND THAT IS THE POINT. The pane draws prose, tables, tool
# arguments and shell output in ONE face at ONE size, so that face has to hold a
# character grid - a table of file:line rendered proportionally is not a table.
# What it does NOT have to be is terminal-drawn, and Cascadia Mono is: slashed
# zero, hard geometry, built for a console. Measured against four candidates on
# the pane's own ground, IBM Plex Mono is the humanist one, and it is the family
# Zed derives its default from, so it is already proven for long reading here.
#
# 🪤 THREE FILES, NOT ONE. Regular, SemiBold and Italic. A family with only a
# Regular makes WPF SYNTHESISE the other two - a smeared oblique and a
# double-struck bold - which is precisely the "fat" the operator reported about
# the old SemiBold captions. Fragment Mono lost the comparison on exactly this:
# it ships one weight. The face count is checked below rather than assumed.
function Install-SRPaneFace {
    $dir = Join-Path $here 'fonts'
    $ttf = Join-Path $dir 'IBMPlexMono-Regular.ttf'
    if (-not (Test-Path -LiteralPath $ttf)) {
        Write-SRLog '  [skip] lib\fonts\IBMPlexMono-Regular.ttf is not there - the pane keeps Cascadia Mono'
        return $false
    }
    try {
        $base = [Uri]('file:///' + $dir.Replace('\', '/').TrimEnd('/') + '/')
        $fams = [System.Windows.Media.Fonts]::GetFontFamilies($base)
        # The PSObject cast is load-bearing here for the same reason it is in
        # Install-SRTypeface - see the note there.
        $fam = [System.Windows.Media.FontFamily](@($fams | Where-Object { "$($_.Source)" -like '*#IBM Plex Mono*' })[0])
        if (-not $fam) { Write-SRLog '  [skip] no IBM Plex Mono family in lib\fonts - the pane keeps Cascadia Mono'; return $false }
        $faces = @($fam.GetTypefaces())
        if ($faces.Count -lt 2) {
            Write-SRLog ('  [skip] IBM Plex Mono exposes only {0} face - a synthesised bold is worse than Cascadia' -f $faces.Count)
            return $false
        }
        # 🔴 A BARE EMBEDDED FAMILY HAS NO FALLBACK, and assigning one here threw
        # away the chain window2.xaml declares. $fam stays the thing that gets
        # VALIDATED above - it is what carries the typefaces - and what gets
        # INSTALLED is a composite built on the same base uri, so a codepoint
        # IBM Plex Mono lacks still reaches a face somebody chose rather than
        # one WPF picked.
        $famFB = $fam
        try {
            $famFB = New-Object System.Windows.Media.FontFamily $base, `
                '#IBM Plex Mono, Cascadia Mono, Consolas, Courier New, Segoe UI Emoji, Segoe UI Symbol'
        } catch { Write-SRLog ('  [skip] composite pane face failed, using the bare family: ' + $_.Exception.Message) }
        $window.Resources['FontPane'] = $famFB
        # 🔴 THE CHROME NO LONGER TAKES IT, AND THAT REVERSES A DATED DECISION.
        #
        # 2026-09-03 put "one face across the entire window, not just the
        # transcript" here, overwriting FontText/FontDisplay/FontSmall as well.
        # That is why Manrope loads a few lines above and is immediately thrown
        # away, and why window2.xaml's "Segoe UI Variable Text" never draws
        # anything: the resource is replaced at runtime, after parse.
        #
        # What overturned it is the operator, twice: "either too terminal-like or
        # something else has happened", and a target of "similarly to how
        # [Zed / Cursor / the VS Code extension] looks but just with a touch of
        # the terminal". One face across the whole window is not a touch of the
        # terminal, it is the terminal - and the complaint was never about the
        # reading pane alone, which is how it survived a cycle of pane-only work.
        #
        # 🔑 FontMono STAYS. It is the key for text that genuinely wants the
        # grid, so pointing it at the shipped mono face is the whole point of
        # shipping one. The three TEXT keys keep Manrope, loaded just above.
        foreach ($k in @('FontMono')) {
            $window.Resources[$k] = $famFB
        }
        Write-SRLog ('  [ok]   IBM Plex Mono loaded from lib\fonts ({0} faces) - pane and chrome' -f $faces.Count)
        return $true
    } catch {
        Write-SRLog ('  [skip] IBM Plex Mono would not load ({0}) - the pane keeps Cascadia Mono' -f $_.Exception.Message)
        return $false
    }
}
$script:hasPlex = Install-SRPaneFace

# ===========================================================================
# ONE TYPE SCALE, AND ONE KNOB THAT MOVES ALL OF IT.
#
# 🔴 THE BASE VALUES ARE NOT DEFINED HERE. They are the six Sz* resources in
# window2.xaml, and this reads them. A second copy of the numbers in script is
# how the "one scale" claim in that file became untrue the first time - the
# styles moved and the builder did not - so there is exactly one place a size is
# written down, and this is not it.
#
# 🔑 WHY A KNOB AND NOT THE WINDOW WIDTH. Reported as "the text from the working
# surface is not scaling with the window size", and it never has: Set-Breakpoint
# moves COLUMNS, and no font size in the tool has ever read the window. The one
# thing that did scale - the reading pane growing 16 -> 20px with its width -
# was removed because it was reported as text that was too large. Growing type
# when a window is dragged wider is zooming, not scaling, and it takes the
# decision away from the person who can see the screen. So: one setting, every
# size together, saved, and the same on both machines.
$SR_GutterBase = 22.0
# 🪤 ONE LEADING FACTOR, IN ONE PLACE, AND DECLARED BEFORE ANYTHING READS IT.
# Set-SRTypeScale and Set-ReadMeasure each held their own copy; this morning
# they disagreed (1.48 against 1.38) and the one that runs on EVERY layout won,
# so the value the scale set was decoration. That is the third time a number in
# this file has been written down twice and the invisible copy has won.
# 1.48 -> 1.62 on report: "it feels the text is sometimes too dense". 1.48 is a
# tight setting for a MONOSPACED face, which is what this pane used to be; on a
# proportional face with a shorter x-height the same ratio reads packed. One
# number, so every paragraph, every fold body and the measure that sizes the
# column all move together.
$SR_LeadFactor = 1.62
$script:TypeBase = @{}
foreach ($k in @('Micro', 'Caption', 'Body', 'Mono', 'Strong', 'Display', 'Pane')) {
    # 🪤 CAST, DO NOT TRUST THE LOOKUP. A missing key returns $null and would
    # silently make every size 0 - a window that lays out to nothing. The
    # fallback keeps the shape of the scale if the XAML is ever out of step.
    $v = 0.0
    try { $v = [double]$window.Resources["Sz$k"] } catch { $v = 0.0 }
    if ($v -le 0) { $v = @{ Micro = 9.5; Caption = 11.0; Body = 12.0; Mono = 12.5; Strong = 14.0; Display = 17.0; Pane = 13.0 }[$k] }
    $script:TypeBase[$k] = $v
}
$script:Type = @{}
$script:Zoom = 100

function Set-SRTypeScale { param([int]$Percent = 0)
    if ($Percent -gt 0) { $script:Zoom = [Math]::Max(70, [Math]::Min(200, $Percent)) }
    $f = $script:Zoom / 100.0
    foreach ($k in @($script:TypeBase.Keys)) {
        # 🔴 THE SIX-STEP SCALE IS COLLAPSED TO ONE STEP, DELIBERATELY. Decided
        # 2026-09-03: one face and one size across the ENTIRE window, chrome
        # included - list rows, buttons, headings, the question panel - and not
        # only the transcript. Every Sz* resource is given the PANE's value, so
        # nothing on screen is a different size from anything else.
        #
        # 🪤 The consequence was stated when this was chosen and is real: the
        # six steps existed because a band heading, a row title and its caption
        # are different things, and size was the cue that separated them. What
        # carries hierarchy now is weight, hue and position. The six base values
        # stay in window2.xaml as the record of what the scale was - deleting
        # the 'Pane' below restores it in one token.
        #
        # Still rounded to a half pixel, because the pane step is 13 and a zoom
        # of 70% or 125% lands between whole numbers.
        $v = [Math]::Round(($script:TypeBase['Pane'] * $f) * 2.0) / 2.0
        $script:Type[$k] = $v
        # The resource is what every XAML style reads, so assigning it here is
        # what makes the chrome move with the pane rather than only the pane.
        $window.Resources["Sz$k"] = $v
    }
    # 🔴 ONE SIZE FOR THE WHOLE TRANSCRIPT, and these two names now point at it.
    # readSize was Body and MonoSize was Mono - two steps, deliberately chosen
    # for x-height PARITY so machine text would read as large as prose. It did,
    # and that was the mistake: tool traffic outnumbers prose five to one in
    # this pane (measured, see the reading-surface note), so making it equally
    # prominent is what turned the whole surface into a terminal. Both names
    # survive because thirty call sites use them; there is one number behind
    # them now.
    $script:PaneSize = $script:Type.Pane
    $script:readSize = $script:PaneSize
    $script:MonoSize = $script:PaneSize
    # Mono needs a little more air between lines than a proportional face at
    # the same size; the factor is $SR_LeadFactor, shared with Set-ReadMeasure.
    $script:readLead = [Math]::Round($script:PaneSize * $SR_LeadFactor, 1)
    # The gutter is a TYPE measure, not a layout constant - it holds one marker
    # glyph and the space after it - so it zooms with the glyph or the marker
    # grows out of its column. Both users of it read this one variable, so the
    # invariant that prose and rail blocks start at the same x survives the
    # scaling; gui2 asserts that in rendered coordinates.
    $script:GutterW = [Math]::Round($SR_GutterBase * $f, 1)
}

try { $script:Zoom = [int](Get-SRConfig).zoom } catch { $script:Zoom = 100 }
Set-SRTypeScale

# ===========================================================================
# HOW GLYPHS ARE ANTIALIASED - the one look in this window the operator sets.
#
# window2.xaml pins Grayscale, with a reasoned comment: ClearType tints the edge
# of every stem red or blue, and on a near-black ground that fringe is visible.
# Against that, ClearType is what a browser uses, and the same words really do
# come out crisper in a web page than here.
#
# 🔴 A SCREENSHOT CANNOT SETTLE IT. RenderTargetBitmap always composites
# greyscale, so every shot this repo takes renders "ClearType" as greyscale -
# measured, see tests\type-driver.ps1, where both ClearType rows come out
# identical to their greyscale twins. Only a monitor can answer it, so the
# answer belongs to the person at one. Flip `textRendering` in the config
# between `grayscale` and `cleartype` and look.
try {
    if ((Get-SRConfig).textRendering -eq 'cleartype') {
        [System.Windows.Media.TextOptions]::SetTextRenderingMode($window, 'ClearType')
        Write-SRLog '  text rendering: ClearType (set in the config)'
    }
} catch { }

# The faces the TRANSCRIPT is drawn in - the biggest block of text in the window.
# Resolved AFTER the typeface is installed, or the document would keep the system
# face while everything around it changed.
$script:UiFace   = $window.FindResource('FontText')
$script:MonoFace = $window.FindResource('FontMono')
# 🔴 THE TRANSCRIPT HAS ONE FACE. Every builder below that draws part of a
# message uses this and nothing else - prose, code, tool names, arguments,
# results, labels, gutter markers. UiFace and MonoFace survive above for the
# CHROME that is built in code (the live question panel, the chips), which is
# not a message and keeps the window's own face.
$script:PaneFace = $window.FindResource('FontPane')

# 🔴 AND PROSE IS NOT MACHINE TEXT. THE PANE HAS TWO FACES, ONE PER ROLE.
#
# 18d0007 unified the pane after "text still looks not unified across every
# single message" and "either too terminal-like or something else has happened".
# It was right about the disease - twelve hard-coded sizes across two faces, four
# of them off the six-step scale entirely, so the pane looked uniform at 100% and
# came apart at every other zoom. It fixed that by putting EVERYTHING on the mono
# face, which answers "too terminal-like" by making all of it terminal.
#
# Its rule is kept exactly: one scale, one face per role, no hard-coded sizes.
# What changes is which face PROSE lands on. Mono is reserved for the text that
# needs a character grid - fenced code, inline code, tool arguments, paths, shell
# output, results, and the glyph columns - because a table of file:line rendered
# proportionally stops being a table.
#
# 🔑 THE CALL SITES ALREADY KNEW. Every one of them passes -Mono when it is
# drawing machine text; that switch was left as a deliberate no-op with a note
# saying the distinction was "still carried - by hue and by the gutter marker,
# not by the face". This reconnects it to the face. No call site moves.
$script:ProseFace = $script:UiFace

# THE MEASURE'S CHARACTER WIDTH, ASKED OF THE FACE RATHER THAN TYPED IN.
#
# 🔴 It was a literal 0.52, described in Set-ReadMeasure as "the measured average
# advance for this face" - and it was, for MANROPE. The pane is monospaced now,
# and nothing pointed the constant at the new face, so a column asked to hold 100
# characters was sized for 87 of them. A hard-coded metric outlives the face it
# was measured from, silently, and the only symptom is a column narrower than it
# claims - which is half of "the text was cut off although the screen was empty".
#
# 🪤 AND IT HAS TO FOLLOW THE FACE PROSE IS ACTUALLY DRAWN IN. The column sizes
# the READING measure, and the reading is prose, so this asks the PROSE face -
# not the mono one, which now draws only code. Getting this wrong is silent by
# construction: the only symptom is a column narrower or wider than it claims.
#
# 🪤 A PROPORTIONAL FACE HAS NO SINGLE ADVANCE, so this is a real average over a
# representative sample rather than the advance of '0'. Sampling one character
# was exact while the pane was monospaced and would be arbitrary now - '0' is
# among the widest glyphs in most proportional faces, which would size the
# column for far fewer characters than it holds.
#
# The fallback is 0.52, which is not a guess: it is the average this file
# carried as a literal for MANROPE before the pane went mono, and prose is on
# Manrope again.
$script:PaneAdvanceEm = 0.52
try {
    $tf0 = New-Object System.Windows.Media.Typeface $script:ProseFace,
               ([System.Windows.FontStyles]::Normal), ([System.Windows.FontWeights]::Normal),
               ([System.Windows.FontStretches]::Normal)
    $gt0 = $null
    if ($tf0.TryGetGlyphTypeface([ref]$gt0)) {
        # Letter frequencies matter more than coverage here: the sample is the
        # text that actually appears, so it is weighted the way English is.
        # 🪤 ORDINARY ENGLISH, NOT AN ALPHABET. The first version averaged over
        # 'a-z A-Z 0-9 punctuation', which is about 40% capitals where real prose
        # is nearer 3% - and capitals are wide. It came out at 0,600 em, the very
        # same number as the monospaced face it replaced, so it would have sized
        # the reading column about 20% over its intended measure while looking
        # like it had been measured properly. A sentence carries the real
        # frequencies, including how often a space appears, and space is the
        # narrowest glyph there is.
        $sample = 'the session was waiting for an answer and nothing else was running at the time, so it simply sat there. '
        $sum = 0.0; $n = 0
        foreach ($ch in $sample.ToCharArray()) {
            $gi = 0
            if ($gt0.CharacterToGlyphMap.TryGetValue([int][char]$ch, [ref]$gi)) {
                $sum += [double]$gt0.AdvanceWidths[$gi]; $n++
            }
        }
        if ($n -gt 0) {
            $avg = $sum / $n
            if ($avg -gt 0.2 -and $avg -lt 1.5) { $script:PaneAdvanceEm = $avg }
        }
    }
} catch { }
$FW_Semi   = [System.Windows.FontWeights]::SemiBold
$FW_Normal = [System.Windows.FontWeights]::Normal

# THE TAIL BUDGET. The biggest transcript on this machine is 2.5 MB and
# FlowDocumentScrollViewer does not virtualize its blocks, so rendering a whole
# conversation is a multi-second freeze on every selection. Start at the same
# 256 KB Get-SRLastSaid uses; "load earlier" doubles it, and the pane says out
# loud when it is showing only part.
# 🔴 96 KB, NOT 256. Measured on the operator's own transcripts: rendering
# scales linearly with this number - 96 KB costs 120 ms, 256 KB costs 256 ms -
# and it is the single biggest component of the ~390 ms stall when selecting a
# conversation, which is the gesture repeated all day. The tail is a READING
# window, not the conversation: 96 KB is still well over a screenful, the pane
# says out loud when it is showing only part, and 'load earlier' doubles it on
# demand for the rare time you want more. Paying 130 ms on every selection so
# that the rare case needs no click is the wrong way round.
$script:TailBase = 98304
$script:tailBytes = $script:TailBase


function New-ReadRun {
    # 🔑 -Mono IS LOAD-BEARING AGAIN. It was left as a no-op when the whole pane
    # went monospaced, with a note that the machine-text distinction was "still
    # carried - by hue and by the gutter marker, not by the face". It is carried
    # by the face again: prose proportional, machine text on the grid.
    param([string]$Text, $Brush, [double]$Size = 0, [string]$Weight = 'Normal', [switch]$Mono, [switch]$Italic)
    if ($Size -le 0) { $Size = $script:PaneSize }
    $r = New-Object System.Windows.Documents.Run ([string]$Text)
    if ($Brush) { $r.Foreground = $Brush }
    $r.FontSize = $Size
    $r.FontFamily = $(if ($Mono) { $script:PaneFace } else { $script:ProseFace })
    if ($Italic) { $r.FontStyle = [System.Windows.FontStyles]::Italic }
    $r.FontWeight = $(if ($Weight -eq 'SemiBold') { $FW_Semi } else { $FW_Normal })
    return $r
}

# ===========================================================================
# THE READING SURFACE.
#
# Chosen from six drawn against a real conversation (tests\design-driver.ps1,
# `run-tests.ps1 -Only design`). The complaint it answers was "very dense and
# really hard to read - you are flooded with a lot of text", and the diagnosis
# was that almost none of the flood is prose:
#
#   measured across six transcripts - text 50, thinking 84, tool_use 129,
#   tool_result 130. Tool traffic outnumbers prose FIVE TO ONE.
#
# So three things do the work, and only the third is decoration:
#
#   1. A MEASURE. Set across a 927px pane, a line runs to about 120 characters
#      and the eye loses the start of the next one. Capped near 70, computed
#      from the live pane width so it stays a measure and not a fixed indent.
#   2. THE MACHINERY IS FOLDED. A run of calls becomes one line naming what ran.
#      Three positions - folded, full, hidden - because "what is it doing right
#      now" and "let me read this reply" want different answers, and only the
#      operator knows which they are doing. Remembered in the config.
#   3. Type, not chrome. One rule and one tracked label per turn; hue names the
#      speaker. No cards around prose - a card per turn spends the vertical
#      space this whole exercise exists to reclaim.
# ===========================================================================

# WPF HAS NO LETTER-SPACING, at all, on any text primitive. Tracking a small
# uppercase caption is the single move that makes it read as a label rather
# than as shouting, so it is built by hand out of thin spaces.
# 🪤 NO PIPELINE. This ran ToCharArray through ForEach-Object to stringify each
# character, and the pipeline was the entire cost - 0.32 ms a call, on a
# function called once per label in a document that is rebuilt whenever the
# transcript grows. `-join` takes the char array directly and needs no
# per-character cmdlet invocation.
function Get-TrackedText { param([string]$Text)
    if (-not $Text) { return '' }
    return ($Text.ToCharArray() -join ([string][char]0x2009))
}

# THERE ARE NO CARDS IN THIS DOCUMENT ANY MORE, and `New-ReadCard` is gone with
# them. It built the rounded, padded, translucent surface every block used to
# sit on - a run, a hook, an answered question, a notice - and the accumulated
# effect was a column of differently-shaped boxes where a terminal has a single
# aligned column of text. Category is carried by the GUTTER now (see the marker
# table below): one marker glyph, one hue, on a fixed left column, with an
# optional rail down it for the blocks that own several lines.
#
# It is deleted rather than left unused on purpose. A card builder sitting in
# this file is an invitation to put one block back in a card, and one block in a
# card is exactly how the old surface started.

function New-ReadText {
    # -Mono selects the face here too; see New-ReadRun.
    param([string]$Text, $Brush, [double]$Size = 0, [switch]$Mono, [switch]$Semi,
          [switch]$Wrap, [double]$Line = 0)
    if ($Size -le 0) { $Size = $script:PaneSize }
    $t = [System.Windows.Controls.TextBlock]::new()
    $t.Text = $Text
    if ($Brush) { $t.Foreground = $Brush }
    $t.FontSize = $Size
    $t.FontFamily = $(if ($Mono) { $script:PaneFace } else { $script:ProseFace })
    if ($Semi) { $t.FontWeight = $FW_Semi }
    if ($Wrap) { $t.TextWrapping = 'Wrap' }
    else { $t.TextWrapping = 'NoWrap'; $t.TextTrimming = 'CharacterEllipsis' }
    if ($Line -gt 0) { $t.LineHeight = $Line; $t.LineStackingStrategy = 'BlockLineHeight' }
    return $t
}

# Markdown, but only the parts that change how a line READS: fenced code, a
# heading, a bullet, and inline `code`. Anything more would be a markdown
# engine, which is not what this needs to be.
function Add-ReadProse {
    param($Doc, [string]$Text, $Brush, [double]$Size = 0, [double]$Line = 0,
          [double]$Indent = 0, [string]$Kind = '', $Ground = $null)
    if ($Size -le 0) { $Size = $script:PaneSize }
    if ($Line -le 0) { $Line = $script:readLead }
    # A grounded paragraph is inset from its own background so the words are not
    # flush against the edge of it, and the box is pulled LEFT by the same
    # amount so the text still starts on the one x every other block uses. Pad
    # without the offset and every line you wrote sits a column right of every
    # line Claude did - which is the alignment complaint, not the fix for it.
    $padX = 0.0
    if ($Ground) { $padX = 11.0 }
    # 🔴 THE BANDS HAVE TO TOUCH OR IT IS NOT A GROUND. Every source line is its
    # own Paragraph with 3px of margin above and below it, so painting the
    # background per-paragraph drew a STRIPE PER LINE with the ground colour
    # missing between them - looked at in a shot, a five-line message read as
    # five separate cards stacked up. The vertical margin goes to zero for a
    # grounded turn and the leading, which lives INSIDE the paragraph, goes on
    # keeping the lines apart exactly as it did.
    # ::new(), and only when there IS a ground. New-Object drives a generic
    # type through the command pipeline on every call of a function that runs
    # once per turn, to hold a list most turns never put anything in.
    $groundPs = $null
    if ($Ground) { $groundPs = [System.Collections.Generic.List[object]]::new() }
    $groundPad = 3.0
    if ($Ground) { $groundPad = 0.0 }
    $lines = @((Remove-SRAnsi $Text) -replace "`r", '' -split "`n")
    $i = 0
    # The marker is drawn ONCE, on the first line that carries words. A turn is
    # one thing said; marking every paragraph of it would put a column of dots
    # down the side of a long reply and say nothing the first one did not.
    $firstMark = ($Kind -ne '')
    while ($i -lt $lines.Count) {
        $ln = $lines[$i]
        if ($ln.TrimStart().StartsWith('``' + '`')) {
            $code = New-Object System.Collections.Generic.List[string]
            $i++
            while ($i -lt $lines.Count -and -not $lines[$i].TrimStart().StartsWith('``' + '`')) { $code.Add($lines[$i]); $i++ }
            $i++
            # A fenced block is machine text: mono, on the rail, and NOT in a
            # card. Nothing in this document is in a card any more.
            $tb = New-ReadText -Text (($code -join "`n").TrimEnd()) -Brush $Pal.TextHigh -Mono -Wrap -Line $script:readLead
            $Doc.Blocks.Add((New-RailBlock -Child $tb -Kind 'result' -Indent $Indent -Top 10 -Bottom 10 -Rail))
            continue
        }
        $p = New-Object System.Windows.Documents.Paragraph
        $p.Margin = New-Object System.Windows.Thickness ($Indent + $script:GutterW - $padX), $groundPad, 0, $groundPad
        $p.TextIndent = -$script:GutterW
        $p.LineHeight = $Line
        $p.LineStackingStrategy = 'BlockLineHeight'
        if ($Ground) {
            $p.Background = $Ground
            $p.Padding = New-Object System.Windows.Thickness $padX, 0, $padX, 0
        }
        if ($firstMark -and $ln.Trim()) {
            $p.Inlines.Add((New-GutterMark -Glyph (Get-MarkGlyph $Kind) -Brush (Get-MarkBrush $Kind)))
            $firstMark = $false
        } else {
            # 🔴 A BLANK GUTTER NEEDS NO OBJECT AT ALL, and this was hosting a
            # UIElement per continuation line to display nothing. Audited:
            # New-GutterMark is 0.85 ms - twelve times a bare Paragraph - and
            # Add-ReadProse added one to EVERY paragraph, which is about a
            # quarter of the 3.44 ms a source line costs.
            #
            # The layout is identical without it. Margin.Left is already
            # Indent + GutterW; the negative TextIndent exists only to pull the
            # first line back so the mark can sit in the space. With no mark to
            # sit there, not pulling it back puts the text on exactly the same
            # x - so this is the same pixels for one fewer UIElement per line.
            $p.TextIndent = 0
        }
        $body = $ln; $size = $Size; $weight = 'Normal'; $bump = 0; $markN = 0
        # 🪤 A HEADING IS WEIGHT NOW, NOT SIZE. `$Size + 2` was one of the twelve
        # sizes that made this pane ragged, and it is the easiest one to justify
        # and still wrong: one size means one size. SemiBold carries it.
        if ($body -match '^\s*#{1,6}\s+(.*)$') { $body = $Matches[1]; $weight = 'SemiBold' }
        # 🔴 $markN IS HOW MANY CHARACTERS THE MARKER OCCUPIES, and it exists so
        # a wrapped line can hang from the WORDS. Measured across 8 transcripts:
        # every list item put its second line at x=84, under the bullet, while
        # prose correctly wrapped to x=66 - so the one block type that is meant
        # to be a column was the one with a ragged left edge. Reported as "the
        # text also sometimes looks misaligned and not unified. It is not left
        # bounded."
        elseif ($body -match '^\s*[-*]\s+(.*)$') { $body = [string][char]0x2022 + '   ' + $Matches[1]; $bump = 18; $markN = 4 }
        elseif ($body -match '^\s*(\d+)\.\s+(.*)$') { $body = $Matches[1] + '.   ' + $Matches[2]; $bump = 18; $markN = $Matches[1].Length + 4 }
        # 🪤 THE GUTTER STAYS IN THE MARGIN. A bullet re-sets the whole Margin,
        # so leaving the original arithmetic here would have dropped the gutter
        # offset on exactly the lines that are indented anyway - every bullet in
        # every reply sliding one column left of the prose above it.
        if ($bump) {
            # 🪤 THE HANG IS ARITHMETIC, NOT A HOSTED BOX. A fixed-width element
            # per bullet would guarantee the column exactly, and measures
            # 0,85 ms EACH - the reason the gutter mark was removed from every
            # continuation line. The marker's width is the advance of the face
            # times the characters in it, which is a pixel or two out on a
            # proportional face and invisible against a 22px gutter.
            $hang = [Math]::Round($size * $script:PaneAdvanceEm * $markN, 1)
            $p.Margin = New-Object System.Windows.Thickness ($Indent + $script:GutterW + $bump - $padX + $hang), $groundPad, 0, $groundPad
            $p.TextIndent = -$hang
        }
        # 🔴 HOW MANY INLINES THIS PARAGRAPH STARTED WITH, because that number is
        # no longer a constant. The blank-line test below used to read
        # `-le 1`, meaning "nothing here but the gutter box" - and the note on it
        # already records that it was once `-eq 0` and silently stopped firing
        # when the gutter box was ADDED in front of every paragraph. Removing the
        # box for unmarked lines moves it again, the other way: a line of real
        # prose would now hold ONE inline and be mistaken for an empty one.
        # Comparing against where this paragraph actually started cannot drift
        # with whatever does or does not precede the body.
        $inl0 = $p.Inlines.Count
        $rest = $body
        while ($rest -match '^(.*?)(`([^`]+)`|\*\*([^*]+)\*\*)(.*)$') {
            $before = $Matches[1]; $codeTxt = $Matches[3]; $boldTxt = $Matches[4]; $rest = $Matches[5]
            if ($before)  { $p.Inlines.Add((New-ReadRun -Text $before -Brush $Brush -Size $size -Weight $weight)) }
            # Inline code was $size - 1.5, i.e. 10.5 against 12 prose - the
            # smallest thing in the document and the one most often a path you
            # actually need to read. Same size as everything else; the hue is
            # what says it is code.
            if ($codeTxt) { $p.Inlines.Add((New-ReadRun -Text $codeTxt -Brush $Pal.TextMax -Size $size -Mono)) }
            elseif ($boldTxt) { $p.Inlines.Add((New-ReadRun -Text $boldTxt -Brush $Pal.TextMax -Size $size -Weight 'SemiBold')) }
        }
        if ($rest) { $p.Inlines.Add((New-ReadRun -Text $rest -Brush $Brush -Size $size -Weight $weight)) }
        # An empty source line is a paragraph break, and it is set SMALL: at the
        # full body size a blank line between two paragraphs is a whole line of
        # nothing and the reply looks double-spaced.
        #
        # 🪤 `-le 1`, NOT `-eq 0`. Every paragraph now opens with its gutter box,
        # so an empty line has ONE inline rather than none - and the old test
        # would have quietly stopped firing, leaving full-size blank lines
        # through every reply. A count that changed meaning when a column was
        # added in front of it.
        if ($p.Inlines.Count -eq $inl0) { $p.Inlines.Add((New-ReadRun -Text ' ' -Brush $Brush -Size ($Size * 0.4))) }
        $Doc.Blocks.Add($p)
        if ($Ground) { $groundPs.Add($p) }
        $i++
    }
    # The first and last lines get the ground's own top and bottom inset. Done
    # here rather than per-paragraph because which paragraph is last is only
    # known once there are no more of them.
    if ($Ground -and $groundPs.Count -gt 0) {
        $pf = $groundPs[0]
        $pf.Padding = New-Object System.Windows.Thickness $padX, 9, $padX, $pf.Padding.Bottom
        $pl = $groundPs[$groundPs.Count - 1]
        $pl.Padding = New-Object System.Windows.Thickness $padX, $pl.Padding.Top, $padX, 9
    }
}

# TURNS, NOT BLOCKS, AND THE RESULT BELONGS TO ITS CALL.
#
# Two things this fixes, both of which were on screen:
#
#   A single reply arrives as SEVERAL text blocks whenever thinking or a tool
#   call sits between them, and the old renderer named the speaker over each -
#   so CLAUDE printed three times down one screen with two sentences under
#   each. It read as a stutter and it spent the vertical space this redesign
#   exists to reclaim.
#
#   A tool_result was rendered as a sibling of its tool_use rather than as its
#   answer, so a folded run could count seven calls and then show a loose
#   result underneath belonging to none of them. Results are paired here, once.
function Get-ReadTurns { param($Blocks)
    $out = New-Object System.Collections.Generic.List[object]
    $arr = @($Blocks)
    $i = 0
    while ($i -lt $arr.Count) {
        $b = $arr[$i]
        if ($b.Kind -ne 'tool' -and $b.Kind -ne 'result') {
            $prev = $null
            if ($out.Count) { $prev = $out[$out.Count - 1] }
            if ($prev -and $prev.Kind -eq "$($b.Kind)" -and ($b.Kind -eq 'you' -or $b.Kind -eq 'said')) {
                $prev.Body = ($prev.Body.TrimEnd() + "`n`n" + "$($b.Body)".TrimStart())
            } elseif ($prev -and $prev.Kind -eq 'system' -and "$($b.Kind)" -eq 'system') {
                # 🔴 NOTICES ARRIVE IN RUNS AND DROWN THE CONVERSATION. A Remote
                # Control session prints one per artifact per reconnect, and a
                # rendered pane turned out to be ELEVEN of them in cramped mono
                # with two lines of what claude actually said above - which is
                # exactly the "flooded with text" this surface was rebuilt to
                # fix, still there, and invisible until the pane was drawn with
                # real content in it.
                #
                # Merged like a tool run: one line folded, all of it under
                # Steps: full. Nothing is swallowed - that was the reason they
                # were added - and nothing shouts either.
                $prev.Body = ($prev.Body.TrimEnd() + "`n" + ('{0}   {1}' -f $b.Head, $b.Body).Trim())
                $prev.Count = [int]$prev.Count + 1
            } elseif ($prev -and $prev.Kind -eq 'file' -and "$($b.Kind)" -eq 'file') {
                # A compact re-reads a handful of files and the terminal prints
                # them as one list. Six separate cards would be six times the
                # height and no more information.
                $prev.Body = ($prev.Body + "`n" + ('{0}   {1}' -f $b.Body, $b.Meta).TrimEnd())
                $prev.Count = [int]$prev.Count + 1
            } else {
                # The turn is stamped with when it STARTED, not when it ended -
                # merged blocks keep the first one's time, because that is the
                # moment the reader is placing.
                $body0 = "$($b.Body)"
                if ("$($b.Kind)" -eq 'file') { $body0 = ('{0}   {1}' -f $b.Body, $b.Meta).TrimEnd() }
                # A run of notices is joined head-first, so the first one has to
                # be written the same way or the run reads ragged.
                if ("$($b.Kind)" -eq 'system') { $body0 = ('{0}   {1}' -f $b.Head, $b.Body).Trim() }
                $out.Add([PSCustomObject]@{ Kind = "$($b.Kind)"; Head = "$($b.Head)"; Body = $body0
                                            Calls = $null; When = $b.When; Count = 1 })
            }
            $i++
            continue
        }
        $calls = New-Object System.Collections.Generic.List[object]
        while ($i -lt $arr.Count -and ($arr[$i].Kind -eq 'tool' -or $arr[$i].Kind -eq 'result')) {
            if ($arr[$i].Kind -eq 'tool') {
                # Which of the three shapes this call is. A Task and a
                # backgrounded Bash each start something that outlives the call,
                # so they carry their own marker in the pane rather than being
                # one more grey row among the Reads.
                $cn = "$($arr[$i].Head)"
                $ck = 'run'
                if ($cn -eq 'Task') { $ck = 'agent' }
                elseif ($cn -eq 'Bash (background)') { $ck = 'shell' }
                elseif ($cn -eq 'SendMessage') { $ck = 'msgout' }
                $calls.Add([PSCustomObject]@{
                    Name = $cn; Arg = "$($arr[$i].Body)"; Res = ''; ResFull = ''; Bad = $false
                    # What a human wrote to say what this is FOR, as opposed to
                    # the prompt or the command, which is the Arg.
                    Desc = "$($arr[$i].Meta)"; CallKind = $ck; Shell = ''
                })
            } elseif ($calls.Count) {
                $last = $calls[$calls.Count - 1]
                if (-not $last.Res) {
                    $lines = @("$($arr[$i].Body)" -replace "`r", '' -split "`n" | Where-Object { $_.Trim() })
                    $one = "$(@($lines | Select-Object -First 1))"
                    if ($one.Length -gt 130) { $one = $one.Substring(0, 127) + [string][char]0x2026 }
                    $last.Res = $one
                    # 🔴 FOLDED KEEPS ITS ONE LINE; OPENED IS THE WHOLE THING.
                    #
                    # This was capped at the first 6 lines or 900 characters,
                    # and it is the single biggest reason the terminal showed
                    # more than this tool did: even with Steps: full, the view
                    # whose entire purpose is to show what ran was cutting the
                    # output off after six lines. There is no cap now. What
                    # keeps it manageable is the FOLD - a closed block is one
                    # summary line - and a scroll region around the open one, so
                    # a long result cannot push the conversation off screen.
                    #
                    # The RAW body, not the blank-stripped $lines: a result's
                    # own blank lines are part of how it reads.
                    $last.ResFull = ("$($arr[$i].Body)" -replace "`r", '').TrimEnd()
                    $last.Bad = ("$($arr[$i].Head)" -eq 'failed')
                    # 🔑 THE SHELL ID, OUT OF THE ANSWER'S OWN PROSE. A
                    # backgrounded Bash returns immediately with
                    #   "Command running in background with ID: beqvs0dpb."
                    # and that id is the ONLY link from the transcript to the
                    # file the shell is still writing. There is no structured
                    # field for it anywhere in the record - which is why a
                    # background shell looked unreadable until this line.
                    if ($last.CallKind -eq 'shell') {
                        $m = [regex]::Match("$($last.ResFull)", 'with\s+ID:\s*([A-Za-z0-9_-]{1,64})')
                        if ($m.Success) { $last.Shell = $m.Groups[1].Value }
                    }
                }
            }
            $i++
        }
        # .ToArray(), NEVER the List. @($someList) over a List[object] throws
        # "Argument types do not match" in PS 5.1, and PowerShell reports it
        # against whatever OUTER assignment started the chain - so the pane goes
        # blank and the error names a line four calls away. This codebase has
        # shipped that bug more than once; it cost six blank renders while this
        # very surface was being designed.
        if ($calls.Count) { $out.Add([PSCustomObject]@{ Kind = 'run'; Body = ''; Calls = $calls.ToArray() }) }
    }
    # A plain array, never comma-wrapped: wrapping makes @(f) a one-element
    # array holding everything, and an empty result becomes one phantom row.
    return $out.ToArray()
}

function Get-RunSummary { param($Calls)
    $names = @(@($Calls) | ForEach-Object { $_.Name } | Select-Object -Unique)
    $shown = @($names | Select-Object -First 3)
    $tail = ''
    if ($names.Count -gt $shown.Count) { $tail = '  +' + ($names.Count - $shown.Count) }
    $n = @($Calls).Count
    $word = 'steps'
    if ($n -eq 1) { $word = 'step' }
    return ('{0} {1}     {2}{3}' -f $n, $word, ($shown -join ('  ' + [string][char]0x00B7 + '  ')), $tail)
}

# THE MEASURE, from the LIVE pane width.
#
# It has to be recomputed, not stored: a fixed right padding is correct at one
# window size and wrong at every other, and this window is resizable and has
# adaptive breakpoints that change the pane width without the window moving.
# FlowDocument has no max-width, so the right PagePadding is the only lever -
# which is why it is arithmetic here rather than a property.
# 🔴 IT IS A CEILING, NOT A WIDTH, and that distinction is the whole of
# "the text was cut off half the screen although the screen was empty". The
# arithmetic below already grows the column with the pane and only starts
# holding it back once the pane is wider than this many characters - so the
# number was never a fixed column, it was the point at which growing stops.
# At 100 it stopped at ~780px, which is most of a laptop pane and half of a
# wide monitor: measured 806px pane -> 718px of text with the rest unused,
# and that 718px would not have moved on a 2560px screen.
#
# 125 is the ceiling now. Past roughly this the eye starts losing the start of
# the next line on the way back from the end of the last, which is the
# complaint that put a cap here in the first place - so it is raised, not
# removed. `readingWidth: full` in the config still takes the cap off entirely.
$script:ReadMeasureChars = 125
# The size the last layout settled on. The renderer reads it rather than a
# literal, so type and measure can never disagree about how wide a line is.
# 🪤 THESE TWO ARE SET BY Set-SRTypeScale AND ARE ONLY DECLARED HERE. They used
# to be the definition - a literal 12.0 - and a second literal 12.0 inside
# Set-ReadMeasure quietly overrode it on every layout, so changing the size here
# did nothing at all. The scale owns them now; assigning a number to either of
# them anywhere else is the bug, not the fix.
$script:readSize = $script:Type.Pane
$script:readLead = [Math]::Round($script:Type.Pane * $SR_LeadFactor, 1)

# THE GUTTER, in device-independent pixels.
#
# Wide enough for one marker glyph plus the space after it, and it is the SAME
# number for a flowed paragraph's hanging indent and for a rail block's first
# Grid column - so a paragraph of prose and a block of machine output start
# their text at exactly the same x. That is the whole point of the column, and
# two numbers that were meant to be equal would drift the first time one moved.
#
# 🪤 DECLARED HERE, OWNED BY Set-SRTypeScale. The base is $SR_GutterBase and the
# live value zooms with the type; writing a literal back into this variable is
# how the zoom would stop reaching the gutter while everything around it moved.
$script:GutterW = [Math]::Round($SR_GutterBase * ($script:Zoom / 100.0), 1)

# THE SIZE MACHINE TEXT IS SET AT - commands, their output, fenced code.
#
# 🔴 IT WAS 16, TO MATCH WINDOWS TERMINAL'S 12pt EXACTLY, AND MATCHING THE
# NOMINAL NUMBER WAS THE MISTAKE. Two faces at the same nominal size are not the
# same size on screen; what the eye reads is the x-height. Measured here:
# Manrope 0.540 em, Cascadia Mono 0.518. So Cascadia at 16 drew an 8.28px
# x-height beside prose with a 6.48px one - machine text 28% LARGER than the
# words around it, on a surface whose whole job is telling the two voices apart.
# That is most of "the text is not uniform in size", and the terminal parity it
# bought was invisible anyway, because nothing else in the pane is at terminal
# scale.
#
# 🔴 AND THEN X-HEIGHT PARITY TURNED OUT TO BE THE WRONG TARGET TOO. Mono at
# 12.5 against a 12 body put the two within a tenth of a pixel of each other -
# machine text exactly as prominent as prose. Tool traffic outnumbers prose five
# to one here, so "exactly as prominent" means the pane is five-sixths machine
# text at full strength, which is what a terminal looks like. Reported as
# "either too terminal-like or something else has happened".
#
# The answer was not a third ratio. It is ONE size for every category, in one
# humanist face - so this is Pane, the same number readSize holds, and the two
# can no longer disagree. It still moves with the zoom.
$script:MonoSize = $script:Type.Pane

# 🔴 THE MARKER TABLE - ONE ROW PER BLOCK KIND, AND EVERY KIND HAS ONE.
#
# Category has to be legible BEFORE the words are, which is the thing a terminal
# does and this pane did not: prose, a command, a hook and a notice all arrived
# as differently-shaped cards and you had to read one to know which it was.
#
# 🪤 GLYPHS ARE CHAR CODES, NEVER LITERALS. PowerShell 5.1 reads a BOM-less
# UTF-8 file as ANSI, so a literal marker here would reach the screen as two
# mojibake characters - the same trap that made the group headers read
# "93 A- 9 armed". CONTEXT.md records it; this table is exactly where it would
# happen again.
# 🔴 THE HUE COLUMN NOW ANSWERS ONE QUESTION: is this you, another session,
# the machine, or something waiting on you. It used to answer three at once -
# see the note on the palette in window2.xaml. Every machine kind points at
# `Tool` and is told apart by its GLYPH, which is what the note below already
# said should be carrying the difference. `said` has no hue at all: Claude's
# reply is the document's default voice, and a voice that is everywhere does
# not need marking.
# 🔴 ONE SHAPE, COLOUR ONLY - THE OPERATOR'S CALL, AND IT REVERSES THE NOTE
# THAT USED TO BE HERE. This table gave every kind its own glyph on the
# reasoning that "every kind is meant to be distinct BEFORE you read it, so the
# shape carries the difference and the hue reinforces it". Asked what he wanted
# after living with it: "I like that we have the messages trailing with a little
# dot on the left side, and maybe we can just simply adopt that and do not use
# any different shapes or styles just different colours".
#
# 🪤 THE CATEGORY IS NOT LOST, BECAUSE IT WAS NEVER ONLY IN THE GLYPH. Every
# machine block is a FOLD whose caption names it in capitals - HOOK, NOTICE,
# THINKING, QUEUED, `3 STEPS`, the run summary - sitting at the text column two
# characters from the marker. The glyph was saying a second time what the words
# already said. What is left for hue to carry is the three things words do not:
# whether this is you, another session, or the machine.
#
# 🪤 GLYPH IS STILL A CHAR CODE, NEVER A LITERAL. PowerShell 5.1 reads a
# BOM-less UTF-8 file as ANSI, so a literal dot here would reach the screen as
# two mojibake characters - the trap that made the group headers read
# "93 A- 9 armed". One code, sixteen rows, and it stays a code.
$SR_MarkDot = 0x25CF
$SR_Marks = @{
    said     = @{ G = $SR_MarkDot; H = 'TextMid' }  # claude speaking
    you      = @{ G = $SR_MarkDot; H = 'Out'     }  # you said
    thinking = @{ G = $SR_MarkDot; H = 'Tool'    }  # thinking
    run      = @{ G = $SR_MarkDot; H = 'Tool'    }  # a tool call
    result   = @{ G = $SR_MarkDot; H = 'Tool'    }  # its result
    system   = @{ G = $SR_MarkDot; H = 'Tool'    }  # a notice
    hook     = @{ G = $SR_MarkDot; H = 'Tool'    }  # a hook fired
    file     = @{ G = $SR_MarkDot; H = 'Tool'    }  # files re-read
    asked    = @{ G = $SR_MarkDot; H = 'Ask'     }  # you answered
    queued   = @{ G = $SR_MarkDot; H = 'Out'     }  # queued input
    compact  = @{ G = $SR_MarkDot; H = 'Tool'    }  # the break
    agent    = @{ G = $SR_MarkDot; H = 'Tool'    }  # a sub-agent
    shell    = @{ G = $SR_MarkDot; H = 'Tool'    }  # a background shell
    msgin    = @{ G = $SR_MarkDot; H = 'In'      }  # a message arrived
    msgout   = @{ G = $SR_MarkDot; H = 'In'      }  # a message sent
}

function Get-MarkGlyph { param([string]$Kind)
    $m = $SR_Marks["$Kind"]
    if (-not $m) { return ' ' }
    return [string][char]$m.G
}

function Get-MarkBrush { param([string]$Kind)
    $m = $SR_Marks["$Kind"]
    if (-not $m) { return $Pal.TextLow }
    return $Pal[$m.H]
}

# WHAT A FOLDED BLOCK SAYS ABOUT ITSELF: its first line of real content, so the
# summary names what the block is about rather than only counting it. "16
# NOTICES" tells you how much; "16 NOTICES  Remote Control disconnected" tells
# you whether to open it.
# 🪤 -Plain FOR A BODY THAT IS AN ENVELOPE. A machine record arrives wrapped -
# <task-notification>, <system-reminder>, <local-command-caveat> - and the
# summary line is one line of prose, not markup. Without this the fold caption
# read "NOTICE  <local-command-caveat>Caveat: The messages below were...", which
# spends the only line you get before opening the block on a tag name.
#
# 🪤 THE TAGS COME OFF THE PREVIEW ONLY. The block still carries its full text,
# because opening a notice should show what actually arrived rather than an
# edited version of it.
$script:SR_RxAnyTag = [regex]::new('</?[a-zA-Z][a-zA-Z0-9-]*[^>]*>')
function Get-SRHeadLine { param([string]$Text, [int]$Max = 88, [switch]$Plain)
    if ($Plain -and $Text) { $Text = $script:SR_RxAnyTag.Replace($Text, ' ') }
    $head = @("$Text" -replace "`r", '' -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1) -join ' '
    $head = "$head".Trim()
    if ($head.Length -gt $Max) { $head = $head.Substring(0, $Max - 1) + [string][char]0x2026 }
    return $head
}

# 🔴 THE MARKER IS A FIXED-WIDTH BOX, NOT A CHARACTER FOLLOWED BY SPACES.
#
# Prose in this pane is set in a PROPORTIONAL face - Segoe UI Variable, the
# operator's choice and deliberately not a terminal font - so nothing about a
# glyph's advance can be counted on. A marker padded with spaces would land the
# text at a different x on every block, which is the exact failure the gutter
# exists to prevent. An InlineUIContainer holding a TextBlock of a KNOWN width
# is the only way to get a guaranteed column inside flowed text.
# 🪤 THE HOSTED ELEMENT IS NOT THE COST, AND IT WAS MY FIRST GUESS. Swapping it
# for a plain monospaced Run was A/B'd twice and measured 4 ms and -21 ms of a
# ~150 ms rebuild - noise both times, once favouring each side. So it stays, on
# the evidence, because it is the only construction that guarantees the column
# is exactly GutterW wide under a PROPORTIONAL prose face. Knuth-Plass line
# breaking measured the same way and is also staying.
function New-GutterMark { param([string]$Glyph, $Brush, [double]$Size = 0)
    if ($Size -le 0) { $Size = $script:PaneSize }
    $tb = [System.Windows.Controls.TextBlock]::new()
    $tb.Text = $Glyph
    $tb.Width = $script:GutterW
    $tb.Foreground = $Brush
    $tb.FontSize = $Size
    $tb.FontFamily = $script:PaneFace
    $tb.TextAlignment = 'Left'
    $iuc = New-Object System.Windows.Documents.InlineUIContainer $tb
    $iuc.BaselineAlignment = 'Baseline'
    return $iuc
}

# A FLOWED PARAGRAPH THAT HANGS OFF THE GUTTER. The negative TextIndent pulls
# the first line back by exactly one gutter so the marker sits in it, and the
# left margin holds every CONTINUATION line at the text column. That is what
# makes a wrapped paragraph line up under itself instead of under its own
# marker - and it is why wrapping and the gutter had to be built together.
function New-GutterPara {
    param([string]$Kind, [double]$Top = 0, [double]$Bottom = 0, [double]$Indent = 0,
          [double]$Line = 0, [switch]$NoMark)
    $p = New-Object System.Windows.Documents.Paragraph
    $p.Margin = New-Object System.Windows.Thickness ($Indent + $script:GutterW), $Top, 0, $Bottom
    $p.TextIndent = -$script:GutterW
    if ($Line -gt 0) { $p.LineHeight = $Line; $p.LineStackingStrategy = 'BlockLineHeight' }
    if ($NoMark) {
        # A continuation paragraph inside one turn: it keeps the indent so it
        # aligns, and shows no marker because the turn already has one.
        #
        # 🔴 IT USED TO HOST A BLANK BOX HERE - "a space is proportional and
        # would not be a gutter", which is true of a SPACE and not of what the
        # box was doing. The box existed to occupy the width the negative
        # TextIndent pulls the first line back over. Not pulling it back leaves
        # the text at Margin.Left, which is already Indent + GutterW: the same
        # column, with no UIElement built for it. 0.85 ms per paragraph.
        $p.TextIndent = 0
    } else {
        $p.Inlines.Add((New-GutterMark -Glyph (Get-MarkGlyph $Kind) -Brush (Get-MarkBrush $Kind)))
    }
    return $p
}

# THE SAME COLUMN, FOR A BLOCK THAT IS CONTROLS RATHER THAN TEXT.
#
# Machine output, a fold header, a sub-agent - these are panels, not paragraphs,
# so they cannot hang off a TextIndent. A two-column Grid whose first column is
# GutterW wide puts them on precisely the same x as the prose above them, and
# the optional rail draws the vertical line down the gutter that says "all of
# this belongs to that marker".
function New-RailBlock {
    param($Child, [string]$Kind, [double]$Top = 8, [double]$Bottom = 8,
          [double]$Indent = 0, [switch]$Rail, $Brush)
    if (-not $Brush) { $Brush = Get-MarkBrush $Kind }
    # 🔴 ONE GRID, NOT TWO. Measured at 1.7 ms a block, which is a lot when a
    # document is dozens of them and the whole thing is rebuilt whenever the
    # transcript grows. The inner Grid existed only to stack the marker above
    # the rail; a rail with a top margin that clears the marker does the same
    # thing in one element instead of four (Grid + 2 RowDefinitions + layout).
    #
    # 🪤 `::new()` RATHER THAN `New-Object` throughout. New-Object goes through
    # PowerShell's command pipeline - parameter binding, a cmdlet invocation -
    # for what is a constructor call, and in a builder that runs hundreds of
    # times per rebuild that overhead is most of the cost. Same objects, same
    # arguments.
    $g = [System.Windows.Controls.Grid]::new()
    $c0 = [System.Windows.Controls.ColumnDefinition]::new()
    $c0.Width = [System.Windows.GridLength]::new($script:GutterW)
    $c1 = [System.Windows.Controls.ColumnDefinition]::new()
    $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $null = $g.ColumnDefinitions.Add($c0)
    $null = $g.ColumnDefinitions.Add($c1)

    $mk = [System.Windows.Controls.TextBlock]::new()
    $mk.Text = (Get-MarkGlyph $Kind)
    $mk.Foreground = $Brush
    $mk.FontSize = $script:PaneSize
    $mk.FontFamily = $script:PaneFace
    $mk.VerticalAlignment = 'Top'
    $null = $g.Children.Add($mk)

    if ($Rail) {
        # 1px, and tinted rather than the full hue: a rail you notice instead of
        # read would compete with the marker it hangs from. 0.28 was invisible
        # in review at 100% - the line was being drawn and could not be seen,
        # which is the same as not drawing it. The top margin is what clears the
        # marker glyph now that they share a cell.
        $ln = [System.Windows.Shapes.Rectangle]::new()
        $ln.Width = 1
        $ln.HorizontalAlignment = 'Left'
        $ln.VerticalAlignment = 'Stretch'
        # 🪤 THE CLEARANCE IS THE MARKER'S HEIGHT, so it has to scale with it.
        # A fixed 17 was tuned against Caption at 100% and, at 150%, left the
        # rail starting part-way up a marker that had grown past it.
        $ln.Margin = [System.Windows.Thickness]::new(3, [Math]::Round($script:PaneSize * 1.3, 1), 0, 2)
        $ln.Fill = (New-SRTint $Brush 0.5)
        $null = $g.Children.Add($ln)
    }

    [System.Windows.Controls.Grid]::SetColumn($Child, 1)
    $null = $g.Children.Add($Child)

    $bc = [System.Windows.Documents.BlockUIContainer]::new($g)
    $bc.Margin = [System.Windows.Thickness]::new($Indent, $Top, 0, $Bottom)
    return $bc
}

# ===========================================================================
# FOLDS THAT ARE ACTUALLY FOLDS
#
# 🔴 The old ones were a LABEL and a GLOBAL SWITCH, and the two together were
# the defect: "16 NOTICES" looked like something you could open, and the only
# control was `Steps: full`, which opened every block in the document at once.
# With it set, that caption was followed by all sixteen notices in full - a
# fold that folds nothing, reported as "although folded I see it is fully
# shown".
#
# Now each block owns its own state and its own caret, and `Steps` supplies
# only the DEFAULT. Two rules make this affordable:
#
#   LAZY - a closed block builds its summary line and nothing else. The
#   content is constructed the first time it is opened and then kept, so
#   selecting a conversation costs the same whether its results are six lines
#   or six thousand.
#
#   BOUNDED - an open block scrolls inside its own region rather than growing
#   the document, so opening one thing never pushes everything else away.
#
# State rides on the header's Tag as plain data, and ONE shared handler reads
# it. A per-block closure would capture the loop variable by reference - every
# header in the document would end up building the last turn's content, which
# is a trap this codebase has walked into with `foreach` scoping before.
$script:FoldMaxHeight = 460.0

function Build-FoldContent { param([string]$Kind, $Data, $Panel)
    switch ($Kind) {
        'run'    { Add-RunDetail    -Panel $Panel -Calls $Data }
        'text'   { Add-MonoDetail   -Panel $Panel -Text  $Data }
        default  { Add-MonoDetail   -Panel $Panel -Text  "$Data" }
    }
}

function Invoke-FoldToggle { param($Header)
    $st = $Header.Tag
    if (-not $st) { return }
    if (-not $st.Built) {
        Build-FoldContent -Kind $st.Kind -Data $st.Data -Panel $st.Panel
        $st.Built = $true
    }
    $st.Open = -not $st.Open
    $st.Panel.Visibility = $(if ($st.Open) { $V_Show } else { $V_Hide })
    $st.Caret.Text = [string][char]$(if ($st.Open) { 0x25BE } else { 0x25B8 })
}

# The clickable summary line. It is a Border rather than a Button so it carries
# no chrome at all - this pane has none anywhere now - but it still takes a
# click, shows a hand, and says what it does.
function New-FoldHeader {
    param([string]$Caption, $Brush, [string]$Kind, $Data, $Panel, [bool]$Open,
          [string]$Trailing = '')
    $bd = New-Object System.Windows.Controls.Border
    $bd.Background = [System.Windows.Media.Brushes]::Transparent
    $bd.Cursor = 'Hand'
    $bd.Padding = New-Object System.Windows.Thickness 0, 1, 0, 2
    $bd.ToolTip = 'Click to open or close this block'
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'

    $car = New-Object System.Windows.Controls.TextBlock
    $car.Text = [string][char]$(if ($Open) { 0x25BE } else { 0x25B8 })
    $car.Foreground = $Brush
    $car.FontSize = $script:PaneSize
    $car.FontFamily = $script:PaneFace
    $car.VerticalAlignment = 'Center'
    # 🔴 THE CARET HANGS IN THE GUTTER, so a fold caption starts on exactly the x
    # every line of prose starts on. It sat INSIDE the text column and pushed
    # its caption ~16px right of everything above and below it - so every
    # foldable block in the document was the one thing not aligned with the
    # rest. Reported as "we need to make the text all aligned".
    #
    # 🪤 THE WIDTH IS FIXED AND THE MARGIN IS DERIVED FROM IT. A glyph's advance
    # moves with the face and with the zoom, so a hand-tuned negative margin
    # would be right at 100% on one font and wrong at every other size.
    # -(w + gap), then the caret's own w, then gap, nets to exactly zero.
    #
    # 🪤 IT SHARES THE GUTTER WITH THE CATEGORY MARKER, so it is sized to fit
    # BESIDE one rather than on top of it: the marker sits at the left of a
    # 22px gutter and the caret is pulled flush to the right of it.
    $carW = [Math]::Round($script:PaneSize * 0.70, 1)
    $carGap = 3.0
    $car.Width = $carW
    $car.TextAlignment = 'Left'
    $car.Margin = New-Object System.Windows.Thickness (-($carW + $carGap)), 0, $carGap, 0
    $null = $sp.Children.Add($car)

    $cap = New-Object System.Windows.Controls.TextBlock
    $cap.Text = "$Caption".ToUpper()
    $cap.Foreground = $Brush
    $cap.FontSize = $script:PaneSize
    # 🪤 THE CAPTION IS A LABEL, THE CARET ABOVE IT IS A GLYPH. The caret keeps
    # the pane face because it sits in a fixed column with the gutter marks and
    # has to line up with them; the caption is words and reads as words.
    $cap.FontFamily = $script:ProseFace
    $cap.VerticalAlignment = 'Center'
    $null = $sp.Children.Add($cap)

    if ($Trailing) {
        $tr = New-Object System.Windows.Controls.TextBlock
        $tr.Text = $Trailing
        $tr.Foreground = $Pal.TextDim
        $tr.FontSize = $script:PaneSize
        $tr.FontFamily = $script:ProseFace
        $tr.VerticalAlignment = 'Center'
        $tr.TextTrimming = 'CharacterEllipsis'
        $tr.Margin = New-Object System.Windows.Thickness 10, 0, 0, 0
        $null = $sp.Children.Add($tr)
    }

    $bd.Child = $sp
    $bd.Tag = @{ Kind = $Kind; Data = $Data; Panel = $Panel; Built = $false
                 Open = $false; Caret = $car }
    # 🔴 PreviewMouseLeftButtonDown, NOT MouseLeftButtonUp - AND THIS BLOCK NEVER
    # OPENED FOR AS LONG AS IT HAS EXISTED. Reported as "clicking a foldable
    # block does nothing", and it was every one of them: tool runs, THINKING,
    # QUEUED, HOOK, NOTICES.
    #
    # 🔑 THE VIEWER TAKES THE MOUSE BEFORE THIS BORDER SEES IT. These headers sit
    # in a BlockUIContainer inside PaneDoc, a FlowDocumentScrollViewer with
    # IsSelectionEnabled="True" - and with selection on, its TextEditor handles
    # MouseLeftButtonDown and CAPTURES the mouse. The matching Up is then
    # delivered to the capture target, so an Up-only handler on an element inside
    # a selectable FlowDocument can never fire. Handling the DOWN gets there
    # first; $e.Handled stops the editor starting a selection drag from it.
    #
    # 🪤 REPLACED, NOT ADDED BESIDE. Wiring both would toggle twice on one click,
    # which looks exactly like the bug that was just fixed.
    #
    # Losing text-selection that starts on the header is correct: it is a button,
    # not prose. Same shape as the band heading in the sessions list, which uses
    # Preview for the same reason - an outer layer claiming button-down first.
    $bd.Add_PreviewMouseLeftButtonDown({ param($s, $e) Invoke-FoldToggle $s; $e.Handled = $true })
    return $bd
}

# A foldable block, assembled: header, then the content panel under it. Returns
# the outer StackPanel so the caller can drop it into a rail.
function New-FoldPanel {
    param([string]$Caption, $Brush, [string]$Kind, $Data, [string]$Trailing = '',
          [bool]$Open = $false)
    $outer = New-Object System.Windows.Controls.StackPanel
    $inner = New-Object System.Windows.Controls.StackPanel
    $inner.Margin = New-Object System.Windows.Thickness 0, 7, 0, 0
    $inner.Visibility = $V_Hide
    $hd = New-FoldHeader -Caption $Caption -Brush $Brush -Kind $Kind -Data $Data `
                         -Panel $inner -Open:$false -Trailing $Trailing
    $null = $outer.Children.Add($hd)
    $null = $outer.Children.Add($inner)
    # Opening it here rather than by setting flags means the OPEN path is the
    # same code the click takes - a default that rendered through a second path
    # is a default that can disagree with the control.
    if ($Open) { Invoke-FoldToggle $hd }
    return $outer
}

# HOW A LONG PIECE OF MACHINE TEXT IS BOUNDED.
#
# Something has to stop a 4,000-line result becoming 4,000 lines of document
# with everything below it unreachable. A ScrollViewer does that AND keeps the
# text reachable - but a nested scrolling container is measured at unbounded
# height and then clipped, which is real layout work, and there is one per
# result. $script:NoInnerScroll is the A/B: same bound, no nested scroller.
#
# 🪤 A nested ScrollViewer also EATS THE MOUSE WHEEL - see the handler below,
# which is the actual defect behind "scrolling lags". Removing the scroller
# entirely was A/B'd and measured as noise (-58 ms on a 355 ms rebuild, i.e. the
# version WITH it read faster), so it stays and the wheel is fixed instead.
# SHELL BLOCKS THAT ARE OPEN, AND ONLY THOSE.
#
# A background shell keeps writing its .output file, so a block opened while it
# runs goes stale the moment it is drawn. These are the ones on screen with
# their content built; the follow tick re-reads them. Cleared on a full rebuild,
# because the controls registered here are then orphaned - the append path does
# NOT clear it, which is right: those controls are still the ones on screen.
$script:liveShells = New-Object System.Collections.Generic.List[object]

function Register-LiveShell { param($Label, $Body, $Panel, [string]$Shell, [string]$Session)
    if (-not $Shell -or -not $Session) { return }
    $script:liveShells.Add(@{ Label = $Label; Body = $Body; Panel = $Panel; Shell = $Shell; Session = $Session })
}

# ===========================================================================
# THE PINNED LIST OF WHAT IS RUNNING BEHIND THE SELECTED CONVERSATION.
#
# 🔴 THE COST OF THIS IS THE WHOLE DESIGN. Get-SRLiveTasks parses up to 24 MB
# of JSONL - measured at 273 ms on an 11 MB transcript - and its cache is keyed
# on the transcript's size and mtime, which on a LIVE session changes every time
# it writes. So calling it from the one-second tick would miss the cache every
# time and re-parse megabytes ON THE UI THREAD once a second. That is exactly
# the defect the chip clock already carries a comment about, and it is the
# defect the operator reported as lag.
#
# Three gates, cheapest first:
#   1. The status line already counts shells, for free, on the sweep. Zero means
#      there is nothing to list and nothing is read at all - the common case,
#      and it costs one integer compare.
#   2. A re-parse only when the ANSWER could have changed: a different
#      conversation, a different count, or $SR_ShellRescan seconds have passed.
#   3. The OUTPUT refresh is not the parse. It is one small file read per shell
#      and it runs every tick, because a shell that is quiet for five seconds is
#      the one you are actually watching.
$SR_ShellRescan = 8
$script:shellFor = ''
$script:shellAt = $null
$script:shellCount = -1
$script:shellList = @()
$script:shellHidden = $false

# ===========================================================================
# THE LIVE SCREEN - for the one state the transcript cannot describe
# ===========================================================================
# 🔴 A COMPACT WRITES NOTHING UNTIL IT IS DONE. The compact_boundary record and
# its compactMetadata are written at the END, so Get-SRConversationState can
# only report 'summarising' once there is nothing left to watch. For the thirty
# to ninety seconds it actually runs, a transcript reader has no bytes at all -
# which is exactly the reported "I do not see the progress of what is happening
# when I compact something".
#
# So this does not read the transcript. It reads the session's SCREEN, the same
# way the question probe does, and draws it where the transcript would be.
#
# 🪤 TWO SIGNALS, AND THE WEAKER ONE IS THE OBVIOUS ONE. 'summarising' off the
# transcript is true only at the finish; what covers the gap is knowing we SENT
# /compact and it has not come back yet. Both are honoured, because the operator
# can also type /compact in the terminal, where this window never saw it.
$SR_LiveRead     = 2      # seconds between screen reads - it is a child process
$SR_CompactWatch = 420    # stop watching after seven minutes, whatever happened
$script:compactSent = @{}
$script:liveAt  = $null
$script:liveFor = ''
$script:liveTxt = ''

function Test-SRCompacting { param($R)
    if (-not $R) { return $false }
    $id = "$($R.Id)"
    if ($script:compactSent.ContainsKey($id)) {
        $age = ((Get-Date) - $script:compactSent[$id]).TotalSeconds
        if ($age -ge $SR_CompactWatch) { $script:compactSent.Remove($id); return $false }
        # 🪤 THE 12-SECOND FLOOR IS LOAD-BEARING. /compact is typed into the
        # terminal and takes a moment to be picked up, so for the first few
        # seconds the session is still 'waiting' and the transcript still says
        # whatever it said before - which looks exactly like "finished" and
        # would close this panel before it ever drew.
        if ($age -gt 12 -and "$($R.A.Status)" -ne 'busy' -and "$($R.Conv.State)" -ne 'summarising') {
            $script:compactSent.Remove($id); return $false
        }
        return $true
    }
    # 🪤 $R.Conv.State, NOT $R.D.State. D is the DIRECTORY object a row belongs
    # to and has no State at all, so this branch read an empty string and could
    # never fire - a compact typed straight into the terminal was invisible here
    # for exactly as long as the code looked correct. Get-Band:770 is the
    # authority on where a row's state lives.
    #
    # 🔴 AND THE TEST DID NOT CATCH IT, IT ENCODED IT: the fixtures were
    # hand-built with a D property shaped the way this function expected, so
    # they proved the two agreed with each other and nothing about the rows the
    # window actually holds. They are built from Conv now.
    return ("$($R.Conv.State)" -eq 'summarising')
}

function Update-LivePane {
    # -Row is for the tests: it lets the SHOWING path be exercised against a
    # made-up row with a pid that does not exist, so the visibility switch is
    # covered without pointing a screen probe at one of the operator's real
    # conversations. Live callers pass nothing and get the selection.
    param($Row)
    $r = $Row
    if (-not $r) {
        $it = $ui.SessionList.SelectedItem
        if ($it -and $it.Kind -eq 'session') { $r = $it.Row }
    }

    $want = $false
    if ($r -and $r.A -and $r.A.Pid) { $want = (Test-SRCompacting $r) }

    if (-not $want) {
        if ("$($ui.LivePane.Visibility)" -ne 'Collapsed') {
            $ui.LivePane.Visibility = $V_Hide
            $ui.PaneDoc.Visibility  = $V_Show
            $script:liveFor = ''; $script:liveTxt = ''; $script:liveAt = $null
        }
        return
    }

    $id  = "$($r.Id)"
    $now = Get-Date
    # Throttled: every read is a child process against a 6-second budget, and
    # the thing being watched changes about once a second.
    $stale = ($script:liveFor -ne $id) -or (-not $script:liveAt) -or
             (($now - $script:liveAt).TotalSeconds -ge $SR_LiveRead)
    if ($stale) {
        if ($script:liveFor -ne $id) { $script:liveTxt = '' }
        $script:liveFor = $id
        $script:liveAt  = $now
        $got = ''
        try { $got = Get-SRScreenText -ProcessId ([int]$r.A.Pid) } catch { $got = '' }
        # 🪤 KEEP THE LAST GOOD SCREEN. A read can miss - the budget is short and
        # the child can lose a race - and blanking the panel on a miss makes the
        # one thing you are watching flicker in and out.
        if ("$got".Trim()) { $script:liveTxt = $got }
    }

    $body = ''
    if ("$($script:liveTxt)".Trim()) {
        $lines = @("$($script:liveTxt)" -replace "`r", '' -split "`n")
        # A console screen is padded to its full height with blanks; showing
        # them would put the spinner at the top of an empty box.
        $end = $lines.Count - 1
        while ($end -ge 0 -and -not "$($lines[$end])".Trim()) { $end-- }
        if ($end -ge 0) {
            $start = [Math]::Max(0, $end - 26)
            $body = (($lines[$start..$end]) -join "`n")
        }
    }
    if (-not $body) { $body = 'reading this session''s screen...' }

    $ui.LiveText.Text = $body
    $who = ''
    try { $who = "$((Get-Title $r.S $r.D).Text)" } catch { $who = '' }
    $ui.LiveHead.Text = ('COMPACTING' + $(if ($who) { '   ' + $who } else { '' }))
    $ui.LivePane.Visibility = $V_Show
    $ui.PaneDoc.Visibility  = $V_Hide
    $ui.PaneEmpty.Visibility = $V_Hide
}

# WHEN A HIDDEN SHELL PANEL COMES BACK. Extracted for the same reason
# Test-SRQueueFresh and Test-SRTypingTarget were: the decision is four operators
# and a promise made in a tooltip, and the function around it cannot be called
# in a test without reading a live conversation off the disk. One call per tick,
# so the invocation cost that mattered for the per-row queue check does not
# apply here.
function Test-SRShellReveal {
    param([string]$For, [string]$Id, [int]$Was, [int]$Now)
    if ($For -ne $Id) { return $true }     # a different conversation entirely
    return ($Now -gt $Was)                 # or something NEW started in this one
}

function Update-ShellPanel {
    $id = ''
    $jsonl = ''
    $n = 0
    $it = $ui.SessionList.SelectedItem
    if ($it -and $it.Kind -eq 'session') {
        $id = "$($it.Row.Id)"
        $jsonl = "$($it.Row.S.jsonl)"
        # The same numbers the marks on the row are drawn from, so the panel and
        # the marks can no longer disagree about whether anything is running.
        # Agents count too: the operator asked for sub-agent sessions to be no
        # less visible than shells, and a running one had no view at all.
        if ($script:chipVitals) {
            try { $n = [int]$script:chipVitals.Shells } catch { $n = 0 }
            try { $a = [int]$script:chipVitals.Agents; if ($a -gt 0) { $n += $a } } catch { }
        }
    }

    if (-not $id -or $n -le 0) {
        if ($script:shellList.Count -or $script:shellFor) {
            $script:shellFor = ''; $script:shellList = @(); $script:shellCount = -1
            $ui.ShellList.ItemsSource = $null
            $ui.ShellBox.Visibility = 'Collapsed'
        }
        return
    }

    $stale = ($script:shellFor -ne $id) -or ($script:shellCount -ne $n) -or
             (-not $script:shellAt) -or (((Get-Date) - $script:shellAt).TotalSeconds -ge $SR_ShellRescan)
    # 🔴 THE BUTTON PROMISED A RECOVERY THAT WAS NEVER WRITTEN. Both the tooltip
    # ("It comes back on its own when another shell starts") and the comment at
    # the handler said this clears on a change of conversation OR on a new set
    # of shells. Only the first half existed. A new shell in the SAME
    # conversation changes $n, not $id - so it made $stale true, re-read the
    # list, and was then collapsed again nine lines below and the fresh list
    # thrown away. One press of `hide` and the panel was gone for that
    # conversation through any number of new shells and sub-agents.
    #
    # 🪤 IT LOOKED INTERMITTENT, WHICH IS WHY IT SURVIVED. If every shell stops
    # first, the `-not $id -or $n -le 0` branch above resets $script:shellFor,
    # so the next shell DOES revive the panel. Hide it while something is still
    # running and it stays hidden; hide it after everything finishes and it
    # comes back. Same symptom, opposite outcomes, no pattern to report.
    #
    # 🪤 A COUNT THAT ROSE, NOT A COUNT THAT CHANGED. A shell FINISHING also
    # changes $n, and un-hiding the panel because something stopped would be a
    # second wrong promise. $script:shellCount still holds the previous count
    # here - it is not updated until the $stale block below.
    if (Test-SRShellReveal -For $script:shellFor -Id $id -Was $script:shellCount -Now $n) { $script:shellHidden = $false }
    if ($stale) {
        $got = @()
        try { $got = @(Get-SRLiveTasks -JsonlPath $jsonl) } catch { $got = @() }
        $script:shellList = $got
        $script:shellFor = $id
        $script:shellCount = $n
        $script:shellAt = Get-Date
    }
    if ($script:shellHidden) { $ui.ShellBox.Visibility = 'Collapsed'; return }

    # 🪤 THE COUNT IN THE HEADING IS THE STATUS LINE'S, NOT THIS LIST'S LENGTH.
    # They can differ honestly: a shell launched before the 24 MB window opened
    # is running and unnamed. Saying "2 running" and listing one is truthful;
    # silently listing one and calling it the total is not.
    $rows = @()
    foreach ($s in $script:shellList) {
        $out = ''
        $isAgent = ("$($s.Kind)" -eq 'agent')
        try {
            if ($isAgent) {
                # An agent has no .output file - it writes a TRANSCRIPT, and the
                # last thing it said there is the equivalent of a shell's last
                # printed line.
                $out = Get-SRAgentLastLine -JsonlPath $jsonl -AgentId "$($s.Shell)"
                if (-not $out) { $out = 'starting' }
            } else {
                $p = Get-SRShellOutputPath -SessionId $id -Shell "$($s.Shell)"
                if ($p) {
                    # A small tail: this is a one-line preview, not the log.
                    $o = Get-SRShellOutput -Path $p -MaxBytes 4096
                    if ($o) {
                        $ls = @("$($o.Text)" -split "`n" | Where-Object { $_.Trim() })
                        if ($ls.Count) { $out = $ls[-1].Trim() }
                    }
                }
            }
        } catch { }
        # How long it has been running, not when it started: the useful question
        # about a background shell is whether it is taking too long. The launch
        # timestamp is parsed as UTC, so the subtraction is too.
        $age = ''
        if ($s.At) {
            try { $age = Format-Clock (([datetime]::UtcNow - ([datetime]$s.At)).TotalSeconds) } catch { }
        }
        $cmd = (Compress-SRPath ("$($s.Command)" -replace '\s+', ' ')).Trim()
        $desc = "$($s.Desc)".Trim()
        if (-not $desc) { $desc = $s.Shell }
        $rows += [PSCustomObject]@{
            # 🔴 THE ROW CARRIED NOTHING THAT IDENTIFIED IT. Every field on it
            # was for display, so even once the template grew a Cursor="Hand"
            # there was nothing a handler could have acted on. These two are
            # what make the click possible; see Open-SRShellRow.
            ShId     = "$($s.Shell)"
            ShIsAgent = $isAgent
            ShDesc   = $desc
            # An agent's "command" is the kind of agent it is, which is the
            # nearest thing it has to one and the thing you actually want to
            # read beside the task it was given.
            ShCmd    = $(if ($isAgent -and $cmd) { '@' + $cmd } else { $cmd })
            ShOut    = $out
            ShOutVis = $(if ($out) { 'Visible' } else { 'Collapsed' })
            ShAge    = $age
            # 🪤 A ROUND MARK IS A SUB-AGENT AND A SQUARE ONE IS MACHINERY. That
            # convention is already what the row marks and the reading pane use,
            # and it is the one thing the operator can read here at a glance.
            ShMark   = $(if ($isAgent) { [string][char]0x25CF } else { [string][char]0x25A0 })
            ShTip    = $(if ($isAgent) {
                            "{0}`n`nsub-agent {1}, id {2}`n`nits own transcript is in subagents\agent-{2}.jsonl - select it in the list to read the whole thing" -f $desc, $cmd, $s.Shell
                        } else {
                            "{0}`n`n{1}`n`nshell {2} - output in %TEMP%\claude\...\tasks\{2}.output" -f $desc, $cmd, $s.Shell
                        })
        }
    }
    $ui.ShellList.ItemsSource = $rows
    # 🪤 THE HEADING COUNTS WHAT THE STATUS LINE SAYS, and names the two kinds
    # separately because they mean different things to the person reading: a
    # shell is machinery you wait for, an agent is work someone else is doing.
    $nsh = @($rows | Where-Object { "$($_.ShMark)" -ne [string][char]0x25CF }).Count
    $nag = $rows.Count - $nsh
    $parts = @()
    if ($nsh) { $parts += ('{0} shell{1}' -f $nsh, $(if ($nsh -eq 1) { '' } else { 's' })) }
    if ($nag) { $parts += ('{0} sub-agent{1}' -f $nag, $(if ($nag -eq 1) { '' } else { 's' })) }
    if (-not $parts.Count) { $parts += ('{0} running' -f $n) }
    # 🪤 A CHAR CODE, NEVER A LITERAL. PowerShell 5.1 reads a BOM-less
    # UTF-8 file as ANSI, so a middot typed here reaches the screen as two
    # mojibake characters - the trap the marker table already carries a
    # warning about, and I walked into it in this very function.
    $sep = '  ' + [string][char]0x00B7 + '  '
    $head = ($parts -join $sep) + ' running'
    # Saying "2 running - 1 named" is honest; listing one and calling it the
    # total is not. They differ when something started before the read window.
    if ($rows.Count -lt $n) { $head += (' - {0} of {1} named' -f $rows.Count, $n) }
    $ui.ShellHead.Text = (Get-TrackedText $head.ToUpper())
    $ui.ShellBox.Visibility = 'Visible'
}

function Update-LiveShells {
    if ($script:liveShells.Count -eq 0) { return }
    foreach ($e in @($script:liveShells)) {
        $p = ''
        try { $p = Get-SRShellOutputPath -SessionId $e.Session -Shell $e.Shell } catch { }
        if (-not $p) { continue }
        $o = $null
        try { $o = Get-SRShellOutput -Path $p } catch { }
        if (-not $o) { continue }
        $txt = "$($o.Text)"
        if (-not $txt.Trim()) { continue }
        try {
            if ($e.Body) {
                # 🪤 ONLY WHEN IT ACTUALLY MOVED. Assigning the same string back
                # invalidates the TextBlock's layout anyway, and this runs every
                # second against every open shell block on screen.
                if ("$($e.Body.Text)" -ne $txt) {
                    $e.Body.Text = $txt
                    $e.Label.Text = (Get-TrackedText ('output   {0:N0} bytes{1}' -f $o.Bytes, $(if ($o.Truncated) { ' - showing the end' } else { '' })))
                }
            } elseif ($e.Panel) {
                # It had nothing to show when it was opened and now does.
                $nb = New-ReadText -Text $txt -Brush $Pal.TextMid -Size $script:MonoSize -Mono -Wrap -Line $script:readLead
                $nb.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0)
                $null = $e.Panel.Children.Add((New-BoundedText $nb))
                $e.Body = $nb
                $e.Label.Text = (Get-TrackedText ('output   {0:N0} bytes' -f $o.Bytes))
            }
        } catch { }
    }
}

function New-BoundedText { param($Child)
    $sv = [System.Windows.Controls.ScrollViewer]::new()
    $sv.VerticalScrollBarVisibility = 'Auto'
    $sv.HorizontalScrollBarVisibility = 'Disabled'
    $sv.MaxHeight = $script:FoldMaxHeight
    $sv.Content = $Child
    # 🔴 THE WHEEL MUST REACH THE CONVERSATION. WPF gives a nested ScrollViewer
    # the wheel unconditionally and does NOT bubble it once that region hits its
    # end - so with the pointer anywhere over a command's output, scrolling the
    # conversation simply stopped. That is not slowness, but it is inseparable
    # from it while you are using the pane: the wheel stops working and the
    # window feels stuck. Reported as scrolling that lags.
    #
    # Inner first while it has somewhere to go, then hand the wheel up - which
    # is what every browser does and what the hand expects.
    $sv.Add_PreviewMouseWheel({
        param($s, $e)
        $canScroll = ($s.ScrollableHeight -gt 0)
        $atTop     = ($s.VerticalOffset -le 0)
        $atBottom  = ($s.VerticalOffset -ge $s.ScrollableHeight)
        if ((-not $canScroll) -or ($e.Delta -gt 0 -and $atTop) -or ($e.Delta -lt 0 -and $atBottom)) {
            $e.Handled = $true
            $up = [System.Windows.Input.MouseWheelEventArgs]::new($e.MouseDevice, $e.Timestamp, $e.Delta)
            $up.RoutedEvent = [System.Windows.UIElement]::MouseWheelEvent
            $p = [System.Windows.Media.VisualTreeHelper]::GetParent($s)
            if ($p) { $p.RaiseEvent($up) }
        }
    })
    return $sv
}

function Add-MonoDetail { param($Panel, [string]$Text, $Brush)
    if (-not $Brush) { $Brush = $Pal.TextMid }
    $t = "$Text".TrimEnd()
    if (-not $t) { return }
    $tb = New-ReadText -Text (Compress-SRPath $t) -Brush $Brush -Size $script:MonoSize -Mono -Wrap -Line $script:readLead
    $null = $Panel.Children.Add((New-BoundedText $tb))
}

# 🔴 A COMPOUND COMMAND IS SEVERAL COMMANDS, AND IT SHOULD READ AS SEVERAL.
#
# The pane used to clip the whole thing mid-path with an ellipsis - the
# reported "git -C C:\...\Millwri..." - so the one view you open to see WHAT RAN
# showed less than the folded one. Splitting on the separators first means each
# statement starts at a predictable place; wrapping with a hanging indent means
# nothing is ever cut.
#
# Quote-aware, because a `;` inside a quoted argument is not a separator and
# splitting on it would print a command that was never run.
function Split-SRCommandLine { param([string]$Cmd)
    $out = New-Object System.Collections.Generic.List[string]
    $buf = New-Object System.Text.StringBuilder
    $q = [char]0; $i = 0; $n = "$Cmd".Length
    # 🪤 DEPTH, OR A `foreach {a; b}` COMES APART INTO PIECES THAT ARE NOT
    # COMMANDS. A semicolon inside braces or parentheses separates statements
    # WITHIN one command; splitting there printed a single loop as four
    # fragments, each of which reads like something that ran on its own. Only a
    # separator at depth zero is a separator.
    $depth = 0
    while ($i -lt $n) {
        $ch = $Cmd[$i]
        if ($q -ne [char]0) {
            $null = $buf.Append($ch)
            if ($ch -eq $q -and ($i -eq 0 -or $Cmd[$i - 1] -ne '`')) { $q = [char]0 }
            $i++
            continue
        }
        if ($ch -eq '"' -or $ch -eq "'") { $q = $ch; $null = $buf.Append($ch); $i++; continue }
        if ($ch -eq '{' -or $ch -eq '(' -or $ch -eq '[') { $depth++ }
        elseif ($ch -eq '}' -or $ch -eq ')' -or $ch -eq ']') { if ($depth -gt 0) { $depth-- } }
        $two = ''
        if ($i + 1 -lt $n) { $two = $Cmd.Substring($i, 2) }
        if ($depth -eq 0 -and ($two -eq '&&' -or $two -eq '||')) {
            $out.Add(($buf.ToString().Trim() + ' ' + $two)); $null = $buf.Clear(); $i += 2; continue
        }
        if ($depth -eq 0 -and $ch -eq ';') {
            $out.Add(($buf.ToString().Trim() + ';')); $null = $buf.Clear(); $i++; continue
        }
        $null = $buf.Append($ch)
        $i++
    }
    $tail = $buf.ToString().Trim()
    if ($tail) { $out.Add($tail) }
    # 🪤 `.ToArray()` HERE THREW ON A STRING, and the reason is the one this
    # codebase keeps re-learning: `@(...)` produces an ARRAY, arrays have no
    # ToArray, and member access on a ONE-ELEMENT array UNROLLS to the element -
    # so a single-statement command reached `[String].ToArray()` and the whole
    # document failed to build. A plain array out, `@()` at the call site.
    $keep = @($out | Where-Object { $_.Trim(' ', ';') })
    if (-not $keep.Count) { return @("$Cmd") }
    return $keep
}

# One tool call, opened: its name, what it was given, and what came back.
function Add-RunDetail { param($Panel, $Calls)
    foreach ($c in @($Calls)) {
        $ln = New-Object System.Windows.Controls.StackPanel
        $ln.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10

        # A SUB-AGENT AND A BACKGROUND SHELL ARE NAMED AS WHAT THEY ARE. Both
        # used to read as an ordinary tool call in the same grey as a Read, and
        # they are the two things a session starts that keep going after the
        # call returns - which is exactly what the operator could not see.
        $ck = "$($c.CallKind)"
        if (-not $ck) { $ck = 'run' }
        $hue = $(if ($c.Bad) { $Pal.Bad } elseif ($ck -ne 'run') { Get-MarkBrush $ck } else { $Pal.Tool })
        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'
        if ($ck -ne 'run') {
            $gm = New-ReadText -Text ((Get-MarkGlyph $ck) + '  ') -Brush $hue -Mono
            $null = $head.Children.Add($gm)
        }
        $null = $head.Children.Add((New-ReadText -Text "$($c.Name)".ToUpper() -Brush $hue))
        $null = $ln.Children.Add($head)

        # What it was FOR, above what it was GIVEN. On a Task this is the one
        # line that says which sub-agent this is; on a background shell it is
        # the only human-written description of what was left running.
        $dsc = "$($c.Desc)".Trim()
        if ($dsc -and $ck -ne 'run') {
            $db = New-ReadText -Text $dsc -Brush $Pal.TextMid -Wrap -Line $script:readLead
            $db.Margin = New-Object System.Windows.Thickness 0, 3, 0, 0
            $null = $ln.Children.Add($db)
        }

        # 🔑 AND FOR A SUB-AGENT, THE WAY INTO ITS CONVERSATION.
        #
        # The sessions column lists only agents that are still RUNNING, which is
        # what the operator asked for - and 374 of the 375 on this machine are
        # finished, so that list is almost always empty. Their findings are the
        # thing you most often want back, and without this they became
        # unreachable when the rows went active-only. Here is the right place
        # for it anyway: you open the agent where it was dispatched.
        #
        # 🪤 MATCHED ON THE DESCRIPTION, because the tool_use id does not survive
        # into the block - New-Block carries four fields and all four are spoken
        # for. The meta.json records the same `description` the Task call was
        # given, so the two are the same string by construction. A collision
        # would open a sibling agent with an identical brief, which is why the
        # one WITH a transcript wins and nothing is drawn when none matches.
        if ($ck -eq 'agent' -and $dsc -and "$($script:docParentPath)") {
            $mine = @()
            try {
                $all = @(Get-SRSubAgents -JsonlPath "$($script:docParentPath)")
                $mine = @($all | Where-Object { "$($_.Description)".Trim() -eq $dsc -and $_.HasTranscript })
            } catch { }
            if ($mine.Count) {
                $op = New-Object System.Windows.Controls.Border
                $op.Background = [System.Windows.Media.Brushes]::Transparent
                $op.Cursor = 'Hand'
                $op.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0)
                $op.ToolTip = 'Open this sub-agent''s own conversation'
                $ot = New-ReadText -Text ((Get-MarkGlyph 'agent') + '  open its conversation  ' + [string][char]0x2192) `
                                   -Brush (Get-MarkBrush 'agent')
                $op.Child = $ot
                $op.Tag = @{ Sub = $mine[0]; Row = $script:docParentRow }
                # 🔴 SAME TRAP AS THE FOLD HEADER, and it killed this too. Anything
                # clickable inside PaneDoc must take PREVIEW-DOWN: the viewer has
                # IsSelectionEnabled and its editor captures the mouse on
                # button-down, so the matching Up is delivered to the capture
                # target and never arrives here. Found while fixing New-FoldHeader.
                $op.Add_PreviewMouseLeftButtonDown({
                    param($s, $e)
                    $g = $s.Tag
                    if ($g -and $g.Sub -and $g.Row) { Show-AgentDoc -Sub $g.Sub -ParentRow $g.Row }
                    $e.Handled = $true
                })
                $null = $ln.Children.Add($op)
            }
        }

        # 🔴 THE COMMAND IS NOT PATH-COMPRESSED. Compress-SRPath is right for a
        # RESULT, which is dense and scanned - but on the command it replaced the
        # middle of every long path with an ellipsis, so the one line you open
        # this block to read verbatim came out as `-Shot "C:\...\444f9...`. That
        # is the reported "cut off", arriving from the shortener rather than from
        # the layout, and it survived the wrap fix because it is baked into the
        # text before the control ever sees it. What ran is shown as it ran.
        $argText = "$($c.Arg)".Trim()
        if ($argText) {
            # 🪤 A SUB-AGENT'S ARGUMENT IS A PROMPT, NOT A COMMAND, and the
            # splitter must not touch it: prose is full of semicolons, and
            # breaking an instruction at each one would print the briefing as a
            # list of statements that were never separate. Only a shell command
            # is split.
            $stmts = @($argText)
            if ($ck -ne 'agent') { $stmts = @(Split-SRCommandLine $argText) }
            foreach ($stmt in $stmts) {
                $ar = New-ReadText -Text $stmt -Brush $(if ($c.Bad) { $Pal.Bad } else { $Pal.TextHigh }) `
                                   -Size $script:MonoSize -Mono -Wrap -Line $script:readLead
                # The hanging indent that makes a wrapped command readable: the
                # statement starts at the left and its continuation lines sit in
                # from it, so you can see where one command ends and the next
                # begins without reading either.
                $ar.Margin = New-Object System.Windows.Thickness 0, 3, 0, 0
                $ar.Padding = New-Object System.Windows.Thickness 0, 0, 0, 0
                $null = $ln.Children.Add($ar)
            }
        }

        $resText = "$($c.ResFull)"
        if (-not $resText) { $resText = "$($c.Res)" }
        if ($resText) {
            $rg = New-Object System.Windows.Controls.Grid
            $rc0 = New-Object System.Windows.Controls.ColumnDefinition
            # 🪤 GutterW, NOT 14. Every other block in this document hangs off
            # $script:GutterW, which scales with the zoom; this column was a
            # bare 14 and so agreed with them at 100% and drifted at every
            # other setting - the result marker sitting left of the prose it
            # belongs under. Reported as "alignment".
            $rc0.Width = New-Object System.Windows.GridLength $script:GutterW
            $rc1 = New-Object System.Windows.Controls.ColumnDefinition
            $rc1.Width = New-Object System.Windows.GridLength 1, 'Star'
            $null = $rg.ColumnDefinitions.Add($rc0)
            $null = $rg.ColumnDefinitions.Add($rc1)
            $rm = New-Object System.Windows.Controls.TextBlock
            $rm.Text = (Get-MarkGlyph 'result')
            $rm.Foreground = $Pal.TextLow
            $rm.FontSize = $script:PaneSize
            $rm.FontFamily = $script:PaneFace
            $rm.VerticalAlignment = 'Top'
            $null = $rg.Children.Add($rm)
            $rt = New-ReadText -Text (Compress-SRPath $resText) -Brush $Pal.TextLow -Size $script:MonoSize -Mono -Wrap -Line $script:readLead
            $sv = New-BoundedText $rt
            [System.Windows.Controls.Grid]::SetColumn($sv, 1)
            $null = $rg.Children.Add($sv)
            $rg.Margin = New-Object System.Windows.Thickness 0, 5, 0, 0
            $null = $ln.Children.Add($rg)
        }

        # 🔑 WHAT THE BACKGROUND SHELL HAS ACTUALLY PRINTED, live off disk.
        #
        # The tool_result above says only "running in background with ID: x" -
        # which was everything this tool could show, and is why a background
        # shell read as a thing you were told about rather than a thing you
        # could watch. Claude Code writes the shell's stdout to
        # %TEMP%\claude\<cwd-slug>\<session>\tasks\<id>.output and keeps writing
        # while it runs, so this is the real current output, not a copy.
        #
        # Read at OPEN time, deliberately: this block is lazy, so the bytes are
        # fetched when you look at it and are as fresh as the click. A folded
        # block reads no files at all.
        if ("$($c.Shell)" -and "$($script:docSessionId)") {
            $sp = ''
            try { $sp = Get-SRShellOutputPath -SessionId "$($script:docSessionId)" -Shell "$($c.Shell)" } catch { }
            $so = $null
            if ($sp) { try { $so = Get-SRShellOutput -Path $sp } catch { } }
            # 🪤 NOT $head / $body. `$head` is the call-header StackPanel a few
            # lines above, still in scope, and PowerShell would have let this
            # silently rebind it to a string - the shadowing family CONTEXT.md
            # already records twice.
            $shLabel = ''
            $shText = ''
            if (-not $sp) {
                # Said plainly rather than left blank. The file is cleaned up
                # once a shell is reaped, so this is the normal state for an old
                # conversation and must not read as a failure.
                $shLabel = 'no output file - this shell has been cleaned up'
            } elseif (-not $so) {
                $shLabel = 'its output file could not be read'
            } elseif (-not "$($so.Text)".Trim()) {
                $shLabel = 'running - nothing printed yet'
            } else {
                $shLabel = ('output   {0:N0} bytes{1}' -f $so.Bytes, $(if ($so.Truncated) { ' - showing the end' } else { '' }))
                $shText = "$($so.Text)"
            }
            $sv2 = New-Object System.Windows.Controls.StackPanel
            # Same column as the result marker above, for the same reason.
            $sv2.Margin = New-Object System.Windows.Thickness $script:GutterW, 7, 0, 0
            $hl = New-ReadText -Text "$shLabel".ToUpper() -Brush (Get-MarkBrush 'shell')
            $null = $sv2.Children.Add($hl)
            $bt = $null
            if ($shText) {
                $bt = New-ReadText -Text $shText -Brush $Pal.TextMid -Size $script:MonoSize -Mono -Wrap -Line $script:readLead
                $bt.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0)
                $null = $sv2.Children.Add((New-BoundedText $bt))
            }
            $null = $ln.Children.Add($sv2)
            # 🔑 AND IT KEEPS UPDATING. The output file is still being written
            # while the shell runs, but this read happens once, when the block
            # is opened - so watching a background command meant closing and
            # re-opening it. An OPENED block registers itself and the follow
            # tick re-reads it; a closed one is not in the list and costs
            # nothing. No new timer: the one that already runs does it.
            if ($sp -and "$($c.Shell)") {
                Register-LiveShell -Label $hl -Body $bt -Panel $sv2 -Shell "$($c.Shell)" -Session "$($script:docSessionId)"
            }
        }
        $null = $Panel.Children.Add($ln)
    }
}

# 🔴 THE TYPE DOES NOT SCALE WITH THE PANE, AND THE MEASURE IS A CEILING.
#
# This function used to do the opposite of both, and between them they are the
# whole of "the text is too large and too wide spaced, and that makes it hard to
# read". It GREW the body from 16px to 20px on a wide window - filling a line by
# growing the letters is zooming, not scaling - and set leading at 1.75x the
# size, so a maximised pane drew 20/35 prose across 120+ characters. Nothing in
# a terminal is set anywhere near that loose, which is why the two surfaces read
# so differently side by side.
#
# Now: ONE fixed size, leading at 1.38x, and the measure capped by default.
# 13/18 is terminal density and holds ~45% more conversation per screen than
# 16/28 did. `readingWidth: full` in the config still removes the cap for anyone
# who wants the old fill behaviour - it is an escape hatch, no longer the
# default, because an uncapped line on a 2,700px window is the defect.
function Set-ReadMeasure { param($Doc, [double]$Size = 0, [double]$PadL = 44)
    $avail = 0.0
    try { $avail = [double]$ui.PaneDoc.ActualWidth } catch { }
    if ($avail -lt 200) { $avail = 900.0 }

    # 🔴 THIS LITERAL WAS THE REAL SIZE OF THE READING PANE, AND IT WAS THE
    # THIRD PLACE ONE WAS WRITTEN DOWN. $script:readSize was set at the top of
    # the file, Set-SRTypeScale set it again, and then this ran on every layout
    # and overwrote both - so the two visible declarations were decoration and
    # only this one did anything. It now takes the scale, and the $Size
    # parameter stays as the one legitimate override (the shot harness renders
    # at a fixed size so a picture is comparable between runs).
    $size = $script:PaneSize
    if ($Size -gt 0) { $size = $Size }
    $script:readSize = $size
    $script:readLead = [Math]::Round($size * $SR_LeadFactor, 1)

    $right = 44.0
    if ($script:readWidth -ne 'full') {
        # The advance comes from the FACE (see $script:PaneAdvanceEm), not from a
        # literal. It was 0.52 - Manrope's average - and stayed that way when the
        # pane went monospaced, so the column held 87 of the 100 characters it
        # was asked for. The gutter is inside the measure, not outside it: the
        # text column is what is being capped, and it starts one gutter in.
        $target = ($script:ReadMeasureChars * $size * $script:PaneAdvanceEm) + $script:GutterW
        $right = [Math]::Max(44.0, $avail - $PadL - $target)
    }
    $Doc.PagePadding = New-Object System.Windows.Thickness $PadL, 24, $right, 34
}

function Add-ReadRule { param($Doc, $Brush, [double]$Top = 26, [double]$Bottom = 0, [double]$Height = 1)
    $r = New-Object System.Windows.Shapes.Rectangle
    $r.Height = $Height
    $r.Fill = $Brush
    $r.HorizontalAlignment = 'Stretch'
    $c = New-Object System.Windows.Documents.BlockUIContainer $r
    $c.Margin = New-Object System.Windows.Thickness 0, $Top, 0, $Bottom
    $Doc.Blocks.Add($c)
}

# WHEN A TURN HAPPENED. Nothing on this surface answered that: the sessions list
# says how long ago a conversation last spoke, and inside it every turn looked
# equally recent - so a reply from this morning and one from four minutes ago
# read the same. Time of day alone while it is today, because that is the form
# anyone reads without converting; the date appears only once it is needed.
function Format-TurnTime { param($When)
    if (-not $When) { return '' }
    try {
        $t = [datetime]$When
        if ($t.Date -eq (Get-Date).Date) { return $t.ToString('HH:mm') }
        if ($t.Date -eq (Get-Date).Date.AddDays(-1)) { return ('yesterday ' + $t.ToString('HH:mm')) }
        return $t.ToString('d MMM HH:mm')
    } catch { return '' }
}

function Add-ReadLabel {
    param($Doc, [string]$Text, $Brush, [string]$Trailing = '', $TrailBrush, $When,
          [double]$Size = 0, [double]$Top = 20, [double]$Bottom = 5)
    if ($Size -le 0) { $Size = $script:PaneSize }
    $p = New-Object System.Windows.Documents.Paragraph
    # INDENTED INTO THE TEXT COLUMN, not sitting out at the page edge. The
    # speaker label belongs over the words it introduces; at x=0 it hung one
    # gutter to the left of everything below it and read as a separate column.
    $p.Margin = New-Object System.Windows.Thickness $script:GutterW, $Top, 0, $Bottom
    # 🔴 BARE: UPPERCASE AND HUE, NOTHING ELSE. This was tracked (hand-spaced
    # with thin spaces) AND SemiBold AND a size step below the prose - three
    # devices to say "label" where the pane already says it twice, in the
    # marker and the colour. The operator named the weight specifically: asked
    # which thing read as "fat", the answer was "the SemiBold labels and
    # captions". A column of small bold capitals on a dark ground blooms, and
    # there is one over every turn. Uppercase and the hue carry it now.
    $p.Inlines.Add((New-ReadRun -Text $Text.ToUpper() -Brush $Brush -Size $Size))
    $stamp = Format-TurnTime $When
    if ($stamp) {
        # Dimmer than the speaker and not tracked: it is a reference you look up
        # when you want it, never something that competes with who is talking.
        $p.Inlines.Add((New-ReadRun -Text ('        ' + $stamp) -Brush $Pal.TextLow -Size $Size))
    }
    if ($Trailing) {
        $p.Inlines.Add((New-ReadRun -Text ('          ' + $Trailing) -Brush $TrailBrush -Size $Size))
    }
    $Doc.Blocks.Add($p)
}

# Which of the three positions the pane is in. Read once from the config and
# then owned by the window, so the toggle is instant and the write is a side
# effect rather than something the render path waits on.
$script:toolView = 'folded'
# MEASURED BY DEFAULT. An uncapped line on a maximised pane is ~120 characters,
# and tracking back to the start of the next one is exactly what makes long
# replies tiring to read. `readingWidth: full` in the config restores the fill.
$script:readWidth = 'measured'
try {
    $cfg0 = Get-SRConfig
    $tv = "$($cfg0.transcriptTools)".Trim().ToLower()
    if ($SR_ToolViews -contains $tv) { $script:toolView = $tv }
    $rw = "$($cfg0.readingWidth)".Trim().ToLower()
    if ($SR_ReadWidths -contains $rw) { $script:readWidth = $rw }
} catch { }

function Get-ToolViewLabel {
    switch ($script:toolView) {
        'full'   { return 'Steps: full' }
        'hidden' { return 'Steps: hidden' }
        default  { return 'Steps: folded' }
    }
}

function Build-ReadDocument {
    param($Blocks, [bool]$Truncated = $false, $Turns = $null)
    $doc = New-Object System.Windows.Documents.FlowDocument
    # The document's own face is what every Run inherits unless it asks for the
    # grid, so prose is the default and mono is the exception - the way round
    # a reading surface wants.
    $doc.FontFamily  = $script:ProseFace
    # 🔴 WHAT IS STILL RUNNING, SO `hidden` CAN HIDE HISTORY WITHOUT HIDING THAT.
    # With Steps on hidden every run block is dropped, and a background shell's
    # output lives ONLY inside an opened run block - so the setting was removing
    # the one route to a running shell rather than reducing noise. Reported as
    # "when I click on the respective background running agent or task, I cannot
    # see its output", in the same breath as the nested-row defect, because on
    # his machine both roads were shut.
    #
    # The operator's ruling, asked directly: a finished tool call is history and
    # stays hidden; one that is still happening keeps its line.
    #
    # 🪤 READ, NEVER PARSED, ON THIS PATH. Get-SRLiveTasks is the authority and
    # it parses up to 24 MB - "the cost of this is the whole design", says its
    # own note - so calling it while building a document would put that on the
    # click. $script:shellList is the same answer, already computed by
    # Update-ShellPanel on the follow tick.
    #
    # 🪤 AND IT MUST BE THIS CONVERSATION'S LIST. $script:shellFor names whose
    # tasks those are; if it does not match, the set is EMPTY and hidden behaves
    # exactly as it did before. An unknown answer hides nothing extra and
    # exempts nothing - it must not guess in either direction.
    $script:docLiveShells = $null
    if ("$($script:shellFor)" -and "$($script:shellFor)" -eq "$($script:docSessionId)") {
        $script:docLiveShells = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($lt in $script:shellList) {
            $sid = "$($lt.Shell)"
            if ($sid) { $null = $script:docLiveShells.Add($sid) }
        }
    }
    # TRANSPARENT, NOT Ink. The document was painting the GROUND colour - the
    # near-black the window shows *around* its cards - inside an output pane
    # that is painted Panel and has a 12px corner radius. The result was a
    # darker square slab filling the rounded card, with the radius visible only
    # at the very corners: the operator's "it doesn't look rounded off". Letting
    # the card show through is the fix, and it costs nothing.
    $doc.Background  = [System.Windows.Media.Brushes]::Transparent
    $doc.Foreground  = $Pal.TextHigh
    $doc.ColumnWidth = [double]::PositiveInfinity
    # 🔴 OPTIMAL PARAGRAPH IS OFF, AND IT IS OFF FOR A MEASURED REASON.
    #
    # It is WPF's good line breaker (Knuth-Plass): it looks at the whole
    # paragraph rather than greedily filling each line, which is the difference
    # between even ragged edges and lumpy ones. It was switched ON for that, and
    # the typography really was better. It is also documented as slower, and
    # nobody had put a number on it.
    #
    # THE NUMBER, measured on this machine against the largest transcript here
    # (201 KB, 40 blocks), same document, same viewer, only this property
    # changing, at a different width each pass so WPF cannot reuse the previous
    # line breaks - which is what a splitter drag actually does:
    #
    #     breaker ON    median 480 ms        breaker OFF   median 355 ms
    #
    # Around 125 ms per reflow, ~1.3x. Taken both interleaved and sequentially
    # (1.35x and 1.32x) because sequential runs on this machine have produced a
    # frankly impossible result before; here the two agree, so the methodology
    # is not doing the work.
    #
    # 🔑 WHY IT MATTERS MORE THAN 125 ms SOUNDS. Dragging a splitter costs
    # 250-435 ms and its handler is 0.3 ms of that, so it is all layout - and the
    # lists virtualize while THIS PANE DOES NOT. So every drag frame, every
    # window resize and every text-size step pays it, which is a real part of
    # "the tool feels laggy everywhere".
    #
    # 🪤 REVERSIBLE IN ONE LINE, deliberately. This is typography traded for
    # speed and the operator may want it back; flip this to $true and nothing
    # else changes. WPF's own default is off, so off is not a workaround.
    #
    # 🪤 AND THE RATIO IS SMALLER THAN IT WAS FIRST REPORTED. A 3.7-4.8x figure
    # went round before this; three runs here over three document sizes gave
    # 1.23x, 1.28x and 1.35x and never approached it. The saving is real and
    # worth taking either way - this note exists so nobody later measures ~1.3x,
    # assumes a regression against the larger figure, and goes hunting.
    $doc.IsOptimalParagraphEnabled = $false
    # Hyphenation stays off - hyphenated prose in a terminal-adjacent surface
    # reads worse, not better.
    $doc.IsHyphenationEnabled = $false
    # 🔴 RAGGED RIGHT, AND FLOWDOCUMENT DOES NOT DEFAULT TO IT. TextAlignment
    # defaults to JUSTIFY, which nothing in this tool ever asked for: with a
    # 70-character measure and hyphenation deliberately off, justification has
    # only the word spaces to stretch, so it opens visible rivers down the
    # paragraph and every line gets a different word gap. That unevenness is a
    # large part of what reads as the text "not being smooth" - and it is not
    # antialiasing, which is where the eye goes looking for it first.
    $doc.TextAlignment = 'Left'
    Set-ReadMeasure -Doc $doc -PadL 44

    if (-not @($Blocks).Count) {
        $p = New-Object System.Windows.Documents.Paragraph
        $p.Inlines.Add((New-ReadRun -Text 'Nothing readable in this transcript yet.' -Brush $Pal.TextMid -Size 14))
        $doc.Blocks.Add($p)
        return $doc
    }

    # SAY WHEN IT IS PARTIAL. A pane that silently shows the last slice of a
    # conversation reads as the whole of a short one.
    # THE WAY BACK OUT OF A SUB-AGENT. Drilling in is not a selection - the
    # sessions column still shows the parent - so without this the only route
    # back would be clicking the row that already looks selected, which does
    # nothing. It sits at the top because that is where you look for it.
    if ($script:agentOpen) {
        $bb = New-Object System.Windows.Controls.Border
        $bb.Background = [System.Windows.Media.Brushes]::Transparent
        $bb.Cursor = 'Hand'
        $bb.ToolTip = 'Back to the conversation that dispatched this agent'
        $bt2 = New-ReadText -Text ([string][char]0x2190 + '  back to ' + "$($script:agentOpen.Row.T.Text)") `
                            -Brush $Pal.Ask
        $bb.Child = $bt2
        # 🔴 AND THIS ONE IS THE WAY BACK. Same capture, same fix - see
        # New-FoldHeader. With both this and the 'open its conversation' border
        # dead, the sub-agent document could be neither entered nor left.
        $bb.Add_PreviewMouseLeftButtonDown({ param($s, $e) Close-AgentDoc; $e.Handled = $true })
        $doc.Blocks.Add((New-RailBlock -Child $bb -Kind 'agent' -Top 0 -Bottom 10))
    }
    if ($Truncated) {
        # 🔴 IT IS A CONTROL, NOT A CAPTION. This said "press L to load earlier"
        # and was the only way to reach the rest of a long conversation - a
        # keyboard shortcut announced in italics at the top of a document nobody
        # had focused. Same defect as the fold captions: the thing that looks
        # like the affordance has to BE the affordance. The L key still works.
        $bd = New-Object System.Windows.Controls.Border
        $bd.Background = [System.Windows.Media.Brushes]::Transparent
        $bd.Cursor = 'Hand'
        $bd.ToolTip = 'Load an earlier slice of this conversation (or press L)'
        # 🔴 THIS ROW CARRIED TWO MARKERS AND WORE THE COST OF BOTH. New-RailBlock
        # already draws this block's dot in the gutter at x=44; the caret below it
        # was a SECOND marker, living inside the text column, and its glyph plus a
        # 7px margin pushed the words to x=81 while every other line in the
        # document starts at 66. Measured at 15px off-column - the only rail block
        # that was, and one of the "text is not left bounded" reports.
        #
        # 🪤 IT IS NOT A CASE FOR MOVING THE CARET INTO THE LABEL'S OWN TEXT. That
        # would put the TextBlock's left edge back on 66 and turn the alignment
        # harness green while the WORDS still started 15px in - the measurement
        # satisfied and the complaint untouched. The second marker had to go, not
        # relocate. It also spent a shape the operator had already ruled out:
        # one dot, colour only, no competing glyphs.
        $lb = New-Object System.Windows.Controls.TextBlock
        $lb.Text = ('load earlier   showing the last {0} KB of a longer conversation' -f [int]($script:tailBytes / 1KB))
        $lb.Foreground = $Pal.TextDim
        $lb.FontSize = $script:PaneSize
        $lb.FontFamily = $script:ProseFace
        $lb.VerticalAlignment = 'Center'
        $bd.Child = $lb
        # 🔴 AND SO WAS 'load earlier' - see New-FoldHeader for the capture.
        $bd.Add_PreviewMouseLeftButtonDown({
            param($s, $e)
            $script:tailBytes = $script:tailBytes * 2
            Update-Document
            Set-Status ('loaded the last {0} KB' -f [int]($script:tailBytes / 1KB))
            $e.Handled = $true
        })
        $doc.Blocks.Add((New-RailBlock -Child $bd -Kind 'system' -Top 0 -Bottom 8))
    }

    $script:docHidden = 0
    # HOW MANY DOCUMENT BLOCKS EACH TURN PRODUCED, in order. This is what makes
    # an incremental update possible: a turn is not one block - a prose turn is
    # a paragraph per source line - so appending or replacing the last turn needs
    # to know exactly how much of the document belongs to it.
    $script:docTurnCounts = New-Object System.Collections.Generic.List[int]
    # A rebuild orphans every control the old document held, so the shell blocks
    # registered against it are gone with it. The APPEND path deliberately does
    # not do this: those controls are still the ones on screen.
    $script:liveShells.Clear()
    # Folding blocks into turns is not free, and Set-ReadDocument has already
    # done it to decide whether this build was needed at all. Reuse it.
    if ($Turns) { $script:docTurns = @($Turns) } else { $script:docTurns = @(Get-ReadTurns $Blocks) }
    foreach ($t in $script:docTurns) {
        $before = $doc.Blocks.Count
        Add-ReadTurn -Doc $doc -Turn $t
        $script:docTurnCounts.Add($doc.Blocks.Count - $before)
    }
    return $doc
}

# ONE TURN, RENDERED. Extracted from Build-ReadDocument's loop so that the
# incremental path and the full build are the SAME code - a second renderer
# that drew "the new turns" slightly differently from the first would be a bug
# nobody could see, because both halves would look right on their own.
# ===========================================================================
# WHAT YOU ACTUALLY TYPED, NOT THE ENVELOPE AROUND IT.
#
# 🔴 A SLASH COMMAND ARRIVED AS SIX LINES OF XML. Looked at in a shot: one
# `/compact` drew <local-command-caveat> and its whole paragraph of boilerplate,
# then <command-name>, <command-message>, <command-args> and
# <local-command-stdout>, each on its own line, INSIDE the block that is meant
# to be the clearest thing in the document. Reported as "the style is sometimes
# not intuitive and not obvious".
#
# 🪤 STRIP THE WRAPPER, NEVER THE WORDS. A user record routinely carries a
# command envelope AND typed prose in one body - this very conversation does -
# so this rewrites only the tags it knows and leaves everything else exactly as
# it found it. The caveat block is the one thing dropped outright: it is
# addressed to the model rather than to you, it is identical every time, and it
# is longer than most of the messages it wraps.
#
# 🪤 THE `<` TEST IS NOT AN OPTIMISATION, it is what keeps eight regex passes
# off the overwhelming majority of turns, which contain no tag at all.
function Convert-SRSpoken { param([string]$Text)
    if (-not $Text) { return '' }
    # 🔴 A BARE '<' IS NOT AN ENVELOPE, AND ALMOST EVERY TURN HAS ONE. The
    # first version of this guard tested for '<' alone, which is true of any
    # body carrying a <system-reminder>, a <task-notification>, an HTML tag or
    # a less-than sign - so eight regex passes ran over most of the document
    # instead of over the handful of slash-command turns they exist for.
    # Measured as a 2.36x regression in "build AND lay out with every block
    # open" the first time this suite saw it.
    #
    # 🪤 TWO IndexOf CALLS, NOT A REGEX, because the point is to be cheaper than
    # the thing being skipped. Ordinal: a culture-sensitive compare on a tag
    # prefix is the trap CONTEXT.md already records.
    if ($Text.IndexOf('<local-command', [System.StringComparison]::Ordinal) -lt 0 -and
        $Text.IndexOf('<system-reminder', [System.StringComparison]::Ordinal) -lt 0 -and
        $Text.IndexOf('<command-', [System.StringComparison]::Ordinal) -lt 0) { return $Text }
    $s = $Text
    $s = [regex]::Replace($s, '(?s)<local-command-caveat>.*?</local-command-caveat>', '')
    # A real message can carry one of these appended to it, and it is context
    # for the model rather than anything the operator wrote.
    $s = [regex]::Replace($s, '(?s)<system-reminder>.*?</system-reminder>', '')
    $s = [regex]::Replace($s, '(?s)<command-message>.*?</command-message>', '')
    $s = [regex]::Replace($s, '(?s)<command-args>\s*</command-args>', '')
    $s = [regex]::Replace($s, '(?s)<command-args>(.*?)</command-args>', '$1')
    $s = [regex]::Replace($s, '(?s)<command-name>/?(.*?)</command-name>', '/$1')
    $s = [regex]::Replace($s, '(?s)<local-command-stdout>\s*</local-command-stdout>', '')
    $s = [regex]::Replace($s, '(?s)<local-command-stdout>(.*?)</local-command-stdout>', '$1')
    # What is left where a block was removed is a run of blank lines.
    $s = [regex]::Replace($s, '(\r?\n[ \t]*){3,}', "`n`n")
    return $s.Trim()
}


function Add-ReadTurn { param($Doc, $Turn)
    $doc = $Doc
    $t = $Turn
    if ($true) {
        switch ($t.Kind) {
            'you' {
                # A human turn is the one real boundary in a conversation, and
                # it keeps a rule. Claude's turns no longer do: a rule above
                # every reply is a rule above almost everything, which is noise
                # rather than structure - the marker says who is speaking now.
                Add-ReadRule -Doc $doc -Brush $PalEdge.Out -Height 1
                $trail = ''
                if ($script:docHidden -gt 0) { $trail = "$script:docHidden steps hidden"; $script:docHidden = 0 }
                Add-ReadLabel -Doc $doc -Text 'you said' -Brush $Pal.Out -Trailing $trail -TrailBrush $Pal.TextLow -When $t.When
                $inner = New-Object System.Windows.Documents.FlowDocument
                Add-ReadProse -Doc $inner -Text (Convert-SRSpoken $t.Body) -Brush $Pal.TextMax -Size $script:readSize -Line $script:readLead -Kind 'you' -Ground $PalYouGround
                # Blocks is a live collection: moving them while enumerating it
                # silently drops every second one, hence the @() snapshot. And
                # $null = on Remove is not tidiness - it returns a BOOL, and an
                # uncaptured value would be emitted, so the function would return
                # an array of $true with the document buried inside it.
                foreach ($blk in @($inner.Blocks)) { $null = $inner.Blocks.Remove($blk); $doc.Blocks.Add($blk) }
            }
            'msgin' {
                # 🔴 A MESSAGE FROM ANOTHER SESSION READ AS SOMETHING YOU TYPED.
                # It arrived as a plain `you said` with its routing envelope
                # printed as prose - and 8,304 of them exist on this machine.
                # The pane's whole job is saying who is speaking, so it says so:
                # who it came from, in the traffic hue, with the arrow that
                # means inbound.
                $trail = ''
                if ($script:docHidden -gt 0) { $trail = "$script:docHidden steps hidden"; $script:docHidden = 0 }
                Add-ReadLabel -Doc $doc -Text ('message from ' + $t.Head) -Brush $Pal.In `
                              -Trailing $trail -TrailBrush $Pal.TextLow -When $t.When
                $inner = New-Object System.Windows.Documents.FlowDocument
                Add-ReadProse -Doc $inner -Text $t.Body -Brush $Pal.TextHigh -Size $script:readSize -Line $script:readLead -Kind 'msgin'
                foreach ($blk in @($inner.Blocks)) { $null = $inner.Blocks.Remove($blk); $doc.Blocks.Add($blk) }
            }
            'said' {
                $trail = ''
                if ($script:docHidden -gt 0) { $trail = "$script:docHidden steps hidden"; $script:docHidden = 0 }
                Add-ReadLabel -Doc $doc -Text 'claude' -Brush $Pal.TextMid -Trailing $trail -TrailBrush $Pal.TextLow -When $t.When
                $inner = New-Object System.Windows.Documents.FlowDocument
                Add-ReadProse -Doc $inner -Text $t.Body -Brush $Pal.TextHigh -Size $script:readSize -Line $script:readLead -Kind 'said'
                foreach ($blk in @($inner.Blocks)) { $null = $inner.Blocks.Remove($blk); $doc.Blocks.Add($blk) }
            }
            'compact' {
                # 🔴 THE STRONGEST BREAK IN THE TRANSCRIPT, because it is the
                # one place the conversation genuinely restarts: everything
                # above it the session can no longer see in full. It was not
                # drawn at all, so compacting a session and then reading it here
                # showed nothing happening.
                $st = New-Object System.Windows.Controls.StackPanel
                $st.Orientation = 'Horizontal'
                $null = $st.Children.Add((New-ReadText -Text 'COMPACTED' -Brush $Pal.Tool))
                if ("$($t.Body)".Trim()) {
                    $tb = New-ReadText -Text "$($t.Body)" -Brush $Pal.TextLow
                    $tb.Margin = New-Object System.Windows.Thickness 10, 0, 0, 0
                    $null = $st.Children.Add($tb)
                }
                $doc.Blocks.Add((New-RailBlock -Child $st -Kind 'compact' -Top 20 -Bottom 16))
            }
            'hook' {
                # What a hook actually said. It rides on a record with no message
                # at all, which is why none of this ever reached the pane.
                #
                # The 600-character cap is gone with the rest of them: folded it
                # is one line, opened it is the whole hook.
                # 🔴 A HOOK IS MACHINERY AND `hidden` MEANS HIDDEN. Every one of
                # the other machine kinds took this gate and this one did not,
                # which on a machine whose UserPromptSubmit hook fires on every
                # prompt left a HOOK block over every turn in the document with
                # Steps set to hidden. The count is kept, so the next thing
                # somebody says still reports how much was put away.
                if ($script:toolView -eq 'hidden') { $script:docHidden++; break }
                $body = "$($t.Body)".Trim()
                $fp = New-FoldPanel -Caption ("HOOK  " + $t.Head) -Brush $Pal.Tool -Kind 'text' `
                                    -Data $body -Trailing (Get-SRHeadLine $body 84 -Plain) `
                                    -Open ($script:toolView -eq 'full')
                $doc.Blocks.Add((New-RailBlock -Child $fp -Kind 'hook' -Rail))
            }
            'system' {
                # 🔴 THE CAPTION IS NOW THE CONTROL. It used to be a label, and
                # `Steps: full` was the only switch - so "16 NOTICES" was
                # followed by all sixteen and there was no way to shut just this
                # one. It folds on its own now; Steps only chooses where it
                # starts. Nothing is discarded either way.
                if ($script:toolView -eq 'hidden') { $script:docHidden += [int]$t.Count; break }
                $n = [int]$t.Count
                if ($n -lt 1) { $n = 1 }
                $body = "$($t.Body)"
                $fp = New-FoldPanel -Caption $(if ($n -eq 1) { 'NOTICE' } else { "$n NOTICES" }) `
                                    -Brush $Pal.Tool -Kind 'text' -Data $body `
                                    -Trailing (Get-SRHeadLine $body 88 -Plain) `
                                    -Open ($script:toolView -eq 'full')
                $doc.Blocks.Add((New-RailBlock -Child $fp -Kind 'system' -Top 9 -Bottom 5))
            }
            'file' {
                # The list a compact prints when it re-reads what it needs.
                if ($script:toolView -eq 'hidden') { $script:docHidden++; break }
                $n = [int]$t.Count
                $word = 'files'; if ($n -eq 1) { $word = 'file' }
                $body = "$($t.Body)".Trim()
                $fp = New-FoldPanel -Caption ('{0}  {1} {2}' -f $t.Head, $n, $word) `
                                    -Brush $Pal.Tool -Kind 'text' -Data $body `
                                    -Trailing (Get-SRHeadLine $body 84) `
                                    -Open ($script:toolView -eq 'full')
                $doc.Blocks.Add((New-RailBlock -Child $fp -Kind 'file' -Rail))
            }
            'asked' {
                # 🔴 A QUESTION YOU ANSWERED, READ AS ONE. It used to arrive as
                # a tool card whose argument was PowerShell's dump of the input
                # object - "@{question=The pane can't beat the transcript..." -
                # followed by a result that was one run-on line of quoted pairs
                # with any option preview inlined behind pipe characters. Every
                # part of that is machinery, and none of it is what you decided.
                #
                # The record carries the questions and the chosen answers as a
                # map, so this draws exactly that: the question quietly, the
                # answer in the hue the question panel uses, one under the next.
                # It does NOT fold. What you decided is the one thing in this
                # document you never want to have to go and open.
                $st = New-Object System.Windows.Controls.StackPanel
                $null = $st.Children.Add((New-ReadText -Text 'YOU ANSWERED' -Brush $Pal.Ask))
                $first = $true
                foreach ($line in @("$($t.Body)" -split "`n")) {
                    if (-not "$line".Trim()) { continue }
                    $bits = "$line" -split ([string][char]1), 2
                    $qt = "$($bits[0])".Trim()
                    $at = $(if ($bits.Count -gt 1) { "$($bits[1])".Trim() } else { '' })
                    $qb = New-ReadText -Text $qt -Brush $Pal.TextMid -Wrap -Line $script:readLead
                    $qb.Margin = New-Object System.Windows.Thickness 0, $(if ($first) { 8 } else { 11 }), 0, 0
                    $null = $st.Children.Add($qb)
                    $first = $false
                    if ($at) {
                        # -Semi survives here and nowhere else in a label's
                        # neighbourhood: this is not a label, it is WHAT YOU
                        # DECIDED, and it is the one thing in the document you
                        # should never have to hunt for.
                        $ab = New-ReadText -Text $at -Brush $Pal.Ask -Semi -Wrap -Line $script:readLead
                        # 🔴 THE SAME COLUMN AS THE QUESTION ABOVE IT. This was
                        # indented 12px, which made the one block in the
                        # document holding your DECISIONS the one block that
                        # did not line up with anything. Reported as "questions,
                        # or user prompts have different colors or different
                        # alignment than the rest of the text", alongside the
                        # ruling that difference should be carried by colour
                        # alone. The hue already says which line is the answer.
                        $ab.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
                        $null = $st.Children.Add($ab)
                    }
                }
                $doc.Blocks.Add((New-RailBlock -Child $st -Kind 'asked' -Top 14 -Bottom 12 -Rail))
            }
            'queued' {
                # The 400-character cap is gone: folded is a line, opened is what
                # you actually typed.
                $body = Convert-SRSpoken $t.Body
                $fp = New-FoldPanel -Caption 'QUEUED' -Brush $Pal.Out -Kind 'text' -Data $body `
                                    -Trailing (Get-SRHeadLine $body 84) `
                                    -Open ($script:toolView -eq 'full')
                $doc.Blocks.Add((New-RailBlock -Child $fp -Kind 'queued' -Rail))
            }
            'thinking' {
                # Thinking was a single 150-character line with no way to see the
                # rest of it. It folds like everything else now.
                if ($script:toolView -eq 'hidden') { break }
                $body = "$($t.Body)".Trim()
                $fp = New-FoldPanel -Caption 'THINKING' -Brush $Pal.Tool -Kind 'text' -Data $body `
                                    -Trailing (Get-SRHeadLine $body 96) `
                                    -Open ($script:toolView -eq 'full')
                $doc.Blocks.Add((New-RailBlock -Child $fp -Kind 'thinking' -Top 9 -Bottom 5))
            }
            'run' {
                # 🔑 HIDDEN HIDES HISTORY, NOT WHAT IS STILL HAPPENING. A run
                # whose shell is still open keeps its one-line fold, because its
                # output is only reachable through that fold. Everything
                # finished still goes away and is still counted.
                if ($script:toolView -eq 'hidden') {
                    $runLive = $false
                    if ($script:docLiveShells -and $script:docLiveShells.Count) {
                        foreach ($c1 in $t.Calls) {
                            $sh = "$($c1.Shell)"
                            if ($sh -and $script:docLiveShells.Contains($sh)) { $runLive = $true; break }
                        }
                    }
                    if (-not $runLive) { $script:docHidden += @($t.Calls).Count; break }
                }

                # 🔴 EVERY CALL, NOT THE FIRST EIGHT. The old renderer stopped
                # at 8 and printed "and N more" - a run of twelve tool calls
                # could not be read here at all. Add-RunDetail draws all of
                # them, lazily, and only once this block is opened.
                #
                # The summary line is the fold's caption, so the thing that
                # looked like a control finally is one.
                # THE BLOCK IS MARKED BY THE MOST NOTABLE THING IN IT. A run
                # that spawned a sub-agent is not the same event as a run of
                # Reads, and at a glance down the gutter that difference is the
                # one worth seeing.
                #
                # 🪤 TWO DIFFERENT "Kind"s ON ONE LINE, and they are not the
                # same argument. New-FoldPanel's -Kind selects which BUILDER
                # fills the panel and must stay 'run'; New-RailBlock's -Kind
                # selects the MARKER. Passing the marker kind to the fold would
                # render the calls as a blob of mono text.
                $rk = 'run'
                foreach ($c0 in @($t.Calls)) {
                    if ("$($c0.CallKind)" -eq 'agent') { $rk = 'agent'; break }
                    if ("$($c0.CallKind)" -eq 'msgout') { $rk = 'msgout'; break }
                    if ("$($c0.CallKind)" -eq 'shell') { $rk = 'shell' }
                }
                $fp = New-FoldPanel -Caption (Get-RunSummary $t.Calls) -Brush (Get-MarkBrush $rk) `
                                    -Kind 'run' -Data $t.Calls `
                                    -Open ($script:toolView -eq 'full')
                $doc.Blocks.Add((New-RailBlock -Child $fp -Kind $rk -Rail))
            }
        }
    }
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
# 🔴 A CONVERSATION MID-TURN CANNOT BE ASKING YOU ANYTHING.
#
# The question is read off the session's SCREEN, and a screen mid-reply is full
# of whatever claude is writing. Measured on millwright-strategy: a reply
# containing a numbered list - "1. The failure is now a carried rule / 2. The
# registration commit / 3. The lane is resumed" - was read as a three-option
# menu and drawn as a question panel, with the prose as its options. Nothing was
# selectable because nothing was a menu.
#
# The follow tick already refused to read a busy session (see its own guard);
# Update-Ask and the background probe did not, so both paths could put a
# fabricated question on screen. This is the one gate all three now pass.
# 🔴 A QUESTION THAT CANNOT BE READ USED TO SHOW NOTHING AT ALL.
#
# Reported from a fresh clone on another machine: "it is getting asked a
# question but the tool does not show me the question". Every path here failed
# SILENTLY - Test-AskAllowed returned false and the panel was simply hidden, so
# a conversation the list itself was marking NEEDS YOU had an empty foot and no
# way to find out why. The reason is always known at the point of the refusal;
# it was just thrown away.
#
# 🪤 The reason is only DRAWN for a conversation that is actually waiting on
# you. Every idle session in the list also has no question, and putting an
# explanation under each of them would be noise on the surface this pane exists
# to keep quiet.
function Get-AskBlocker { param($R)
    if (-not $R) { return 'nothing is selected' }
    if (-not $R.A -or -not $R.A.Pid) {
        return 'this conversation is not running, so there is no screen to read a question from'
    }
    if ("$($R.A.Status)" -eq 'busy') {
        return 'it is mid-turn - a question can only be read once it stops'
    }
    return ''
}

function Test-AskAllowed { param($R)
    return (-not (Get-AskBlocker $R))
}

# ===========================================================================
# 🔴 INTERRUPT IS THE EXACT OPPOSITE GATE TO Get-AskBlocker, AND THAT IS THE
# WHOLE SAFETY ARGUMENT.
#
# A question can only be READ off a session that has STOPPED - that is what
# Get-AskBlocker says. An interrupt is only MEANINGFUL on a session that is
# still going. Same evidence, opposite answer, and they must never both allow:
# Esc into a session sitting at its prompt does not stop anything, it clears
# whatever is typed there, and pressed twice it opens the rewind picker, which
# offers to revert CODE. That is why this refuses on anything but 'busy' rather
# than merely warning - Send-SRInterrupt sends its key blind, so this gate is
# the only thing standing between the button and that.
#
# 🪤 'busy' IS THE AGENT PROBE'S WORD, not an inference from the transcript. A
# row can look busy because its transcript grew a moment ago and still be idle
# now; the probe asks claude itself. Anything the probe has not called busy -
# idle, waiting, a background agent, a session with no process - is refused.
function Get-InterruptBlocker { param($R)
    if (-not $R) { return 'nothing is selected' }
    if (-not $R.A -or -not $R.A.Pid) {
        return 'this conversation is not running, so there is nothing to interrupt'
    }
    if ("$($R.A.Kind)" -ne 'interactive') {
        return 'that is a background agent - it has no console to press Esc in'
    }
    if ("$($R.A.Status)" -ne 'busy') {
        return 'it is not mid-turn - there is nothing running to interrupt, and Esc at its prompt would clear what you have typed'
    }
    return ''
}

# Does the list think this conversation is waiting on the operator? That is what
# makes an unreadable question worth explaining rather than ignoring.
function Test-AskExpected { param($R)
    if (-not $R) { return $false }
    return ("$($R.Band)" -eq 'needs')
}

function Show-AskWhy { param($R, [string]$Why)
    Show-Ask $null
    if (-not $Why -or -not (Test-AskExpected $R)) { return }
    $ui.AskHeader.Text = 'waiting on you'
    $ui.AskText.Text = 'Its question could not be read from the screen.'
    $ui.AskNote.Text = $Why
    $ui.AskNote.Visibility = $V_Show
    $ui.AskBox.Visibility = $V_Show
}

# ===========================================================================
# 🔴 A NUMBERED LIST IS NOT A MENU, AND THE WINDOW SPENT A DAY INSISTING IT WAS.
#
# Reported: the card demanded an answer to a question neither the terminal nor
# the phone was showing. The session had written two decisions as ORDINARY PROSE
# in a numbered list - it wrote them that way precisely BECAUSE a rule forbade it
# using the selectable prompt - and Invoke-SRParseScreenQuestion turned the prose
# straight back into a prompt. Its defences are "starts at 1", "consecutive" and
# "at least two", and a 1./2. list clears all three.
#
# 🔑 THE THING THAT TELLS THEM APART IS THE HIGHLIGHT. A live TUI menu always has
# its cursor somewhere; prose never does. The parser already knows this and says
# so in its own contract - "-1 when no cursor could be seen. A caller that cannot
# see the cursor must not send arrows on a guess" - and every caller on the
# SENDING side honours it. The drawing side never asked.
#
# 🪤 SCREEN-DERIVED ONLY. A question built from the TRANSCRIPT by
# Get-SRPendingQuestion carries no cursor at all, because a transcript has no
# highlight to read; gating Show-Ask itself would blank the card for every
# question the pane recovers that way. So this guards the three places that draw
# from a SCREEN, and nothing else.
function Test-ScreenMenu { param($Q)
    if (-not $Q -or -not @($Q.Options).Count) { return $false }
    $at = -1
    try {
        if ($Q.PSObject.Properties['CursorAt'] -and $null -ne $Q.CursorAt) { $at = [int]$Q.CursorAt }
    } catch { $at = -1 }
    return ($at -ge 0)
}

function Update-Ask { param($R)
    $why = Get-AskBlocker $R
    if ($why) { Show-AskWhy -R $R -Why $why; return }
    $q = $null
    $err = ''
    try { $q = Get-SRScreenQuestion -ProcessId ([int]$R.A.Pid) } catch { $err = "$($_.Exception.Message)" }
    if (Test-ScreenMenu $q) { Show-Ask $q; return }
    # 🪤 READING THE SCREEN IS THE PART THAT BREAKS ON A NEW MACHINE. The reader
    # is a small C# helper compiled into .state\ on demand, and .state\ is
    # gitignored - so a fresh clone builds it on first use and a machine without
    # csc.exe falls back to a slower PowerShell path. When neither works there
    # is no question and, until now, no explanation either.
    Show-AskWhy -R $R -Why $(if ($err) {
        "the screen reader failed: $err"
    } else {
        'nothing that looks like a question is on its screen - it may have just been answered, or the screen could not be read (see .state\restore.log)'
    })
}

# ===========================================================================
# THE ROUND, DRAWN THE WAY THE TERMINAL DRAWS IT.
#
# 🔑 The terminal's bar is `<-  [ ] Alpha  [x] Beta  (v) Submit  ->`, and the two
# arrows are the whole navigation: LEFT and RIGHT step between questions.
#
# 🪤 WHICH TAB IS ACTIVE IS NOT IN THE TEXT, and it is not guessed at here. The
# terminal marks it with colour, and the screen reader takes CHARACTERS off the
# console buffer (ReadConsoleOutputCharacterW) - attributes never reach us. So
# the chips report STATE, which the boxes do carry, and the two arrow buttons
# carry the MOVEMENT, which needs a direction and not a position. That is also
# exactly the pair the terminal itself offers; inventing a highlight we cannot
# read would be the one thing this relay refuses to do.
function New-AskTabChip {
    param([string]$Label, [bool]$Answered)
    $bd = New-Object System.Windows.Controls.Border
    $bd.Background = $PalGlass
    $bd.CornerRadius = New-Object System.Windows.CornerRadius 5
    $bd.Padding = New-Object System.Windows.Thickness 8, 2, 9, 3
    $bd.Margin = New-Object System.Windows.Thickness 0, 0, 6, 5
    $bd.ToolTip = $(if ($Answered) { "'$Label' has been answered - step back to it to see or change your answer" }
                    else { "'$Label' has not been answered yet" })
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $mark = New-Object System.Windows.Controls.TextBlock
    # The terminal's own two states, in this window's type: a ring until it is
    # answered, a tick once it is.
    $mark.Text = $(if ($Answered) { [string][char]0x2714 } else { [string][char]0x25CB })
    $mark.Foreground = $(if ($Answered) { $Pal.Ask } else { $window.FindResource('TextLow') })
    $mark.FontSize = $script:Type.Caption
    $mark.FontFamily = $script:UiFace
    $mark.VerticalAlignment = 'Center'
    $mark.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
    $null = $sp.Children.Add($mark)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Label
    $t.FontSize = $script:Type.Caption
    $t.FontFamily = $script:UiFace
    $t.VerticalAlignment = 'Center'
    $t.Foreground = $(if ($Answered) { $window.FindResource('TextMid') } else { $window.FindResource('TextLow') })
    $null = $sp.Children.Add($t)
    $bd.Child = $sp
    return $bd
}

function New-AskArrow {
    param([string]$Glyph, [int]$Delta, [string]$Tip)
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $window.FindResource('BtnSlim')
    $b.Content = $Glyph
    $b.Margin = New-Object System.Windows.Thickness 0, 0, 8, 5
    $b.Tag = $Delta
    $b.ToolTip = $Tip
    $b.Add_Click({ param($s, $e) Invoke-AskMove ([int]$s.Tag) })
    return $b
}

function Show-Ask { param($q)
    $ui.AskBox.Visibility = $V_Hide
    $ui.AskOptions.ItemsSource = $null
    $ui.AskTabs.ItemsSource = $null
    $ui.AskTabs.Visibility = $V_Hide
    $ui.AskFreeBox.Visibility = $V_Hide
    $ui.AskReview.ItemsSource = $null
    $ui.AskReview.Visibility = $V_Hide
    # 🔴 CLEARED ON EVERY PATH. It used to be set only after the early return, so
    # selecting a conversation that was not running left the PREVIOUS one's
    # question in it - and the answer record then filed another conversation's
    # options against this answer. That record exists to settle a wrong reading;
    # one that names the wrong menu is worse than none at all.
    $script:lastAsk = $q
    # 🔑 AND THE POLL'S SIGNATURE WITH IT. Every other path that draws the card -
    # the probe, the answer landing, a round move - must leave the fast lane
    # agreeing with what is now on screen, or its next tick would redraw the
    # identical menu and take the focus back off whatever the operator was doing.
    try { $script:askSig = Get-AskSignature $q } catch { $script:askSig = '' }
    # 🔴 AND THE POLL'S TEXT CACHE. The signature alone is not enough: the fast
    # lane skips the parse entirely when the SCREEN has not changed, so a card
    # blanked from here while the terminal is still showing the same menu would
    # stay blank - the poll would keep matching its cached text and returning
    # before it ever looked. Every path that draws or blanks the card has to
    # leave the lane willing to read again, not just agreeing about the drawing.
    $script:askText = $null
    if (-not $q -or -not @($q.Options).Count) { return }

    $ui.AskHeader.Text = $(if ("$($q.Header)") { "$($q.Header)".ToUpper() } else { 'IT IS ASKING' })
    $ui.AskText.Text   = "$($q.Question)"

    # 🪤 READ THE ROUND FIELDS DEFENSIVELY, because not every question HAS them.
    # Only the screen parser fills these in; Get-SRPendingQuestion builds a
    # question out of the transcript and knows nothing about tabs or ticks, and a
    # test builds one by hand. On a PSCustomObject a missing property reads as
    # $null, and [int]$null is 0 - so "which option did you choose" silently
    # became "the first one" and every transcript-derived question drew a tick it
    # had no business drawing. Absent means -1 here, and -1 means nobody knows.
    $askInt = {
        param($Obj, [string]$Name, [int]$Fallback)
        if ($Obj -and $Obj.PSObject.Properties[$Name] -and $null -ne $Obj.$Name) { return [int]$Obj.$Name }
        return $Fallback
    }
    $chosenAt = & $askInt $q 'ChosenAt' -1
    $freeAt   = & $askInt $q 'FreeAt'   -1
    $realCnt  = & $askInt $q 'RealCount' 0

    # ---- the round, when this question is one of several ----------------
    $tabs = @()
    if ($q.PSObject.Properties['Tabs']) { $tabs = @($q.Tabs) }
    if ($tabs.Count -ge 2) {
        $strip = New-Object System.Collections.Generic.List[object]
        $strip.Add((New-AskArrow -Glyph ([string][char]0x2039) -Delta -1 -Tip 'Back to the previous question - your answer to it is shown as you left it'))
        foreach ($t in $tabs) { $strip.Add((New-AskTabChip -Label "$($t.Label)" -Answered ([bool]$t.Answered))) }
        $strip.Add((New-AskArrow -Glyph ([string][char]0x203A) -Delta 1 -Tip 'On to the next question'))
        $ui.AskTabs.ItemsSource = $strip.ToArray()
        $ui.AskTabs.Visibility = $V_Show
    }

    # ---- the review, on the round's last tab -----------------------------
    if ($q.PSObject.Properties['Review'] -and $q.Review) {
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($a in @($q.Review.Answers)) {
            $bd = New-Object System.Windows.Controls.Border
            $bd.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
            $sp2 = New-Object System.Windows.Controls.StackPanel
            $qt = New-Object System.Windows.Controls.TextBlock
            $qt.Text = "$($a.Question)"
            $qt.TextWrapping = 'Wrap'
            $qt.FontSize = $script:Type.Body
            $qt.Foreground = $window.FindResource('TextMid')
            $qt.FontFamily = $script:UiFace
            $null = $sp2.Children.Add($qt)
            $at2 = New-Object System.Windows.Controls.TextBlock
            $at2.Text = "$($a.Answer)"
            $at2.TextWrapping = 'Wrap'
            $at2.FontSize = $script:Type.Strong
            $at2.FontWeight = $FW_Semi
            $at2.Foreground = $Pal.Ask
            $at2.FontFamily = $script:UiFace
            $at2.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
            $null = $sp2.Children.Add($at2)
            $bd.Child = $sp2
            $rows.Add($bd)
        }
        if ($rows.Count) {
            $ui.AskReview.ItemsSource = $rows.ToArray()
            $ui.AskReview.Visibility = $V_Show
        }
    }

    # AN OPTION IS A LABEL AND ITS REASONING, and the reasoning is why you would
    # pick it. Each row carries both: the label on top, what claude wrote
    # underneath it, in the same order it was drawn on screen.
    #
    # 🔴 A NUMBERED BADGE, NOT "1." IN THE LABEL. The number is how you answer -
    # it is the key you press - so it is a control, and it belongs in its own
    # column where the eye can run down it. Inline it was just the first two
    # characters of a wrapping sentence, and on a four-line option it ended up
    # nowhere near the option it numbered.
    $details = @($q.Details)
    # 🔴 THE TWO ROWS THE TUI ADDS ARE NOT OPTIONS, and drawing them as buttons
    # was a live hazard: ENTER on an empty "Type something" DECLINES THE WHOLE
    # ROUND, measured twice. RealCount is everything before that row; the editor
    # gets a text box of its own below, and "Chat about this" is not offered at
    # all - it cancels the question, which is not something to reach for by
    # mistake from a list of answers.
    $real = @($q.Options)
    $shown = $realCnt
    if ($shown -gt 0 -and $shown -lt $real.Count) { $real = @($real[0..($shown - 1)]) }
    $ticked = @{}
    # 🪤 Same trap as ChosenAt: @($null) is a ONE-element array holding $null, and
    # [int]$null is 0 - so a question with no Ticked property marked option 1 as
    # already ticked. Only iterate what is actually there.
    if ($q.PSObject.Properties['Ticked'] -and $null -ne $q.Ticked) {
        foreach ($t in @($q.Ticked)) { if ($null -ne $t) { $ticked[[int]$t] = $true } }
    }
    $chosen = $chosenAt
    $btns = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($o in $real) {
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $window.FindResource('BtnOption')
        $b.HorizontalContentAlignment = 'Stretch'
        $b.Margin = New-Object System.Windows.Thickness 0, 0, 0, 7
        $b.Tag = $n

        $g = New-Object System.Windows.Controls.Grid
        $cBadge = New-Object System.Windows.Controls.ColumnDefinition
        $cBadge.Width = New-Object System.Windows.GridLength 0, 'Auto'
        $cBody = New-Object System.Windows.Controls.ColumnDefinition
        $g.ColumnDefinitions.Add($cBadge)
        $g.ColumnDefinitions.Add($cBody)

        $badge = New-Object System.Windows.Controls.Border
        $badge.Width = 22; $badge.Height = 22
        $badge.CornerRadius = New-Object System.Windows.CornerRadius 11
        $badge.Background = $PalWash.Ask
        $badge.VerticalAlignment = 'Top'
        $badge.Margin = New-Object System.Windows.Thickness 0, 1, 13, 0
        $bt = New-Object System.Windows.Controls.TextBlock
        # 🔑 WHAT YOU ALREADY CHOSE, IN THE BADGE. Coming back to an answered
        # question, the terminal redraws the chosen row with a trailing tick and
        # a ticked multi-select box with "[✔]" - so the badge that normally
        # carries the key you would press carries the tick instead. It is the
        # same slot, saying the same thing the terminal says in the same place.
        $isOn = $(if ($q.Multi) { [bool]$ticked[$n] } else { $n -eq $chosen })
        $bt.Text = $(if ($isOn) { [string][char]0x2714 } else { "$($n + 1)" })
        $bt.Foreground = $Pal.Ask
        $bt.FontSize = $script:Type.Caption
        $bt.FontWeight = $FW_Semi
        $bt.FontFamily = $script:UiFace
        $bt.HorizontalAlignment = 'Center'
        $bt.VerticalAlignment = 'Center'
        $badge.Child = $bt
        [System.Windows.Controls.Grid]::SetColumn($badge, 0)
        $null = $g.Children.Add($badge)

        $stack = New-Object System.Windows.Controls.StackPanel
        [System.Windows.Controls.Grid]::SetColumn($stack, 1)
        $lab = New-Object System.Windows.Controls.TextBlock
        $lab.Text = "$o"
        $lab.TextWrapping = 'Wrap'
        $lab.FontSize = $script:Type.Body
        $lab.FontWeight = $FW_Semi
        # The first option is the one claude put first, and on a recommended
        # menu that is the recommendation. It is tinted, not bolder: this panel
        # already has one weight doing work.
        $lab.Foreground = $(if ($n -eq 0) { $Pal.Ask } else { $window.FindResource('TextMax') })
        $null = $stack.Children.Add($lab)

        $d = $(if ($n -lt $details.Count) { "$($details[$n])".Trim() } else { '' })
        if ($d) {
            $sub = New-Object System.Windows.Controls.TextBlock
            $sub.Text = $d
            $sub.TextWrapping = 'Wrap'
            $sub.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
            $sub.Foreground = $window.FindResource('TextMid')
            $sub.FontSize = $script:Type.Caption
            $sub.LineHeight = 18
            $sub.LineStackingStrategy = 'BlockLineHeight'
            $null = $stack.Children.Add($sub)
        }
        $null = $g.Children.Add($stack)

        $b.Content = $g
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

    # ---- answering in your own words -------------------------------------
    # 🔑 PREFILLED WITH WHAT IS ALREADY IN THE ROW. Come back to a question you
    # answered in your own words and the terminal redraws the row holding that
    # text; this box shows the same thing, so what you typed is visible rather
    # than something you have to remember. That was the operator's actual ask.
    if ($freeAt -ge 0) {
        # 🔴 IT TYPED OVER YOU. Reported as "I just tried typing into the free
        # text answer field and the text just simply disappeared after I
        # typed". This line ran on EVERY dressing of the panel, and the panel
        # is re-dressed by the background probe and by the follow tick - so a
        # few seconds after you started typing, whatever the terminal's own row
        # held (usually nothing) was written over what you were in the middle
        # of writing. The prefill above is still the right behaviour when you
        # arrive at a question; it is only wrong once the box is yours.
        #
        # 🪤 THE FLAG IS SET BY TYPING, NOT BY THE TEXT CHANGING. This
        # assignment raises TextChanged itself, so a handler that simply marked
        # the box dirty on any change would mark it dirty the first time the
        # panel drew - and the prefill would then never happen again for the
        # life of the window. $askFreeWriting is what tells the two apart.
        # 🔴 THE RESET BELONGS TO A CHANGE OF QUESTION, NOT TO A REDRAW - AND
        # THE FIRST VERSION OF THIS GUARD GOT THAT WRONG IN A WAY THAT MADE IT
        # INERT. It cleared the flag where AskFreeBox is hidden, on the reading
        # that a hidden panel means the question is gone. But Show-Ask hides
        # that box in its OPENING LINES, on every single call, including the
        # calls that re-show it moments later - so the reset ran at body line 8
        # and the guard that reads it at body line 225, and the flag was always
        # false by the time it mattered. Caught by the control audit, which
        # watched the flag directly: after typing True, after ONE redraw of the
        # SAME question False, box empty. The hidden state the reset keyed on is
        # never a state the operator sees; it lasts microseconds inside a redraw.
        #
        # 🪤 AND THE KEY DELIBERATELY OMITS CursorAt AND Ticked. Get-AskSignature
        # includes both because a round being WORKED changes only those and a
        # card that ignored them would freeze on its first frame. Here the
        # question is exactly the opposite thing: moving the terminal cursor one
        # row is the same question, and treating it as a new one would empty the
        # box on a keystroke in another window - which is the reported defect
        # wearing a different cause.
        # 🔴 AND THE CONVERSATION IT BELONGS TO. Without this the key is the
        # QUESTION alone, and two sessions running the same prompt ask a
        # byte-identical one - so typing meant for A survived a switch to B and
        # could be SENT there, into a different live console. Found by the
        # control audit as a residual it could not reproduce but could read off
        # the key, which is the right way to report a hazard you cannot stage.
        # Losing what you typed is an annoyance; sending it to the wrong session
        # is the class of mistake this whole tool is built to avoid.
        $qKey = "$($script:selId)|$($q.Question)|$($q.Header)|" + ((@($q.Options) | ForEach-Object { "$_" }) -join ([string][char]1))
        if ($qKey -ne $script:askFreeKey) {
            $script:askFreeKey = $qKey
            $script:askFreeDirty = $false
        }
        if (-not $script:askFreeDirty) {
            $script:askFreeWriting = $true
            try { $ui.AskFree.Text = "$($q.FreeText)" } finally { $script:askFreeWriting = $false }
        }
        $ui.AskFreeLabel.Text = $(if ("$($q.FreeText)" -and $chosenAt -eq $freeAt) {
                'YOUR ANSWER, IN YOUR OWN WORDS'
            } elseif ("$($q.FreeText)") { 'TYPED, NOT YET SENT' }
            else { 'OR ANSWER IN YOUR OWN WORDS' })
        $ui.AskFreeBox.Visibility = $V_Show
    }

    if ($q.Multi) {
        $ui.AskNote.Text = 'Several answers - pick every one that applies, then Submit. Measured against a real round on 2026-08-30: ENTER toggles a box, and every send is recorded to .state.'
        $ui.AskNote.Visibility = $V_Show
    } elseif ($chosenAt -ge 0) {
        $ui.AskNote.Text = 'You have answered this one - the tick shows what you chose. Picking another replaces it.'
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
# 🪤 THE OPTIMISTIC MOVE IS NOT A GUESS ABOUT THE FUTURE, it is a statement
# about the past: keys have just been delivered to that session, so it is no
# longer waiting on you whatever it does next. The probe is kicked in the same
# breath and overwrites this with measured truth within a second or two; if it
# comes back still waiting - because it asked something new - the real state
# wins. Nothing here fakes a state that is not about to be confirmed.
function Move-RowToWorking { param($Row)
    if (-not $Row) { return }
    # Keys have just been delivered, so whatever menu the last screen read saw
    # has been answered. Clearing the flag as well as the band is what keeps the
    # next recompute from deriving 'needs' straight back out of stale evidence.
    $null = Set-AskSeen -Id "$($Row.Id)" -Asking $false
    $Row.Band = 'working'
    # 🔴 AND SAY SO AT ONCE, RATHER THAN IN FIFTEEN SECONDS. Reported as "I am
    # missing an indicator that shows the session is currently working".
    #
    # The indicator already existed - Set-WorkingPulse breathes the state dot -
    # but it is driven from $r.A.Status, which is the AGENT PROBE's answer and
    # is refreshed on its own schedule. So keys were delivered, the row moved to
    # WORKING in the list, and the pane went on saying 'waiting for you' with a
    # still dot until the probe caught up. Nothing was wrong except the delay,
    # and a liveness indicator that lags by fifteen seconds is not one.
    #
    # 🪤 MUTATING THE PROBE'S RECORD IS A LIE THE NEXT PROBE CORRECTS, and it is
    # the RIGHT lie: keys have just been delivered to that console, so it IS
    # mid-turn - this window knows that before any probe can. The same reasoning
    # already justifies setting Band above.
    try { if ($Row.A) { $Row.A.Status = 'busy' } } catch { }
    try {
        $sel = $ui.SessionList.SelectedItem
        if ($sel -and $sel.Kind -eq 'session' -and "$($sel.Row.Id)" -eq "$($Row.Id)") {
            Set-WorkingPulse $true
            $ui.PaneState.Text = ('WORKING   |   just sent, waiting for it to start   |   {0}' -f (Get-ProjectLabel "$($Row.D.path)"))
        }
    } catch { }
    try { Build-Sessions } catch { }
    try { Update-SendState } catch { }
    # Restart rather than merely start, so the next scheduled probe is a full
    # interval after THIS one instead of arriving on top of it.
    try {
        $script:liveTimer.Stop()
        Start-LiveProbe
        $script:liveTimer.Start()
    } catch { }
}

# ===========================================================================
# ANSWERING, WITHOUT THE WINDOW STOPPING.
#
# 🔴 THE CLICK USED TO DO ALL OF IT ON THE UI THREAD. Send-SRQuestionAnswer
# reads the target session's CONSOLE to find the cursor before a single key
# leaves - a child process with a budget measured in SECONDS - and then the
# handler read the screen a SECOND time to see what the round did next. Both on
# the thread that draws. Pressing an option froze the window for as long as
# both reads took, which is the "answering a question is laggy" report.
#
# The click now does only what a click can afford: it disables the options so
# the same answer cannot be sent twice, says what it is doing, and hands the
# work to a runspace. The lane collects it.
#
# 🪤 THE BUTTONS ARE DISABLED, NOT LEFT LIVE WITH A STATUS LINE. Returning
# immediately means the operator can press a second option while the first is
# still travelling, and two arrow-key sequences interleaved on one menu would
# answer a question nobody chose. Disabling is what makes returning early safe.
$script:ansPs = $null
$script:ansRs = $null
$script:ansHandle = $null
$script:ansFor = $null

# 🔴 ALL THREE SENDS, NOT JUST THE OPTION CLICK. Answering went off the UI
# thread months ago and the other two never did - and they are the SAME shape of
# work. Invoke-SRRoundMove reads the screen, then sends up to eight keys and
# verifies EACH ONE by reading the screen again; the typed answer writes the
# text, re-reads to confirm the row is holding it, and only then sends ENTER.
# Both ran on the thread that draws, so "navigating backwards from a question"
# and "typing an answer" froze the window for as long as all of those reads
# took - which is exactly the pair the operator named alongside answering.
#
# One job with a Kind rather than three lanes: the guard that refuses a second
# send while one is in flight, the 25-second timeout that gives the panel back,
# and the collector are all things there must be exactly one of.
# ===========================================================================
# A RUNSPACE READY BEFORE IT IS ASKED FOR.
#
# 🔴 OPENING ONE COSTS 17-25 ms ON THE THREAD THAT DRAWS, and this window opens
# them on gestures. Audited 2026-09-05: Start-AskSend is 19.41 ms before a
# single key is sent, and Start-DocParse is 24.9 ms of which 17.4 is the bare
# runspace.Open() - so a cold conversation click can open TWO, one for the parse
# and one for the probe Show-Selected kicks. That is three frames of nothing,
# paid before any of the actual work starts, on the two most repeated gestures
# in the tool.
#
# The cost is not avoidable, but the TIMING is: one spare is kept open, a click
# takes it, and the replacement is built at ApplicationIdle - which is precisely
# "when the operator is not waiting for anything".
#
# 🔒 ON THE DISPATCHER, DELIBERATELY, NOT ON A THREADPOOL THREAD. Warming off
# the UI thread would save nothing that matters (the cost is already off the
# click) and would buy a race on $script:spareRs for it. Idle priority means it
# cannot delay a gesture: the dispatcher runs it only when there is nothing else
# to do.
#
# 🪤 ONE SPARE, NOT A POOL. Every open runspace holds a thread; a pool would
# trade a visible 20 ms for an invisible handful of threads sitting idle for
# hours, which is the kind of thing this tool is supposed to be fixing.
$script:spareRs = $null

function New-SRRunspace {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('SRHere', $here)
    return $rs
}

function Request-SRSpareRunspace {
    if ($script:spareRs) { return }
    try {
        $null = $window.Dispatcher.BeginInvoke([Action]{
            if ($script:spareRs) { return }
            try { $script:spareRs = New-SRRunspace } catch { $script:spareRs = $null }
        }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    } catch { }
}

# Hand out the spare if there is one, build one if there is not, and queue the
# next either way. The caller owns what it gets and disposes it as before.
function Get-SRRunspace {
    $rs = $script:spareRs
    $script:spareRs = $null
    if (-not $rs) {
        try { $rs = New-SRRunspace } catch { return $null }
    }
    Request-SRSpareRunspace
    return $rs
}

$script:AnswerJob = {
    . (Join-Path $SRHere '_common.ps1')
    # ===================================================================
    # 🔴 THE HELD-OPEN READER IS PER RUNSPACE, AND ONLY THE UI EVER ASKED FOR
    # ONE. Connect-SRScreenServer refuses a first start unless SR_ScreenWant is
    # set, and the sole caller of Start-SRScreenServer was the window's own
    # startup - so every job spawned the reader exe once per read.
    #
    # That silently defeated a tuning decision two files away:
    # Wait-SRScreenState's SliceMs was dropped to 8 on the basis that a served
    # read is ~5 ms, and answering does one read to find the cursor and then
    # another per iteration until the highlight arrives. Unserved those are ~78
    # ms each, so the loop was paced entirely by the reads and the slice was
    # decoration.
    #
    # 🔑 AND IT PAYS FROM THE FIRST READ, which is not what I expected. Starting
    # the server costs a process spawn, so a job that reads once looked like a
    # net loss. Measured in this exact shape - fresh runspace, dot-source, then
    # N reads of a live console, 30 of them on the machine:
    #
    #     reads      spawn-per-read     held-open
    #         1            244 ms         134 ms
    #         2            162 ms          88 ms
    #         5            365 ms         124 ms
    #        16          1,096 ms         224 ms
    #
    # There is no crossover to find: one served read plus the server start still
    # beats one spawn-per-read, because that path also writes a temp file, waits
    # on process exit, reads it back and deletes it.
    #
    # 🔒 AND IT IS STOPPED AGAIN BELOW. The server is a child process that
    # outlives the runspace - it self-exits after 30 s idle, but a backstop is
    # not a substitute for closing what you opened, and answers happen far more
    # often than every 30 s.
    $null = Start-SRScreenServer
    $why = ''
    # 🔴 NO 'default' THAT ANSWERS. The obvious way to write this switch puts the
    # option click in the default arm - and then ANY kind that does not match,
    # including one misspelled at a call site, COMMITS AN ANSWER. Pressing "back"
    # would answer the question. Every arm is named and anything else refuses,
    # because the failure this shape prevents is silent and irreversible.
    try {
        switch ("$($SRAns.Kind)") {
            'answer' { $why = Send-SRQuestionAnswer -SessionId $SRAns.SessionId -Index $SRAns.Index `
                                                    -ProcessId ([int]$SRAns.Pid) -Kind "$($SRAns.AgentKind)" `
                                                    -Name "$($SRAns.AgentName)" -MenuSeen ([bool]$SRAns.MenuSeen) }
            'move'   { $why = Invoke-SRRoundMove -ProcessId ([int]$SRAns.Pid) -Delta ([int]$SRAns.Delta) }
            'typed'  { $why = Invoke-SRAnswerTypedOnScreen -ProcessId ([int]$SRAns.Pid) -Text "$($SRAns.Text)" -Who "$($SRAns.SessionId)" }
            'send'   { $why = Send-SRSessionInput -SessionId $SRAns.SessionId -Text "$($SRAns.Text)" `
                                                  -ProcessId ([int]$SRAns.Pid) -Kind "$($SRAns.AgentKind)" `
                                                  -WaitingFor "$($SRAns.AgentWaitingFor)" `
                                                  -Force:([bool]$SRAns.Force) }
            # 🪤 NAMED LIKE THE REST, and it is the one arm that picks nothing:
            # Esc stops a turn rather than choosing an option, so there is no
            # index to be wrong about and no screen to verify against. The
            # safety is entirely in the gate at the click - Get-InterruptBlocker
            # - which is why THAT is what the suite asserts on.
            'esc'    { $why = Send-SRInterrupt -ProcessId ([int]$SRAns.Pid) -Who "$($SRAns.SessionId)" }
            default  { $why = "nothing was sent - '$($SRAns.Kind)' is not a kind of send this knows" }
        }
    }
    catch { $why = "$($_.Exception.Message)" }
    # Close the reader this job opened. See the note above: it would go on its
    # own after 30 s idle, but sends are far more frequent than that and this
    # machine's conventions single out orphan processes for good reason.
    try { Stop-SRScreenServer } catch { }
    @{ Why = "$why" }
}

# The one place a send is started, whichever gesture asked for it.
function Start-AskSend {
    param(
        [Parameter(Mandatory)][string]$Kind,   # answer | move | typed | send | esc
        [Parameter(Mandatory)]$Row,
        [int]$Index = -1,
        [int]$Delta = 0,
        [string]$Text = '',
        [string]$Saying = 'working...',
        # Lift the dialog/menu refusal. Set ONLY by the composer's retry,
        # after the operator has been shown what is on that screen and said
        # go ahead - see Complete-AnswerLanded. Never set by /compact or the
        # broadcast queue, which act across sessions nobody is watching.
        [switch]$Force
    )
    $procId = [int]$Row.A.Pid
    Set-Status $Saying
    Set-AskEnabled $false
    # 🔑 WHAT THE JOB USED TO SPAWN claude TO FIND OUT. Send-SRQuestionAnswer
    # asked `claude agents --json` on every option click - 837-1,090 ms measured
    # with 31 sessions live - to read a pid, a kind and one status field. All of
    # it is already here, on the UI thread, for nothing.
    #
    # 🔒 MenuSeen IS THE CARD ITSELF. $script:lastAsk is the parse the card was
    # drawn from, so it is at most one 400 ms poll old and it came off a real
    # screen read - which is what the agent list's 'waiting' is a second-hand
    # summary of. If it is null the card is not showing a menu, and an option
    # cannot have been clicked. Deliberately NOT falling back to askSeen: that
    # is the sweep's older verdict and would only loosen a gate the card can
    # answer exactly.
    $payload = @{
        Kind = $Kind; SessionId = "$($Row.Id)"; Pid = $procId
        Index = $Index; Delta = $Delta; Text = $Text
        AgentKind = "$($Row.A.Kind)"; AgentName = "$($Row.A.Name)"
        AgentWaitingFor = "$($Row.A.WaitingFor)"
        MenuSeen = [bool]$script:lastAsk
        Force = [bool]$Force
    }
    try {
        # Warm if one was ready; see New-SRRunspace. SRHere is already set on it.
        $rs = Get-SRRunspace
        if (-not $rs) { throw 'no runspace' }
        $rs.SessionStateProxy.SetVariable('SRAns', $payload)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($script:AnswerJob)
        $script:ansRs = $rs
        $script:ansPs = $ps
        $script:ansHandle = $ps.BeginInvoke()
        $script:ansFor = @{
            Row = $Row; Pid = $procId; Index = $Index; Kind = $Kind
            Text = $Text; Force = [bool]$Force
            Question = $script:lastAsk; At = (Get-Date)
        }
        try { $script:ansTimer.Start() } catch { }
        return $true
    } catch {
        # 🪤 A FALLBACK THAT STILL SENDS. If a runspace will not open, doing it
        # on this thread is slow but correct; refusing the gesture is not.
        #
        # 🔴 BUT CLOSE THE ONE WE WERE HANDED FIRST. Get-SRRunspace returns an
        # ALREADY-OPEN runspace, so a throw from SetVariable, AddScript or
        # BeginInvoke strands a live thread with nothing referencing it. Before
        # the warm spare, the throw here was almost always Open() itself and
        # there was nothing yet to leak; taking a pre-opened one moved the
        # failure window to after the open.
        try { if ($rs) { $rs.Close(); $rs.Dispose() } } catch { }
        Write-SRLog ('  [skip] sending off-thread failed, sending inline: ' + $_.Exception.Message)
        $script:ansPs = $null; $script:ansRs = $null; $script:ansHandle = $null
        $why = $null
        try {
            # Named arms only, for the reason spelled out on the job above: a
            # default that answers turns any unknown kind into a committed answer.
            switch ($Kind) {
                'answer' { $why = Send-SRQuestionAnswer -SessionId $Row.Id -Index $Index `
                                                        -ProcessId $procId -Kind "$($Row.A.Kind)" `
                                                        -Name "$($Row.A.Name)" -MenuSeen ([bool]$script:lastAsk) }
                'move'   { $why = Invoke-SRRoundMove -ProcessId $procId -Delta $Delta }
                'typed'  { $why = Invoke-SRAnswerTypedOnScreen -ProcessId $procId -Text $Text -Who "$($Row.Id)" }
                'send'   { $why = Send-SRSessionInput -SessionId $Row.Id -Text $Text `
                                                      -ProcessId $procId -Kind "$($Row.A.Kind)" `
                                                      -WaitingFor "$($Row.A.WaitingFor)" `
                                                      -Force:$Force }
                'esc'    { $why = Send-SRInterrupt -ProcessId $procId -Who "$($Row.Id)" }
                default  { $why = "nothing was sent - '$Kind' is not a kind of send this knows" }
            }
        } catch { $why = $_.Exception.Message }
        Complete-AnswerLanded -Row $Row -Pid_ $procId -Index $Index -Question $script:lastAsk -Why "$why" -Kind $Kind `
                              -Text $Text -Force ([bool]$Force)
        return $false
    }
}

function Set-AskEnabled { param([bool]$On)
    try { $ui.AskOptions.IsEnabled = $On } catch { }
    try { $ui.AskFreeSend.IsEnabled = $On } catch { }
    try { $ui.AskTabs.IsEnabled = $On } catch { }
}

function Invoke-Answer { param([int]$Index)
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return }
    $r = $it.Row
    if (-not $r.A -or -not $r.A.Pid) { Set-Status 'that conversation is not running any more' 'warn'; return }
    # One in flight at a time. A second click while the first is out is exactly
    # the double-answer this guard exists to refuse.
    if ($script:ansPs) { Set-Status 'still sending the last answer...' 'warn'; return }
    $null = Start-AskSend -Kind 'answer' -Row $r -Index $Index -Saying 'answering...'
}

# What used to run straight after the send, now run wherever the send finished.
# 🪤 $Text AND $Force TRAVEL WITH IT so the composer's retry has something to
# re-send and cannot loop: a forced send skips both refusals, so it can never
# come back here forceable again, and the -not $Force guard says so out loud
# rather than relying on that staying true.
function Complete-AnswerLanded { param($Row, [int]$Pid_, [int]$Index, $Question, [string]$Why, [string]$Kind = 'answer',
                                       [string]$Text = '', [bool]$Force = $false)
    Set-AskEnabled $true

    # A SENT MESSAGE IS NOT AN ANSWER EITHER. It clears the composer rather than
    # the question card, and it files no answer record - nothing was chosen.
    if ($Kind -eq 'send') {
        # 🔴 THE OFFER IS MADE HERE, WHERE IT CAN ACTUALLY BE HONOURED. The two
        # refusals -Force lifts used to end "or send anyway" inside the message
        # itself, while not one of the four call sites passed -Force and no path
        # retried - so the sentence named an action the operator could not take.
        # The message now states the fact only (see $SR_RefuseMenu) and the
        # composer, which is the one caller with a person standing in front of
        # it, puts the choice to them and re-sends forced if they take it.
        #
        # 🪤 THE MESSAGE IS NOT CLEARED AND THE ROW IS NOT MOVED on this path.
        # Nothing has been sent yet; if the operator declines, what they typed
        # has to still be in the box.
        if ($Why -and (Test-SRForceableRefusal $Why) -and -not $Force) {
            Set-AskEnabled $true
            $t = (Get-Title $Row.S $Row.D).Text
            if (Confirm-Action 'Send it anyway' (
                "{0}`n`n'{1}' is waiting on something on its own screen. Sending now types your message into that, which is almost never what you meant - and if it IS, this is the way." -f `
                    $Why, $t) -Verb 'Send anyway') {
                $null = Start-AskSend -Kind 'send' -Row $Row -Text $Text -Saying 'sending anyway...' -Force
            } else {
                Set-Status 'not sent - it is still waiting on its own screen' 'warn'
            }
            try { Update-SendState } catch { }
            return
        }
        if ($Why) { Set-Status $Why 'bad' } else {
            # 🪤 CLEARED ON LANDING, NOT ON THE CLICK. Same reasoning as the
            # typed answer: off-thread, clearing it at the click would throw the
            # message away while the send could still come back refused.
            try { $ui.SendBox.Text = '' } catch { }
            Set-Status 'sent' 'ok'
            # Typed into, so it is not waiting on you any more.
            Move-RowToWorking $Row
        }
        try { Update-SendState } catch { }
        return
    }

    # A MOVE IS NOT AN ANSWER, and must not be reported or cleaned up as one.
    # Nothing was committed, so there is no record to file and no row to send
    # back to working - a refused move still leaves the menu somewhere, and the
    # card's own lane redraws it from the screen within 400 ms either way.
    if ($Kind -eq 'move') {
        if ($Why) { Set-Status $Why 'warn' } else { Set-Status '' }
        # Kicked rather than waited for: the same read the lane does, taken now
        # so the arrow feels like it moved the menu rather than like it will.
        try { Invoke-AskPoll } catch { }
        return
    }

    # 🔴 AN INTERRUPT IS NOT AN ANSWER EITHER, and it is the one that would have
    # been worst to treat as one. Nothing was chosen, so there is no answer to
    # file; and the code below reads the screen for the NEXT question of a round
    # and draws it - which after an Esc would put a card in front of a session
    # that has just been told to stop. It also must not move the row to working:
    # what an interrupted session does next is claude's to decide and the probe's
    # to observe, and this window guessing at it is how a row starts flickering.
    if ($Kind -eq 'esc') {
        if ($Why) { Set-Status $Why 'bad' } else { Set-Status 'interrupted - it will stop at the next thing it can stop at' 'ok' }
        try { Update-SendState } catch { }
        return
    }

    if ($Why) { Set-Status $Why 'bad' } else {
        Set-Status $(if ($Kind -eq 'typed') { 'answered in your own words' } else { 'answered' }) 'ok'
        if ($Kind -eq 'typed') {
            $script:askFreeDirty = $false
            $script:askFreeWriting = $true
            try { $ui.AskFree.Text = '' } catch { } finally { $script:askFreeWriting = $false }
        }
        # 🔑 A ROUND DOES NOT END WITH ONE ANSWER. Measured: answering a
        # single-select AUTO-ADVANCES the terminal to the next question, so
        # closing the panel here left the operator staring at a session that was
        # still waiting on them with nothing on screen to say so. Re-read: if
        # another question came up, draw it; only a menu that has actually gone
        # closes the panel and sends the row back to working.
        $seen = $null
        try { $seen = Get-SRScreenQuestion -ProcessId $Pid_ } catch { }

        # 🔴 THE CARD BELONGS TO WHAT IS SELECTED NOW, NOT TO WHAT WAS ANSWERED.
        # This job is 150-200 ms out and keyed on the pid captured at SEND time;
        # every sibling collector guards on the selection for that reason
        # (Complete-DocParse on docFor, Complete-AskProbe and Complete-LiveProbe
        # on selId) and this one did not. Answer A, click B while it is in
        # flight, and A's NEXT question was drawn onto the card under B's name -
        # and Invoke-Answer reads SelectedItem fresh, so the option clicked on
        # that card went into B. Send-SRQuestionAnswer only checks that B is
        # waiting, not that the menu matches, so it would commit.
        #
        # 🪤 THE ROW BOOKKEEPING IS NOT GUARDED, and must not be: whether A still
        # has a menu is a fact about A, true wherever the operator has clicked.
        # Only the drawing is about the selection.
        $sel = $null
        try { $sel = Get-SelectedRow } catch { }
        $stillOn = ($sel -and "$($sel.Id)" -eq "$($Row.Id)")
        if (Test-ScreenMenu $seen) {
            if ($stillOn) { Show-Ask $seen }
        } else {
            if ($stillOn) {
                $ui.AskBox.Visibility = $V_Hide
                $script:lastAsk = $null
            }
            Move-RowToWorking $Row
        }
    }
    # The AFTER shot is the evidence, and it is taken on a background thread so
    # it costs the operator nothing. It is still the same measurement: what the
    # screen said once the keys had landed.
    Start-AnswerRecord -SessionId "$($Row.Id)" -Pid_ $Pid_ -Index $Index -Question $Question -Why "$Why"
}

# 🔴 A SEND IN FLIGHT IS POLLED FAST, NOT ON THE ONE-SECOND FOLLOW TICK.
#
# Reported: "when I select an answer, the terminal already shows the next
# question, but the tool takes a few seconds - and then it repeats." Measured,
# the wait is two things added together and only one of them is real work:
#
#   the send itself - Invoke-SRAnswerOnScreen has to let the TUI repaint between
#   keystrokes or it drops them into somebody's console. It used to do that by
#   SLEEPING a flat 250 ms and then 180-220 ms per arrow, which is where the
#   1.1 s came from; it now watches the screen for the highlight to arrive and
#   goes on the moment it does. With the held-open reader making a screen read
#   about 5 ms instead of 130, single-select answering measures 142-206 ms
#   against the 369-421 it was.
#
#   and then UP TO A FULL SECOND of nothing at all, because the completion was
#   noticed by Invoke-FollowTick, which runs once a second. The keys had landed,
#   the terminal had already drawn the next question, and the window was simply
#   not looking yet.
#
# This timer removes the second part. It runs only while a send is out, at 50 ms,
# and stops itself the moment the job is claimed - so it costs nothing at rest
# and cannot outlive the thing it is watching. The follow tick still calls
# Complete-AnswerSend as the backstop, which is what makes this an optimisation
# rather than a new single point of failure.
$script:ansTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ansTimer.Interval = [TimeSpan]::FromMilliseconds(50)
$script:ansTimer.Add_Tick({
    # Stop on EITHER condition: Complete-AnswerSend returning true means it
    # claimed the result, and $ansPs going null means somebody else did.
    if (-not $script:ansPs) { $script:ansTimer.Stop(); return }
    if (Complete-AnswerSend) { $script:ansTimer.Stop() }
})

# A send is allowed this long before the panel is given back. Send-SRQuestionAnswer
# reads another process's console and has its own budget, so anything past this
# is a job that is not coming back rather than one still working.
$SR_AnswerTimeout = 25

function Complete-AnswerSend {
    if (-not $script:ansPs -or -not $script:ansHandle) { return $false }
    # 🔴 THE PANEL MUST COME BACK EVEN IF THE SEND DOES NOT. The options are
    # disabled on the click so a second press cannot interleave two arrow-key
    # sequences on one menu - which means a job that never completes would
    # leave the question permanently unanswerable, with no way out but
    # restarting the window. Disabling a control and having no path that
    # re-enables it is a worse failure than the double-send it prevents.
    if (-not $script:ansHandle.IsCompleted) {
        $started = $null
        if ($script:ansFor) { $started = $script:ansFor.At }
        if ($started -and ((Get-Date) - $started).TotalSeconds -gt $SR_AnswerTimeout) {
            try { $script:ansPs.Stop(); $script:ansPs.Dispose() } catch { }
            try { $script:ansRs.Close(); $script:ansRs.Dispose() } catch { }
            $script:ansPs = $null; $script:ansRs = $null; $script:ansHandle = $null
            $script:ansFor = $null
            Set-AskEnabled $true
            # 🪤 IT DOES NOT SAY "NOTHING WAS SENT". The keys may well have
            # landed before the job stopped answering - abandoning the runspace
            # says nothing about what reached the console. Claiming the answer
            # did not go through would be worse than saying it is unknown: the
            # operator would press again and answer twice.
            Set-Status ('the answer has not come back after {0}s - check the session before answering again' -f $SR_AnswerTimeout) 'bad'
            return $true
        }
        return $false
    }
    $res = $null
    try { $res = @($script:ansPs.EndInvoke($script:ansHandle))[0] } catch { }
    try { $script:ansPs.Dispose(); $script:ansRs.Close(); $script:ansRs.Dispose() } catch { }
    $script:ansPs = $null; $script:ansRs = $null; $script:ansHandle = $null
    $f = $script:ansFor
    $script:ansFor = $null
    if (-not $f) { Set-AskEnabled $true; return $false }
    $why = ''
    if ($res) { $why = "$($res.Why)" }
    Complete-AnswerLanded -Row $f.Row -Pid_ ([int]$f.Pid) -Index ([int]$f.Index) -Question $f.Question -Why $why `
                          -Kind "$(if ($f.Kind) { $f.Kind } else { 'answer' })" `
                          -Text "$($f.Text)" -Force ([bool]$f.Force)
    return $true
}

# ===========================================================================
# 🔴 CLOSING THE WINDOW MID-SEND CAN LEAVE TEXT TYPED INTO A LIVE SESSION AND
# NEVER SUBMITTED, AND NOTHING USED TO WAIT FOR IT.
#
# The close handler stopped the timers, the probe, the sweep and the reader, and
# never looked at $ansPs at all - the send runspace was simply abandoned, and its
# thread died with the process partway through whatever it was doing.
#
# 🔑 WHY THAT IS NOT A LEAKED THREAD BUT A CORRECTNESS BUG. The sends are not
# atomic and cannot be: Invoke-SRAnswerTypedOnScreen writes the text, re-reads
# the screen to confirm the row is holding it, and only THEN sends ENTER - a
# deliberate order, because ENTER on an empty editor row throws the whole round
# away. Send-SRSessionInput has the same two-step shape and says so. Kill the
# thread between the text and the ENTER and the operator's message is sitting in
# a live session's input box, unsent, with the window that put it there gone.
#
# So this WAITS rather than stopping. The job is on its own runspace thread and
# does not need the dispatcher, so blocking here cannot deadlock it.
#
# 🪤 AND THE BUDGET IS NOT $SR_AnswerTimeout. That is 25 s, which is the right
# budget for a card that must eventually be given back but the wrong one for a
# window the operator has just closed - a close that hangs for 25 s reads as a
# crash. Measured, the whole job is ~1.4 s and the key choreography ~300 ms, so
# five seconds covers it several times over and anything past that is a job that
# is not coming back.
#
# 🔒 IT REPORTS WHICH OF THE THREE HAPPENED rather than returning a bool, because
# 'abandoned' is not a failure to be swallowed - it is the one case where a
# message may be half-delivered, and the log is the only place that can say so
# after the window is gone. Its own function so the suite can drive it with a
# send genuinely in flight; inside the close handler it could only be reached by
# closing a real window over a real send.
function Stop-SendInFlight {
    param([int]$BudgetMs = 5000)
    if (-not $script:ansPs -or -not $script:ansHandle) { return 'idle' }
    $landed = $false
    try { $landed = [bool]$script:ansHandle.AsyncWaitHandle.WaitOne($BudgetMs) } catch { $landed = $false }
    if ($landed) {
        # Collect it properly. EndInvoke also surfaces anything the job threw.
        try { $null = $script:ansPs.EndInvoke($script:ansHandle) } catch { }
    } else {
        # 🪤 SAY IT PLAINLY AND DO NOT GUESS WHICH HALF LANDED. The same rule the
        # answer timeout keeps: claiming nothing was sent would have the operator
        # answer twice.
        $who = ''
        try { if ($script:ansFor) { $who = " to $($script:ansFor.Row.Id)" } } catch { }
        try {
            Write-SRLog ("  [warn] the window closed while a send{0} was still going out after {1} ms - it may have typed without submitting; check that session" -f $who, $BudgetMs)
        } catch { }
        try { $script:ansPs.Stop() } catch { }
    }
    try { $script:ansPs.Dispose() } catch { }
    try { if ($script:ansRs) { $script:ansRs.Close(); $script:ansRs.Dispose() } } catch { }
    $script:ansPs = $null; $script:ansRs = $null; $script:ansHandle = $null; $script:ansFor = $null
    return $(if ($landed) { 'landed' } else { 'abandoned' })
}

# The two READ jobs, which are a different problem with a different answer. A
# screen read or a transcript parse types nothing into anything, so there is
# nothing to half-deliver and nothing to wait for - they are stopped, not
# awaited. What they DO hold is a thread and, for the ask probe, a child
# process, and the close handler was leaving both.
function Stop-ReadJobs {
    foreach ($pair in @(
        @{ Ps = 'askPs'; Rs = 'askRs'; H = 'askHandle' }
        @{ Ps = 'docPs'; Rs = 'docRs'; H = 'docHandle' })) {
        $ps = $null
        try { $ps = Get-Variable -Name $pair.Ps -Scope Script -ValueOnly -ErrorAction SilentlyContinue } catch { }
        if (-not $ps) { continue }
        try { $ps.Stop() } catch { }
        try { $ps.Dispose() } catch { }
        $rs = $null
        try { $rs = Get-Variable -Name $pair.Rs -Scope Script -ValueOnly -ErrorAction SilentlyContinue } catch { }
        try { if ($rs) { $rs.Close(); $rs.Dispose() } } catch { }
        try { Set-Variable -Name $pair.Ps -Scope Script -Value $null } catch { }
        try { Set-Variable -Name $pair.Rs -Scope Script -Value $null } catch { }
        try { Set-Variable -Name $pair.H  -Scope Script -Value $null } catch { }
    }
}

# ===========================================================================
# THE QUESTION CARD FOLLOWS THE SCREEN, NOT THE FIFTEEN-SECOND PROBE.
#
# 🔴 REPORTED AS "the questions are also not immediately updated", AND MEASURED
# AT FIFTEEN SECONDS. The card was fed from exactly one place: the live probe,
# which reads the selected session's screen while it is out there doing the
# expensive work, and runs on $LiveSeconds. So a question that appeared one
# second after a probe returned sat unseen for the next fourteen.
#
# The vitals sweep already reads EVERY session's screen every 2.5 s and already
# parses it - but it keeps only a boolean, `Asking`, to drive the band. The
# parse it threw away is the card. That was the whole gap.
#
# 🔑 A READ IS NOW CHEAPER THAN THE TICK THAT SCHEDULES IT. The held-open reader
# put a screen read at 5.6-9.3 ms against a 6.9 ms terminal. That was not true
# when this file was written: a read was 130 ms, and a lane like this would have
# cost a third of the UI thread.
#
# 🔴 AND THE FIRST VERSION OF THIS NOTE WAS WRONG ABOUT THE PRICE. It said the
# lane costs "about 2% of one thread", having counted the READ and omitted the
# PARSE that followed it on every single tick. Audited: a steady-state tick is
# 20.69 ms - parse 9.33, read 5.57, signature 0.82, gates and Add-Member the
# rest - which at four a second is 5-6% of the UI thread, permanently, and
# three times the bar per tick.
#
# It is cheap now because the parse is SKIPPED when the screen has not changed
# (see below), which is the difference between paying 20.69 ms a tick and
# paying it only when something actually moved.
#
# 🪤 IT MUST NOT REDRAW WHAT IT ALREADY DREW. Show-Ask replaces ItemsSource, so
# an unconditional redraw every 400 ms would take the focus out from under a
# keyboard user and re-enter the list mid-click. The signature below is built
# from everything the card actually shows - including the cursor and the ticks,
# which are what MOVE while a round is being worked - so a redraw happens when
# the menu changed and at no other time.
$script:AskPollFastMs = 400
$script:AskPollSlowMs = 2500
$script:askSig  = ''
$script:askMiss = 0
$script:askSlow = $false
# How many reads IN A ROW have come back over the bar. See the note in the poll:
# the bar is right and the flap was that one slow read was enough.
$script:askSlowRun = 0
# The last screen this lane read, and whose it was. See the note in the poll:
# an unchanged screen cannot hold a changed menu, so it skips the parse.
$script:askText = ''
$script:askTextPid = 0

function Get-AskSignature { param($Q)
    if (-not $Q) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    $null = $parts.Add("$($Q.Question)")
    $null = $parts.Add("$($Q.Header)")
    foreach ($o in @($Q.Options)) { $null = $parts.Add("$o") }
    # The two that move without the question changing: where the cursor is
    # sitting and what is already ticked. A round being worked changes only
    # these, and a card that ignored them would freeze on the first frame.
    $null = $parts.Add('@' + "$($Q.CursorAt)")
    $null = $parts.Add('#' + ((@($Q.Ticked) | Sort-Object) -join ','))
    $null = $parts.Add('*' + "$($Q.Multi)")
    foreach ($t in @($Q.Tabs)) { $null = $parts.Add('~' + "$($t.Label)" + '=' + "$($t.Answered)") }
    return ($parts.ToArray() -join '|')
}

function Invoke-AskPoll {
    # 🔒 EVERY GATE THE PROBE'S OWN ASK PATH HAS, plus one the probe does not
    # need: an answer in flight OWNS the card, and Complete-AnswerLanded redraws
    # it the moment the keys land. A poll landing between the send and that
    # redraw would draw the menu the answer has already moved past.
    if ($script:sheetDepth -gt 0) { return }
    if ($script:ansPs) { return }
    if ($script:surface -ne 'work') { return }

    $row = Get-SelectedRow
    if (-not $row -or -not $row.A -or -not $row.A.Pid) { $script:askSig = ''; $script:askMiss = 0; return }
    if ($row.A.Kind -and "$($row.A.Kind)" -ne 'interactive') { $script:askSig = ''; return }
    if (-not (Test-AskAllowed $row)) { return }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $txt = $null
    try { $txt = Get-SRScreenText -ProcessId ([int]$row.A.Pid) } catch { }
    $sw.Stop()

    # 🪤 BACK OFF IF THE FAST READER IS NOT THERE. This lane is only affordable
    # because the held-open reader answers in single-digit milliseconds; on the
    # spawn fallback the same read is ~100 ms, and polling THAT four times a
    # second would put a fifth of the UI thread into watching one console. The
    # measurement decides, not an assumption about which path is live.
    # 🔴 THE BAR WAS RIGHT AND THE FLAP WAS THAT ONE READ WAS ENOUGH.
    #
    # Counted in the operator's own running window (.state\restore.log): 135
    # transitions, 68 trips down to 2500 ms and 67 back up - flapping, not
    # settling - and the read that tripped it was n=64, min 40, p50 50, p90 143.
    # 56 of those 64 (88%) were reads UNDER 100 ms, i.e. the held-open reader
    # working normally, ten milliseconds over a bar set at forty. Every misfire
    # cost a full 2500 ms tick, so the card's real worst case was ~2.5 s and not
    # the 400 ms this lane advertises.
    #
    # 🪤 AND NO THRESHOLD CAN FIX IT, WHICH IS WHY THE 40 STAYS. Measured n=300
    # served reads round-robin over 30 live consoles against n=40 on the spawn
    # fallback:
    #
    #     served  min 3.3  p50 5.2  p90 8.0  p99 12.5  p99.7 60.8  max 94.7
    #     spawn   min 57.9 p50 71.4 p90 81.2                       max 96.7
    #
    # The two OVERLAP - 58 to 95 belongs to both - so raising the bar to 100 or
    # 150 stops the false trips only by disabling the detector: at 100 ms the
    # spawn fallback trips on 0% of its reads and the back-off never fires at
    # all. What separates them is not one read but two: at 40 ms, 3 of 300
    # served reads are over the bar and NO TWO IN A ROW are, while every spawn
    # read is over it - so the fallback is still caught inside two ticks.
    #
    # Asymmetric on purpose: two over the bar to back off, one under it to come
    # back. Being briefly fast is never worth punishing.
    $overBar = ($sw.Elapsed.TotalMilliseconds -gt 40)
    if ($overBar) { $script:askSlowRun++ } else { $script:askSlowRun = 0 }
    $slow = $(if ($script:askSlow) { $overBar } else { $script:askSlowRun -ge 2 })
    if ($slow -ne $script:askSlow) {
        $script:askSlow = $slow
        try {
            $script:askTimer.Interval = [TimeSpan]::FromMilliseconds(
                $(if ($slow) { $script:AskPollSlowMs } else { $script:AskPollFastMs }))
        } catch { }
        Write-SRLog ('  [ask] screen read {0:N0} ms - question card polling every {1} ms' -f `
            $sw.Elapsed.TotalMilliseconds, $(if ($slow) { $script:AskPollSlowMs } else { $script:AskPollFastMs }))
    }

    # 🔴 A FAILED READ IS NOT AN ABSENT MENU, and conflating them is how a live
    # question would blink out of the card. Only a screen that was actually READ
    # and parsed to nothing is evidence that the menu has gone, and even then it
    # takes two in a row - one dropped frame mid-repaint is normal.
    if (-not $txt) { return }

    # 🔴 THE PARSE IS THE EXPENSIVE HALF, AND IT RAN EVERY TICK REGARDLESS.
    # Measured across a tick: parse 9.33 ms (45%), read 5.57 (27%), signature
    # 0.82, the rest gates - 20.7 ms in total, four times a second. The note
    # that used to sit above this lane claimed "about 2% of one thread"; it
    # counted the READ and quietly omitted the parse that follows it every time.
    # The true figure was 5-6%.
    #
    # 🔑 THE SCREEN IS ITS OWN CHANGE DETECTOR, and it is free - the text is
    # already in hand. If not one character moved, no menu moved either, so
    # there is nothing to parse and nothing to redraw. Only a screen that
    # actually differs is worth the 9.33 ms.
    #
    # 🪤 KEYED ON THE PID. Without it, switching to another session whose screen
    # happened to match the last one read would skip the parse and leave the
    # previous conversation's menu on the card - which is the worst bug this
    # window can have.
    # 🔴 EXCEPT WHILE A CLEAR IS PENDING, and leaving that out made the card lie.
    # The two rules are each right and together they deadlocked: "an unchanged
    # screen costs no parse" and "clearing takes two parsed-empty reads IN A ROW"
    # cannot both hold, because the second read never happens. Traced: the
    # operator answers in the terminal, the menu goes, tick 1 parses empty and
    # sets askMiss=1, and every tick after that matches the cached text and
    # returns - askMiss frozen at 1 forever. The card was then cleared only by
    # the fifteen-second probe this lane was written to replace, in the one
    # direction where a stale card is still CLICKABLE.
    #
    # One extra parse, only while askMiss is exactly 1. It settles at 2 on the
    # next read and the short-circuit resumes.
    $same = ($txt -eq $script:askText -and [int]$row.A.Pid -eq [int]$script:askTextPid)
    if ($same -and $script:askMiss -ne 1) { return }
    $script:askText = $txt
    $script:askTextPid = [int]$row.A.Pid

    $q = $null
    try { $q = Invoke-SRParseScreenQuestion -Text $txt } catch { }
    if ($q) { $q | Add-Member -NotePropertyName Screen -NotePropertyValue $txt -Force }

    # Cursorless parses fall through to the CLEAR path rather than a separate
    # branch, so a card already showing prose is taken down by the same two-miss
    # rule that takes down a menu that has gone. See Test-ScreenMenu above.
    if (-not (Test-ScreenMenu $q)) {
        $script:askMiss++
        if ($script:askMiss -ge 2 -and $script:askSig) {
            $script:askSig = ''
            $ui.AskBox.Visibility = $V_Hide
            $script:lastAsk = $null
        }
        return
    }
    $script:askMiss = 0

    $sig = Get-AskSignature $q
    if ($sig -eq $script:askSig) { return }
    $script:askSig = $sig
    Show-Ask $q
}

# ===========================================================================
# STEPPING THROUGH THE ROUND.
#
# 🔑 The panel does not hold a copy of the round and page through it. It moves
# the REAL menu with the same LEFT/RIGHT keys a person would press, then re-reads
# the screen and redraws from what came back. So what you see is what the
# terminal is showing - there is no second model of the round that can drift out
# of step with it, which is the whole reason this window reads screens at all.
function Invoke-AskMove { param([int]$Delta)
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return }
    $r = $it.Row
    if (-not $r.A -or -not $r.A.Pid) { Set-Status 'that conversation is not running any more' 'warn'; return }
    # 🔴 THE SAME GUARD THE OPTION CLICK HAS. A move sends arrows into the same
    # menu an answer sends arrows into, so two of them in flight together would
    # interleave exactly as two answers would - and pressing back twice quickly
    # is far more natural than pressing two options quickly.
    if ($script:ansPs) { Set-Status 'still sending...' 'warn'; return }
    $null = Start-AskSend -Kind 'move' -Row $r -Delta $Delta `
                          -Saying $(if ($Delta -lt 0) { 'going back...' } else { 'going on...' })
}

# 🔴 THE ONE ORDER THAT CANNOT DECLINE THE ROUND. Text first, screen re-read to
# confirm the row is holding it, and only then ENTER - because ENTER on an empty
# editor row throws the whole round away. Invoke-SRAnswerTypedOnScreen enforces
# it; this only refuses to call it with nothing.
function Invoke-AskTyped {
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return }
    $r = $it.Row
    if (-not $r.A -or -not $r.A.Pid) { Set-Status 'that conversation is not running any more' 'warn'; return }
    $txt = "$($ui.AskFree.Text)".Trim()
    if (-not $txt) { Set-Status 'type an answer first - sending an empty one would decline the question' 'warn'; return }
    if ($script:ansPs) { Set-Status 'still sending...' 'warn'; return }
    # 🪤 THE BOX IS CLEARED WHEN THE SEND LANDS, NOT HERE. It used to be cleared
    # straight after the call returned, which was safe only because the call was
    # synchronous; off-thread, clearing it now would throw the text away while
    # the send could still come back with a refusal - and then there would be
    # nothing left to try again with. Complete-AnswerLanded clears it on success.
    $null = Start-AskSend -Kind 'typed' -Row $r -Text $txt -Saying 'typing your answer in...'
}

# ===========================================================================
# THE COMPOSER - honest about when it cannot send
#
# It LOOKS like chat and is not: it synthesises keystrokes into a real terminal.
# So it says why it is disabled rather than silently dropping what was typed,
# which is the worst outcome available here.
# ===========================================================================
# ===========================================================================
# WHAT IS WAITING, UNDER THE CONVERSATION IT IS WAITING IN.
#
# 🔴 THE COUNT ON THE ROW SAYS WHERE, THIS SAYS WHAT. They are the same data
# read once by the probe (Get-SRQueue) and shown twice, because they answer
# different questions: the row is scanned across twenty conversations, this is
# read in the one you have open, next to the box you are about to type in.
#
# 🪤 YOURS FIRST, ALWAYS. The queue is mostly not you - measured across this
# machine, 1,356 cross-session messages and 1,107 task notifications against 144
# lines a person typed - so a list in queue order would push your own message
# off the bottom of a cap behind machine chatter you did not write and cannot
# act on. Ordered yours-first, capped, and the remainder is a count.
$SR_QueueShow = 4
# Two minutes, because that is where the measured distribution turns: the median
# wait is 7 seconds and 21% of queued messages pass this line. Anything shorter
# would be lit almost always; anything much longer would only ever confirm what
# you had already noticed.
$SR_QueueStaleSecs = 120

$script:qSig = $null

function Update-QueuePanel {
    if (-not $ui.QueueBox) { return }
    $it = $ui.SessionList.SelectedItem
    $rec = $null
    if ($it -and $it.Kind -eq 'session' -and $it.Row) { $rec = $it.Row.Q }
    # 🔴 THIS PANEL HAD NO FRESHNESS GATE AT ALL. The row mark in the sessions
    # list got one; the strip above the composer - the thing actually on screen
    # while he types - drew on `Count -gt 0` and nothing else. So the phantom he
    # screenshotted was showing in the one place he could not miss it.
    #
    # 🪤 IT GATES BEFORE THE SIGNATURE IS BUILT, deliberately. The note below
    # records that staleness has to be part of the signature or the panel keeps
    # a picture that has stopped being true; the same argument applies to
    # whether the panel should be there at all, so this runs first and the
    # signature is computed from what survives.
    if ($rec -and -not (Test-SRQueueFresh -Rec $rec -Now (Get-Date) `
                            -MaxHours $SR_QueueStaleHours -MachineMins $SR_QueueMachineStaleMins)) {
        $rec = $null
    }

    # 🔴 REBUILT ONLY WHEN THE QUEUE ACTUALLY MOVED. This hangs off
    # Update-SendState, and one of that function's callers is the composer's
    # TextChanged - so without this, every KEYSTROKE would rebuild the list and
    # hand WPF a new ItemsSource. Typing is the one thing in this window that
    # must never wait for anything, and the panel it would be rebuilding is
    # identical between one character and the next.
    #
    # The signature is what the panel actually draws: which conversation, how
    # many, how many are yours, and the front of the queue. Anything that
    # changes the picture changes one of those.
    # 🔴 STALENESS IS PART OF THE SIGNATURE, and leaving it out is a bug that
    # hides itself. Nothing about a queue CHANGES while it sits there - same
    # count, same front, same everything - so a signature built only from its
    # contents is identical either side of the two-minute line, and the warning
    # this exists to show would never be drawn. It appears the next time
    # something else about the queue happens to change, which looks like it
    # works and is the worst kind of wrong.
    $oldestMine = $null
    if ($rec -and [int]$rec.Mine -gt 0) {
        foreach ($qi in @($rec.Items)) {
            if (-not $qi.Mine -or -not $qi.At) { continue }
            $t = $null
            try { $t = [datetime]$qi.At } catch { continue }
            if (-not $oldestMine -or $t -lt $oldestMine) { $oldestMine = $t }
        }
    }
    $isStale = $false
    if ($oldestMine) { $isStale = (((Get-Date) - $oldestMine).TotalSeconds -ge $SR_QueueStaleSecs) }

    $sig = 'none'
    if ($rec -and [int]$rec.Count -gt 0) {
        $front = ''
        if (@($rec.Items).Count) { $front = "$($rec.Items[0].Text)" }
        $sig = '{0}|{1}|{2}|{3}|{4}' -f "$($it.Id)", [int]$rec.Count, [int]$rec.Mine, $isStale, $front
    } else {
        $sig = 'none|{0}' -f "$($it.Id)"
    }
    if ($sig -eq $script:qSig) { return }
    $script:qSig = $sig

    if (-not $rec -or [int]$rec.Count -le 0) {
        $ui.QueueBox.Visibility = $V_Hide
        $ui.QueueList.ItemsSource = $null
        return
    }

    $amber = [System.Windows.Media.Brush]$window.FindResource('HueOut')
    $grey  = [System.Windows.Media.Brush]$window.FindResource('TextLow')

    $all = @($rec.Items)
    $ordered = @(@($all | Where-Object { $_.Mine }) + @($all | Where-Object { -not $_.Mine }))
    $show = @($ordered | Select-Object -First $SR_QueueShow)

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($qi in $show) {
        $when = ''
        if ($qi.At) { try { $when = (Get-AgeTicks ([datetime]$qi.At).Ticks) } catch { } }
        $txt = "$($qi.First)".Trim()
        if (-not $txt) { $txt = "$($qi.Text)".Trim() }
        # A machine message is its envelope; the envelope is not worth reading,
        # so it is named rather than printed. The pane makes the same call about
        # inbound messages, for the same reason.
        if (-not $qi.Mine) { $txt = Get-QueueMachineLabel $txt }
        $null = $rows.Add([PSCustomObject]@{
            QiText  = $txt
            QiWhen  = $when
            QiBrush = $(if ($qi.Mine) { $amber } else { $grey })
            QiTip   = "$($qi.Text)"
        })
    }
    $ui.QueueList.ItemsSource = $rows

    $head = ''
    if ([int]$rec.Mine -gt 0) {
        $head = ('{0} of yours waiting' -f [int]$rec.Mine)
        if ([int]$rec.Machine -gt 0) { $head = $head + (', and {0} from the machine' -f [int]$rec.Machine) }
    } else {
        $head = ('{0} queued, none of them yours' -f [int]$rec.Count)
    }
    $hidden = [int]$rec.Count - $rows.Count
    if ($hidden -gt 0) { $head = $head + ('   ({0} more not shown)' -f $hidden) }

    # 🔴 HOW LONG THE OLDEST OF YOURS HAS SAT THERE, once that stops being a
    # detail. Measured across 432 transcripts: the median wait is 7 seconds, but
    # 21% of queued messages wait longer than two minutes and the p90 is 26.
    # A message queued seconds ago needs no comment; one that has been sitting
    # for four minutes is the thing you opened the window to find out.
    #
    # 🪤 THE HEADING CHANGES COLOUR, NOT THE ROW. Grey carries state and hue
    # carries identity everywhere else in this window, and the mark on the list
    # is already spending the one hue it gets on 'these are your words'. Putting
    # a second hue out there would make the scanned surface say two things in
    # colour; this is a line you are already reading in the pane you already
    # chose, so it can afford to say it plainly.
    if ($isStale -and $oldestMine) {
        $head = $head + ('   -   OLDEST HAS WAITED {0}' -f (Get-AgeTicks $oldestMine.Ticks))
    }
    $ui.QueueHead.Foreground = [System.Windows.Media.Brush]$window.FindResource($(if ($isStale) { 'HueWarn' } else { 'TextLow' }))
    $ui.QueueHead.Text = $head.ToUpper()
    $ui.QueueBox.Visibility = $V_Show
}

# The envelope, named rather than printed. <cross-session-message from="uds:\\.\
# pipe\LOCAL\cc-msg-c08065bfbd7..."> is 60 characters of routing before a word of
# content, and the pane already refuses to print that where a name goes.
function Get-QueueMachineLabel { param([string]$Text)
    $t = "$Text".TrimStart()
    if ($t.StartsWith('<task-notification', [StringComparison]::OrdinalIgnoreCase)) { return 'a background task reported back' }
    if ($t.StartsWith('<cross-session-message', [StringComparison]::OrdinalIgnoreCase)) { return 'a message from another session' }
    if ($t.StartsWith('<agent-message', [StringComparison]::OrdinalIgnoreCase)) { return 'a message from an agent' }
    if ($t.StartsWith('<system-reminder', [StringComparison]::OrdinalIgnoreCase)) { return 'a system reminder' }
    if ($t.StartsWith('<', [StringComparison]::Ordinal)) { return 'machine input' }
    return $t
}

function Update-SendState {
    $it = $ui.SessionList.SelectedItem
    $why = ''      # a real blocker: the box is disabled
    $note = ''     # something worth saying while still allowing typing
    if (-not $it -or $it.Kind -ne 'session') { $why = 'nothing is selected' }
    else {
        $r = $it.Row
        if (-not $r.A -or -not $r.A.Pid) { $why = 'this conversation is not running, so there is nothing to type into' }
        elseif ($r.A.Kind -and $r.A.Kind -ne 'interactive') { $why = 'a background agent has no console to type into' }
        elseif ($script:askSeen["$($r.Id)"]) {
            # 🪤 THE ONE CASE STILL REFUSED, and it is not "busy". A session
            # sitting on a MENU reads keystrokes as menu input, so text typed
            # here would pick an option rather than queue behind one. The
            # question panel above is the way to answer that.
            $why = 'it is waiting on a question - answer it in the panel above'
        }
        elseif ("$($r.A.Status)" -eq 'busy') {
            # 🔴 BUSY IS NO LONGER A BLOCKER. It used to disable the box outright
            # - "wait for it to stop before typing" - which is why a second
            # message could not be written while the first was being worked on.
            # But claude ACCEPTS typed input mid-turn and QUEUES it; that is what
            # the terminal does, and refusing here made the tool less capable
            # than the thing it is a window onto. Reported as: writing multiple
            # messages subsequently and queueing them up is not working.
            # 🪤 AND IT SAYS WHERE IT WILL LAND. "queued behind it" is true and
            # useless when four things are already waiting: the question the
            # operator actually has is whether this is the next thing read or
            # the fifth. The panel above lists them; this one line says where
            # the message being typed RIGHT NOW joins.
            $note = 'it is mid-turn - what you type will be queued behind it'
            $qn = 0
            if ($r.Q) { $qn = [int]$r.Q.Count }
            if ($qn -gt 0) {
                $note = ('it is mid-turn - what you type joins the queue at position {0}' -f ($qn + 1))
            }
        }
    }
    # Same trigger as the note above it: the queue panel describes the selected
    # conversation, so it is refreshed exactly when what is selected, or what it
    # is doing, has changed. Every caller of Update-SendState is one of those.
    try { Update-QueuePanel } catch { }
    $ui.SendBtn.IsEnabled = (-not $why) -and "$($ui.SendBox.Text)".Trim()
    $ui.SendBox.IsEnabled = (-not $why)
    $msg = $(if ($why) { $why } else { $note })
    if ($msg) { $ui.SendNote.Text = $msg; $ui.SendNote.Visibility = $V_Show }
    else { $ui.SendNote.Visibility = $V_Hide }
}

function Invoke-Send {
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return }
    $r = $it.Row
    $msg = "$($ui.SendBox.Text)".Trim()
    if (-not $msg -or -not $r.A -or -not $r.A.Pid) { return }
    # 🔴 THIS WAS THE WORST FREEZE IN THE WINDOW, and it was excused rather than
    # measured. The coverage map recorded this control as "its gesture is a
    # string trim" - true of the four lines above and of nothing below them.
    # Send-SRSessionInput runs Get-SRAgentStatus -Refresh, which SPAWNS
    # `claude agents --json` (528-862 ms), then a CIM process query, then
    # Start-Sleep 400 between the text and the ENTER that commits it. All of it
    # was on the thread that draws: roughly 1.0-1.3 SECONDS of frozen window
    # every time the operator pressed Send.
    #
    # The 400 ms pause is right and stays - the input box needs a beat before it
    # will accept the newline, and without it messages land in the box and sit
    # there unsent. It just has no business being taken on the UI thread.
    #
    # 🔒 THE SAME LANE THE ANSWERS USE, and sharing its in-flight guard is
    # correct rather than convenient: answering and sending both write keys into
    # ONE console, and two of those interleaved is a message nobody typed.
    if ($script:ansPs) { Set-Status 'still sending...' 'warn'; return }
    $null = Start-AskSend -Kind 'send' -Row $r -Text $msg -Saying 'typing it in...'
}

# ===========================================================================
# COMPACT - the one command worth a button of its own.
#
# It is the thing you want the moment the context chip goes amber, and the
# window already shows you that number before the session itself complains. So
# the two sit together: read the bar, press the button.
#
# 🪤 IT GOES THROUGH Send-SRSessionInput, the same path as anything typed, and
# NOT through the answer relay. The relay counts arrow keys against a menu read
# off the screen; a slash command is text, and pretending otherwise is how a
# keystroke lands in whatever happens to be highlighted.
#
# Not guarded by a confirmation, deliberately: compacting summarises and carries
# on, so a stray press costs a summary rather than any work. The status line
# says what was sent, which is the trace that matters if one was not meant.
function Invoke-Compact {
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { Set-Status 'pick a conversation first' 'bad'; return }
    $r = $it.Row
    if (-not $r.A -or -not $r.A.Pid) {
        Set-Status 'that conversation is not running, so there is nothing to compact' 'bad'
        return
    }
    Set-Status 'compacting...'
    $why = $null
    # 🪤 THIS RUNS ON THE UI THREAD, so what it costs is what the window freezes
    # for. It used to spawn `claude agents --json` from here - about a second of
    # dead window on every /compact - for a pid and a kind that are on the row.
    try {
        # 🔴 NO -Force HERE, AND THAT IS THE POINT. The composer offers
        # "send anyway" because the operator is standing in front of it and can
        # see which session they mean. This is acting on a session that may have started asking something since you looked, where forcing a
        # sentence into a menu is exactly the accident the refusal exists to
        # stop. It reports what was skipped instead - and the refusal text no
        # longer names an action, so what it reports is now true here.
        $why = Send-SRSessionInput -SessionId $r.Id -Text '/compact' `
                                   -ProcessId ([int]$r.A.Pid) -Kind "$($r.A.Kind)" `
                                   -WaitingFor "$($r.A.WaitingFor)"
    } catch { $why = $_.Exception.Message }
    if ($why) { Set-Status $why 'bad' } else {
        Set-Status 'sent /compact' 'ok'
        Move-RowToWorking $r
        # 🔑 REMEMBER THAT WE SENT IT. Nothing reaches the transcript until the
        # compact finishes, so this timestamp is the only thing that knows a
        # compact is in flight - and it is what puts the session's own screen in
        # the pane while it runs. See Test-SRCompacting.
        $script:compactSent["$($r.Id)"] = Get-Date
        try { Update-LivePane } catch { }
    }
}

# ===========================================================================
# Selection, and following the selected transcript
# ===========================================================================
# DRILLING INTO A SUB-AGENT FROM THE CONVERSATION THAT DISPATCHED IT.
#
# Not a selection: the agent has no row while it is finished, which is the
# whole reason this exists. It swaps what the pane is reading and remembers the
# way back, and the document draws its own return control (see Build-ReadDocument).
$script:agentOpen = $null
$script:docParentPath = ''
$script:docParentRow = $null

function Show-AgentDoc { param($Sub, $ParentRow)
    if (-not $Sub -or -not $ParentRow) { return }
    $script:agentOpen = @{ Sub = $Sub; Row = $ParentRow }
    $script:docSessionId = "$($ParentRow.Id)"
    $script:docPath = "$($Sub.Path)"
    $script:docParentPath = "$($ParentRow.S.jsonl)"
    $script:docParentRow = $ParentRow
    $ui.PaneName.Text = "$($Sub.Label)"
    $ui.PaneStateDot.Background = $window.FindResource('HueAsk')
    Set-WorkingPulse $false
    $what = $(if ($Sub.IsTeammate) { 'teammate' } else { 'task sub-agent' })
    $bits = @("$what")
    try { $bits += ('working for ' + "$($ParentRow.T.Text)") } catch { }
    if ("$($Sub.Description)") { $bits += "$($Sub.Description)" }
    $ui.PaneState.Text = ($bits -join '   |   ')
    # Nothing on the strip describes a transcript no process is holding, and an
    # agent cannot be waiting on a question.
    try { Update-Chips $null } catch { }
    Show-Ask $null
    $script:docKey = ''; $script:docTurns = $null
    $script:docToBottom = $true
    $blocks = @()
    $trunc = $false
    try { $trunc = ((Get-Item -LiteralPath $Sub.Path).Length -gt $script:tailBytes) } catch { }
    # 🪤 Assign, then wrap - the comma guard.
    try {
        $got = Get-SRTranscriptBlocks -JsonlPath $Sub.Path -MaxRecords 220 -MaxTailBytes $script:tailBytes
        $blocks = @($got)
    } catch { }
    Set-ReadDocument -Blocks $blocks -Truncated $trunc
}

function Close-AgentDoc {
    $script:agentOpen = $null
    Show-Selected -Force
}

function Update-Document { param([switch]$Wait)
    # 🪤 THE FOLLOW TICK MUST NOT CLOBBER A DRILL-IN. This runs every second the
    # selected transcript grows, and the selection is still the PARENT while an
    # agent is open - so without this the agent's conversation was replaced by
    # its parent's a second after being opened. Clearing the drill-in belongs to
    # a deliberate selection (Show-Selected), never to a refresh.
    if ($script:agentOpen) { return }
    $it = $ui.SessionList.SelectedItem
    if (-not $it) { return }
    # A SUB-AGENT IS READ BY THE SAME PATH. Its transcript uses the same record
    # shape as any conversation, so everything below this line is unchanged -
    # the only difference is which file is opened.
    if ($it.Kind -ne 'session' -and $it.Kind -ne 'agent') { return }
    $r = $it.Row
    $j = "$($r.S.jsonl)"
    if ($it.Kind -eq 'agent') { $j = "$($it.Sub.Path)" }
    # Which conversation's background shells this document may read. Always the
    # PARENT's id, sub-agent or not: the tasks directory belongs to the session,
    # and an agent's shells are filed under the session that owns it.
    $script:docSessionId = "$($r.Id)"
    # 🪤 THE APPEND KEY IS THE PATH, NOT THE SESSION ID. A sub-agent is read
    # under its PARENT's id (its shells live in the parent's tasks directory),
    # so keying the incremental update on the id would make a session and its
    # own sub-agent look like the same document and append one onto the other.
    $script:docPath = $j
    # The PARENT's transcript and row, kept whatever is being read: a sub-agent
    # is filed beside its parent, so this is what an agent block looks itself up
    # in, and what a drill-in comes back to.
    $script:docParentPath = "$($r.S.jsonl)"
    $script:docParentRow = $r
    if (-not $j -or -not (Test-Path -LiteralPath $j)) {
        $ui.PaneDoc.Document = $null
        $ui.PaneEmpty.Text = $(if ($it.Kind -eq 'agent') {
            # Not an error, and it must not read as one: 45 of 374 sub-agents on
            # this machine are in exactly this state. What it was ASKED to do is
            # still known, so it is shown rather than an empty pane.
            $d = "$($it.Sub.Description)"
            if ($d) { "This sub-agent left no transcript on disk." + [Environment]::NewLine + [Environment]::NewLine + "It was asked to: " + $d }
            else { 'This sub-agent left no transcript on disk.' }
        } else { 'This conversation has no transcript left on disk.' })
        $ui.PaneEmpty.Visibility = $V_Show
        return
    }
    # 🔴 THE PARSE IS NOT DONE HERE ANY MORE. Measured best-of-seven:
    # Get-SRTranscriptBlocks over a 96 KB tail is ~37 ms and building the
    # FlowDocument another ~20 ms, so this function cost 56 ms on the UI thread
    # and the click that calls it 54 ms - both over the 50 ms a gesture is
    # allowed. 'Load earlier' doubles the tail and cost 108 ms.
    #
    # The parse now runs in a runspace and the document is built when it lands.
    # Building WPF objects has to stay on this thread - they have thread
    # affinity - but 20 ms is inside budget, and the pane keeps showing the
    # previous document until the new one is ready, which is what it looked
    # like anyway.
    # -Wait parses inline and renders before returning. The window never uses
    # it; a test, a screenshot or anything that needs the document to EXIST on
    # the next line does. Without this an async render is untestable, and the
    # first thing an untestable render does is stop rendering.
    if ($Wait) {
        $blocks = @()
        $trunc = $false
        try { $trunc = ((Get-Item -LiteralPath $j).Length -gt $script:tailBytes) } catch { }
        try { $blocks = Get-SRTranscriptBlocks -JsonlPath $j -MaxRecords 220 -MaxTailBytes $script:tailBytes } catch { }
        Set-ReadDocument -Blocks $blocks -Truncated $trunc
        return
    }
    Start-DocParse -Path $j
    return
}

# The parse, off the UI thread. Keyed by path AND tail size so 'load earlier'
# supersedes the read it is widening rather than racing it.
$script:docPs = $null
$script:docRs = $null
$script:docHandle = $null
$script:docFor = ''
$script:docTrunc = $false
$script:docToBottom = $false

$script:DocJob = {
    . (Join-Path $SRHere '_common.ps1')
    $out = @{ Blocks = @() }
    try {
        # 🔴 ASSIGN, THEN WRAP. NEVER @(Get-SRTranscriptBlocks ...) IN ONE STEP.
        #
        # That function ends with `return ,@($out.ToArray())` - the comma guard
        # that stops the pipeline unrolling the array. So it emits ONE object
        # which IS the array, and @() around a command does not flatten a nested
        # array: it produces a one-element array holding all sixteen blocks.
        #
        # Everything downstream then behaved perfectly on one nonsense block.
        # @($Blocks).Count was 1, so Build-ReadDocument skipped its "nothing
        # readable" path and drew the truncation notice; Get-ReadTurns made a
        # single turn whose Kind was every kind joined into one string by
        # PowerShell's member enumeration, which matched no case in the switch,
        # so not one turn was rendered. The pane showed the header and nothing
        # else - for every conversation - while every assertion stayed green,
        # because the only thing being asserted was that a Document EXISTED.
        #
        # Assigning first gives the array itself, and @() on a variable holding
        # an array is the identity. The two forms are not interchangeable.
        $got = Get-SRTranscriptBlocks -JsonlPath $SRDoc.Path -MaxRecords 220 -MaxTailBytes $SRDoc.Tail
        $out.Blocks = @($got)
        # 🔑 FOLD THE BLOCKS INTO TURNS OUT HERE TOO, not back on the dispatcher.
        # Get-ReadTurns was 16.3 ms on the UI THREAD on every conversation
        # opened - over the bar on its own, before a single WPF object is made -
        # and there is nothing thread-affine about it: 113 lines over plain
        # records, calling nothing but built-ins. The parse beside it has run off
        # the UI thread for months; this had simply never been looked at.
        #
        # 🪤 THE FUNCTION IS SENT IN, NOT MOVED. It belongs to the reading pane
        # and moving 113 lines into _common.ps1 to reach a runspace would be the
        # tail wagging the dog - so Start-DocParse hands its source across and it
        # is redefined here. One definition, still living where it is edited.
        if ($SRDoc.TurnsFn) {
            try {
                Set-Item -Path 'function:Get-ReadTurns' -Value ([scriptblock]::Create($SRDoc.TurnsFn))
                $turned = Get-ReadTurns $out.Blocks
                $out.Turns = @($turned)
            } catch { $out.Turns = $null }
        }
    } catch { }
    $out
}

function Start-DocParse { param([string]$Path)
    $key = ('{0}|{1}' -f $Path.ToLower(), $script:tailBytes)
    # 🪤 Abandoned, not queued. Clicking through four conversations must render
    # the FOURTH, and a queue renders all four in order with the last one last -
    # which looks identical until the transcripts are large.
    if ($script:docPs) {
        try { $script:docPs.Stop(); $script:docPs.Dispose() } catch { }
        try { $script:docRs.Close(); $script:docRs.Dispose() } catch { }
        $script:docPs = $null; $script:docRs = $null; $script:docHandle = $null
    }
    $script:docTrunc = $false
    try { $script:docTrunc = ((Get-Item -LiteralPath $Path).Length -gt $script:tailBytes) } catch { }
    try {
        # 🔑 THE WARM ONE. Opening a runspace here was 17.4 of this function's
        # 24.9 ms, on the click that opens a conversation - the most repeated
        # gesture in the tool. See New-SRRunspace.
        $rs = Get-SRRunspace
        if (-not $rs) { throw 'no runspace' }
        $rs.SessionStateProxy.SetVariable('SRDoc', @{
            Path = $Path; Tail = $script:tailBytes
            # See the note in DocJob: the fold-into-turns pass goes with it.
            TurnsFn = ${function:Get-ReadTurns}.ToString()
        })
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($script:DocJob)
        $script:docRs = $rs
        $script:docPs = $ps
        $script:docHandle = $ps.BeginInvoke()
        $script:docFor = $key
    } catch {
        # 🪤 A FALLBACK THAT STILL RENDERS. If a runspace will not open, reading
        # on this thread is slow but correct; showing nothing would not be.
        # 🔴 The open runspace goes with it - see the note in Start-AskSend's
        # catch: what Get-SRRunspace hands back is already open, so a throw after
        # that point leaks a thread.
        try { if ($rs) { $rs.Close(); $rs.Dispose() } } catch { }
        Write-SRLog ('  [skip] parsing off-thread failed, reading inline: ' + $_.Exception.Message)
        $script:docPs = $null; $script:docRs = $null
        $blocks = @()
        try { $blocks = Get-SRTranscriptBlocks -JsonlPath $Path -MaxRecords 220 -MaxTailBytes $script:tailBytes } catch { }
        Set-ReadDocument -Blocks $blocks -Truncated $script:docTrunc
    }
}

function Complete-DocParse {
    if (-not $script:docPs -or -not $script:docHandle) { return $false }
    if (-not $script:docHandle.IsCompleted) { return $false }
    $res = $null
    try { $res = @($script:docPs.EndInvoke($script:docHandle))[0] } catch { }
    try { $script:docPs.Dispose(); $script:docRs.Close(); $script:docRs.Dispose() } catch { }
    $script:docPs = $null; $script:docRs = $null; $script:docHandle = $null
    if (-not $res) { return $false }
    # The selection may have moved while the parse was out; a transcript belongs
    # to the conversation it was read from. That hazard is real and this still
    # guards it - what changed is WHAT IT COMPARES.
    #
    # 🔴 THE KEY IS THE ONE Start-DocParse KEYED ON, NOT A SECOND DERIVATION OF
    # IT. This rebuilt the key out of the SELECTION - "$($it.Row.S.jsonl)" -
    # while Start-DocParse had keyed it on the path Update-Document actually
    # chose. For a conversation those two are the same string, so the
    # duplication was invisible; for a SUB-AGENT row they are the PARENT and the
    # AGENT, and the comparison could never match. A $it.Kind test above it
    # refused first anyway, so a click on a nested row threw its own finished
    # parse away twice over - reported as "when I click on the respective
    # background running agent or task, I cannot see its output", with the
    # header naming the agent over the parent's document.
    #
    # 🔑 $script:docPath IS the document that is wanted, and it is already
    # treated that way: Update-Document writes it on every selection before it
    # starts anything, Show-AgentDoc writes it on a drill-in, and
    # Build-ReadDocument keys the append-or-rebuild decision on it. One place
    # decides which file a selection means; this only asks whether the parse in
    # hand is still for it. The tail size stays in the key, so 'load earlier'
    # still supersedes the read it is widening rather than racing it.
    #
    # 🪤 AND IT IS WHAT KEEPS A DRILL-IN SAFE, with no test of its own.
    # Show-AgentDoc parses inline and leaves the PARENT selected, so a parse
    # still in flight for the parent used to be free to land on top of the agent
    # just opened. docPath has already moved to the agent by then, so it cannot.
    $now = ('{0}|{1}' -f "$($script:docPath)".ToLower(), $script:tailBytes)
    if ($now -ne $script:docFor) { return $false }
    Set-ReadDocument -Blocks $res.Blocks -Truncated $script:docTrunc -PreTurns $res.Turns
    return $true
}

# Building the document and putting it on screen. Separated from the parse so
# the expensive half can move threads and this half - which cannot, because WPF
# objects have thread affinity - stays here and stays inside budget.
# What the document on screen was built from, so the next update can tell
# whether it is a continuation of the same conversation or a different one.
$script:docKey = ''

# 🔴 A CONVERSATION THAT IS WORKING REBUILT THE WHOLE DOCUMENT EVERY TIME IT
# WROTE, and that is the lag you feel while watching one.
#
# The follow tick calls this whenever the transcript grows. It threw away every
# block and built them again - measured at ~250 ms on a real conversation - and
# then assigned a NEW FlowDocument, which resets the scroll extent. The
# stick-to-bottom logic below saves your place only if you were AT the bottom;
# scroll up to read something while the session is working and every write
# threw you back. Reported as scrolling that lags.
#
# So growth is now an APPEND. Only the tail of the document is touched:
#
#   Everything before the last turn is IMMUTABLE. A finished turn cannot change
#   - the records behind it are written and done.
#
#   THE LAST TURN CAN. A run gains another call, consecutive prose merges, a
#   notice joins a run of notices. So the last turn is re-rendered rather than
#   assumed, and only turns after it are appended.
#
# Appending MUTATES the document already on screen instead of replacing it,
# which is what keeps the scroll offset: the reader stays exactly where they
# were, with no save-and-restore to get wrong.
#
# 🪤 ANY DOUBT FALLS BACK TO A FULL BUILD. A different conversation, a changed
# tail budget, a shorter turn list than last time (a compact), a Steps setting
# that moved - each of those can change blocks anywhere in the document, and
# there is no cheap way to know which. Rebuilding is always correct; appending
# is only correct under conditions this checks first.
function Test-CanAppend { param($NewTurns, [string]$Key)
    if ($script:docKey -ne $Key) { return $false }
    if (-not $script:docTurns -or -not $script:docTurnCounts) { return $false }
    $old = @($script:docTurns)
    $new = @($NewTurns)
    if ($old.Count -eq 0) { return $false }
    if ($new.Count -lt $old.Count) { return $false }
    if ($script:docTurnCounts.Count -ne $old.Count) { return $false }
    if (-not $ui.PaneDoc.Document) { return $false }
    # Every turn before the last must be untouched. Kind and body length is a
    # cheap signature that catches a re-flow without comparing whole bodies.
    for ($i = 0; $i -lt $old.Count - 1; $i++) {
        if ("$($old[$i].Kind)" -ne "$($new[$i].Kind)") { return $false }
        if ("$($old[$i].Body)".Length -ne "$($new[$i].Body)".Length) { return $false }
        if (@($old[$i].Calls).Count -ne @($new[$i].Calls).Count) { return $false }
    }
    return $true
}

function Add-ReadDocumentTail { param($NewTurns)
    $doc = $ui.PaneDoc.Document
    $old = @($script:docTurns)
    $new = @($NewTurns)
    # Drop the blocks belonging to the last rendered turn - it is the one that
    # may have changed - then render it again along with everything new.
    $lastCount = [int]$script:docTurnCounts[$script:docTurnCounts.Count - 1]
    for ($k = 0; $k -lt $lastCount; $k++) {
        if ($doc.Blocks.Count -le 0) { break }
        $null = $doc.Blocks.Remove($doc.Blocks.LastBlock)
    }
    $script:docTurnCounts.RemoveAt($script:docTurnCounts.Count - 1)
    for ($i = $old.Count - 1; $i -lt $new.Count; $i++) {
        $before = $doc.Blocks.Count
        Add-ReadTurn -Doc $doc -Turn $new[$i]
        $script:docTurnCounts.Add($doc.Blocks.Count - $before)
    }
    $script:docTurns = $new
}

# 🪤 $PreTurns, NOT $Turns. PowerShell is case-insensitive, and this function's
# working local is $turns - so a parameter called $Turns would BE that local,
# and the assignment below would silently overwrite the thing it was reading.
# This codebase has been bitten by that shape before; the names are kept apart.
function Set-ReadDocument { param($Blocks, [bool]$Truncated = $false, $PreTurns = $null)
    # 🔴 NEVER REPLACE A CONVERSATION WITH AN EMPTY ONE. Reported as "the session
    # loaded up, I could see the conversation, however I then entered something
    # and the content of the conversation was gone."
    #
    # Every reader here is best-effort by design: the parse runs in a runspace
    # that dot-sources _common.ps1 and swallows its own exceptions, the tail can
    # miss, a file can be locked mid-write. All of those hand back an EMPTY block
    # list, which is indistinguishable from "this conversation has nothing in
    # it" - and the pane dutifully drew that over a conversation that was on
    # screen and correct a moment earlier.
    #
    # 🪤 A CONVERSATION NEVER GETS SHORTER. A transcript is append-only, so zero
    # blocks where there were blocks before is ALWAYS a failed read and never
    # news. Keeping the stale document is right even when the read failed for a
    # good reason: what is on screen was true a second ago, and blank is true of
    # nothing at all.
    if (-not @($Blocks).Count -and $ui.PaneDoc.Document -and @($script:docTurns).Count) {
        Write-SRLog '  [skip] the transcript read came back empty - keeping the conversation that is on screen'
        return
    }
    $key = ('{0}|{1}|{2}' -f "$($script:docPath)".ToLower(), $script:tailBytes, $script:toolView)
    # 🔑 THE PARSE RUNSPACE ALREADY FOLDED THESE. Recomputing costs 16.3 ms on
    # the dispatcher for an identical answer; see the note in DocJob. The
    # fallback is the inline path, which is what -Wait and every test use.
    $turns = $(if ($null -ne $PreTurns) { @($PreTurns) } else { @(Get-ReadTurns $Blocks) })
    if ((-not $Truncated) -and (Test-CanAppend -NewTurns $turns -Key $key)) {
        $stickA = Test-AtBottom
        if ($script:docToBottom) { $stickA = $true; $script:docToBottom = $false }
        Add-ReadDocumentTail -NewTurns $turns
        $ui.PaneEmpty.Visibility = $V_Hide
        if ($stickA) { Move-ToBottom }
        return
    }
    $doc = Build-ReadDocument -Blocks $Blocks -Truncated $Truncated -Turns $turns
    if ($doc -isnot [System.Windows.Documents.FlowDocument]) {
        throw ('Build-ReadDocument returned {0}, not a FlowDocument - something in it emitted to the pipeline' -f $doc.GetType().Name)
    }
    $script:docKey = $key
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
    if ($script:docToBottom) { $stick = $true; $script:docToBottom = $false }
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
# ===========================================================================
# THE VITALS STRIP.
#
# What the terminal's own status line shows, for the conversation on screen:
#
#   Model: Opus 5 | [####------] 184k/1.0M (18%) | main | (+166,-66)
#
# plus the two things the terminal does not show and this window can - whether
# Remote Control is on, and what is running RIGHT NOW (background shells,
# sub-agents). Get-SRSessionVitals reads all of it off the transcript; only the
# +N -N costs a subprocess, and that answer is cached for 20 seconds.
#
# 🪤 REBUILT ONLY WHEN SOMETHING CHANGES. This is refreshed on the one-second
# follow tick, and throwing away ten Borders a second to redraw the same ten
# would put a permanent load on the UI thread for nothing. The strip carries a
# fingerprint of everything except the clock; the clock is a TextBlock this
# keeps a handle on and writes directly.
# ===========================================================================
$script:chipStamp = ''
$script:chipClock = $null
# The last vitals actually read. The clock ticks off THIS rather than off the
# transcript - see Step-ChipClock.
$script:chipVitals = $null
# Which conversation the strip is currently showing, so the clock can find that
# session's own figure rather than the selected row's - they are the same thing
# until the selection moves mid-tick.
$script:clockId = ''

# ===========================================================================
# THE ONE ANIMATION IN THE WINDOW, and it earns its place by meaning something:
# this conversation is working AT THIS MOMENT. Nothing else moves, so movement
# reads as liveness rather than as decoration.
#
# 🪤 STARTED AND STOPPED, NEVER LEFT RUNNING. A storyboard on a control that is
# no longer showing what it was started for keeps animating - and worse, keeps a
# timer alive - so selecting a finished conversation would leave a dot pulsing
# about a session that stopped an hour ago.
$script:pulseOn = $false
$script:pulseStory = $null

function Set-WorkingPulse { param([bool]$On)
    if ($On -eq $script:pulseOn) { return }
    $script:pulseOn = $On
    if (-not $On) {
        try { $ui.PaneStateDot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null) } catch { }
        $ui.PaneStateDot.Opacity = 1.0
        return
    }
    try {
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation
        $a.From = 1.0
        $a.To = 0.25
        $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(900))
        $a.AutoReverse = $true
        $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        # Eased, not linear: a linear fade reads as a fault light, a sine one
        # reads as breathing.
        $ease = New-Object System.Windows.Media.Animation.SineEase
        $ease.EasingMode = 'EaseInOut'
        $a.EasingFunction = $ease
        $ui.PaneStateDot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    } catch { $script:pulseOn = $false }
}

function Get-ShortModel { param([string]$Model)
    if (-not $Model) { return 'model unknown' }
    $s = $Model -replace '^claude-', '' -replace '-\d{8}$', ''
    $s = $s -replace '\[1m\]', ' 1M'
    return ($s -replace '-', ' ')
}

# 🪤 A HALF THOUSAND IS INFORMATION BELOW 100k AND NOISE ABOVE IT. Rounding to
# whole thousands turned a turn that had written 40,500 tokens into "40k", which
# is the wrong number and the wrong precision - the terminal's own status line
# says 40.5k. Above 100k the decimal buys nothing: 184.2k is not more useful
# than 184k, and it makes the chip wider for no reason.
function Format-Kilo { param([int]$N)
    if ($N -ge 1000000) { return ('{0:0.0}M' -f ($N / 1000000.0)) }
    if ($N -ge 100000)  { return ('{0}k' -f [int][math]::Round($N / 1000.0)) }
    if ($N -ge 1000) {
        $k = [math]::Round($N / 1000.0, 1)
        # 12.0k reads worse than 12k, so the decimal is dropped when it is zero.
        if ($k -eq [math]::Floor($k)) { return ('{0}k' -f [int]$k) }
        return ('{0:0.0}k' -f $k)
    }
    return "$N"
}

function Format-Clock { param([double]$Seconds)
    if ($Seconds -le 0) { return '' }
    if ($Seconds -lt 60) { return ('{0}s' -f [int]$Seconds) }
    $m = [int][math]::Floor($Seconds / 60)
    $s = [int][math]::Floor($Seconds - $m * 60)
    if ($m -lt 60) { return ('{0}m {1}s' -f $m, $s) }
    $h = [int][math]::Floor($m / 60)
    return ('{0}h {1}m' -f $h, ($m - $h * 60))
}

# ===========================================================================
# 🔴 REFERENCE, NOT HEADLINES. This strip answers questions you did not ask
# out loud - which model, how full, which branch - so it has to be READABLE
# without being LOUD. It was neither: pill-sized padding, semibold 11.5, and
# the four accent chips carrying a tinted wash AND a coloured border, which
# made "remote control" the brightest thing in a header whose subject is the
# conversation's name.
#
# So one rule now, and it is the rule the rest of the window already follows:
# the chip body is always glass, and HUE LIVES IN THE DOT AND THE TEXT. That
# still tells the four accent chips apart at a glance - a teal dot reads as
# teal - while none of them outshouts the title above.
# 🔴 THE LAST SIZE IN THE WINDOW THAT WAS OFF THE SCALE, AND IT WAS FROZEN.
#
# This was the literal 10,5 - between SzMicro (9,5) and SzCaption (11), on the
# scale's steps but not one of them - and because it was a literal rather than a
# resource it did NOT move with the text-size control. Every chip in the header
# stayed 10,5 px while the name above it went to 19,5 at 150%, which is the one
# place a fixed size is guaranteed to be seen.
#
# Caught by gui2's "every size on screen is one of the six" check, which walks
# realised TextBlocks. It only fires when a chip is actually drawn, and a chip is
# only drawn when a session has vitals - so on a quiet machine the check passes
# and the defect is still there. That is why it went unnoticed.
#
# 🪤 READ AT BUILD TIME, NOT CACHED IN A SCRIPT VARIABLE. Set-SRTypeScale
# rewrites $window.Resources['Sz*'] and XAML picks that up through
# {DynamicResource}; code-built text has to ask again. Update-Chips rebuilds the
# strip on the follow tick, so asking here is what makes chips follow the scale.
function Get-ChipFont { return [double]$window.FindResource('SzCaption') }
function New-Chip {
    param([string]$Text, $Fg, $Bg, $Dot, [double]$Bar = -1, $BarFg, [string]$Tip, [switch]$Square)
    $bd = New-Object System.Windows.Controls.Border
    if ($Bg) { $bd.Background = $Bg }
    $bd.CornerRadius = New-Object System.Windows.CornerRadius 5
    $bd.Padding = New-Object System.Windows.Thickness 7, 2, 8, 3
    $bd.Margin = New-Object System.Windows.Thickness 0, 0, 6, 4
    if ($Tip) { $bd.ToolTip = $Tip }
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    if ($Dot) {
        $d = New-Object System.Windows.Controls.Border
        $d.Width = 5; $d.Height = 5
        # Round for a sub-agent, square for a background shell - the same pair
        # the session rows use, so the two surfaces teach the same vocabulary.
        $d.CornerRadius = New-Object System.Windows.CornerRadius $(if ($Square) { 1 } else { 2.5 })
        $d.Background = $Dot
        $d.VerticalAlignment = 'Center'
        $d.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
        $null = $sp.Children.Add($d)
    }
    if ($Bar -ge 0) {
        $track = New-Object System.Windows.Controls.Border
        $track.Width = 38; $track.Height = 4
        $track.CornerRadius = New-Object System.Windows.CornerRadius 2
        $track.Background = $PalSunk
        $track.VerticalAlignment = 'Center'
        $track.HorizontalAlignment = 'Left'
        $track.Margin = New-Object System.Windows.Thickness 0, 0, 7, 0
        $fill = New-Object System.Windows.Controls.Border
        $fill.Height = 4
        $fill.Width = [Math]::Max(2.0, 38.0 * [Math]::Min(1.0, $Bar))
        $fill.CornerRadius = New-Object System.Windows.CornerRadius 2
        $fill.Background = $BarFg
        $fill.HorizontalAlignment = 'Left'
        $track.Child = $fill
        $null = $sp.Children.Add($track)
    }
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.Foreground = $Fg
    $tb.FontSize = (Get-ChipFont)
    $tb.FontWeight = $FW_Normal
    $tb.FontFamily = $script:UiFace
    $null = $sp.Children.Add($tb)
    $bd.Child = $sp
    return @{ Border = $bd; Text = $tb }
}

function Update-Chips { param($R, [switch]$Force)
    # The pulse follows the STATUS, not the selection: a session you are already
    # looking at starts and stops working while you watch it, and the dot has to
    # follow that rather than whatever was true when you clicked.
    Set-WorkingPulse ([bool]($R -and $R.A -and "$($R.A.Status)" -eq 'busy'))
    if (-not $R) { $ui.PaneChips.Children.Clear(); $script:chipStamp = ''; $script:chipClock = $null; $script:chipVitals = $null; $script:clockId = ''; return }
    $v = $null
    try {
        $v = Get-SRSessionVitals -JsonlPath "$($R.S.jsonl)" -Session $R.S -WorkDir "$($R.D.path)"
    } catch { }
    if (-not $v -or -not $v.Ok) {
        $ui.PaneChips.Children.Clear(); $script:chipStamp = ''; $script:chipClock = $null; $script:chipVitals = $null; $script:clockId = ''; return
    }
    # 🔴 THE SESSION'S OWN COUNT WINS. The transcript estimate cannot see a
    # background shell at all - a Bash call with run_in_background gets its
    # result back immediately, so the "a call nobody answered is still running"
    # test never fires for one - and the session prints the true number on its
    # status line, which the ask probe has already read. -1 means the screen
    # could not be read, which is not zero and must not overwrite anything.
    if ($script:screenShells -ge 0) { $v.Shells = $script:screenShells }
    if ($script:screenAgents -ge 0) { $v.Agents = $script:screenAgents }
    $script:chipVitals = $v
    $script:clockId = "$($R.Id)"

    # Everything except the clock. If none of it moved, only the clock is
    # rewritten - which is one property set rather than ten object graphs.
    $stamp = '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}' -f $v.Model, $v.Tokens, $v.Window, $v.Branch,
             $v.Shells, $v.Agents, $v.Remote, $v.Mode, $v.Effort, $v.Added, $v.Removed
    if (-not $Force -and $stamp -eq $script:chipStamp) { Update-ChipClock $v; return }
    $script:chipStamp = $stamp
    $script:chipClock = $null
    $ui.PaneChips.Children.Clear()

    $glass = $PalGlass
    $null = $ui.PaneChips.Children.Add((New-Chip -Text (Get-ShortModel $v.Model) -Fg $Pal.TextHigh -Bg $glass -Dot $Pal.In -Tip 'The model this conversation is actually replying with').Border)

    # 🔑 THE SESSION'S OWN BAR WINS, both numbers. The window was inferred from
    # the token count (a 1M session below 200k read as a 200k one) and the count
    # came from the last usage record (which a /compact leaves stale until the
    # next reply). The bar states both and the sweep already has it.
    # 🔴 ONE SOURCE: THE BAR THE SESSION PRINTS. The transcript-derived pair is
    # gone rather than kept as a fallback, and that is a deliberate trade. Both
    # halves of it were wrong in ways nobody could see: the window was INFERRED
    # from the count, so a 1M session under 200k was drawn against a 200k scale
    # (measured: a bar reading 122k/1.0M shown as 61% instead of 12%), and the
    # count went stale across a /compact until the next reply (measured: 123.5k
    # in the terminal, 619k here). A figure that is confidently wrong is worse
    # than an absent one, so a session whose screen cannot be read - a
    # background agent has no console at all - now shows NO context chip rather
    # than a plausible fiction.
    $csig = Get-RowScreenSig "$($R.Id)"
    $ctxTok = -1; $ctxWin = -1
    if ($csig -and [int]$csig.CtxWindow -gt 0) { $ctxTok = [int]$csig.CtxTokens; $ctxWin = [int]$csig.CtxWindow }
    $frac = 0.0
    if ($ctxWin -gt 0) { $frac = [double]$ctxTok / [double]$ctxWin }
    $barFg = Get-CtxBrush $(if ($ctxTok -ge 0) { $ctxTok } else { 0 })
    if ($ctxWin -gt 0) {
        $ctx = ('{0} / {1}   {2}%' -f (Format-Kilo $ctxTok), (Format-Kilo $ctxWin), [int][math]::Round($frac * 100))
        $null = $ui.PaneChips.Children.Add((New-Chip -Text $ctx -Fg $Pal.TextHigh -Bg $glass -Bar $frac -BarFg $barFg -Tip 'Context in use, read off the line this session prints for itself - both the count and the window it is against').Border)
    }

    if ($v.Branch) {
        $null = $ui.PaneChips.Children.Add((New-Chip -Text ([string][char]0x2387 + '  ' + $v.Branch) -Fg $Pal.TextMid -Bg $glass -Tip 'The branch this conversation is working on').Border)
    }
    # (+166,-66). Two colours rather than one grey string, because the question
    # is "how much is uncommitted" and the halves mean opposite things.
    if ($v.Added -ge 0) {
        $bd = New-Object System.Windows.Controls.Border
        $bd.Background = $glass
        $bd.CornerRadius = New-Object System.Windows.CornerRadius 5
        $bd.Padding = New-Object System.Windows.Thickness 7, 2, 8, 3
        $bd.Margin = New-Object System.Windows.Thickness 0, 0, 6, 4
        $bd.ToolTip = 'The working tree against HEAD'
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        foreach ($part in @(@(('+' + $v.Added), $Pal.Ask), @(('   ' + [string][char]0x2212 + $v.Removed), $Pal.Bad))) {
            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = $part[0]; $t.Foreground = $part[1]
            $t.FontSize = (Get-ChipFont); $t.FontWeight = $FW_Normal; $t.FontFamily = $script:UiFace
            $null = $sp.Children.Add($t)
        }
        $bd.Child = $sp
        $null = $ui.PaneChips.Children.Add($bd)
    }
    if ($v.Remote) {
        $null = $ui.PaneChips.Children.Add((New-Chip -Text 'remote control' -Fg $Pal.Ask -Bg $glass -Dot $Pal.Ask -Tip 'This conversation can be driven from the Claude app').Border)
    }
    if ($v.Mode) {
        $null = $ui.PaneChips.Children.Add((New-Chip -Text (($v.Mode -creplace '([a-z])([A-Z])', '$1 $2').ToLower()) -Fg $Pal.Warn -Bg $glass -Dot $Pal.Warn -Tip 'The permission mode it was launched with').Border)
    }
    # 🔑 THE EFFORT THE SESSION IS ACTUALLY THINKING AT, not the one it was
    # launched with. This read a per-session launch PREFERENCE, which nobody had
    # set on any of ten live sessions - so the chip was blank everywhere and the
    # operator asked for a figure that was already meant to be there. The
    # session prints it on its spinner line, "thinking with xhigh effort", and
    # the sweep now files it. The preference stays as the fallback for a session
    # that is not mid-turn and so is not printing one.
    $eff = "$($v.Effort)"
    $sig = Get-RowScreenSig "$($R.Id)"
    if ($sig -and "$($sig.Effort)") { $eff = "$($sig.Effort)" }
    if ($eff) {
        $null = $ui.PaneChips.Children.Add((New-Chip -Text ($eff + ' effort') -Fg $Pal.TextMid -Bg $glass -Tip 'How hard it is thinking - read off the session''s own line while it works').Border)
    }
    # 🪤 SHOWN ONLY WHEN THERE ARE SOME. A permanent "0 shells" is noise on a
    # strip that is meant to be scanned: what is running is the signal, and its
    # absence is the other half of that signal.
    if ($v.Shells -gt 0) {
        $w = 'shells'; if ($v.Shells -eq 1) { $w = 'shell' }
        $null = $ui.PaneChips.Children.Add((New-Chip -Text ('{0} {1}' -f $v.Shells, $w) -Fg $Pal.Tool -Bg $glass -Dot $Pal.Tool -Square -Tip 'Background commands still running - a square mark means machinery, a round one means a sub-agent').Border)
    }
    if ($v.Agents -gt 0) {
        $w = 'sub-agents'; if ($v.Agents -eq 1) { $w = 'sub-agent' }
        $null = $ui.PaneChips.Children.Add((New-Chip -Text ('{0} {1}' -f $v.Agents, $w) -Fg $Pal.Out -Bg $glass -Dot $Pal.Out -Tip 'Sub-agents started and not yet reported back').Border)
    }

    $clock = New-Chip -Text '' -Fg $Pal.TextLow -Bg $glass -Tip 'How long this turn has been running, and what it has written'
    $script:chipClock = $clock.Text
    $null = $ui.PaneChips.Children.Add($clock.Border)
    Update-ChipClock $v
}

function Update-ChipClock { param($V)
    if (-not $script:chipClock -or -not $V) { return }
    # Recomputed from WHEN the turn started, never from the Elapsed the read
    # returned - that number was true once and is a second staler on every tick.
    $secs = $V.Elapsed
    if ($V.TurnAt) { $secs = ([datetime]::UtcNow - $V.TurnAt).TotalSeconds }

    # 🔴 THE SESSION'S OWN FIGURE WINS, because the transcript-derived one was
    # wrong in BOTH directions - measured across ten live sessions:
    #   idle : the tool said 10,734 s where the session said "for 2m 49s · done"
    #          -- now-minus-the-last-human-turn never stops when the turn does
    #   busy : the tool said 12 s where the session said "(1h 27m 38s ...)"
    #          -- something other than a human message resets the start
    # The screen carries what the terminal is showing the operator, and being
    # identical to the terminal is the whole point of this strip.
    #
    # 🪤 A FINISHED TURN IS A FIXED NUMBER. Only a RUNNING one gets the drift
    # since the read added to it; adding it to a "done" figure would invent the
    # very forward creep this replaces.
    $done = $false
    $sig = Get-RowScreenSig "$($script:clockId)"
    if ($sig -and [int]$sig.TurnSecs -ge 0) {
        $secs = [int]$sig.TurnSecs
        $done = [bool]$sig.TurnDone
        if (-not $done) { $secs += [Math]::Max(0.0, ((Get-Date) - $sig.At).TotalSeconds) }
    }
    $t = Format-Clock $secs
    if (-not $t) { $script:chipClock.Text = ''; return }
    if ($V.TurnTokens -gt 0) {
        $t += '   ' + [string][char]0x00B7 + '   ' + [string][char]0x2193 + ' ' + (Format-Kilo $V.TurnTokens)
    }
    $script:chipClock.Text = $t
}

# 🔴 THE CLOCK MOVES ON ARITHMETIC, AND ON NOTHING ELSE. This ran once a second
# and CALLED Get-SRSessionVitals, whose cache is keyed on the transcript's size
# and mtime - which on the one kind of session whose clock you are watching, a
# live one, changes every time it writes. So the cache missed every tick and the
# window re-parsed up to 600 KB of JSONL through ConvertFrom-Json ON THE UI
# THREAD, once a second, to advance a number it already had.
#
# The elapsed time is (now - the turn's start), and the turn's start is in the
# vitals object the last real read produced. Nothing needs re-reading; only the
# subtraction is per-tick. Update-Chips does the reading, on the tick that
# notices the transcript actually grew.
function Step-ChipClock {
    if (-not $script:chipClock -or -not $script:chipVitals) { return }
    try { Update-ChipClock $script:chipVitals } catch { }
}

# ===========================================================================
# HOW MUCH OF THE MACHINERY THE PANE SHOWS.
#
# One button cycling three positions, because the answer changes with what the
# operator is doing: reading a reply wants it folded, watching a run wants it
# full, and writing wants it gone. Remembered in the config, so the choice
# survives the window.
# ===========================================================================
function Step-ToolView {
    $i = [array]::IndexOf($SR_ToolViews, $script:toolView)
    if ($i -lt 0) { $i = 0 }
    $script:toolView = $SR_ToolViews[($i + 1) % $SR_ToolViews.Count]
    $ui.PaneTools.Content = Get-ToolViewLabel
    # 🪤 The write is a SIDE EFFECT, never something the redraw waits on. A
    # config that cannot be written must not stop the pane from redrawing - the
    # setting is already live in this window either way. Which is also why it
    # queues: nothing on this path reads it back, so the file only has to be
    # right before the window closes.
    try { Save-SRConfigLater -Name 'transcriptTools' -Value $script:toolView; Request-SRConfigFlush }
    catch { Write-SRLog ('  [skip] could not remember the steps setting: ' + $_.Exception.Message) }
    Show-Selected -Force
}

# ===========================================================================
# HOW BIG EVERYTHING IS - one control, the whole surface.
#
# 🔑 IT MOVES THE CHROME, NOT JUST THE PANE. The six Sz* resources are what
# every style in window2.xaml reads, so writing them here reaches the list, the
# rail, the header, the buttons and the menus in the same gesture. That is the
# difference between this and the thing it replaces: the reading pane used to
# grow on its own while the surface around it stayed put, so the two drifted
# apart and the pane looked wrong rather than bigger.
#
# 🪤 THE DOCUMENT DOES NOT FOLLOW ON ITS OWN. Everything in the FlowDocument is
# built in script with a size baked into each run, so a DynamicResource cannot
# reach it - it has to be rebuilt, which is what the Show-Selected at the end is
# for. Forgetting that is a zoom that visibly moves every part of the window
# EXCEPT the conversation, which is the part being read.
$SR_ZoomSteps = @(80, 90, 100, 110, 125, 150)

function Get-ZoomLabel { 'Text: {0}%' -f $script:Zoom }

function Step-Zoom {
    # Nearest step rather than IndexOf, so a hand-edited config (or the clamp
    # above) lands somewhere sensible instead of silently restarting at 80.
    $cur = $script:Zoom
    $i = 0
    for ($n = 0; $n -lt $SR_ZoomSteps.Count; $n++) {
        if ([Math]::Abs($SR_ZoomSteps[$n] - $cur) -lt [Math]::Abs($SR_ZoomSteps[$i] - $cur)) { $i = $n }
    }
    Set-SRTypeScale -Percent $SR_ZoomSteps[($i + 1) % $SR_ZoomSteps.Count]
    $ui.PaneZoom.Content = Get-ZoomLabel
    try { Save-SRConfigLater -Name 'zoom' -Value $script:Zoom; Request-SRConfigFlush }
    catch { Write-SRLog ('  [skip] could not remember the zoom setting: ' + $_.Exception.Message) }
    # 🔴 THERE IS NO Items.Refresh() HERE ANY MORE, AND THAT IS THE POINT.
    #
    # It used to sit here with "the rows carry their own measured heights, so the
    # list has to be told the type under it changed or it keeps laying out for
    # the old size". That premise was never tested, and it is false. Every
    # FontSize in window2.xaml is a {DynamicResource Sz*}, and Set-SRTypeScale
    # above assigns $window.Resources["Sz$k"] - which WPF propagates by itself,
    # invalidating measure on every element that reads it. The rows re-measure
    # whether or not the list is told anything.
    #
    # MEASURED on a realised container, stepping 100% -> 150%:
    #
    #     row height   100%  64.0px      150% WITHOUT the refresh  72.0px
    #                                    150% WITH the refresh     72.0px
    #
    # Identical. And the refresh was not free: Items.Refresh() plus layout ran
    # 339.5 ms median, against 12.5 ms for Set-SRTypeScale plus layout - it
    # discards and regenerates every container in the list to arrive at the size
    # the rows had already taken. That is the whole of the text-size button's
    # cost, spent on nothing.
    #
    # 🪤 IF A ROW EVER BAKES A FONT-DERIVED NUMBER INTO ITS ITEM OBJECT rather
    # than reading a resource, this stops being true and the height will lag a
    # step behind. The suite asserts the height actually tracks the scale with no
    # refresh, so that would go red here rather than being noticed as "the zoom
    # looks wrong sometimes".
    Show-Selected -Force
}

function Show-Selected { param([switch]$Force)
    $it = $ui.SessionList.SelectedItem
    if (-not $it) { return }
    # Choosing something in the list is the deliberate act that leaves a
    # drilled-into sub-agent behind. Close-AgentDoc comes through here too,
    # having already cleared it, which is why this is a plain assignment rather
    # than a branch.
    $script:agentOpen = $null

    # ===================================================================
    # A SUB-AGENT, OPENED.
    #
    # It gets its own path rather than sharing the session one, because every
    # live thing below this block is meaningless for it: it has no process, so
    # nothing can be typed into it, it cannot be waiting on a question, and
    # there is no console to read. Running the session path against an agent
    # would spawn a screen probe for a pid that does not exist and put the
    # PARENT's pending question over the agent's transcript.
    #
    # What it does share is the document, which is the whole point - the same
    # reader, the same gutter, the same folds.
    # ===================================================================
    if ($it.Kind -eq 'agent') {
        $same = ($script:selId -eq $it.Id)
        $script:selId = $it.Id
        $sa = $it.Sub
        $ui.PaneName.Text = "$($sa.Label)"
        $ui.PaneStateDot.Background = $window.FindResource('HueAsk')
        Set-WorkingPulse $false
        $what = $(if ($sa.IsTeammate) { 'teammate' } else { 'task sub-agent' })
        $of = ''
        try { $of = "$($it.Row.T.Text)" } catch { }
        $bits = @("$what")
        if ($of) { $bits += ('working for ' + $of) }
        if ($sa.Description) { $bits += "$($sa.Description)" }
        $ui.PaneState.Text = ($bits -join '   |   ')
        # The vitals strip describes a LIVE session - model, context, branch,
        # turn clock. None of it applies to a transcript nothing is holding.
        if (-not $same) { try { Update-Chips $null } catch { } }
        Show-Ask $null
        if ($same -and -not $Force) { return }
        if (-not $same) {
            $script:tailBytes = $script:TailBase
            $script:docToBottom = $true
        }
        Update-Document
        return
    }

    if ($it.Kind -ne 'session') { return }
    $same = ($script:selId -eq $it.Id)
    $script:selId = $it.Id
    $r = $it.Row
    $t = $r.T
    $ui.PaneName.Text = $t.Text
    $b = @($script:Bands | Where-Object { $_.Key -eq "$($r.Band)" })
    $ui.PaneStateDot.Background = $(if ($b.Count) { $window.FindResource($b[0].Acc) } else { $window.FindResource('AccIdle') })
    # 🔑 A DOT THAT BREATHES WHILE IT IS ACTUALLY THINKING. The header said
    # WORKING in text, which is a state you have to read; there was nothing that
    # said "right now" at a glance, and on a surface whose whole job is telling
    # you what is alive that is the one thing worth animating. It runs only
    # while the session is mid-turn, and stops dead otherwise - a permanent
    # animation would be decoration, and this window has none.
    Set-WorkingPulse ($r.A -and "$($r.A.Status)" -eq 'busy')
    $detail = $(if ($r.Conv -and "$($r.Conv.Detail)") { "$($r.Conv.Detail)" } else { 'no process is holding it' })
    $ui.PaneState.Text = ('{0}   |   {1}   |   {2}' -f $(if ($b.Count) { $b[0].Label } else { '' }), $detail, (Get-ProjectLabel "$($r.D.path)"))
    # 🔴 NOT ON THE CLICK. Reading the vitals costs ~120 ms of JSONL parsing plus
    # a git call, and selecting a conversation is the one interaction the
    # operator has already reported as laggy. The strip is CLEARED here and
    # filled by the follow tick within a second - exactly the arrangement the
    # question panel already uses, and for the same reason. A strip that arrives
    # a beat late is barely noticeable; a click that takes an extra beat is.
    if (-not $same) { try { Update-Chips $null } catch { } }

    # Everything above is a few string assignments and is always safe to redo.
    # Everything below reads files and spawns a process.
    if ($same -and -not $Force) { return }

    # 🔴 ONLY A DIFFERENT CONVERSATION STARTS AT THE BUDGET. -Force means "the
    # content moved", not "this is a new conversation", and resetting here undid
    # 'load earlier' on every forced refresh - the exact defect the $same guard
    # above was added to fix, reintroduced one line below it.
    if (-not $same) { $script:tailBytes = $script:TailBase }
    # A DIFFERENT conversation always opens at its newest line. The parse is
    # off-thread now, so the document does not exist on the next line - the
    # intent is carried and honoured by whoever builds it.
    if (-not $same) { $script:docToBottom = $true }
    Update-Document
    if (-not $same) {
        # 🔴 THE CONSOLE READ IS NOT DONE HERE ANY MORE. Update-Ask calls
        # Get-SRScreenQuestion, which spawns a child process with a 3-SECOND
        # BUDGET AND A RETRY - synchronously, on the UI thread, on every single
        # click in the session list. That is the lag: selecting a conversation
        # could block the window for six seconds while it read another process's
        # console. The background probe already reads the pending question for
        # whatever is selected, so this hands the job to it and kicks it now
        # rather than waiting up to 15 seconds for the next tick.
        #
        # 🪤 The panel is CLEARED first. Leaving the previous conversation's
        # question up while the probe fetches this one's is how an answer gets
        # filed against the wrong menu - the defect Show-Ask's own comment was
        # written for.
        $script:lastAskAt = Get-Date
        Show-Ask $null
        # 🔴 THE QUESTION GETS ITS OWN PROBE, STARTED HERE. Waiting for the heavy
        # one meant ten to fifteen seconds before a waiting conversation showed
        # what it was waiting for - it refreshes the registry and spawns claude
        # before it ever gets to the screen read. This job does the screen read
        # and nothing else, and the 100ms lane collects it.
        $script:screenShells = -1
        $script:screenAgents = -1
        # 🪤 REQUESTED HERE, STARTED ON THE LANE. Opening a runspace is 200-400ms
        # of synchronous work, and doing it in the click handler put the cold
        # click back to 1,191ms - measured, and caught by the profile assertion.
        # That is the very cost this probe exists to keep off the click. The lane
        # runs ten times a second, so the read still begins within a tenth of a
        # second of the click and the click itself pays nothing.
        $script:askWanted = $true
        try {
            $script:liveTimer.Stop()
            Start-LiveProbe
            $script:liveTimer.Start()
        } catch { }
    }
    Update-SendState
    if (-not $same) {
        $script:followStamp = $null
        # One watcher, on the conversation actually on screen. Following all
        # twelve would be twelve handles for eleven panes nobody is reading.
        try { Start-TranscriptWatch "$($r.S.jsonl)" } catch { }
    }
}

# FOLLOW ONLY THE SELECTED SESSION. One file, checked once a second, rather than
# a watcher per conversation: 14 run today and the cost has to stay flat in that
# number. Polling one file also has nothing to leak when the selection changes,
# which a FileSystemWatcher does.
$script:followStamp = $null
$script:followTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:followTimer.Interval = [TimeSpan]::FromSeconds(1)

# A named function rather than an anonymous handler, so the suite can drive one
# tick directly. The band-jump defect this tick caused was invisible to any test
# that could not call it.
function Invoke-FollowTick {
    # Nothing moves under an open sheet - see the gate on the model timers.
    if ($script:sheetDepth -gt 0) { return }
    # The turn clock, BEFORE the early returns below. It has to move on a
    # conversation whose transcript has not changed this second - which is every
    # second of a long reply, and exactly when you are watching it.
    try { Step-ChipClock } catch { }
    # 🔑 AND THE OPEN BACKGROUND SHELLS, for the same reason and in the same
    # place: a shell keeps writing while the transcript sits still, so behind
    # the returns below its output would only ever move when something else did.
    # Costs nothing when no shell block is open - the list is empty.
    try { Update-LiveShells } catch { }
    # 🪤 AFTER Update-LiveShells, and it is NOT the same thing. That one
    # refreshes shell blocks the operator has OPENED inside the transcript;
    # this one is the pinned list of what is running whether or not any block
    # is open. Its own gates keep it free when nothing is.
    try { Update-ShellPanel } catch { }
    # 🪤 BEFORE the early return below. A compacting session is BUSY, and the
    # guard further down leaves this tick early for a busy one - which would
    # have meant the panel that exists to watch a compact never updated while
    # one was running.
    try { Update-LivePane } catch { }
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return }
    $r = $it.Row
    # 🪤 BEFORE the Live check, not after. Show-Selected clears the strip to keep
    # the read off the click, so this is what puts it back - and a conversation
    # that is NOT running still has a model, a context figure and a branch worth
    # showing. Behind the Live return it would have filled for busy sessions
    # only, and every idle one would have shown an empty header forever.
    if (-not $script:chipVitals) { try { Update-Chips $r } catch { } }
    if (-not $r.Live) { return }
    $j = "$($r.S.jsonl)"
    if (-not $j -or -not (Test-Path -LiteralPath $j)) { return }
    $now = $null
    try { $fi = Get-Item -LiteralPath $j; $now = ('{0}|{1}' -f $fi.Length, $fi.LastWriteTimeUtc.Ticks) } catch { return }
    if ($now -eq $script:followStamp) { return }
    # 🔴 A FIRST OBSERVATION IS NOT A CHANGE. followStamp is reset to $null when
    # you select a different conversation, so the very next tick saw "the stamp
    # differs from nothing", called that growth, and moved the row straight out
    # of NEEDS YOU - which is why clicking a waiting conversation made it vanish
    # from the band you clicked it in. Selecting something is not evidence about
    # it. The first tick after a selection RECORDS the stamp and does nothing
    # else; only a second, different stamp is growth.
    $firstLook = ($null -eq $script:followStamp)
    $script:followStamp = $now
    try { Update-Document; Update-SendState } catch { }
    # The vitals are re-read HERE and nowhere else on this tick: the transcript
    # has demonstrably grown, so the context figure, the model, the sub-agent and
    # shell counts can all have moved. On a quiet second nothing above this line
    # runs, which is what keeps a per-second timer cheap.
    try { Update-Chips $r } catch { }
    if ($firstLook) { return }

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
}
# 🔴 EVERY TICK IS WRAPPED. An unhandled exception out of a DispatcherTimer
# tick takes the WHOLE WINDOW down - the launch tick's own comment says so and
# then four of the seven ticks were left unguarded anyway, including this one,
# which runs every second against a file another process is writing.
$script:followTimer.Add_Tick({
    try { Invoke-FollowTick } catch { Write-SRLog ('follow tick failed: ' + $_.Exception.Message) } })

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------
$ui.ModeWork.Add_Checked({   Set-Surface 'work' })
$ui.ModeManage.Add_Checked({ Set-Surface 'manage' })
$window.Add_SizeChanged({ Set-Breakpoint })

# THE MEASURE IS ARITHMETIC ON THE PANE WIDTH, so it is wrong the moment the
# window is resized until the document is rebuilt. Rebuilding on every pixel of
# a drag would be absurd; this waits for the drag to stop.
$script:measureTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:measureTimer.Interval = [TimeSpan]::FromMilliseconds(240)
$script:measureTimer.Add_Tick({
    $script:measureTimer.Stop()
    if ($script:sheetDepth -gt 0) { return }
    try {
        $doc = $ui.PaneDoc.Document
        if (-not $doc) { return }
        # 🪤 PADDING CAN BE RESTATED; TYPE CANNOT. Set-ReadMeasure recomputes the
        # size the pane now wants, but every Run in the document was built at
        # the OLD size and nothing re-reads it - so when the size band actually
        # moves, the document has to be rebuilt rather than re-padded. Compared
        # before and after, so an ordinary drag still costs only the padding.
        $was = $script:readSize
        Set-ReadMeasure -Doc $doc -PadL 44
        if ([Math]::Abs($script:readSize - $was) -ge 0.5) { Show-Selected -Force }
    } catch { }
})
$ui.PaneDoc.Add_SizeChanged({ $script:measureTimer.Stop(); $script:measureTimer.Start() })
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
        # Through the prompt as well: closing is exactly when being unable to
        # save, with no way out, costs the most.
        if (-not (Save-RegistryOrAsk 'your ticks')) { $e.Cancel = $true }
    }
})

# 🔴 THE STATE FILTER, BACK. The retired window had three clickable count
# pills; the rewrite dropped them and nothing replaced them, so there was no way
# to say "show me only what is waiting on me" - reported as "the filter option
# and logic is gone as well". It returns on the band headings rather than as new
# chrome: they already say the state and the count, and they are already where
# you are looking when you want to narrow the list.
#
# 🪤 PreviewMouseLeftButtonDown, NOT SelectionChanged or a click on the row.
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

# ===========================================================================
# STEPPING THROUGH THE LIST WITH THE ARROW KEYS
#
# 🔴 EIGHT ROWS COST 747-973 ms, AND THERE IS NO ARROW HANDLER AT ALL. WPF
# moves the selection on its own and SelectionChanged then runs the WHOLE of
# Show-Selected for every row - including every row you are only passing
# THROUGH on the way to the one you want. Nothing was wrong with Show-Selected;
# it was simply being asked to draw eight conversations to show one.
#
# The operator's ruling, asked directly: the chrome moves on every key, the
# DOCUMENT settles once you stop. So the first press draws immediately - a
# single arrow key has to feel exactly like a click - and everything after it
# inside the window coalesces onto ONE draw when the stepping ends.
#
# 🪤 THE LEADING EDGE IS WHAT KEEPS ONE PRESS INSTANT. A plain trailing
# debounce puts the full interval in front of EVERY arrow key, including the
# single press that is not a scan at all - which trades a 100 ms stall for a
# 140 ms one and would have measured as an improvement across eight rows while
# making the common gesture worse.
#
# 🪤 AND THE TRAILING TICK ONLY DRAWS IF SOMETHING WAS ACTUALLY COALESCED.
# Arming the timer after the leading draw is what lets a second key find it
# running; without $showPending it would then fire on a selection that is
# already on screen and spend a second full Show-Selected doing nothing, 140 ms
# after every single click in the list.
$script:showPending = $false
$script:showLast = $null
$script:showTimer = New-Object System.Windows.Threading.DispatcherTimer
# 🔴 90 ms, AND THE NUMBER IS THE KEY-REPEAT RATE, NOT A FEELING. Windows
# repeats a held key about every 32 ms, so anything comfortably above that
# coalesces a run and anything below it draws mid-scan. 140 was the first guess
# and it measured badly for a reason worth writing down: the settle is INSIDE
# what the operator waits for, so an interval that is longer than the work it
# saves makes the gesture slower while making the bench look better. Measured
# over eight rows: 276 ms drawing every one, 244 ms with a 140 ms settle - of
# which 140 ms WAS the settle, so the real work fell from 276 to about 104 and
# the operator got almost none of it.
$script:showTimer.Interval = [TimeSpan]::FromMilliseconds(90)
$script:showTimer.Add_Tick({
    $script:showTimer.Stop()
    if ($script:showPending) {
        $script:showPending = $false
        $script:showLast = [DateTime]::UtcNow
        try { Show-Selected } catch { Write-SRLog ('  [skip] the settled draw failed: ' + $_.Exception.Message) }
    }
})

# A named function rather than an inline handler, for the reason Invoke-FollowTick
# gives: a gesture the suite cannot call is a gesture the suite cannot check.
# 🔴 THE CONTROL HAS TO BE MEASURABLE IN THE SAME RUN. A bar in milliseconds
# cannot say whether this debounce moved anything on a machine whose floor
# drifts between runs - only the old path, timed beside the new one, can. So the
# suite can turn it off, step the list, and time what it used to cost. It is
# never written anywhere but a bench; the window ships with it on.
$script:showDebounce = $true

function Request-ShowSelected {
    if (-not $script:showDebounce) { Show-Selected; return }
    $nowSel = [DateTime]::UtcNow
    if ($script:showLast -and ($nowSel - $script:showLast).TotalMilliseconds -lt $script:showTimer.Interval.TotalMilliseconds) {
        $script:showPending = $true
        $script:showTimer.Stop()
        $script:showTimer.Start()
        return
    }
    $script:showPending = $false
    $script:showLast = $nowSel
    Show-Selected
    $script:showTimer.Start()
}


$ui.SessionList.Add_SelectionChanged({
    $it = $ui.SessionList.SelectedItem
    if ($it -and $it.Kind -eq 'band') {
        # A heading is not a target. Step past it rather than arming nothing.
        $i = $ui.SessionList.SelectedIndex + 1
        if ($i -lt @($ui.SessionList.Items).Count) { $ui.SessionList.SelectedIndex = $i }
        return
    }
    Request-ShowSelected
})

# 🪤 PreviewMouseLeftButtonDown, FOR THE REASON THE SESSIONS COLUMN GIVES ABOVE:
# ListBoxItem marks the button-down HANDLED when it selects, so a heading click
# would never reach a normal Click handler. Handling it here also stops the
# selection, which is what keeps a heading from becoming a project filter.
$ui.RailList.Add_PreviewMouseLeftButtonDown({
    param($s, $e)
    $it = Get-ClickedRow $e.OriginalSource
    if (-not $it -or "$($it.Kind)" -ne 'band') { return }
    Toggle-RailBand "$($it.BandKey)"
    Set-Status $(if ($script:railBandShut["$($it.BandKey)"]) {
        "$($it.BandLabel.ToLower()) folded away - click the heading again to show those $($it.BandCount) project(s)"
    } else { "showing the $($it.BandCount) project(s) in $($it.BandLabel.ToLower())" })
    $e.Handled = $true
})

$ui.RailList.Add_SelectionChanged({
    $it = $ui.RailList.SelectedItem
    if (-not $it) { return }
    # 🔴 A HEADING IS NOT A PROJECT. Its Path is '', and letting that through
    # set railPick to an empty string - which matches no project, so the sessions
    # column filtered itself down to nothing with no tile highlighted to say why.
    # The band click above already handles the gesture; this only has to refuse.
    if ("$($it.Kind)" -eq 'band') { return }
    $script:railPick = $(if ($script:railPick -eq $it.Path) { $null } else { $it.Path })
    Build-Rail
    Build-Sessions
})
$ui.RailClear.Add_MouseLeftButtonUp({ $script:railPick = $null; Build-Rail; Build-Sessions })

# Typing filters, but not on every keystroke: a rebuild over 215 rows per letter
# is a visibly laggy search box.
#
# 🔑 180 -> 90 ms, BECAUSE THE COST THIS WAS CHOSEN FOR HAS HALVED. The wait is
# a straight function of what a rebuild costs, and Build-Sessions went 194 -> 67
# ms; leaving the constant where it was would keep charging for work that is no
# longer done. Measured before this change, a letter into the header box cost
# 611 ms click-to-presented-frame, of which this timer was 180 - the single
# largest item in the gesture, and 26x the terminal's own 6,9 ms bar on its own.
#
# 🪤 SHORTER IS NOT AUTOMATICALLY BETTER, WHICH IS WHY IT IS NOT SHORTER STILL.
# Below roughly the interval between two keystrokes this stops being a debounce
# and rebuilds three panes per letter, which feels worse than a brief wait even
# as the number improves. 90 ms sits under a comfortable typing cadence and
# above one rebuild, so a burst of typing still collapses into a single pass.
#
# 🔴 THE 90 ms IS DEDUCED, NOT MEASURED, AND THAT DISTINCTION IS THE POINT.
# An interleaved A/B - 90/180/90/180, so both settings eat the same drift - could
# not separate them at all: the header box read 1.113 and 1.082 ms at 90, against
# 1.313 and 713 at 180. The 180 runs STRADDLE the 90 runs and the fastest of all
# four was a 180. Within-setting spread was 1,84x, far wider than the 90 ms being
# looked for, so the instrument cannot resolve this gesture to better than about
# a factor of two.
#
# That is a fact about the measurement, not evidence the change does nothing:
# this constant is a DispatcherTimer interval, i.e. pure wall-clock waiting with
# no work in it, so 90 ms less of it is 90 ms less waiting by construction. The
# reason to record it here rather than claim a win is that the next person to
# benchmark this gesture will see numbers swing by 600 ms on untouched code, and
# should not go hunting for a regression that is only the spread.
$script:searchTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:searchTimer.Interval = [TimeSpan]::FromMilliseconds(90)
# 🔴 BOTH PANES. The header box narrows the rail as well as the list now, and
# the rail has a box of its own - so a rebuild of only the sessions column would
# leave the projects showing a set that no longer matches what you typed.
$script:searchTimer.Add_Tick({
    $script:searchTimer.Stop()
    # A KEYSTROKE MUST NOT BE ABLE TO KILL THE WINDOW. This ran Build-Rail and
    # Build-Sessions bare, and both walk every conversation calling helpers that
    # have thrown before now (Get-ProjectLabel on an empty path did exactly
    # that) - so one malformed registry entry plus one character typed into the
    # search box was a closed window.
    try { Build-Rail; Build-Sessions } catch { Write-SRLog ('search rebuild failed: ' + $_.Exception.Message) } })
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

# The filter chips. Add_Checked rather than Add_Click: a RadioButton in a group
# is also unchecked programmatically, and the handler has to fire for whichever
# one ends up ON rather than for whichever one was pressed.
foreach ($pair in @(@('MgrAll', 'all'), @('MgrTicked', 'ticked'),
                    @('MgrRunning', 'running'), @('MgrNeeds', 'needs'))) {
    $ui[$pair[0]].Tag = $pair[1]
    $ui[$pair[0]].Add_Checked({
        param($s, $e)
        $script:mgrFilter = "$($s.Tag)"
        Build-Manager
    })
}

# --- the two panes' own controls -------------------------------------------
function Update-RailLabels {
    $cur = @($script:RailSorts | Where-Object { $_.Key -eq $script:railSort })
    $ui.RailSort.Text = $(if ($cur.Count) { "$($cur[0].Label)" } else { 'recent' })
    $ui.RailOnlyLive.Text = $(if ($script:railOnlyLive) { 'running' } else { 'all' })
    $ui.RailOnlyLive.Foreground = $window.FindResource($(if ($script:railOnlyLive) { 'TextMax' } else { 'TextLow' }))
}
$ui.RailSort.Add_MouseLeftButtonDown({
    param($s, $e)
    $keys = @($script:RailSorts | ForEach-Object { $_.Key })
    $at = [array]::IndexOf($keys, $script:railSort)
    $script:railSort = $keys[($at + 1) % $keys.Count]
    Update-RailLabels
    Build-Rail
    $e.Handled = $true
})
$ui.RailOnlyLive.Add_MouseLeftButtonDown({
    param($s, $e)
    $script:railOnlyLive = -not $script:railOnlyLive
    Update-RailLabels
    Build-Rail
    $e.Handled = $true
})
$ui.RailShelved.Add_MouseLeftButtonDown({
    param($s, $e)
    $script:railShowShelved = -not $script:railShowShelved
    Build-Rail
    Set-Status $(if ($script:railShowShelved) {
        "showing the $($script:railShelved) shelved project(s) - right-click one to put it back for good"
    } else { 'shelved projects put away again' })
    $e.Handled = $true
})
Update-RailLabels

# 🪤 THE SAME DEBOUNCE THE HEADER BOX USES. Rebuilding on every keystroke over
# 190 conversations is a stutter you can feel while typing; the timer collapses
# a burst of keys into one rebuild.
$ui.RailSearch.Add_TextChanged({ $script:searchTimer.Stop(); $script:searchTimer.Start() })
$ui.ListSearch.Add_TextChanged({ $script:searchTimer.Stop(); $script:searchTimer.Start() })

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

# ===========================================================================
# THE PROJECT TILE'S OWN MENU - one item, and it is the only way to shelve.
#
# Built the same way the manager's is, and for the same reason: a ContextMenu
# lives in its own popup outside the window's visual tree, so an implicit style
# in Window.Resources is not something to rely on reaching it. Without the two
# explicit assignments it keeps the OPERATING SYSTEM's white slab, in the middle
# of a black window, on a gesture that is about to change what comes back
# tomorrow morning.
$script:railMenuDir = $null
$script:railMenuLabel = ''

# WHICH WAY THE ONE ITEM GOES. Its own function because it is the part that can
# be wrong: an item reading "Shelve this project" over one already shelved would
# put it back, and the operator would have pressed the opposite of what they
# read. Decided when the menu opens, not by carrying two items of which one is
# always the wrong thing to offer.
function Get-RailShelveVerb { param($Dir)
    if (Test-SRProjectShelved $Dir) { return 'Put this project back' }
    return 'Shelve this project'
}

function New-RailMenu {
    $m = New-Object System.Windows.Controls.ContextMenu
    $m.Style = [System.Windows.Style]$window.FindResource([System.Windows.Controls.ContextMenu])
    $i = New-Object System.Windows.Controls.MenuItem
    $i.Style = [System.Windows.Style]$window.FindResource([System.Windows.Controls.MenuItem])
    $i.Header = 'Shelve this project'
    $i.Add_Click({
        $d = $script:railMenuDir
        $script:railMenuDir = $null
        if (-not $d) { return }
        $lbl = $script:railMenuLabel
        if (Test-SRProjectShelved $d) {
            if (Set-ProjectShelved -Dir $d -Shelved $false) {
                Build-Rail; Build-Sessions
                Set-Status ("'{0}' is back on the rail, and will be restored at logon again" -f $lbl) 'ok'
            }
            return
        }
        # 🔴 IT CHANGES WHAT COMES BACK TOMORROW MORNING, so it says so before it
        # does it. Hiding is undoable - nothing is deleted and the count in the
        # header is the way back - but the consequence that matters happens while
        # nobody is watching, at the next logon, and a gesture whose effect is
        # invisible for sixteen hours is one to confirm.
        $kids = @($script:model | Where-Object { "$($_.D.path)" -eq "$($d.path)" })
        $ticked = @($kids | Where-Object { [bool]$_.S.enabled }).Count
        if (-not (Confirm-Action 'Shelve this project' (
            "'{0}' leaves the projects rail, and none of its conversations will be restored at the next logon{1}.`n`n" +
            "Nothing is deleted: its {2} conversation(s) and their ticks are kept, and the rail header will say it is shelved so you can put it back." -f `
                $lbl, $(if ($ticked) { " ($ticked of them are ticked today)" } else { '' }), $kids.Count) -Verb 'Shelve it')) {
            Set-Status 'nothing shelved'; return
        }
        if (Set-ProjectShelved -Dir $d -Shelved $true) {
            # 🪤 THE FILTER GOES WITH IT. Leaving railPick on a project that is no
            # longer drawn would narrow the sessions column to conversations from
            # a tile nobody can see.
            if ("$($script:railPick)" -eq "$($d.path)") { $script:railPick = $null }
            Build-Rail; Build-Sessions
            Set-Status ("'{0}' is shelved - click the count in the projects header to put it back" -f $lbl) 'ok'
        }
    })
    $null = $m.Items.Add($i)
    return $m
}

$ui.RailList.ContextMenu = New-RailMenu
$ui.RailList.Add_PreviewMouseRightButtonDown({
    param($sender, $e)
    $it = Get-ClickedRow $e.OriginalSource
    # An age-band heading is not a project, so it gets no menu rather than a menu
    # whose one item would act on whatever was right-clicked last.
    if (-not $it -or "$($it.Kind)" -ne 'project') {
        $script:railMenuDir = $null
        $ui.RailList.ContextMenu.IsOpen = $false
        $e.Handled = $true
        return
    }
    $kid = @($script:model | Where-Object { "$($_.D.path)" -eq "$($it.Path)" })
    if (-not $kid.Count) { $script:railMenuDir = $null; $e.Handled = $true; return }
    $script:railMenuDir = $kid[0].D
    $script:railMenuLabel = "$($it.Label)"
    $ui.RailList.ContextMenu.Items[0].Header = Get-RailShelveVerb $script:railMenuDir
})

$ui.SaveBtn.Add_Click({
    if (Save-RegistryOrAsk) {
        if ($script:surface -eq 'manage') { Build-Manager }
        Set-Status 'saved - those ticks decide what comes back at the next logon' 'ok'
    }
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
    # 🔴 THE SAME $sheetDepth GATE AS THE MODEL TIMERS, and this one matters
    # most: when the queue drains it calls Update-Model, which REPLACES every row
    # object. A sheet blocks its caller on a nested dispatcher frame while the
    # dispatcher keeps pumping, so without this the confirmation you are looking
    # at could have its rows swapped out from under it and the action would land
    # on orphans. It also types into terminals, which is not a thing to do while
    # the operator is being asked a question. Nothing is lost by waiting - the
    # queue is still there on the next tick.
    if ($script:sheetDepth -gt 0) { return }
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
        # 🪤 THIS BRANCH WAS OUTSIDE EVERY try. Update-Model re-reads the
        # registry and throws on an unreadable one, and this runs in the moments
        # AFTER a relaunch has already closed the conversations it reopened -
        # losing the window here leaves the whole set shut with no way to reopen
        # it from the tool, which is the exact disaster the comment further down
        # was written to prevent.
        try {
            Update-Model -KeepAgents; Update-Surface; Start-LiveProbe
            if ($script:surface -eq 'manage') { Build-Manager }
        } catch {
            Write-SRLog ('launch drain failed: ' + $_.Exception.Message)
            Set-Status ('opened them, but the list could not be refreshed: ' + $_.Exception.Message) 'bad'
        }
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
        catch {
            # 🔴 THE LOG IS NOT SOMEWHERE THE OPERATOR LOOKS. This failure went
            # only to restore.log and the launch carried on: the sessions open
            # correctly, because they are launched from memory - but the ticks
            # and the freshly adopted names never reached disk, so the NEXT
            # LOGON quietly brings back the old set. The one moment that matters
            # is hours away, which is precisely why it has to be said now.
            Write-SRLog ('  [FAIL] could not save before launching: {0}' -f $_.Exception.Message)
            Set-Status ('opening anyway, but the ticks could NOT be saved - press Save, or the next logon uses the old set: ' +
                $_.Exception.Message) 'bad'
        }
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
# 🔴 THE STALE-WRITE GUARD NEEDED A WAY OUT, AND HAD NONE. It refuses a save
# when the file has moved on since this window read it - which is right, and
# stopped two windows discarding each other's ticks. What it missed is that the
# HOURLY SCAN TASK writes that file from its own process. So: tick something,
# wait for the scan, press Save -> refused; press Rescan -> it must save first,
# also refused. Neither button could get the ticks out and the only exit was
# closing the window and losing them. Measured in a sandbox on 2026-08-30, and
# reachable within an hour of ordinary use.
#
# 🪤 FORCING IS SAFE HERE IN THE COMMON CASE AND THE OPERATOR IS STILL ASKED.
# The scan only ADDS conversations it discovered; anything overwritten comes back
# on its next run. What forcing cannot tell apart is another WINDOW's ticks,
# which do not come back - so this asks rather than deciding, and says which
# outcome is which.
function Save-RegistryOrAsk {
    param([string]$What = 'those ticks')
    try { Save-SRRegistry -Registry $script:reg; $script:dirty = $false; return $true }
    catch {
        $msg = "$($_.Exception.Message)"
        if ($msg -notmatch 'changed on disk') {
            Set-Status ("could not save: $msg") 'bad'
            return $false
        }
        $pick = Show-Sheet -Title 'The registry changed while you were working' -Escape 'keep' -Body (
            "Something else has written it since this window read it - almost always the hourly scan, " +
            "which only adds conversations it has discovered.`n`n" +
            "Saving yours replaces what it wrote. Anything the scan found comes back on its next run; " +
            "ticks made in ANOTHER Sessions window would not.") -Choices @(
            @{ Key = 'keep';  Label = 'Leave it for now' },
            @{ Key = 'force'; Label = 'Save mine anyway' }
        )
        if ($pick -ne 'force') { Set-Status ("$What not saved - the file changed underneath this window") 'warn'; return $false }
        try { Save-SRRegistry -Registry $script:reg -Force; $script:dirty = $false; return $true }
        catch { Set-Status ("could not save even forced: $($_.Exception.Message)") 'bad'; return $false }
    }
}

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

# ===========================================================================
# SIGNING IN, AND THEN ACTUALLY BEING SIGNED IN.
#
# 🔴 SIGNING IN DOES NOT REACH A RUNNING SESSION. A running claude reads the
# login token AT STARTUP - CONTEXT.md's `relaunch` entry records it - so after a
# token expiry every open session sits at its own login prompt and signing in
# once reaches none of them. That is the whole of the chore this replaces:
# operator signs in, then relaunches everything by hand.
#
# 🪤 AND MEASURED 2026-09-01, THE DAILY RE-LOGIN SHOULD NOT BE NEEDED AT ALL.
# The access token lives EIGHT HOURS but the refresh token lasts 27 DAYS, so
# claude is meant to renew it silently. What is actually seen on this machine is
#   "Could not refresh your login because another Claude Code process is
#    refreshing it (or exited mid-refresh)"
# - sixteen concurrent sessions contending over one credentials file, losing the
# refresh between them. This button automates the chore; it does not fix that,
# and the fix is not a button. See also Get-SRBridgeSuppression, which records
# the OTHER thing that looks identical from the outside.
$script:signInWatch = $null
$script:signInFrom = $null

# 🔴 THE ONE THING THAT WAS NEVER ON SCREEN. Measured across the operator's
# transcripts: eleven `401 OAuth access token has expired` all between 07:30 and
# 07:35 on four consecutive mornings, up to five sessions in the same minute -
# the logon restore relaunching the ticked set and every process racing to
# refresh one overnight-expired token. None since the launches were staggered.
#
# What remains is the OTHER failure, and it is the one that reads as being
# logged out: Claude Code counts consecutive Remote Control bridge failures and
# stops trying on the seventh. While that holds, sessions run perfectly and do
# not register, so the phone shows nothing. It sat at SIX on the day this was
# written. Nothing anywhere said so.
#
# 🪤 Quiet until it matters. A healthy bridge draws nothing at all - a chip that
# is always there is a chip nobody reads, and this row is deliberately sparse.
function Update-BridgeNote {
    # 🔴 THE TOKEN COMES FIRST, BECAUSE IT IS THE ONE THAT ACTUALLY STOPS THE
    # MORNING. Diagnosed 2026-09-02: the access token lives 8 hours, this
    # machine is off overnight, and NOTHING on this surface ever said so - the
    # window looked perfectly signed in while every session launched at boot
    # came up unauthorized. A suppressed bridge is survivable; a dead token is
    # not, so it outranks the bridge note and uses the same one line.
    $exp = $null
    try { $exp = Get-SRTokenExpiry } catch { }
    if ($exp -and -not (Test-SRTokenLive)) {
        $ui.BridgeNote.Text = 'signed in - token expired'
        $ui.BridgeNote.Foreground = $window.FindResource('HueBad')
        $ui.BridgeNote.ToolTip = ('Your account is signed in, but its access token expired at {0:HH:mm} and every new session would come up unauthorized. It refreshes on its own once something asks it to - press Sign in if it does not. Your REFRESH token is good until well into next month, so this is not a real sign-out.' -f $exp)
        $ui.BridgeNote.Visibility = $V_Show
        return
    }

    $b = $null
    try { $b = Get-SRBridgeState } catch { }
    if (-not $b -or -not $b.Ok) { $ui.BridgeNote.Visibility = $V_Hide; return }
    if ($b.Suppressed) {
        $ui.BridgeNote.Text = ('remote control off until {0:HH:mm}' -f $b.Until)
        $ui.BridgeNote.Foreground = $window.FindResource('HueBad')
        $ui.BridgeNote.ToolTip = ('Claude Code has stopped trying to register sessions with Remote Control after {0} consecutive failures, until {1:HH:mm}. The sessions are running normally - they are just not visible on your phone. Signing in does not change this.' -f $b.Fails, $b.Until)
        $ui.BridgeNote.Visibility = $V_Show
        return
    }
    # Climbing but not yet tripped is the moment worth knowing about: one more
    # failure and Remote Control goes quiet.
    if ($b.Fails -ge ($b.Limit - 2)) {
        $ui.BridgeNote.Text = ('remote control {0}/{1}' -f $b.Fails, $b.Limit)
        $ui.BridgeNote.Foreground = $window.FindResource('HueWarn')
        $ui.BridgeNote.ToolTip = ('{0} consecutive Remote Control registration failures. At {1} Claude Code stops trying, and your sessions stop appearing on your phone even though they are running. This is not a login problem.' -f $b.Fails, $b.Limit)
        $ui.BridgeNote.Visibility = $V_Show
        return
    }
    $ui.BridgeNote.Visibility = $V_Hide
}

function Get-SRCredStamp {
    $p = Join-Path (Join-Path $env:USERPROFILE '.claude') '.credentials.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Item -LiteralPath $p).LastWriteTimeUtc } catch { return $null }
}

# 🪤 THE FILE IS THE EVIDENCE, NOT THE TERMINAL CLOSING. A login terminal can be
# closed without signing in, and it can sit open long after a successful one -
# so watching the window would relaunch on a login that never happened, and
# kill live sessions for nothing. `.credentials.json` is rewritten exactly when
# a sign-in succeeds, which is the only fact worth acting on.
function Stop-SignInWatch {
    if ($script:signInWatch) { try { $script:signInWatch.Stop() } catch { } }
    $script:signInWatch = $null
    $script:signInFrom = $null
}

$ui.SignIn.Add_Click({
    if ($script:signInWatch) { Set-Status 'already waiting for the sign-in to finish' 'warn'; return }
    $script:signInFrom = Get-SRCredStamp
    # A sign-in that never happens must not leave a timer running for the life
    # of the window, polling a file every two seconds forever.
    $script:signInUntil = (Get-Date).AddMinutes(10)
    $why = ''
    try {
        # A REAL, VISIBLE terminal: signing in is an interactive flow with a
        # browser round trip, and it is the operator's to complete.
        #
        # 🔴 `claude auth login`, NOT `claude /login`. The second one STARTS AN
        # INTERACTIVE CONVERSATION and types a slash command into it - so every
        # single sign-in left a real transcript behind. Found by tracing a
        # nameless, blank conversation that the window was listing as live: it
        # was this morning's sign-in, seven records long, containing /login and
        # "Login successful". In a tool whose whole job is deciding which
        # conversations exist and which reopen at logon, the sign-in button was
        # quietly manufacturing one every time it was pressed, and each one is
        # then a candidate for tomorrow's restore.
        # `auth login` is the dedicated command - same browser round trip, no
        # session, no transcript.
        $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
        if ($wt) {
            Start-Process 'wt.exe' -ArgumentList @(
                'new-tab', '--title', 'Claude sign-in',
                'powershell', '-NoExit', '-NoProfile', '-Command', 'claude auth login') | Out-Null
        } else {
            Start-Process 'powershell.exe' -ArgumentList @(
                '-NoExit', '-NoProfile', '-Command', 'claude auth login') | Out-Null
        }
    } catch { $why = $_.Exception.Message }
    if ($why) { Set-Status ('could not open a terminal to sign in: ' + $why) 'bad'; return }
    Set-Status 'signing in - finish it in the terminal that just opened, then the ticked conversations relaunch'
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(2)
    $t.Add_Tick({
        try {
            if ((Get-Date) -gt $script:signInUntil) {
                Stop-SignInWatch
                Set-Status 'stopped waiting for the sign-in - press Sign in again when you have finished it' 'warn'
                return
            }
            $now = Get-SRCredStamp
            if (-not $now) { return }
            if ($script:signInFrom -and $now -le $script:signInFrom) { return }
            Stop-SignInWatch
            Set-Status 'signed in - relaunching the ticked conversations onto the new login' 'ok'
            # 🔑 THE EXISTING BUTTON, RAISED. Relaunch already names what it will
            # close, honours the cap, refuses anything mid-turn and asks first.
            # Duplicating any of that here would be a second relaunch with its
            # own guards to keep in step - and this one KILLS LIVE PROCESSES.
            $ui.RelaunchSessions.RaiseEvent(
                (New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        } catch { Write-SRLog ('sign-in watch failed: ' + $_.Exception.Message) }
    })
    $script:signInWatch = $t
    $t.Start()
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
    # Anything that would not close. It is dropped from the launch set below
    # rather than reopened on top of itself.
    $stuck = New-Object System.Collections.Generic.List[object]
    foreach ($r in $go) {
        $procId = [int]$r.A.Pid
        $proc = $null
        try { $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop } catch { }
        if (-not $proc -or $proc.Name -ne 'claude.exe') { continue }
        $tabName = $(if ("$($r.A.Name)") { "$($r.A.Name)" } else { (Get-Title $r.S $r.D).Text })
        $parent = $null
        try { $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)" -ErrorAction Stop } catch { }
        # 🔴 ONLY WHAT ACTUALLY DIED IS REOPENED. `continue` skipped the rest
        # of THIS iteration but the row stayed in $go, so the launch queue below
        # opened it regardless: a process that refused to die left the old
        # conversation running while a new one started on the same transcript.
        # Two claude processes on one file is the state this tool exists to
        # avoid, and it arrived here silently.
        try { Stop-Process -Id $procId -Force -ErrorAction Stop; $killed++ }
        catch {
            Write-SRLog ("  [FAIL] could not close '{0}': {1}" -f $tabName, $_.Exception.Message)
            $stuck.Add($r)
            continue
        }
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
    # running go through the same half-second-apart launch. Anything that would
    # not close is in NEITHER - reopening it would duplicate it.
    $stuckIds = @($stuck | ForEach-Object { "$($_.Id)" })
    $launch = @(@($go | Where-Object { $stuckIds -notcontains "$($_.Id)" }) + @($open))
    if ($stuck.Count) {
        Set-Status ('{0} would not close and were NOT reopened - they are still running' -f $stuck.Count) 'bad'
    }
    Start-LaunchQueue $launch
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

# 🔑 RULED ON, 2026-09-06, AND NOT TO BE RE-LITIGATED WITHOUT ASKING HIM.
# Put to the operator directly after he reported losing text in this box: keep
# Enter as send, or make it a newline with Ctrl+Enter or the button to send.
# He chose to KEEP IT, so the whole window has one muscle memory - this box,
# the composer three inches below it, and the terminal all commit on Enter.
#
# 🪤 THE ASYMMETRY IS WHY IT WAS WORTH ASKING RATHER THAN ASSUMING. A stray
# Enter here does not lose your text, it TYPES A PARTIAL ANSWER INTO A LIVE
# SESSION - so this is a send gesture, and a send gesture is not something to
# change on a reading of what someone probably meant.
# Answering a question in your own words. Enter sends it, the same key that
# commits it in the terminal - but only through Invoke-AskTyped, which will not
# send an empty one.
$ui.AskFreeSend.Add_Click({ Invoke-AskTyped })
# Typed here, by you, and not yet sent. Everything that redraws the question
# panel reads this before it prefills the box.
$script:askFreeDirty = $false
$script:askFreeWriting = $false
# Which question the box is currently answering. Typing is protected until this
# changes - see the note at the guard for why it is not Get-AskSignature.
$script:askFreeKey = $null
$ui.AskFree.Add_TextChanged({ if (-not $script:askFreeWriting) { $script:askFreeDirty = $true } })

$ui.AskFree.Add_PreviewKeyDown({
    param($sender, $e)
    # Shift+Enter falls through to the box as a newline - see the SendBox
    # handler below for why both boxes now need this.
    if ($e.Key -eq 'Return') {
        if ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) { return }
        Invoke-AskTyped; $e.Handled = $true
    }
})
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
    # 🔴 ENTER STILL SENDS; SHIFT+ENTER IS THE NEWLINE. The box takes returns
    # now - that is what lets it wrap and grow instead of scrolling your reply
    # out of sight sideways - so without this WPF would insert a newline on
    # Enter and the send gesture would simply be gone. Enter keeps the meaning
    # it has in the terminal; Shift+Enter is the one that falls through.
    #
    # 🪤 A DISABLED SEND SWALLOWS IT TOO. Letting Enter through in that case
    # would quietly put a newline in a box you cannot send from, and the next
    # thing you typed would arrive on line two of a message you thought was one.
    if ($e.Key -eq 'Return') {
        if ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) { return }
        if ($ui.SendBtn.IsEnabled) { Invoke-Send }
        $e.Handled = $true
    }
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

# THE INTERRUPT. Nothing is confirmed here on purpose: stopping a turn is the
# recoverable half of the pair beside it - the session stays open, the
# transcript keeps everything written so far, and pressing it by mistake costs
# the rest of one turn. Relaunch, which loses the turn AND the process, does
# confirm. A sheet in front of a gesture whose whole point is "stop, now"
# would be asking the operator to watch it keep going while they read.
function Invoke-Interrupt {
    $r = Get-SelectedRow
    $why = Get-InterruptBlocker $r
    if ($why) { Set-Status $why 'warn'; return }
    # One in flight at a time, exactly as an answer is - and for a sharper
    # reason here: the lane carries the pid captured at send time, so a second
    # press while the first is out would queue a key against a turn that may
    # already have stopped.
    if ($script:ansPs) { Set-Status 'still sending the last thing...' 'warn'; return }
    $null = Start-AskSend -Kind 'esc' -Row $r -Saying 'interrupting...'
}
$ui.PaneStop.Add_Click({ Invoke-Interrupt })

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
            # 🔴 A FAILED KILL MUST NOT BECOME A SECOND SESSION. This swallowed
            # the failure and launched anyway, so a process that refused to die
            # left the OLD conversation running while a NEW one opened on the
            # same transcript - two claude processes holding one file, which is
            # the exact state Show-SRHiddenSession's own comment says must never
            # happen ("the second would resume a session the first is still
            # writing"). A relaunch that cannot close is not a relaunch, and
            # saying so beats silently corrupting a conversation.
            $dead = $false
            try { Stop-Process -Id $procId -Force -ErrorAction Stop; $dead = $true }
            catch { Write-SRLog ("  [FAIL] could not close '{0}': {1}" -f $t, $_.Exception.Message) }
            if (-not $dead) {
                Set-Status ("'{0}' would not close, so it has NOT been reopened - it is still running" -f $t) 'bad'
                return
            }
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

$ui.PaneTools.Content = Get-ToolViewLabel
$ui.PaneTools.Add_Click({ Step-ToolView })
$ui.PaneZoom.Content = Get-ZoomLabel
$ui.PaneZoom.Add_Click({ Step-Zoom })
# Hiding is per-conversation and deliberately not remembered: it means "I have
# seen this one", and it clears when you select a different conversation or a
# different set of shells starts.
$ui.ShellFold.Add_Click({
    $script:shellHidden = $true
    $ui.ShellBox.Visibility = 'Collapsed'
})

# ===========================================================================
# 🔴 THE ROWS LOOKED CLICKABLE AND WERE NOT. The template carries
# Background="Transparent" with Cursor="Hand" - the exact pair StripList,
# CastList, TickBox and the rail tiles use, all four of which have handlers -
# and ShellList had none at all. No Add_Click, no PreviewMouseLeftButtonDown,
# and as an ItemsControl it does not even select. So the pointer changed over a
# row naming a running sub-agent and the click was swallowed. Reported as "when
# I click on the respective background running agent or task, I cannot see its
# output".
#
# 🔑 IT DOES WHAT ITS OWN TOOLTIP ALREADY TOLD YOU TO DO BY HAND. The agent tip
# ends "select it in the list to read the whole thing" - so the click selects
# it, and the whole existing path takes over from there (SessionList's
# SelectionChanged opens a sub-agent document for a row of Kind 'agent'). No
# second way to open the same thing.
function Open-SRShellRow { param($Ctx)
    if (-not $Ctx) { return }
    $sid = "$($Ctx.ShId)"
    if (-not $sid) { return }
    if ($Ctx.ShIsAgent) {
        # The list builds sub-agent rows as Id = 'agent:' + the agent's id.
        $want = 'agent:' + $sid
        foreach ($it in $ui.SessionList.Items) {
            if ("$($it.Id)" -eq $want) {
                $ui.SessionList.SelectedItem = $it
                try { $ui.SessionList.ScrollIntoView($it) } catch { }
                return
            }
        }
        # 🪤 AND IT SAYS SO RATHER THAN DOING NOTHING. An agent that has been
        # dispatched but has not written its transcript yet has no row to
        # select, and a click that silently does nothing is what this whole
        # block exists to fix.
        Set-Status 'that sub-agent has no transcript yet - it appears in the list once it writes one'
        return
    }
    # A shell is not a conversation; its output is a block in the one already
    # open. liveShells is the registry the document fills as it builds.
    foreach ($le in $script:liveShells) {
        if ("$($le.Shell)" -eq $sid) {
            $tgt = $(if ($le.Panel) { $le.Panel } else { $le.Label })
            if ($tgt) { try { $tgt.BringIntoView() } catch { } }
            return
        }
    }
    Set-Status 'that shell has not printed anything into this conversation yet'
}

# 🪤 ONE HANDLER ON THE LIST, NOT ONE PER ROW. A handler attached inside the
# DataTemplate would be re-attached on every ItemsSource assignment - which is
# every rescan - and the rows are rebuilt wholesale each time. This walks up
# from whatever was actually hit to the first element carrying one of our row
# objects, which is also why it needs ShId to exist on them.
$ui.ShellList.AddHandler(
    [System.Windows.UIElement]::PreviewMouseLeftButtonDownEvent,
    [System.Windows.Input.MouseButtonEventHandler] {
        param($s, $e)
        $node = $e.OriginalSource
        $ctx = $null
        for ($d = 0; $d -lt 8 -and $node; $d++) {
            if ($node -is [System.Windows.FrameworkElement]) {
                $dc = $node.DataContext
                if ($dc -and $dc.PSObject.Properties['ShId']) { $ctx = $dc; break }
            }
            try { $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node) } catch { break }
        }
        if (-not $ctx) { return }
        Open-SRShellRow $ctx
        $e.Handled = $true
    })
$ui.PaneCompact.Add_Click({ Invoke-Compact })

# ===========================================================================
# WATCHING THE TRANSCRIPT INSTEAD OF ASKING ABOUT IT.
#
# The follow tick polls the selected conversation once a second, so the pane was
# up to a second behind what the terminal had already printed - reported as
# wanting to see what is happening "almost immediately". A FileSystemWatcher
# fires when claude writes, which is both faster AND cheaper: nothing runs at
# all while a session is quiet, where polling stats a file every second forever.
#
# 🪤 THE HANDLER RUNS ON A THREADPOOL THREAD, NOT THE UI THREAD. Touching any
# control from it throws InvalidOperationException from deep inside WPF, so it
# does exactly one thing - marshal a flag onto the dispatcher. The one-second
# timer STAYS as the backstop: a watcher misses events under load, dies with its
# directory, and cannot see a file on a network path, and a pane that silently
# stopped updating would be far worse than one that updates a beat late.
$script:watcher = $null
$script:watchPath = ''

function Stop-TranscriptWatch {
    # 🔴 UNREGISTER THE SUBSCRIBER, NOT JUST THE WATCHER. Register-ObjectEvent
    # keeps the subscription under its SourceIdentifier until it is explicitly
    # removed - disposing the FileSystemWatcher does not take it with it. So the
    # SECOND conversation selected hit "The subscription identifier is already
    # in use", the registration failed inside the try, and the window fell back
    # to the one-second timer for the rest of its life. Silently: the catch logs
    # to a file nobody reads while a session is open.
    #
    # 🪤 -Force, because the subscriber is created by an -Action and PowerShell
    # marks those as its own; without it the removal is refused.
    try { Unregister-Event -SourceIdentifier 'SRTranscript' -Force -ErrorAction SilentlyContinue } catch { }
    if (-not $script:watcher) { return }
    try { $script:watcher.EnableRaisingEvents = $false } catch { }
    try { $script:watcher.Dispose() } catch { }
    $script:watcher = $null
    $script:watchPath = ''
}

function Start-TranscriptWatch { param([string]$Path)
    if (-not $Path -or $Path -eq $script:watchPath) { return }
    Stop-TranscriptWatch
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $w = New-Object System.IO.FileSystemWatcher
        $w.Path = (Split-Path -Parent $Path)
        $w.Filter = (Split-Path -Leaf $Path)
        $w.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::Size
        $w.IncludeSubdirectories = $false
        # 🔴 NO -Action, AND THAT IS THE WHOLE FIX. This was
        # `-Action { $script:transcriptDirty = $true }`, which never once fired
        # the pane: an -Action block runs in its OWN scope, so `$script:` inside
        # it is the action's module scope and not this script's. The flag was
        # being set somewhere nobody reads, the lane never woke, and the window
        # ran on the one-second backstop for the whole time it was described as
        # near-instant. Measured by a test that watches a file and waits for the
        # flag - it never came.
        #
        # Registering WITHOUT an action queues the events instead, and the lane
        # drains that queue. No cross-scope write exists to get wrong.
        $null = Register-ObjectEvent -InputObject $w -EventName Changed -SourceIdentifier 'SRTranscript'
        $w.EnableRaisingEvents = $true
        $script:watcher = $w
        $script:watchPath = $Path
    } catch {
        Write-SRLog ('  [skip] could not watch the transcript, falling back to the timer: ' + $_.Exception.Message)
        Stop-TranscriptWatch
    }
}

# Set by the watcher thread, read and cleared by the dispatcher. A bool
# assignment is atomic, and the worst a race costs here is one extra refresh.
$script:transcriptDirty = $false

# ===========================================================================
# EVERY LIVE CONVERSATION, NOT JUST THE ONE ON SCREEN.
#
# 🔴 A STATUS CHANGE WAITED UP TO SIX SECONDS. Update-LiveWriters already moves
# any session whose transcript grew out of NEEDS YOU and into WORKING - for ALL
# live sessions, not only the selected one - but it ran on the six-second pass.
# So a conversation starting work, or picking up after you answered it, changed
# colour some seconds later.
#
# Every transcript on the machine lives under one root, so ONE watcher with
# subdirectories covers all of them - cheaper than a watcher each and far
# cheaper than stat-ing twenty-four files on a timer. It raises an event, the
# lane drains it and runs the file-stat pass that already existed.
#
# 🪤 NO -Action, for the reason the transcript watcher records the hard way: an
# -Action block runs in its own scope and cannot write $script: state, which is
# how the first watcher in this window silently never fired at all.
$script:projWatcher = $null

# ===========================================================================
# A SESSION THAT WENT QUIET IS PROBABLY ASKING YOU SOMETHING.
#
# 🔴 WORKING -> NEEDS YOU WAS THE SLOWEST TRANSITION IN THE TOOL. It comes from
# the agent probe, and the agent probe spawns claude - 536 ms measured - so it
# runs every fifteen seconds and a conversation could sit in WORKING for that
# long after it had actually stopped and asked.
#
# The other direction is already instant: a transcript that GROWS is a session
# that is working, which the projects watcher now catches in 16 ms. This is the
# mirror of it. A transcript that has STOPPED growing is the only cheap signal
# that a session may have finished its turn, and a screen read - 66 ms since the
# reader was compiled, down from 560 - can then say whether a menu is up.
#
# 🪤 BOUNDED THREE WAYS, because this is the expensive direction. One session
# per pass, never one that was checked in the last ten seconds, and only after
# it has been quiet for three - a session mid-reply pauses constantly between
# tool calls, and reading the screen on every pause would spend the saving.
$script:quietSince = @{}
$script:quietChecked = @{}
$script:quietPs = $null
$script:quietRs = $null
$script:quietHandle = $null
$script:quietFor = ''
$script:quietAt = $null

# ===========================================================================
# WHAT EACH LIVE SESSION SAYS IT HAS RUNNING, KEPT PER SESSION.
#
# 🔴 THE SQUARE SHELL MARK HAD NEVER ONCE APPEARED ON A ROW, and it could not
# have: the row read its shell count off the transcript, where a background
# Bash is answered the instant it is launched, so the count was structurally
# zero (see Get-SRRowSignals). The strip already knew better - it reads the
# figure the session prints on its own status line - but only for the ONE
# conversation on the pane, and the operator was looking at the list.
#
# So the screen read that the quiet check already makes now answers both
# questions from the one screen it has in hand, and the answer is filed per
# session here. Rows draw from this; nothing else can tell them.
#
# 🪤 -1 MEANS "THE LINE DID NOT SAY", WHICH IS NOT ZERO, and the two figures
# want opposite defaults. A session with no shells prints no shell count, so
# silence there IS zero and a finished shell has to clear its mark. Sub-agents
# the line does not always name at all - and the transcript CAN see those - so
# silence there means "ask the transcript" instead.
$script:rowScreen = @{}
# Seconds a filed count is still worth drawing. Comfortably longer than the
# sweep's own cadence, so an entry only ages out when the sweeps have actually
# stopped landing - a count that old describes a session that has since done
# anything at all.
$SR_RowScreenTTL = 45

function Set-RowScreenSig {
    param([string]$Id, [int]$Shells, [int]$Agents, [string]$Effort = '', [int]$TurnSecs = -1, [bool]$TurnDone = $false,
          [int]$CtxTokens = -1, [int]$CtxWindow = -1)
    if (-not $Id) { return $false }
    $was = $script:rowScreen[$Id]
    # Only the two MARKS decide whether the list needs redrawing; the clock and
    # the effort live on the strip, which repaints on its own tick. A redraw of
    # every row once a second because a timer moved would be the opposite of
    # what the sweep is for.
    $changed = (-not $was) -or ([int]$was.Shells -ne $Shells) -or ([int]$was.Agents -ne $Agents)
    # 🪤 The context figures move constantly, so they are deliberately NOT part
    # of what decides a redraw - the bar is repainted by the strip's own tick and
    # by the row build that any other change triggers. Redrawing every row
    # because a token count ticked would undo the whole point of the sweep.
    $script:rowScreen[$Id] = @{
        At = (Get-Date); Shells = $Shells; Agents = $Agents
        Effort = "$Effort"; TurnSecs = $TurnSecs; TurnDone = $TurnDone
        CtxTokens = $CtxTokens; CtxWindow = $CtxWindow
    }
    return $changed
}

# 🔑 $Now IS OPTIONAL, FOR THE SAME REASON AS Get-AgeTicks. This TTL check called
# Get-Date once per row - 52 per rebuild, 14,5 ms, 7,5% of the build - to decide
# whether a reading taken seconds ago is still fresh. A row cannot age
# meaningfully inside one pass, so the caller in the loop takes it once.
function Get-RowScreenSig { param([string]$Id, [datetime]$Now = [datetime]::MinValue)
    if (-not $Id) { return $null }
    $v = $script:rowScreen[$Id]
    if (-not $v) { return $null }
    # A count read four minutes ago describes a session that has since done
    # anything at all. Past its life it is not evidence and must not draw.
    if ($Now -eq [datetime]::MinValue) { $Now = Get-Date }
    if (($Now - $v.At).TotalSeconds -gt $SR_RowScreenTTL) { return $null }
    return $v
}

# THE SUB-AGENT LIST FOR ONE ROW, CACHED, because Build-Sessions runs on every
# refresh and this touches the disk.
#
# 🪤 THE CHEAP TEST COMES FIRST AND IS THE WHOLE OPTIMISATION. Only 24 of the
# 374 conversations on this machine have a subagents directory at all, so a
# Test-Path that fails is the answer for almost every row and costs nothing.
# Enumerating and parsing the meta files - 2 to 31 tiny JSON reads - happens
# only for the few that do, and then not again for 20 seconds.
#
# The cache is keyed on the conversation id and holds the empty answer too: a
# row with no agents must not re-probe the filesystem on every single repaint,
# and that is the common case.
$script:subAgents = @{}
$SR_SubAgentTTL = 20

# 🔴 THIS USED TO OPEN A TRANSCRIPT FROM INSIDE Build-Sessions, ONCE PER ROW.
#
# It was cached on a 20-second TTL, which sounds harmless and is not: the rows
# are read together, so they EXPIRE together, and the next rebuild after that
# pays the whole disk sweep at once. Audited: one rebuild in eight cost 784.7 ms
# - and which one is a matter of when you happened to click. An unpredictable
# stall is worse than a constant one; there is nothing the operator can learn
# about it.
#
# 🔑 THE PROBE ALREADY OPENS THESE FILES, off the UI thread, for the said-lines
# and the queue. Reading the sub-agents in the same pass costs it one more read
# of a file it has already opened, and costs a click nothing at all. This is now
# a pure cache read: whatever the last probe filed, or nothing.
#
# 🪤 IT NO LONGER REFRESHES ITSELF, so a conversation the probe has not reached
# yet shows no agent marks rather than blocking to find out. That is the right
# trade in this direction only - a mark that appears a probe late is a cosmetic
# delay; a rebuild that stops for three-quarters of a second is the thing the
# operator has been reporting for weeks.
function Get-RowSubAgents { param($R)
    $id = "$($R.Id)"
    if (-not $id) { return @() }
    $v = $script:subAgents[$id]
    if ($v) { return $v.List }
    return @()
}

# ===========================================================================
# WHAT EVERY LIVE SESSION HAS RUNNING, IN ONE PASS.
#
# 🔴 THE MARKS WERE NOT SLOW, THEY WERE STARVED. Filing them was a second duty
# bolted onto the quiet check, which picks ONE session per pass and gives the
# "is it asking?" question first refusal. On a machine with a dozen working
# sessions that question always had a candidate, so the refresh never ran; when
# it did run it was one session per second behind a ten-second cooldown, so a
# shell that started now could take a quarter of a minute to show up. The
# operator reported it as the marks not appearing at all, which is what
# "eventually" looks like from the outside.
#
# 🔑 THE SPAWN WAS THE COST, NOT THE READING. 129 ms median per console, of
# which about 30 is console work and the rest is starting a process. One child
# reading all thirteen: 287 ms, measured against 2,332 one at a time - 8.1x. So
# the whole board refreshes in one pass rather than being rationed.
$script:sweepPs = $null
$script:sweepRs = $null
$script:sweepHandle = $null
$script:sweepFor = @()
$script:sweepAt = $null
$SR_SweepEvery = 2500      # ms between sweeps, once one has finished

$script:SweepJob = {
    . (Join-Path $SRHere '_common.ps1')
    $out = @{}
    try {
        $screens = Get-SRScreenTextMany -ProcessIds ([int[]]$SRSweep.Pids)
        foreach ($k in $screens.Keys) {
            $v = Read-SRScreenVitals -ScreenText $screens[$k]
            # 🔑 THE SAME SCREEN ANSWERS "IS IT ASKING?" TOO, and having it for
            # every session on every pass is what lets the flag be cleared by
            # evidence rather than left to expire. Before this, only a session
            # the quiet check happened to pick got looked at - one per pass,
            # once per ten seconds - and a row already in NEEDS YOU was skipped
            # by its picker entirely, so nothing could ever say "not any more".
            # 🔴 THE SAME QUESTION THE CARD ASKS, THROUGH THE SAME FUNCTION.
            # This used to be `@($q.Options).Count -ge 2` - no cursor, no
            # structure, nothing - while the card required more. So the row and
            # the card disagreed about one screen, and the operator got a row
            # sitting in NEEDS YOU whose card said "nothing that looks like a
            # question is on its screen". Two code paths answering one question
            # differently is the whole shape of what was reported.
            #
            # 🔑 AND IT DROPS THE PARSE. The full parse ran on every screen on
            # every pass purely to reach Options.Count; nothing else here used
            # $q. Test-SRLiveMenu answers the only question being asked.
            #
            # 🪤 THE SAVING IS THE DIFFERENCE, NOT THE PARSE. The first version
            # of this note quoted 144 ms - the cost of the parse being removed -
            # which reads as the saving and is not. The predicate is not free.
            # Measured over 30 live screens, three alternating passes each:
            # full parse 245 ms median, Test-SRLiveMenu 136 ms median, so the
            # sweep drops ~109 ms a pass. The two agreed on all 30, which is
            # what makes the saving a saving rather than a different answer.
            $asking = $false
            try { $asking = [bool](Test-SRLiveMenu -Text $screens[$k]) } catch { }
            # Same two defaults the single reader uses, and for the same reason:
            # a line that printed no shell count IS zero, and one that named no
            # sub-agents means "ask the transcript" rather than "there are none".
            $out[[int]$k] = @{
                Shells = [int]$v.Shells
                Agents = $(if ($v.SawAgents) { [int]$v.Agents } else { -1 })
                Asking = $asking
                # What the session says about its own turn and how hard it is
                # thinking. Both are '' / -1 when the screen did not say, which
                # is not the same as zero.
                Effort   = $(if ($v.SawEffort) { "$($v.Effort)" } else { '' })
                TurnSecs = $(if ($v.SawTurn) { [int]$v.TurnSecs } else { -1 })
                TurnDone = [bool]$v.TurnDone
                CtxTokens = $(if ($v.SawCtx) { [int]$v.CtxTokens } else { -1 })
                CtxWindow = $(if ($v.SawCtx) { [int]$v.CtxWindow } else { -1 })
            }
        }
    } catch { }
    $out
}

function Start-VitalsSweep {
    if ($script:sweepPs) { return }
    if ($script:sweepAt -and ((Get-Date) - $script:sweepAt).TotalMilliseconds -lt $SR_SweepEvery) { return }
    $pids = New-Object System.Collections.Generic.List[object]
    $ids  = New-Object System.Collections.Generic.List[object]
    foreach ($r in $script:model) {
        if (-not $r.Live -or -not $r.A -or -not $r.A.Pid) { continue }
        if ($r.A.Kind -and "$($r.A.Kind)" -ne 'interactive') { continue }
        $null = $pids.Add([int]$r.A.Pid)
        $null = $ids.Add([PSCustomObject]@{ Id = "$($r.Id)"; Pid = [int]$r.A.Pid })
    }
    if (-not $pids.Count) { $script:sweepAt = Get-Date; return }
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('SRHere', $here)
        $rs.SessionStateProxy.SetVariable('SRSweep', @{ Pids = $pids.ToArray() })
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($script:SweepJob)
        $script:sweepRs = $rs
        $script:sweepPs = $ps
        $script:sweepHandle = $ps.BeginInvoke()
        $script:sweepFor = $ids.ToArray()
        $script:sweepAt = Get-Date
    } catch { $script:sweepPs = $null }
}

function Complete-VitalsSweep {
    if (-not $script:sweepPs -or -not $script:sweepHandle) { return $false }
    if (-not $script:sweepHandle.IsCompleted) {
        # Bounded like every other child in this window: one that never answers
        # must not wedge the lane that collects it.
        if ($script:sweepAt -and ((Get-Date) - $script:sweepAt).TotalSeconds -gt 30) {
            try { $script:sweepPs.Stop(); $script:sweepPs.Dispose() } catch { }
            try { $script:sweepRs.Close(); $script:sweepRs.Dispose() } catch { }
            $script:sweepPs = $null; $script:sweepRs = $null; $script:sweepHandle = $null
            Write-SRLog '  [warn] the vitals sweep did not answer in 30s - abandoned'
        }
        return $false
    }
    $res = $null
    try { $res = @($script:sweepPs.EndInvoke($script:sweepHandle))[0] } catch { }
    try { $script:sweepPs.Dispose(); $script:sweepRs.Close(); $script:sweepRs.Dispose() } catch { }
    $script:sweepPs = $null; $script:sweepRs = $null; $script:sweepHandle = $null
    # When this pass's screens were taken, kept before the clock is reset: a
    # session that wrote after that moment has outrun the read.
    $started = $script:sweepAt
    $script:sweepAt = Get-Date
    if (-not $res) { return $false }
    $changed = $false
    # 🔑 ONE INDEX, NOT A PIPELINE SCAN PER SWEPT ROW.
    #
    # Finding the model row for a swept session used to be
    # `@($script:model | Where-Object { $_.Id -eq $row.Id })` - INSIDE this
    # loop. Every swept session therefore drove a full pass over all 327 rows
    # plus a Where-Object invocation, so the work was rows x sessions and the
    # cost landed on the 30 ms lane, which is the one thing between a keystroke
    # and the screen.
    #
    # Measured over 30 s of a window nobody was touching: Complete-VitalsSweep
    # 747 calls, 2.204 ms total, 3,0 ms each - 44% of Invoke-WriteLane's whole
    # 4.973 ms, which is itself a 16,6% duty cycle on the UI thread. The idle
    # keystroke MEDIAN is fine at 2,0 ms; it is the 90th at 22,0 ms and the 44
    # pumps over 50 ms that this feeds, and a keystroke landing inside one of
    # those waits for it.
    #
    # 🪤 THE WORK ORDER NAMED THE WRONG CAUSE. It asked for the guard
    # Complete-DocParse has - handle, then IsCompleted, both returning early.
    # This function has had exactly that as its first two lines all along. The
    # number in the work order was right and the diagnosis was not, which is
    # why this comment carries the measurement rather than the claim.
    #
    # 🪤 A HASHTABLE KEEPS THE LAST ROW FOR AN ID WHERE THE PIPELINE KEPT THE
    # FIRST. Conversation ids are unique in the model, so the two agree; it is
    # written down because it is the one way they could ever differ.
    $byId = @{}
    foreach ($mr in $script:model) { $byId["$($mr.Id)"] = $mr }
    foreach ($row in @($script:sweepFor)) {
        $got = $res[[int]$row.Pid]
        # 🪤 A CONSOLE THAT COULD NOT BE READ FILES NOTHING. Absent is not zero,
        # and writing a zero here would clear a mark on no evidence - the entry
        # ages out on its own if the reads keep failing.
        if (-not $got) { continue }
        if (Set-RowScreenSig -Id "$($row.Id)" -Shells ([int]$got.Shells) -Agents ([int]$got.Agents) `
                             -Effort "$($got.Effort)" -TurnSecs ([int]$got.TurnSecs) -TurnDone ([bool]$got.TurnDone) `
                             -CtxTokens ([int]$got.CtxTokens) -CtxWindow ([int]$got.CtxWindow)) {
            $changed = $true
        }

        # ---- and whether it is asking ------------------------------------
        # 🪤 A READ THAT STARTED BEFORE THE SESSION LAST WROTE IS STALE, and
        # applying it is how the flap would come straight back in a new form:
        # the transcript grows, the writers pass clears the flag, and then a
        # sweep that began earlier puts it back from a screen that no longer
        # exists. The write time decides.
        $mv = $script:quietSince["$($row.Id)"]
        if ($mv -and $started -and $mv -gt $started) { continue }
        $live = $byId["$($row.Id)"]
        if (-not $live) { continue }
        if ([bool]$got.Asking) {
            # 🔴 THROUGH THE SAME ONE-WAY RULE the quiet check uses. Only a
            # WORKING row may be moved into needing you, whatever the screen
            # shows for a row that is done, idle or quiet.
            if (Test-QuietVerdict -Row $live -Asking $true) { $changed = $true }
        } elseif (Set-AskSeen -Id "$($row.Id)" -Asking $false) {
            # Measured absence, which is the half that never used to happen:
            # the row can now leave NEEDS YOU because the menu is gone, not
            # merely because something else recomputed the band.
            if ("$($live.Band)" -eq 'needs') { $live.Band = Get-Band $live }
            $changed = $true
        }
    }
    return $changed
}

function Stop-VitalsSweep {
    if (-not $script:sweepPs) { return }
    try { $script:sweepPs.Stop(); $script:sweepPs.Dispose() } catch { }
    try { $script:sweepRs.Close(); $script:sweepRs.Dispose() } catch { }
    $script:sweepPs = $null; $script:sweepRs = $null; $script:sweepHandle = $null
}

# ===========================================================================
# 🔴 THERE IS NO LIVE TAIL, AND THAT IS A DECISION, NOT AN OMISSION.
#
# The reading pane trails the terminal by seconds because its SOURCE does:
# claude writes a transcript record when a BLOCK COMPLETES, and a busy session
# measured three writes in thirty seconds, a median of 14.6 s apart. The parse
# is 150-215 ms even on a 132 MB file and the watcher fires in 130, so the
# tool's own contribution is under half a second. No amount of speed touches it.
#
# A live strip reading the session's SCREEN was built to close that gap, first
# beside the document and then inside it. Both were removed, for two reasons the
# operator reported and neither of which is fixable while it exists:
#
#   1. IT SHOWS THE SAME CONVERSATION TWICE. Once the record catches up, the
#      screen tail and the parsed cards are the same turn side by side.
#   2. IT IGNORES THE Steps SETTING. It is raw screen text, so a shell's output
#      appeared in full on a pane explicitly folded to hide it.
#
# Freshness bought at the cost of showing everything twice and overriding a
# control the operator set is not a good trade. The pane reads the record, the
# record is what it is, and the strip's turn clock - which IS read off the
# screen - is what says a session is working right now.
# ===========================================================================

$script:QuietJob = {
    . (Join-Path $SRHere '_common.ps1')
    # One read per pass, and the held-open reader still beats spawning for it -
    # measured at 134 ms against 244. See the note on AnswerJob.
    $null = Start-SRScreenServer
    $out = @{ Asking = $false; Read = $false; Shells = 0; Agents = -1 }
    try {
        $txt = Get-SRScreenText -ProcessId $SRQuiet.Pid
        if ($txt) {
            $out.Read = $true
            # 🔴 THE SAME QUESTION THE CARD ASKS, THROUGH THE SAME FUNCTION. This
            # used to be `@($q.Options).Count -ge 2` while the card required more,
            # so the row could sit in NEEDS YOU and the card say "nothing that
            # looks like a question is on its screen" about one screen. Two code
            # paths answering one question differently is the whole shape of the
            # bug the operator reported.
            if (Test-SRLiveMenu -Text $txt) { $out.Asking = $true }
            # The same screen answers the other thing a row wants to know, so
            # it costs nothing beyond the read that was already being made.
            $sv = Read-SRScreenVitals -ScreenText $txt
            if ($sv.SawShells) { $out.Shells = [int]$sv.Shells }
            if ($sv.SawAgents) { $out.Agents = [int]$sv.Agents }
        }
    } catch { }
    try { Stop-SRScreenServer } catch { }
    $out
}

function Start-QuietCheck {
    if ($script:quietPs) { return }
    $now = Get-Date
    $pick = $null
    foreach ($r in $script:model) {
        if (-not $r.Live -or "$($r.Band)" -ne 'working') { continue }
        if (-not $r.A -or -not $r.A.Pid) { continue }
        $key = "$($r.Id)"
        $since = $script:quietSince[$key]
        if (-not $since -or ($now - $since).TotalSeconds -lt 3) { continue }
        $last = $script:quietChecked[$key]
        if ($last -and ($now - $last).TotalSeconds -lt 10) { continue }
        $pick = $r
        break
    }
    # 🪤 THIS USED TO TAKE A SECOND PASS OVER EVERY LIVE SESSION to refresh what
    # each had running, and it was the wrong place for it twice over: the ask
    # check has first refusal, so on a busy machine the refresh never ran at all,
    # and even when it did, one session per second meant a shell mark could be
    # thirteen seconds late. Start-VitalsSweep reads every console in ONE child
    # process instead - 287 ms for thirteen, measured - and this went back to
    # doing the one thing it is good at.
    if (-not $pick) { return }
    $script:quietChecked["$($pick.Id)"] = $now
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('SRHere', $here)
        $rs.SessionStateProxy.SetVariable('SRQuiet', @{ Pid = [int]$pick.A.Pid })
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($script:QuietJob)
        $script:quietRs = $rs
        $script:quietPs = $ps
        $script:quietHandle = $ps.BeginInvoke()
        $script:quietFor = "$($pick.Id)"
    } catch { $script:quietPs = $null }
}

function Complete-QuietCheck {
    if (-not $script:quietPs -or -not $script:quietHandle) { return $false }
    if (-not $script:quietHandle.IsCompleted) { return $false }
    $res = $null
    try { $res = @($script:quietPs.EndInvoke($script:quietHandle))[0] } catch { }
    try { $script:quietPs.Dispose(); $script:quietRs.Close(); $script:quietRs.Dispose() } catch { }
    $script:quietPs = $null; $script:quietRs = $null; $script:quietHandle = $null
    if (-not $res) { return $false }
    # What it has running is filed whatever the answer about the menu was - a
    # read that found no question still read the status line successfully.
    $redraw = $false
    if ($res.Read) {
        if (Set-RowScreenSig -Id "$($script:quietFor)" -Shells ([int]$res.Shells) -Agents ([int]$res.Agents)) {
            $redraw = $true
        }
    }
    $row = @($script:model | Where-Object { "$($_.Id)" -eq $script:quietFor })
    if (-not $row.Count) { return $redraw }
    if (Test-QuietVerdict -Row $row[0] -Asking ([bool]$res.Asking)) { return $true }
    return $redraw
}

# 🔴 ONLY EVER INTO 'needs', AND ONLY ON A MENU ACTUALLY SEEN. Claiming a
# conversation wants you is a claim that has to be measured - the same rule the
# follow tick states for the opposite direction, where growth may only move a
# row OUT of needing you.
#
# 🪤 ITS OWN FUNCTION SO THE RULE CAN BE PUT UNDER TEST. Inside the collector it
# could only be reached by a completed screen read, so the suite drove it with
# no job in flight - and Complete-QuietCheck returns at its first line when
# there is none. Three assertions that a done/idle/quiet row is left alone were
# passing because nothing ran at all, which is a green that cannot go red.
# ===========================================================================
# 🔴 THIS RULE USED TO SAY 'working' AND IT NO LONGER DOES. REVERSING A
# CONSIDERED DECISION, SO HERE IS WHY.
#
# The rule was: only a WORKING row may be moved into needing you, whatever the
# screen shows for one that is done, idle or quiet. That was right when it was
# written, and it was compensating for a specific weakness - the parser could
# not tell an ordinary numbered list from a live menu, so a screen "showing a
# menu" was not trustworthy evidence, and the band was used as a second opinion
# to contain the damage.
#
# The structural test removed that weakness: a run is a menu only when the
# session's prompt status line is not drawn below it, which scored 13 of 13 on
# the fixtures against the old cursor gate's 10, and agreed exactly with
# `claude agents --json` across 30 live consoles. The second opinion is now
# costing more than it saves.
#
# 🔴 WHAT IT COSTS. The sweep reads every live screen every ~2.9 s and could see
# the menu - but a row the 15 s probe last called idle or done was FORBIDDEN to
# move, so noticing fell through to the only other route: the probe reporting
# 'waiting'. That probe measures 11.3 s on a 15 s timer, so the operator's own
# complaint - "not instantly seeing when a session has questions" - was a
# worst case near 26 s on exactly the rows most likely to be asking, because a
# session that has just gone quiet is the one about to want you.
#
# 🔒 WHAT STAYS. A row that is not LIVE is still refused, and that is not a
# softer version of the old rule but a different fact: a conversation with no
# process has no screen, so there is nothing that could have seen a menu on it.
# The sweep never even offers one - it skips rows without a pid - so this guard
# is about the direct callers and the suite.
function Test-QuietVerdict { param($Row, [bool]$Asking)
    if (-not $Row -or -not $Asking) { return $false }
    if (-not $Row.Live) { return $false }
    # Already there: nothing changed, so say so rather than asking for a redraw.
    if ("$($Row.Band)" -eq 'needs') { return $false }
    # 🔴 THE FLAG FIRST, THEN THE BAND. Setting only the band is what made the
    # row flap: the band is derived, so the next recompute wiped it and the
    # screen had to win the same argument again a few seconds later. The flag is
    # what Get-Band reads, so a recompute now agrees instead of overruling.
    $null = Set-AskSeen -Id "$($Row.Id)" -Asking $true
    $Row.Band = 'needs'
    return $true
}

function Stop-ProjectsWatch {
    try { Unregister-Event -SourceIdentifier 'SRProjects' -Force -ErrorAction SilentlyContinue } catch { }
    if (-not $script:projWatcher) { return }
    try { $script:projWatcher.EnableRaisingEvents = $false } catch { }
    try { $script:projWatcher.Dispose() } catch { }
    $script:projWatcher = $null
}

function Start-ProjectsWatch {
    if ($script:projWatcher) { return }
    $root = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path -LiteralPath $root)) { return }
    try {
        $w = New-Object System.IO.FileSystemWatcher
        $w.Path = $root
        $w.Filter = '*.jsonl'
        $w.IncludeSubdirectories = $true
        $w.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::Size
        # 🪤 A BIGGER BUFFER THAN THE DEFAULT. Two dozen conversations writing at
        # once overflows the default 8 KB queue, and an overflowed watcher drops
        # events SILENTLY - which would look exactly like a session whose status
        # stopped updating, the very complaint this is here to fix.
        $w.InternalBufferSize = 65536
        $null = Register-ObjectEvent -InputObject $w -EventName Changed -SourceIdentifier 'SRProjects'
        $w.EnableRaisingEvents = $true
        $script:projWatcher = $w
        Write-SRLog '  watching every live transcript for status changes'
    } catch {
        Write-SRLog ('  [skip] could not watch the projects root; status falls back to the 6s pass: ' + $_.Exception.Message)
        Stop-ProjectsWatch
    }
}

# 🔴 THE FAST LANE. It runs ten times a second, does NOTHING at all unless the
# watcher raised the flag, and then does only what a write can have changed -
# the document and the send state. The vitals, the bands and the question all
# stay on the one-second tick, because none of them is what you are watching
# when you watch a session type.
$script:writeTimer = New-Object System.Windows.Threading.DispatcherTimer
# 30 ms, not 100. The lane does nothing at all unless the watcher raised a
# flag or a parse landed, so the interval is almost pure polling cost - but it
# is also the LATENCY between work finishing and the pane showing it, and it
# was contributing up to 100 ms of the select-to-readable round trip.
$script:writeTimer.Interval = [TimeSpan]::FromMilliseconds(30)
# A named function rather than an anonymous handler, so the suite can drive one
# pass directly - the same reason Invoke-FollowTick is named. The defect this
# lane introduced (filling in the follow stamp before the tick's first look, so
# clicking a waiting conversation moved it) was invisible to any test that could
# not call it.
function Invoke-WriteLane {
    # Collected here rather than on the one-second tick: this lane runs ten
    # times a second, so a question that took a second to read is on screen
    # within a tenth of a second of arriving.
    if ($script:sheetDepth -eq 0) {
        # The click asked for a read; this is where it actually starts, so the
        # runspace is opened off the click path.
        # A selection asks once; this asks again while the answer is still
        # missing, so a conversation that had not yet printed its context bar
        # does not wait for the slow rotation. Costs one comparison when the bar
        # is already there, which is the common case.
        if (-not $script:askWanted) { try { Request-ContextRetry } catch { } }
        if ($script:askWanted) {
            $script:askWanted = $false
            try { Start-AskProbe (Get-SelectedRow) } catch { }
        }
        try { Complete-AskProbe } catch { }
        # A transcript parse that has landed becomes the document here, on the
        # lane, so the gesture that asked for it never waited.
        try { $null = Complete-DocParse } catch { }
        # An answer that has landed reports here, on the lane, so the click that
        # sent it never waited for a console read.
        try { $null = Complete-AnswerSend } catch { }
    }
    # Drain whatever the watcher queued. Several writes between two ticks are
    # one redraw, which is the point of collecting rather than handling.
    try {
        foreach ($ev in @(Get-Event -SourceIdentifier 'SRTranscript' -ErrorAction SilentlyContinue)) {
            Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue
            $script:transcriptDirty = $true
        }
    } catch { }

    # ANY live conversation writing, not just the one on screen. Coalesced the
    # same way: two dozen sessions writing between two ticks is one pass over
    # the file stamps and at most one redraw of the list.
    try {
        $projHit = $false
        foreach ($pv in @(Get-Event -SourceIdentifier 'SRProjects' -ErrorAction SilentlyContinue)) {
            Remove-Event -EventIdentifier $pv.EventIdentifier -ErrorAction SilentlyContinue
            $projHit = $true
        }
        if ($projHit -and $script:sheetDepth -eq 0) {
            if (Update-LiveWriters) { Build-Sessions }
        }
    } catch { }

    # The other direction: a session that has STOPPED writing may be asking.
    # Collected first, then at most one new check a second.
    if ($script:sheetDepth -eq 0) {
        try { if (Complete-QuietCheck) { Build-Sessions } } catch { }
        if (-not $script:quietAt -or ((Get-Date) - $script:quietAt).TotalMilliseconds -ge 1000) {
            $script:quietAt = Get-Date
            try { Start-QuietCheck } catch { }
        }
        # 🔑 AND WHAT EVERY LIVE SESSION HAS RUNNING, in one child process rather
        # than one session per second. The first sweep goes out as soon as the
        # model exists, so the marks are up within a few hundred milliseconds of
        # the window opening instead of trickling in over a quarter of a minute.
        try { if (Complete-VitalsSweep) { Build-Sessions } } catch { }
        try { Start-VitalsSweep } catch { }
    }
    # Returns whether it actually redrew. The tick discards it; the suite needs
    # it, because the flag is consumed in the same call that sets it and there
    # is otherwise nothing to observe from outside.
    if (-not $script:transcriptDirty) { return $false }
    $script:transcriptDirty = $false
    if ($script:sheetDepth -gt 0) { return $false }
    try {
        $it = $ui.SessionList.SelectedItem
        if (-not $it -or $it.Kind -ne 'session') { return $false }
        Update-Document
        Update-SendState
        # Keep the polling tick from redoing this work a beat later: it compares
        # this stamp to decide whether anything moved.
        # 🔴 NEVER WHILE IT IS $null - THAT IS "THE TICK HAS NOT LOOKED YET".
        #
        # The follow tick reads a null stamp as "this is the first observation of
        # a conversation you just selected" and refuses to call the difference
        # growth; it is the guard that stops clicking a waiting session from
        # moving it straight into WORKING. Writing a stamp here filled that null
        # in before the tick ever ran, so the very next tick saw a changed stamp
        # with firstLook false and moved the row - which is exactly what
        # happened to V-INGEST: clicked in NEEDS YOU, gone to WORKING.
        #
        # This may only ever REFRESH a stamp the tick has already taken.
        if ($null -ne $script:followStamp) {
            $j = "$($it.Row.S.jsonl)"
            if ($j -and (Test-Path -LiteralPath $j)) {
                $fi = Get-Item -LiteralPath $j
                $script:followStamp = ('{0}|{1}' -f $fi.Length, $fi.LastWriteTimeUtc.Ticks)
            }
        }
    } catch { }
    return $true
}
$script:writeTimer.Add_Tick({ Invoke-WriteLane })
$script:writeTimer.Start()
# One watcher over every transcript on the machine, so a status change does not
# wait for the six-second pass. Started here rather than on first selection:
# the list is showing statuses before anything is clicked.
try { Start-ProjectsWatch } catch { }

# A NEW CONVERSATION IN ANOTHER WORKTREE - never this one moved. A claude
# conversation is bound to the directory it was started in and its transcript is
# filed under that directory, so "switch this session to another worktree" is
# not an operation that exists: what exists is starting a fresh one there. The
# dialog opens on this project with the worktree box already ticked, so the
# common case is two clicks, and every other launch setting stays available.
$ui.PaneWorktree.Add_Click({
    $r = Get-SelectedRow
    $d = ''
    if ($r -and $r.D) { $d = "$($r.D.path)" }
    Show-Spawn -PresetDir $d -PresetWorktree
})
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
    Update-Model -KeepAgents; Update-Surface; Start-LiveProbe

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

function Show-Spawn { param([string]$PresetDir, [switch]$PresetWorktree)
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
    # A worktree started from the pane can be for a project that is not in the
    # recent list at all. Adding it rather than letting Set-DropValue miss and
    # leave the default selected, which would start the session somewhere else
    # entirely without saying so.
    if ($PresetDir -and -not $seen.ContainsKey($PresetDir)) {
        $pi = New-Object System.Windows.Controls.ComboBoxItem
        $pi.Content = (Get-ProjectLabel $PresetDir); $pi.Tag = $PresetDir
        $dirs.Insert(0, $pi)
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
    if ($PresetDir) { Set-DropValue $s.SpDir $PresetDir }
    if ($PresetWorktree) { $s.SpWorktree.IsChecked = $true }

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
    # 🔴 THE SETTINGS OUTLIVE THIS RUN NOW. They were applied to the launched
    # process and then forgotten, because a brand new conversation has no session
    # id to write them against - so the same conversation came back at the next
    # logon as default model, default permissions, remote on. The claim below is
    # redeemed by the scan the moment the conversation first appears.
    try {
        Add-SRPrefClaim -Dir "$($G.Dir)" -Title "$($G.Name)" -Prefs @{
            model          = "$($G.Model)"
            effort         = "$($G.Effort)"
            permissionMode = "$($G.Perm)"
            remoteControl  = [bool]$G.Remote
            hidden         = [bool]$G.Hidden
        }
    } catch { Write-SRLog ('  [skip] could not record the new session settings: ' + $_.Exception.Message) }

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
# Four carets, two actions: each column's own header collapses it, and the strip
# it collapses to opens it again. A TextBlock has no Click, so these are
# MouseLeftButtonUp - the same gesture ListSort beside them already uses.
$ui.RailFold.Add_MouseLeftButtonUp({ Invoke-ColumnFold -Which 'rail' })
$ui.ListFold.Add_MouseLeftButtonUp({ Invoke-ColumnFold -Which 'list' })
$ui.RailOpen.Add_MouseLeftButtonUp({ Invoke-ColumnFold -Which 'rail' })
$ui.ListOpen.Add_MouseLeftButtonUp({ Invoke-ColumnFold -Which 'list' })
# A dot on the strip goes straight to that conversation - and opens the list
# again, because you pressed it in order to do something with the session and
# the next thing you want is to see it in context.
$ui.StripList.Add_PreviewMouseLeftButtonUp({
    param($sender, $e)
    $el = $e.OriginalSource
    $id = ''
    while ($el) {
        if ($el -is [System.Windows.FrameworkElement] -and $el.DataContext -and
            $el.DataContext.PSObject.Properties['Id']) { $id = "$($el.DataContext.Id)"; break }
        $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el)
    }
    if (-not $id) { return }
    # 🪤 SELECT IT, DO NOT RE-OPEN THE LIST. Un-collapsing here would undo the
    # thing you just asked for the moment you used it - and the list does not
    # need to be visible to work: Build-Sessions still binds it and restores the
    # selection from $script:selId, which fires the usual handler and puts the
    # conversation in the pane.
    $null = Select-SRSessionById $id
    Update-Strip
})

# Pulled out of the strip handler so it can be asserted: "did this rebuild the
# list?" is the whole question here and there is no way to ask it of a routed
# event raised on a never-rendered window. Returns $true when it selected
# without rebuilding.
function Select-SRSessionById { param([string]$Id)
    if (-not $Id) { return $false }
    $script:selId = $Id
    # 🔴 SELECT THE ROW, DO NOT REBUILD THE LIST TO GET AT IT. This called
    # Build-Sessions purely so that the rebind would restore the selection from
    # $script:selId - a correct route to the right outcome, and audited at
    # 164 ms for the gesture with 114 of it inside that one call. Every row in
    # the list is reconstructed to change which of them is highlighted.
    #
    # The items are already bound whether or not the list is visible, so the row
    # can simply be found and selected; SelectionChanged then does exactly what
    # it did after the rebuild.
    #
    # 🪤 THE FALLBACK IS NOT DECORATION. A filter or a search can leave the
    # target out of the bound list entirely, and then there is nothing to
    # select - so it falls back to the rebuild, which is what used to happen
    # every time. (A rebuild applies the same filter, so it may not find it
    # either; that is pre-existing behaviour and is left exactly as it was.)
    $hit = $null
    foreach ($sit in $ui.SessionList.Items) {
        if ($sit.Kind -eq 'session' -and "$($sit.Row.Id)" -eq $Id) { $hit = $sit; break }
    }
    if ($hit) {
        if (-not [object]::ReferenceEquals($ui.SessionList.SelectedItem, $hit)) {
            $ui.SessionList.SelectedItem = $hit
        }
        return $true
    }
    Build-Sessions
    return $false
}
# 🔴 ONE LINE, NOT TWO MESSAGES. `/compact` takes instructions, and giving them
# to it is what makes the compaction aligned rather than a race: a bare
# /compact summarises whatever happens to be in context, which is exactly the
# state the morning is trying not to lose. Sending a brief FIRST and compacting
# second would spend a turn per session and still leave the summariser guessing.
#
# 🪤 The wording lives in the config, because it is the whole feature. Changing
# what a session is told to preserve must not mean editing PowerShell.
$SR_CompactBrief = '/compact Preserve, in this order: what this lane is working on and where it has got to; every finding or measurement with the evidence behind it; what is still OPEN and owed; the exact next item you will take; and any rulings or decisions that have been made and who they bind. Keep file paths, commit shas, command lines and numbers verbatim - do not paraphrase them. Drop tool output that has already been acted on.'
function Get-SRCompactBrief {
    $t = ''
    try { $t = "$((Get-SRConfig).compactBrief)".Trim() } catch { $t = '' }
    if (-not $t) { $t = $SR_CompactBrief }
    return $t
}
$ui.CastCompact.Add_Click({
    $ui.CastText.Text = (Get-SRCompactBrief)
    $ui.CastText.CaretIndex = $ui.CastText.Text.Length
    $null = $ui.CastText.Focus()
    $n = @($script:castPick.Keys).Count
    Set-Status ("read it, then press Send - it will go to {0} ticked conversation(s)" -f $n)
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
    # Same gate: this one TYPES INTO LIVE TERMINALS one at a time, and doing
    # that while a confirmation is open is the last thing anyone wants.
    if ($script:sheetDepth -gt 0) { return }
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
            # 🪤 ONE SPAWN PER ROW is what this used to cost: the send asked
            # `claude agents --json` for each conversation it drained, so a cast
            # to ten was ten spawns on top of the keys. The row already holds
            # every field it wanted.
            # 🔴 NO -Force HERE, AND THAT IS THE POINT. The composer offers
            # "send anyway" because the operator is standing in front of it and can
            # see which session they mean. This is acting on every ticked conversation at once, where forcing a
            # sentence into a menu is exactly the accident the refusal exists to
            # stop. It reports what was skipped instead - and the refusal text no
            # longer names an action, so what it reports is now true here.
            $why = Send-SRSessionInput -SessionId $r.Id -Text $script:castMsg `
                                       -ProcessId ([int]$r.A.Pid) -Kind "$($r.A.Kind)" `
                                       -WaitingFor "$($r.A.WaitingFor)"
            if ($why) { $script:castBad.Add(('{0} ({1})' -f $t, $why)); Write-SRLog ('  [FAIL] cast to {0}: {1}' -f $t, $why) }
            else { $script:castOk++; Write-SRLog ('  [ok]   cast to {0}' -f $t) }
        }
    } catch {
        $script:castBad.Add(('{0} ({1})' -f $t, $_.Exception.Message))
    }
    Set-Status ('sending... {0} left' -f $script:castQueue.Count)
})

$ui.Rescan.Add_Click({
    # The order that matters - save unsaved ticks, THEN scan, and refuse if that
    # save fails - lives in Invoke-SRRescan so it can be tested in a sandbox
    # rather than against the operator's real registry. See the note there.
    # Save first, THROUGH THE PROMPT, so a stale stamp cannot leave the rescan
    # and the save both refusing with no way out - see Save-RegistryOrAsk.
    if ($script:dirty) {
        Set-Status 'saving your ticks, then rescanning...'
        if (-not (Save-RegistryOrAsk 'your ticks')) { return }
    } else { Set-Status 'rescanning...' }
    $r = Invoke-SRRescan -Registry $script:reg -Config $script:cfg -Dirty $false -Quiet
    Update-Model -KeepAgents; Update-Surface; Start-LiveProbe
    if (-not $r.Scanned) {
        Write-SRLog ('  [FAIL] rescan: ' + $r.Why)
        Set-Status ('not rescanned - ' + $r.Why) 'bad'
    } else { Set-Status 'rescanned' 'ok' }
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
# The handle exists from here on, which is the earliest the accent border can be
# turned off - and it has to be off before the first paint or it is visible for
# a frame. See Hide-SRAccentBorder.
$window.Add_SourceInitialized({ Hide-SRAccentBorder $window })
$ui.Shell.Add_SizeChanged({ Update-ShellClip })
Update-Frame

# / focuses the search from anywhere; ESC clears it, then hands focus back to
# the list. The three panes are Tab stops in reading order.
$window.Add_PreviewKeyDown({
    param($sender, $e)
    # 🔴 ESCAPE MOVED BELOW THE TYPING GUARD. It was checked FIRST, so pressing
    # it while the cursor was in any box other than the header Search threw the
    # focus out to the sessions list and lost the box you were in.
    # Ctrl+N is checked BEFORE the typing guard: a new session is worth starting
    # even when the cursor happens to be in the search box, and no text field
    # wants Ctrl+N for itself.
    if ($e.Key -eq 'N' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
        Show-Spawn; $e.Handled = $true; return
    }
    # Ctrl+1 / Ctrl+2 fold the two columns, checked before the typing guard for
    # the same reason as Ctrl+N: no text field wants them, and the moment you
    # most want the pane wider is usually while you are reading something in it.
    if ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) {
        if ($e.Key -eq 'D1' -or $e.Key -eq 'NumPad1') { Invoke-ColumnFold -Which 'rail'; $e.Handled = $true; return }
        if ($e.Key -eq 'D2' -or $e.Key -eq 'NumPad2') { Invoke-ColumnFold -Which 'list'; $e.Handled = $true; return }
    }
    # 🔴 THE TYPING GUARD NAMED TWO BOXES AND THIS WINDOW HAS NINE. Everything
    # below is a bare-letter shortcut, and PreviewKeyDown TUNNELS - it runs
    # before the focused TextBox ever sees the key - so seven boxes were having
    # their keystrokes eaten by shortcuts: RailSearch, ListSearch, CastText,
    # SetName, SetAllow, SetDeny and AskFree.
    #
    # Measured by the control audit by invoking this delegate with neither named
    # box focused, which is exactly the state a focused RailSearch produces:
    # typing `hello` into the broadcast box yields `heo`, and EACH swallowed `l`
    # doubled the transcript tail budget (98304 -> 196608 -> 393216) and rebuilt
    # the reading pane. `/` jumped the focus to the header search mid-word. On
    # the manage surface `o` toggled showOlder at 174,4 ms a press and space
    # ticked whatever row was selected.
    #
    # 🪤 ASK THE FOCUSED ELEMENT WHAT IT IS, DO NOT LIST THE BOXES. A list is
    # how this broke: it was correct when the window had two text boxes and
    # silently wrong for every one added afterwards. TextBoxBase covers TextBox
    # and RichTextBox; PasswordBox is not a TextBoxBase and has to be named.
    # The two original tests stay as an OR because IsKeyboardFocusWithin also
    # catches focus sitting on a template part rather than on the box itself.
    $fe = [System.Windows.Input.Keyboard]::FocusedElement
    $typing = (Test-SRTypingTarget $fe) -or
              $ui.Search.IsKeyboardFocusWithin -or $ui.SendBox.IsKeyboardFocusWithin
    if ($typing) {
        # The one shortcut a text field does want: Escape empties a search box
        # if it has anything in it, and otherwise leaves the box.
        if ($e.Key -eq 'Escape') {
            foreach ($sb in @($ui.Search, $ui.RailSearch, $ui.ListSearch)) {
                if ($sb.IsKeyboardFocusWithin -and "$($sb.Text)") {
                    $sb.Text = ''; $e.Handled = $true; return
                }
            }
            $null = $ui.SessionList.Focus(); $e.Handled = $true; return
        }
        return
    }
    if ($e.Key -eq 'Escape') { $null = $ui.SessionList.Focus(); $e.Handled = $true; return }
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
#
# 🔴 THIS WAS UNGUARDED, AND THIS PROCESS HAS NO CONSOLE. The host is built
# /target:winexe precisely so no black window flashes up, which means an
# unhandled exception here goes NOWHERE: the script dies before ShowDialog and
# the operator double-clicks Sessions.exe and watches nothing happen. Not a slow
# start, not an error - nothing. Get-SRRegistry throws by design on an
# unreadable registry ("Delete it to start fresh"), which is a good message that
# was being delivered to no one.
#
# 🪤 IT MUST STILL OPEN. Falling back to an EMPTY registry rather than
# refusing to start is deliberate: an empty list plus a message you can read is
# recoverable, and a tool that will not open is not. Nothing is written in this
# state - $script:dirty stays false, so the empty registry can never be saved
# over the real one.
# ---------------------------------------------------------------------------
$script:startupError = $null
try {
    # 🪤 STARTUP KEEPS THE FULL AGENT REFRESH, deliberately. It is the one caller
    # with no earlier probe to reuse - there is no list yet - so skipping it
    # would open the window with every conversation shown as not running and
    # correct itself a second later, which is worse than opening a second later.
    # The three GESTURES that had an earlier list now reuse it; this one pays.
    #
    # 🔴 BUT NOT THE SAID-LINES, AND THAT NOTE ONLY EVER DEFENDED LIVENESS.
    # Measured 2026-09-04: the cold pass is 1,272 ms and Get-SRLastSaid is 799
    # of them - 63% of the wait before the window appears, spent on ONE COLUMN
    # OF TEXT. Liveness is worth opening late for because a wrong answer there
    # is a lie about what is running; a blank 'what it last said' is visibly
    # missing rather than wrong, and it fills itself in.
    #
    # 🪤 WHICH IS ONLY TRUE BECAUSE THE PROBE IS KICKED AT ContentRendered. The
    # live timer's first tick is fifteen seconds after the window opens, so
    # without that kick this trade would be "paint 800 ms sooner, then sit with
    # an empty column for a quarter of a minute" - which is not the trade being
    # made here, and would be a bad one.
    Update-Model -NoSaid
} catch {
    $script:startupError = "$($_.Exception.Message)"
    Write-SRLog ('  [FAIL] first paint could not read your sessions: {0}' -f $script:startupError)
    $script:reg    = [PSCustomObject]@{ version = 2; lastScan = $null; directories = @() }
    $script:dirs   = @()
    $script:agents = @{}
    # 🪤 THE COUNTER BUMPS HERE TOO. It is the invariant Get-RailGrouping
    # rests on: ASSIGNING THE MODEL BUMPS THE GENERATION, every time and
    # everywhere, or a cache keyed on it serves the previous model's answer.
    # This path only runs before the first build, so it cannot bite today -
    # which is exactly why it would be missed when a third assignment is
    # added somewhere it can.
    $script:model  = New-Object System.Collections.Generic.List[object]; $script:modelGen++
    $script:dirty  = $false
}
try {
    Update-Surface
    Set-Surface 'work'
    Set-Breakpoint
} catch {
    if (-not $script:startupError) { $script:startupError = "$($_.Exception.Message)" }
    Write-SRLog ('  [FAIL] first paint could not draw the window: {0}' -f $_.Exception.Message)
}
if ($script:startupError) {
    Set-Status ("could not read your sessions - $script:startupError") 'bad'
    try {
        $ui.PaneEmpty.Text = "This window opened, but your session registry could not be read." +
            [Environment]::NewLine + [Environment]::NewLine + $script:startupError
        $ui.PaneEmpty.Visibility = $V_Show
    } catch { }
}

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
# 🔴 15, NOT 45. The whole probe runs OFF the UI thread and was measured at
# ~1.2 s (the agent map is 950 ms of it - `claude agents --json` is a process
# spawn, so that cost is irreducible without changing the source of truth). At
# 45 s a conversation you were not looking at could be three-quarters of a
# minute stale, which is what "the sessions are not updating" kept meaning. 15 s
# is an 8% background duty cycle for a threefold improvement in freshness.
$script:LiveSeconds = 15
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

# 🔴 THE 6-SECOND PASS COULD NOT DISCOVER ANYTHING. It re-derived the bands
# from $script:model - which only the 45-second probe ever refreshed - so it was
# a REPAINT wearing a refresh's clothes: six seconds of apparent attentiveness
# over data that could be three-quarters of a minute old.
#
# This gives it a signal of its own, and a cheap one. A transcript that is
# GROWING is a session that is working, and stating the live set costs 14.7 ms
# for 15 conversations (measured) against the 950 ms the agent map costs. It is
# the follow-tick's trick generalised from the selected conversation to every
# live one.
#
# 🪤 IT ONLY EVER MOVES A ROW *OUT* OF NEEDS YOU. File activity proves a
# session is doing something; it can never prove one has started waiting, and
# claiming something wants you is a claim that has to be measured. The probe
# stays the only thing that can put a row INTO needs.
$script:liveStamp = @{}
function Update-LiveWriters {
    $moved = $false
    foreach ($r in $script:model) {
        if (-not $r.Live) { continue }
        $j = "$($r.S.jsonl)"
        if (-not $j) { continue }
        $now = $null
        try {
            $fi = New-Object System.IO.FileInfo $j
            if (-not $fi.Exists) { continue }
            $now = ('{0}|{1}' -f $fi.Length, $fi.LastWriteTimeUtc.Ticks)
        } catch { continue }
        $key = "$($r.Id)"
        $was = $script:liveStamp[$key]
        $script:liveStamp[$key] = $now
        # When it last moved, which is what makes 'gone quiet' answerable at all.
        if ($was -ne $now) { $script:quietSince[$key] = Get-Date }
        if ($was -and $was -ne $now) {
            # 🔴 GROWING IS THE MEASURED ANSWER TO "IS IT STILL ASKING?" - a
            # session writing is a session working, whatever a screen read from
            # two seconds ago said. Clearing the flag here is what stops the
            # sweep's older evidence putting the row straight back.
            if (Set-AskSeen -Id $key -Asking $false) { $moved = $true }
            if ("$($r.Band)" -eq 'needs') {
                $r.Band = 'working'
                $moved = $true
            }
        }
    }
    return $moved
}

function Invoke-FastPass {
    # The stamp is the one thing that must move every tick: it is how you know
    # the window is still watching rather than frozen.
    $ui.Stamp.Text = ('as of {0}' -f $script:probeAt.ToString('HH:mm:ss'))
    # 🪤 BEFORE the surface return below. The bridge is a machine-wide fact, not
    # a property of the work surface, and behind that return it would never
    # update while the session manager was open - which is exactly where an
    # operator goes when their sessions have stopped appearing on their phone.
    try { Update-BridgeNote } catch { }
    $moved = Update-LiveWriters
    if ($script:surface -ne 'work') { return }
    $fp = Get-ModelFingerprint
    if (-not $moved -and $fp -eq $script:lastFp) { return }
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
    $out = @{ Reg = $null; Agents = @{}; Said = @{}; Queue = @{}; Subs = @{}; Ask = $null; AskFor = ''; RegStamp = '' }
    try { $out.Reg = Get-SRRegistry; $out.RegStamp = Get-SRRegistryStamp } catch { }
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
                # 🔴 THE QUEUE, AND ONLY FOR WHAT IS RUNNING. A conversation with
                # no process cannot drain a queue, so a backlog drawn on one says
                # something that will never stop being true - and the read is the
                # most expensive one here: 42.8 ms cold against a 4 MB tail,
                # measured over 46 conversations. Live only turns 1,971 ms into a
                # few hundred, and it is cached against the file stamp, so the
                # steady state is 29 ms for the whole set.
                #
                # 🪤 AND IT BELONGS ON THIS THREAD, not the model pass. That is
                # the whole lesson of the last-said reads three lines up.
                if ($out.Agents[$id]) {
                    try { $out.Queue[$id] = Get-SRQueue -JsonlPath $s.jsonl } catch { }
                }
                # 🔑 AND THE SUB-AGENTS, HERE RATHER THAN INSIDE A REBUILD. See
                # the note on Get-RowSubAgents: read per row on a click this was
                # 784.7 ms every eighth rebuild, at random. The file is already
                # open on this thread for the two reads above.
                try { $subsOne = Get-SRSubAgents -JsonlPath $s.jsonl; $out.Subs[$id] = @($subsOne) } catch { }
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

# 🔴 A PROBE THAT NEVER COMES BACK USED TO STOP THE WINDOW FOREVER, silently.
# The "one at a time" guard below is right - a queue of these would pile up - but
# it was the ONLY thing gating a new probe, so a single job that never completed
# left $script:probePs set for the rest of the session: every later tick
# returned immediately, no refresh ever ran again, and nothing said so. The only
# visible symptom is the "as of" stamp quietly ceasing to move, which is exactly
# the kind of thing you notice an hour later.
#
# It spawns `claude agents --json`, so hanging is not hypothetical - a wedged
# child process is a normal thing for a machine to produce. Raising the probe
# from 45 s to 15 s tripled the number of spawns that could hit it.
#
# 🪤 THE DEADLINE IS GENEROUS ON PURPOSE. The probe legitimately takes ~1.2 s
# and a loaded machine can take several times that; abandoning a healthy probe
# would be worse than the bug, because two of them running at once is what the
# guard exists to prevent. 90 seconds is six normal intervals - long past the
# point where anything is coming back.
$script:probeStartedAt = $null
$script:ProbeDeadlineSeconds = 90
# Separated so the suite can ask the question without starting a probe: this is
# the decision, Start-LiveProbe is the consequence.
function Test-ProbeOverdue {
    if (-not $script:probePs) { return $false }
    if (-not $script:probeStartedAt) { return $false }
    return (((Get-Date) - $script:probeStartedAt).TotalSeconds -gt $script:ProbeDeadlineSeconds)
}

# ===========================================================================
# THE ASK PROBE - one screen read, and nothing else.
#
# 🔴 THE QUESTION USED TO ARRIVE WITH THE HEAVY PROBE, and that probe also
# refreshes the registry, spawns claude for the agent list and reads last-said
# for every live conversation. So clicking a conversation that was waiting on
# you showed nothing for ten to fifteen seconds - on the one surface whose
# entire purpose is to show you what is waiting.
#
# This is its own runspace carrying one job: read that session's screen, return
# the question and the two counts printed on its status line. It is started by
# the click and collected on the 100ms lane, so the answer lands in about a
# second. The heavy probe keeps its own cadence for everything else and no
# longer decides how fast a question appears.
$script:askPs = $null
$script:askRs = $null
$script:askHandle = $null
$script:askFor = ''
$script:askStartedAt = $null

$script:AskJob = {
    . (Join-Path $SRHere '_common.ps1')
    # One read, and a second whenever the first comes back empty. Served either
    # way now - see the note on AnswerJob for why it pays even at one read.
    $null = Start-SRScreenServer
    $out = @{ Ask = $null; Read = $false; Shells = -1; Agents = -1
              Effort = ''; TurnSecs = -1; TurnDone = $false; CtxTokens = -1; CtxWindow = -1 }
    try {
        # ONE screen read serves both answers - the question and the counts the
        # session prints about itself are on the same screen, and reading it
        # twice would double the one cost this job has.
        $txt = Get-SRScreenText -ProcessId $SRAsk.Pid
        # The same single retry Get-SRScreenQuestion makes, and for the same
        # reason: a missed 3-second budget on a busy machine is not evidence
        # that there is no question.
        if (-not $txt) {
            Start-Sleep -Milliseconds 300
            $txt = Get-SRScreenText -ProcessId $SRAsk.Pid
        }
        if ($txt) {
            $q = Invoke-SRParseScreenQuestion -Text $txt
            # The raw screen travels with the parse, exactly as it does on the
            # other path: when an answer turns out wrong it is the only record
            # of what was actually on screen when the options were offered.
            if ($q) { $q | Add-Member -NotePropertyName Screen -NotePropertyValue $txt -Force }
            $out.Ask = $q
            $out.Read = $true
            $sv = Read-SRScreenVitals -ScreenText $txt
            # 🪤 A SUCCESSFUL READ THAT NAMED NO SHELLS IS A TRUE ZERO. Gating
            # this on $sv.Ok - which is only set when one of the two figures
            # was actually printed - left the chip showing the count from the
            # last session that HAD one, because -1 means "do not overwrite".
            $out.Shells = [int]$sv.Shells
            if ($sv.SawAgents) { $out.Agents = [int]$sv.Agents }
            # 🔑 EVERYTHING ELSE THE SAME SCREEN CARRIES. The strip's context,
            # effort and turn clock all come off this line now, and the sweep
            # reaches a given session only every 2.5 s - so clicking a
            # conversation showed no context chip at all until the sweep came
            # round to it. This read is already happening on the click; filing
            # the rest of what it saw costs nothing and closes that gap.
            $out.Effort    = $(if ($sv.SawEffort) { "$($sv.Effort)" } else { '' })
            $out.TurnSecs  = $(if ($sv.SawTurn) { [int]$sv.TurnSecs } else { -1 })
            $out.TurnDone  = [bool]$sv.TurnDone
            $out.CtxTokens = $(if ($sv.SawCtx) { [int]$sv.CtxTokens } else { -1 })
            $out.CtxWindow = $(if ($sv.SawCtx) { [int]$sv.CtxWindow } else { -1 })
        }
    } catch { }
    try { Stop-SRScreenServer } catch { }
    $out
}

function Start-AskProbe { param($R)
    # 🪤 Abandoned rather than queued. A second click while the first read is
    # still out must answer the SECOND conversation; letting them queue is how
    # one conversation's menu ends up filed against another.
    if ($script:askPs) {
        try { $script:askPs.Stop(); $script:askPs.Dispose() } catch { }
        try { $script:askRs.Close(); $script:askRs.Dispose() } catch { }
        $script:askPs = $null; $script:askRs = $null; $script:askHandle = $null
    }
    # Same refusal, same duty to say so: this is the path the window actually
    # takes on a selection, so a silent return here is the one the operator sees.
    $whyProbe = Get-AskBlocker $R
    if ($whyProbe) { $script:askFor = ''; Show-AskWhy -R $R -Why $whyProbe; return }
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('SRHere', $here)
        $rs.SessionStateProxy.SetVariable('SRAsk', @{ Pid = [int]$R.A.Pid })
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($script:AskJob)
        $script:askRs = $rs
        $script:askPs = $ps
        $script:askHandle = $ps.BeginInvoke()
        $script:askFor = "$($R.Id)"
        $script:askStartedAt = Get-Date
    } catch {
        Write-SRLog ('  [skip] the ask probe would not start: ' + $_.Exception.Message)
        $script:askPs = $null; $script:askFor = ''
    }
}

function Complete-AskProbe {
    if (-not $script:askPs -or -not $script:askHandle) { return }
    if (-not $script:askHandle.IsCompleted) {
        # Bounded like the heavy one, and for the same reason: a child that
        # never answers must not wedge the lane that collects it.
        if ($script:askStartedAt -and ((Get-Date) - $script:askStartedAt).TotalSeconds -gt 20) {
            try { $script:askPs.Stop(); $script:askPs.Dispose() } catch { }
            try { $script:askRs.Close(); $script:askRs.Dispose() } catch { }
            $script:askPs = $null; $script:askRs = $null; $script:askHandle = $null
            Write-SRLog '  [warn] the ask probe did not answer in 20s - abandoned'
        }
        return
    }
    $res = $null
    try { $res = @($script:askPs.EndInvoke($script:askHandle))[0] } catch { }
    try { $script:askPs.Dispose(); $script:askRs.Close(); $script:askRs.Dispose() } catch { }
    $script:askPs = $null; $script:askRs = $null; $script:askHandle = $null
    if (-not $res) { return }
    # The selection may have moved while the read was out; a menu belongs to the
    # conversation it was read from and to no other.
    if ("$($script:askFor)" -ne "$($script:selId)") { return }
    $row = Get-SelectedRow
    $whyDone = Get-AskBlocker $row
    if ($whyDone) { Show-AskWhy -R $row -Why $whyDone; return }
    if ($res.Ask) { Show-Ask $res.Ask }
    else {
        # 🪤 THE READ CAME BACK AND FOUND NOTHING, which is a different fact from
        # "the read was refused" and used to look identical - both drew an empty
        # foot. $res.Read is the screen reader's own answer about whether it
        # could see the console at all, so the two are told apart here.
        Show-AskWhy -R $row -Why $(if ($res.Read) {
            'its screen was read, and there is no question on it - it may have just been answered'
        } else {
            'its screen could not be read - the reader is built into .state\ on first use, and a failure is logged in .state\restore.log'
        })
    }
    # The counts the session printed about itself. -1 means the screen could not
    # be read, which is not the same as zero and must not overwrite anything.
    if ($res.Read) {
        $script:screenShells = [int]$res.Shells
        $script:screenAgents = [int]$res.Agents
        # The row wants the same figure the strip is about to show, and this is
        # the freshest read of it there will be - so the list is told too, and
        # the conversation you just clicked carries its marks immediately
        # instead of waiting for the rotation to come round to it.
        if (Set-RowScreenSig -Id "$($script:askFor)" -Shells ([int]$res.Shells) -Agents ([int]$res.Agents) `
                             -Effort "$($res.Effort)" -TurnSecs ([int]$res.TurnSecs) -TurnDone ([bool]$res.TurnDone) `
                             -CtxTokens ([int]$res.CtxTokens) -CtxWindow ([int]$res.CtxWindow)) {
            try { Build-Sessions } catch { }
        }
        try { Update-Chips $row -Force } catch { }
    }
}
$script:screenShells = -1
$script:screenAgents = -1
# Set by the click, consumed by the lane. One flag rather than a queue: a second
# click before the first read starts should read the SECOND conversation, and
# the lane always reads whatever is selected when it fires.
$script:askWanted = $false

# ===========================================================================
# KEEP ASKING UNTIL THE BAR IS THERE
# ===========================================================================
# 🔴 THE CONTEXT CHIP COMES FROM THE SESSION'S OWN STATUS BAR AND NOTHING ELSE,
# and that rule is staying - it was made against measurements and they still
# hold: the window inferred from the token count drew a 1M session at 122k as
# 61% instead of 12%, and the transcript count went stale across a compact
# (123.5k on screen, 619k here). A figure that is confidently wrong is worse
# than an absent one.
#
# But the DELAY was never part of that trade. The screen was read ONCE per
# selection, so a conversation that had not yet printed a bar - which is every
# conversation for the first moments after a restore - showed nothing until the
# slow rotation happened to come round to it. Reported as: I do not see the
# context on restarting the sessions, only after a while.
#
# So the read repeats until it yields a bar. Same single source, asked more
# than once.
#
# 🪤 BOUNDED, AND IT STOPS ON SUCCESS. Each attempt is a child process against
# another console; a retry with no ceiling would be a spinner nobody can see
# burning a process every couple of seconds for the life of the window. Eight
# attempts two seconds apart is sixteen seconds of trying, which covers a
# session that is still starting, and then it gives up and waits for the
# rotation exactly as before.
$SR_CtxRetryMax  = 8
$SR_CtxRetrySecs = 2.0
$script:ctxTries = 0
$script:ctxFor   = ''
$script:ctxAt    = $null

function Request-ContextRetry {
    $r = Get-SelectedRow
    if (-not $r -or -not $r.A -or -not $r.A.Pid) { return }
    $id = "$($r.Id)"
    # A different conversation is a fresh budget - the count is per selection,
    # not per window.
    if ($script:ctxFor -ne $id) { $script:ctxFor = $id; $script:ctxTries = 0; $script:ctxAt = $null }
    $sig = Get-RowScreenSig $id
    if ($sig -and [int]$sig.CtxWindow -gt 0) { return }   # it is on screen; nothing to chase
    if ($script:ctxTries -ge $SR_CtxRetryMax) { return }
    if ($script:ctxAt -and ((Get-Date) - $script:ctxAt).TotalSeconds -lt $SR_CtxRetrySecs) { return }
    $script:ctxAt = Get-Date
    $script:ctxTries++
    $script:askWanted = $true
}

function Start-LiveProbe {
    if ($script:probePs) {
        if (Test-ProbeOverdue) {
            Write-SRLog ('  [warn] the live probe has not returned in {0}s - abandoning it and starting another' -f `
                [int]((Get-Date) - $script:probeStartedAt).TotalSeconds)
            # Stop() rather than just dropping the reference: the runspace holds
            # a thread, and leaking one per 90 seconds is its own slow failure.
            try { $script:probePs.Stop() } catch { }
            try { $script:probePs.Dispose() } catch { }
            try { $script:probeRs.Close(); $script:probeRs.Dispose() } catch { }
            $script:probePs = $null; $script:probeHandle = $null; $script:probeRs = $null
            Set-Status 'the background refresh stopped responding - restarted it' 'warn'
        } else { return }   # one at a time; a queue would pile up
    }
    try {
        # What the pane is showing, so the job can read its pending question
        # while it is out there anyway.
        $selPid = 0; $selId = ''
        $selRow = Get-SelectedRow
        if ($selRow -and $selRow.A -and $selRow.A.Pid) { $selPid = [int]$selRow.A.Pid; $selId = "$($selRow.Id)" }

        # 🔑 THE WARM ONE HERE TOO, and this is the case that showed why it
        # matters beyond the average. The suite asserts this function returns
        # promptly - "starting the live probe blocked for 893 ms - it is not in
        # the background" - and that assertion goes off at random, because the
        # only slow thing in here IS runspace.Open() and it occasionally takes
        # most of a second under load. A 17 ms median with a 900 ms tail, on the
        # dispatcher, every fifteen seconds.
        #
        # 🪤 IT COMPETES WITH THE GESTURES FOR THE SPARE, and that is acceptable
        # rather than free: taking it here means the next click may pay full
        # price, which is exactly what every click paid before this existed. The
        # refill is queued immediately and runs at idle, so the window between
        # them is the one moment nothing is being asked of the dispatcher.
        $rs = Get-SRRunspace
        if (-not $rs) { throw 'no runspace' }
        $rs.SessionStateProxy.SetVariable('SRData', @{ SelPid = $selPid; SelId = $selId })
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($script:ProbeJob)
        $script:probeRs = $rs
        $script:probePs = $ps
        $script:probeHandle = $ps.BeginInvoke()
        $script:probeStartedAt = Get-Date
    } catch {
        # 🔴 The open runspace goes with it - see the note in Start-AskSend's
        # catch. This one runs every 15 seconds, so a leak here is the one that
        # would accumulate threads fastest.
        try { if ($rs) { $rs.Close(); $rs.Dispose() } } catch { }
        Write-SRLog ('  [FAIL] the live probe would not start: {0}' -f $_.Exception.Message)
        $script:probePs = $null; $script:probeRs = $null
    }
}

function Complete-LiveProbe {
    if (-not $script:probePs -or -not $script:probeHandle -or -not $script:probeHandle.IsCompleted) { return }
    $res = $null
    try { $res = @($script:probePs.EndInvoke($script:probeHandle)) | Select-Object -Last 1 } catch { }
    try { $script:probePs.Dispose() } catch { }
    try { $script:probeRs.Close(); $script:probeRs.Dispose() } catch { }
    $script:probePs = $null; $script:probeHandle = $null; $script:probeRs = $null
    $script:probeStartedAt = $null
    if (-not $res) { return }

    # 🔴 NEVER OVERWRITE UNSAVED TICKS. The probe carries a registry read from
    # disk; adopting it while there are unsaved changes would discard what you
    # just ticked. With unsaved work in hand, only the agent map is taken - and
    # then the ROWS ARE NOT REBOUND EITHER, because the rows must always point
    # into whichever registry $script:reg is.
    # 🔑 THE SUB-AGENT LISTS GO IN FIRST, AND ON BOTH BRANCHES. They are a cache
    # of their own keyed by id, not part of the model, so they do not need to
    # travel through Update-Model - and putting them in before the rebuild below
    # means the very next Build-Sessions draws the marks the probe just found.
    if ($res.Subs) {
        $subsAt = Get-Date
        foreach ($sk in @($res.Subs.Keys)) {
            $script:subAgents["$sk"] = @{ At = $subsAt; List = @($res.Subs[$sk]) }
        }
    }

    if (-not $script:dirty -and $res.Reg) {
        # 🪤 THE STAMP COMES WITH THE DATA. The probe read the registry in its
        # own runspace, so this window is now holding something newer than its
        # own stamp - and the stale-write check would refuse the next save
        # against a file it actually agrees with.
        if ("$($res.RegStamp)") { Set-SRRegistryStamp "$($res.RegStamp)" }
        Update-Model -Registry $res.Reg -Agents $res.Agents -Said $res.Said -Queue $res.Queue
    } elseif ($res.Agents) {
        $script:agents = $res.Agents
        foreach ($r in $script:model) {
            $a = $script:agents["$($r.Id)"]
            $r.A = $a
            $r.Live = [bool]$a
            try { $r.Conv = Resolve-SRSessionState -Agent $a -Conv $null } catch { }
            if ($res.Said -and $res.Said.ContainsKey("$($r.Id)")) { $r.Said = $res.Said["$($r.Id)"] }
            # The queue too, or the badge would freeze at whatever it said when
            # the last full model pass ran - which on a machine with unsaved
            # ticks is every pass, since this branch is the one that runs then.
            if ($res.Queue -and $res.Queue.ContainsKey("$($r.Id)")) { $r.Q = $res.Queue["$($r.Id)"] }
            elseif (-not $r.Live) { $r.Q = $null }
            $r.Band = Get-Band $r
        }
    }

    if ($script:surface -eq 'work') { Build-Sessions } else { Build-Manager }
    $ui.LiveCount.Text = ('{0} live of {1} in {2} projects' -f `
        @($script:model | Where-Object { $_.Live }).Count, $script:model.Count, @($script:dirs).Count)

    # The pending question the job read for us, applied only if the pane is
    # still showing the same conversation - the selection can move while a probe
    # is in flight, and showing one session's menu under another's name would be
    # the worst possible bug in this window.
    # 🪤 THE SAME GATE THE FOREGROUND PATH USES. The probe reads the screen on a
    # background thread and the session can have STARTED a reply between the
    # read and here - so being handed a question is not evidence that one is
    # still up, and a mid-turn screen is where the false menus come from.
    if ("$($res.AskFor)" -and "$($res.AskFor)" -eq "$($script:selId)") {
        $askRow = Get-SelectedRow
        if (Test-AskAllowed $askRow) { Show-Ask $res.Ask } else { Show-Ask $null }
    }
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

# The question card's own lane. See the note on Invoke-AskPoll: this is the
# difference between a question appearing in fifteen seconds and in under half
# of one, and it is only affordable because the held-open reader made a screen
# read cheaper than the tick that schedules it.
$script:askTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:askTimer.Interval = [TimeSpan]::FromMilliseconds($script:AskPollFastMs)
$script:askTimer.Add_Tick({
    if ($script:sheetDepth -gt 0) { return }
    try { Invoke-AskPoll } catch { Write-SRLog ('ask poll failed: ' + $_.Exception.Message) } })

$window.Add_ContentRendered({
    Set-Breakpoint
    $null = $ui.SessionList.Focus()
    $script:followTimer.Start()
    $script:fastTimer.Start()
    $script:liveTimer.Start()
    $script:pollTimer.Start()
    $script:askTimer.Start()
    # 🔴 THE FIRST PROBE GOES NOW, NOT IN FIFTEEN SECONDS. A DispatcherTimer
    # fires after its first interval, so the window used to open and then learn
    # nothing new for a quarter of a minute - which was survivable while the
    # startup pass read everything itself, and is not now that it hands the
    # said-lines to this probe (see the note beside Update-Model -NoSaid).
    #
    # 🪤 AFTER the timers are started, so a probe that fails cannot stop them.
    # It is the same call the timer makes and it is already guarded against
    # running twice, so the tick that lands fifteen seconds from now is a
    # no-op if this one is still in flight.
    try { Start-LiveProbe } catch { Write-SRLog ('first probe failed: ' + $_.Exception.Message) }
    # 🔑 THE HELD-OPEN SCREEN READER, asked for once, here. This runspace lives
    # for hours and reads consoles constantly - the question card on every follow
    # tick, three or four times per answer - and starting the reader exe was 100
    # of the 130 ms each of those cost. Measured: a read goes 48 ms to 5.
    #
    # 🪤 ONLY THIS RUNSPACE ASKS. The live probe's runspace is built and thrown
    # away every fifteen seconds and reads one screen in its life; a reader there
    # would cost a process start to save nothing and then idle behind it. See the
    # note on Start-SRScreenServer.
    try { $null = Start-SRScreenServer } catch { Write-SRLog ('screen reader: ' + $_.Exception.Message) }
    # 🔑 AND ONE RUNSPACE READY BEFORE THE FIRST CLICK ASKS FOR IT. Queued at
    # idle priority, so it costs the opening frames nothing; see New-SRRunspace.
    try { Request-SRSpareRunspace } catch { }
})
$window.Add_Closed({
    # 🔴 THE SETTINGS FIRST, BEFORE ANYTHING HERE CAN THROW. Save-SRConfigLater
    # takes the write off the click and leaves it queued for an idle moment; a
    # window closed inside that moment has the value in memory and nowhere else.
    # This is the line that makes the queue safe rather than lossy, so it runs
    # before the timers, the runspaces and the child process - each of which is
    # a chance to throw and skip whatever came after it.
    try { $null = Save-SRConfigWrites }
    catch { try { Write-SRLog ('  [skip] a setting could not be remembered on close: ' + $_.Exception.Message) } catch { } }
    # 🪤 ALL SEVEN, NOT FOUR. searchTimer, launchTimer and castTimer were
    # left running: the dispatcher shuts down with ShowDialog so they do not
    # actually fire, which is exactly why the omission was invisible - and
    # launchTimer is the one that OPENS SESSIONS, so it is not a timer to leave
    # armed on the strength of "the dispatcher probably stops first".
    foreach ($t in @($script:followTimer, $script:fastTimer, $script:liveTimer, $script:pollTimer,
                     $script:searchTimer, $script:launchTimer, $script:castTimer, $script:askTimer)) {
        try { $t.Stop() } catch { }
    }
    # 🔴 A SEND IN FLIGHT IS WAITED FOR, NOT TORN DOWN. Everything else in this
    # handler releases a resource; this one is about what is happening to somebody
    # else's console. See Stop-SendInFlight: the sends type and then submit as two
    # steps, so a thread killed between them leaves the operator's text sitting
    # unsent in a live session. AFTER the timers, so ansTimer cannot race the
    # collection, and BEFORE the runspaces below, which is what used to abandon it.
    try { $null = Stop-SendInFlight } catch { }
    try { $script:ansTimer.Stop() } catch { }
    # The read jobs hold a thread each and the ask probe holds a child process.
    # Nothing to wait for - they type into nothing.
    try { Stop-ReadJobs } catch { }
    # 🔴 STOP BEFORE DISPOSE. A runspace left open holds a thread after the
    # window is gone - but Dispose() on a PowerShell instance that is STILL
    # RUNNING is not a clean shutdown: it can block the close or leave the
    # thread behind anyway. A probe takes ~1.2 s and now runs every 15 s, so
    # roughly one close in twelve lands on one in flight.
    try { if ($script:probePs) { $script:probePs.Stop() } } catch { }
    try { if ($script:probePs) { $script:probePs.Dispose() } } catch { }
    try { if ($script:probeRs) { $script:probeRs.Close(); $script:probeRs.Dispose() } } catch { }
    # The sweep runs every 2.5 s and takes about 0.3, so a close lands on one in
    # flight far more often than it lands on the probe - and it holds a thread
    # and a child process of its own.
    try { Stop-VitalsSweep } catch { }
    # 🔒 AND THE HELD-OPEN READER, which is a child process this window started
    # and is therefore this window's to end. It exits on its own after 30 s idle
    # so a crash cannot strand it, but a backstop is not a substitute for closing
    # what you opened - the whole reason this machine's conventions single out
    # orphan processes is that every one of them was somebody's backstop.
    try { Stop-SRScreenServer } catch { }
    # 🔒 AND THE SPARE RUNSPACE, which holds a thread exactly like the ones the
    # jobs use. It is nobody else's to close.
    try { if ($script:spareRs) { $script:spareRs.Close(); $script:spareRs.Dispose(); $script:spareRs = $null } } catch { }
})

$null = $window.ShowDialog()
