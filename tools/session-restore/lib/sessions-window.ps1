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
    'WorkSurface','RailCol','ListCol','RailPane','RailSplit','RailList','RailClear','RailSearch','RailSort','RailOnlyLive',
    'ListPane','ListSplit','ListCaption','ListSort','ListSearch','ListCount','SessionList',
    'AskTabs','AskFreeBox','AskFree','AskFreeSend','AskFreeLabel','AskReview',
    'OutputPane','PaneName','PaneState','PaneStateDot','PaneGoTo','PaneRelaunch','PaneSettings',
    'SettingsBox','SetName','SetModel','SetEffort','SetPerm','SetPermNote',
    'SetRemote','SetHidden','SetPending','SetCancel','SetApply',
    'SetToolsFold','SetAllow','SetDeny',
    'CastBox','CastWho','CastList','CastText','CastCancel','CastSend',
    'PaneDoc','PaneEmpty','PaneChips','PaneTools','PaneWorktree','PaneCompact','AskBox','AskHeader','AskText','AskOptions','AskFooter','AskNote',
    'SendNote','SendBox','SendBtn','SkillPop','SkillList','SkillHint',
    'ManageSurface','ManageCaption','ManageList','ManageCount',
    'OpenNotRunning','RelaunchSessions',
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

# Built manager rows, keyed by conversation id. Dropped by Update-Model and by
# Toggle-Tick - the only two things that change what a row says.
$script:mgrItems = @{}

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
        $kids = @(Sort-ManagerRows (Select-ManagerRows $byProj[$k]))
        $inWindow = @($kids | Where-Object {
            if ($script:showOlder) { return $true }
            return ($_.At -gt $cutTicks)
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
    # A tick is the one thing a built row says that can change without the model
    # being rebuilt, so it drops the cache. See Build-Manager.
    $script:mgrItems = @{}
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
    $script:mgrItems = @{}
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
    # 🪤 ONLY EVER working -> needs, the same one-way rule the screen read has
    # always carried. A menu on the screen of a conversation the probe calls
    # WORKING means the probe is behind; it does not license moving a row that
    # is done, idle or quiet, whatever the screen appears to show.
    if ($band -eq 'working' -and $script:askSeen["$($Row.Id)"]) { return 'needs' }
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
function Get-AgeTicks { param([long]$Ticks)
    if ($Ticks -le 0) { return '' }
    return (Get-AgeLabel ([DateTime]::Now.Ticks - $Ticks))
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
                Sig = $(if ($live -or (Test-Warm $s)) { try { Get-SRRowSignals "$($s.jsonl)" } catch { $null } } else { $null })
                # Filled below, once the project labels exist. See the note there.
                Hay = ''; HayProj = ''
                At = $at; Warm = ($at -gt $warmCut)
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
    foreach ($r in $rows) {
        $r.Band = Get-Band $r
        $r.Lane = (Get-LaneLabel $r "$($r.T.Text)")
    }
    $script:model = $rows
    Update-ProjectLabels

    # 🔴 THE SEARCH HAYSTACK IS BUILT ONCE, HERE. Typing in the header box cost
    # 338 ms per rebuild - over budget for a gesture that happens on a KEYSTROKE
    # - because both builders composed the same string per row: a Get-Title and
    # a Get-ProjectLabel across 191 conversations, twice over. None of the
    # inputs change between rebuilds; they change when the MODEL changes, which
    # is exactly here. Two haystacks, because the two boxes ask different
    # questions - the rail's matches the project only.
    foreach ($r in $rows) {
        $t = ''
        try { $t = (Get-Title $r.S $r.D).Text } catch { }
        $pl = ''
        if ("$($r.D.path)") { $pl = Get-ProjectLabel "$($r.D.path)" }
        $r.Hay     = ('{0} {1} {2} {3} {4}' -f $t, $r.S.autoTitle, $r.D.path, $r.Id, $pl).ToLower()
        $r.HayProj = ('{0} {1}' -f $pl, $r.D.path).ToLower()
    }
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

# The rail's own ordering and its own filter, independent of the sessions column.
$script:railSort = 'recent'
$script:RailSorts = @(
    @{ Key = 'recent';  Label = 'recent first' },
    @{ Key = 'name';    Label = 'by name' },
    @{ Key = 'waiting'; Label = 'most waiting' },
    @{ Key = 'busiest'; Label = 'busiest' }
)
$script:railOnlyLive = $false

function Build-Rail {
    # 🔴 TWO SEARCHES, AND THEY ARE NOT THE SAME QUESTION. The header box is
    # GLOBAL and narrows both panes at once; this pane's own box narrows only
    # the projects. Being able to hold "AlgoTrader" in one and "KERNEL" in the
    # other is the whole reason for having both, and is what "I am still missing
    # the search in the work surface projects and sessions" meant after the
    # global box already reached here.
    $q = "$($ui.Search.Text)".Trim().ToLower()
    $qr = "$($ui.RailSearch.Text)".Trim().ToLower()
    $byProj = @{}
    foreach ($r in $script:model) {
        if (-not (Test-OnSurface $r)) { continue }
        if ($q -and "$($r.Hay)" -notlike "*$q*") { continue }
        # This box matches the PROJECT, not the conversation - it is the projects
        # list, and matching conversation titles would hide projects whose names
        # you had typed correctly.
        if ($qr -and "$($r.HayProj)" -notlike "*$qr*") { continue }
        $k = "$($r.D.path)"
        if (-not $byProj.ContainsKey($k)) { $byProj[$k] = New-Object System.Collections.Generic.List[object] }
        $byProj[$k].Add($r)
    }
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
            default   {
                $newest = [datetime]0
                foreach ($x in $kids2) { try { $t = [datetime]$x.S.lastActive; if ($t -gt $newest) { $newest = $t } } catch { } }
                - $newest.Ticks
            }
        }
    })
    if ($script:railOnlyLive) {
        # A project with nothing running is not somewhere you are going to look
        # next, which is the only thing this rail is for.
        $order = @($order | Where-Object { @($byProj[$_] | Where-Object { $_.Live }).Count -gt 0 })
    }
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
    $q  = "$($ui.Search.Text)".Trim().ToLower()
    $ql = "$($ui.ListSearch.Text)".Trim().ToLower()

    $keep = New-Object System.Collections.Generic.List[object]
    foreach ($r in $script:model) {
        if (-not (Test-OnSurface $r)) { continue }
        if ($script:railPick -and "$($r.D.path)" -ne $script:railPick) { continue }
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
            $scr = Get-RowScreenSig "$($r.Id)"
            $rowShells = $(if ($scr) { [int]$scr.Shells } else { 0 })
            $rowAgents = $(if ($r.Sig) { [int]$r.Sig.Agents } else { 0 })
            if ($scr -and [int]$scr.Agents -ge 0) { $rowAgents = [int]$scr.Agents }
            $items.Add([PSCustomObject]@{
                Kind = 'session'; Id = $r.Id; Row = $r
                BandVis = $V_Hide; RowVis = $V_Show
                DotVis = $(if ($b.Key -eq 'needs') { $V_Show } else { $V_Hide })
                BandLabel = ''; BandCount = ''; Accent = $acc
                Name = $t.Text
                NameWeight = $(if ($b.Key -eq 'needs') { 'SemiBold' } else { 'Normal' })
                NameStyle  = $(if ($t.Derived) { 'Italic' } else { 'Normal' })
                Age  = (Get-AgeTicks $r.At)
                Said = $saidText
                BarOpacity = $(if ($b.Key -eq 'quiet') { 0.25 } else { 0.85 })
                # 🔴 TWO MARKS, AND ONLY WHEN THEY MEAN SOMETHING. This list was
                # asked to get LESS dense, so a signal that is present on every
                # row is a signal that has cost density and bought nothing: the
                # context bar appears once a conversation is past half its
                # window, and the sub-agent dot only while one is actually out.
                # A quiet row looks exactly as it did before.
                CtxVis = $(if ($r.Sig -and $r.Sig.Frac -gt 0.5) { $V_Show } else { $V_Hide })
                CtxWidth = $(if ($r.Sig) { [Math]::Max(2.0, 34.0 * [Math]::Min(1.0, $r.Sig.Frac)) } else { 0.0 })
                # Green, amber, red - on the token count, not on the fraction.
                # See Get-CtxBrush: 85% of a 200k window and 85% of a 1M window
                # are not the same situation and must not be the same colour.
                CtxBrush = [System.Windows.Media.Brush]$(
                    if ($r.Sig) { Get-CtxBrush ([int]$r.Sig.Tokens) } else { $Pal.Ok })
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
    param([string]$Text, $Brush, [double]$Size = 13, [string]$Weight = 'Normal', [switch]$Mono, [switch]$Italic)
    $r = New-Object System.Windows.Documents.Run ([string]$Text)
    if ($Brush) { $r.Foreground = $Brush }
    $r.FontSize = $Size
    if ($Mono)   { $r.FontFamily = $script:MonoFace }
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
function Get-TrackedText { param([string]$Text)
    if (-not $Text) { return '' }
    return (($Text.ToCharArray() | ForEach-Object { [string]$_ }) -join ([string][char]0x2009))
}

# A ROUNDED, PADDED SURFACE INSIDE A FLOWDOCUMENT.
#
# Paragraph.Background paints a HARD RECTANGLE and Paragraph has no CornerRadius
# at all. That is the whole reason the old code blocks were square slabs sitting
# inside a card with a 12px radius - reported as the text "not looking clean and
# rounded off", which sounded like a font problem and was a layout one. A Border
# inside a BlockUIContainer is the only way to get a rounded, padded,
# translucent block in flowed text.
#
# The container's own Margin does the spacing, not the Border's, or the two
# stack and every block drifts further right than the one above it.
function New-ReadCard {
    param($Child, $Bg, $Stroke, [double]$Radius = 12, [double]$BW = 0,
          [double]$PadL = 16, [double]$PadT = 12, [double]$PadR = 16, [double]$PadB = 12,
          [double]$Left = 0, [double]$Top = 10, [double]$Bottom = 10, [switch]$Hug)
    $bd = New-Object System.Windows.Controls.Border
    # 🪤 A CARD THAT STRETCHES TO CARRY TWO WORDS reads as a mistake, and on a
    # maximised window a folded run of calls did exactly that - 2,200px of
    # ground behind "1 step  Bash". Hug means the card is only as wide as what
    # is in it; everything with real content still fills, because a code block
    # that stopped early would break the left-edge alignment this pane is built
    # on.
    if ($Hug) { $bd.HorizontalAlignment = 'Left' }
    if ($Bg) { $bd.Background = $Bg }
    if ($Stroke -and $BW -gt 0) {
        $bd.BorderBrush = $Stroke
        $bd.BorderThickness = New-Object System.Windows.Thickness $BW
    }
    $bd.CornerRadius = New-Object System.Windows.CornerRadius $Radius
    $bd.Padding = New-Object System.Windows.Thickness $PadL, $PadT, $PadR, $PadB
    $bd.SnapsToDevicePixels = $true
    $bd.Child = $Child
    $c = New-Object System.Windows.Documents.BlockUIContainer $bd
    $c.Margin = New-Object System.Windows.Thickness $Left, $Top, 0, $Bottom
    return $c
}

function New-ReadText {
    param([string]$Text, $Brush, [double]$Size = 13, [switch]$Mono, [switch]$Semi,
          [switch]$Wrap, [double]$Line = 0)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    if ($Brush) { $t.Foreground = $Brush }
    $t.FontSize = $Size
    if ($Mono) { $t.FontFamily = $script:MonoFace } else { $t.FontFamily = $script:UiFace }
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
    param($Doc, [string]$Text, $Brush, [double]$Size = 16, [double]$Line = 28,
          $CodeBg, $CodeStroke, [double]$Indent = 0)
    if (-not $CodeBg) { $CodeBg = $PalGlassHi }
    $lines = @((Remove-SRAnsi $Text) -replace "`r", '' -split "`n")
    $i = 0
    while ($i -lt $lines.Count) {
        $ln = $lines[$i]
        if ($ln.TrimStart().StartsWith('``' + '`')) {
            $code = New-Object System.Collections.Generic.List[string]
            $i++
            while ($i -lt $lines.Count -and -not $lines[$i].TrimStart().StartsWith('``' + '`')) { $code.Add($lines[$i]); $i++ }
            $i++
            $tb = New-ReadText -Text (($code -join "`n").TrimEnd()) -Brush $Pal.TextHigh -Size ($Size - 2.5) -Mono -Wrap -Line ($Size + 5)
            $bw = 0; if ($CodeStroke) { $bw = 1 }
            $Doc.Blocks.Add((New-ReadCard -Child $tb -Bg $CodeBg -Stroke $CodeStroke -BW $bw -Radius 10 -Left $Indent -Top 12 -Bottom 12))
            continue
        }
        $p = New-Object System.Windows.Documents.Paragraph
        $p.Margin = New-Object System.Windows.Thickness $Indent, 3, 0, 3
        $p.LineHeight = $Line
        $p.LineStackingStrategy = 'BlockLineHeight'
        $body = $ln; $size = $Size; $weight = 'Normal'; $bump = 0
        if ($body -match '^\s*#{1,6}\s+(.*)$') { $body = $Matches[1]; $weight = 'SemiBold'; $size = $Size + 2 }
        elseif ($body -match '^\s*[-*]\s+(.*)$') { $body = [string][char]0x2022 + '   ' + $Matches[1]; $bump = 18 }
        elseif ($body -match '^\s*(\d+)\.\s+(.*)$') { $body = $Matches[1] + '.   ' + $Matches[2]; $bump = 18 }
        if ($bump) { $p.Margin = New-Object System.Windows.Thickness ($Indent + $bump), 2, 0, 2 }
        $rest = $body
        while ($rest -match '^(.*?)(`([^`]+)`|\*\*([^*]+)\*\*)(.*)$') {
            $before = $Matches[1]; $codeTxt = $Matches[3]; $boldTxt = $Matches[4]; $rest = $Matches[5]
            if ($before)  { $p.Inlines.Add((New-ReadRun -Text $before -Brush $Brush -Size $size -Weight $weight)) }
            if ($codeTxt) { $p.Inlines.Add((New-ReadRun -Text $codeTxt -Brush $Pal.TextMax -Size ($size - 1.5) -Mono)) }
            elseif ($boldTxt) { $p.Inlines.Add((New-ReadRun -Text $boldTxt -Brush $Pal.TextMax -Size $size -Weight 'SemiBold')) }
        }
        if ($rest) { $p.Inlines.Add((New-ReadRun -Text $rest -Brush $Brush -Size $size -Weight $weight)) }
        # An empty source line is a paragraph break, and it is set SMALL: at the
        # full body size a blank line between two paragraphs is 28px of nothing
        # and the reply looks double-spaced.
        if ($p.Inlines.Count -eq 0) { $p.Inlines.Add((New-ReadRun -Text ' ' -Brush $Brush -Size ($Size * 0.4))) }
        $Doc.Blocks.Add($p)
        $i++
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
                $out.Add([PSCustomObject]@{ Kind = "$($b.Kind)"; Head = "$($b.Head)"; Body = $body0
                                            Calls = $null; When = $b.When; Count = 1 })
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
                    $one = "$(@("$($arr[$i].Body)" -replace "`r", '' -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1))"
                    if ($one.Length -gt 130) { $one = $one.Substring(0, 127) + [string][char]0x2026 }
                    $last.Res = $one
                    $last.Bad = ("$($arr[$i].Head)" -eq 'failed')
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
$script:ReadMeasureChars = 70
# The size the last layout settled on. The renderer reads it rather than a
# literal, so type and measure can never disagree about how wide a line is.
$script:readSize = 16.0
$script:readLead = 28.0

# 🔴 A MEASURE IS A CEILING, NOT A WIDTH - AND AS AN ABSOLUTE IT WAS WRONG.
#
# 70 characters is right on a 927px pane and absurd on a maximised one:
# measured at a 2,746px window the text column was still ~580px, so 78% of the
# pane was empty, the hairlines between turns stopped a third of the way across,
# and the whole document hugged the left edge. Reported as the text not scaling
# and the alignment looking off, which is exactly what it was.
#
# So the pane now FILLS, the way the terminal it mirrors does, and the type
# scales with it so a long line is still readable: 16px on a normal window,
# rising to 20px on a very wide one. The old column is not deleted - it is
# `readingWidth: measured` in the config, because a capped measure genuinely
# reads better for long prose and that argument did not stop being true.
function Set-ReadMeasure { param($Doc, [double]$Size = 0, [double]$PadL = 44)
    $avail = 0.0
    try { $avail = [double]$ui.PaneDoc.ActualWidth } catch { }
    if ($avail -lt 200) { $avail = 900.0 }

    # Type scales with the pane, gently and with a ceiling. Linear scaling would
    # reach 47px at this width - filling the line by growing the letters is not
    # scaling, it is zooming.
    $size = 16.0
    if ($avail -gt 1100) { $size = 16.0 + [Math]::Min(4.0, ($avail - 1100.0) / 340.0) }
    if ($Size -gt 0) { $size = $Size }
    $script:readSize = $size
    $script:readLead = [Math]::Round($size * 1.75, 1)

    $right = 44.0
    if ($script:readWidth -eq 'measured') {
        # 0.52em per character is Manrope's measured average advance for prose
        # at these sizes; it does not need to be exact, only stable.
        $target = $script:ReadMeasureChars * $size * 0.52
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
          [double]$Size = 10, [double]$Top = 12, [double]$Bottom = 9)
    $p = New-Object System.Windows.Documents.Paragraph
    $p.Margin = New-Object System.Windows.Thickness 0, $Top, 0, $Bottom
    $p.Inlines.Add((New-ReadRun -Text (Get-TrackedText $Text.ToUpper()) -Brush $Brush -Size $Size -Weight 'SemiBold'))
    $stamp = Format-TurnTime $When
    if ($stamp) {
        # Dimmer than the speaker and not tracked: it is a reference you look up
        # when you want it, never something that competes with who is talking.
        $p.Inlines.Add((New-ReadRun -Text ('        ' + $stamp) -Brush $Pal.TextLow -Size ($Size + 0.5)))
    }
    if ($Trailing) {
        $p.Inlines.Add((New-ReadRun -Text ('          ' + $Trailing) -Brush $TrailBrush -Size ($Size + 0.5)))
    }
    $Doc.Blocks.Add($p)
}

# Which of the three positions the pane is in. Read once from the config and
# then owned by the window, so the toggle is instant and the write is a side
# effect rather than something the render path waits on.
$script:toolView = 'folded'
$script:readWidth = 'full'
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
    param($Blocks, [bool]$Truncated = $false)
    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.FontFamily  = $script:UiFace
    # TRANSPARENT, NOT Ink. The document was painting the GROUND colour - the
    # near-black the window shows *around* its cards - inside an output pane
    # that is painted Panel and has a 12px corner radius. The result was a
    # darker square slab filling the rounded card, with the radius visible only
    # at the very corners: the operator's "it doesn't look rounded off". Letting
    # the card show through is the fix, and it costs nothing.
    $doc.Background  = [System.Windows.Media.Brushes]::Transparent
    $doc.Foreground  = $Pal.TextHigh
    $doc.ColumnWidth = [double]::PositiveInfinity
    # OPTIMAL PARAGRAPH IS WPF'S GOOD LINE BREAKER (Knuth-Plass): it looks at
    # the whole paragraph rather than greedily filling each line, which is the
    # difference between even ragged edges and the lumpy ones that read as "not
    # clean". Off by default, and it was left off. Hyphenation stays off -
    # hyphenated prose in a terminal-adjacent surface reads worse, not better.
    $doc.IsOptimalParagraphEnabled = $true
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
    if ($Truncated) {
        $p = New-Object System.Windows.Documents.Paragraph
        $p.Margin = New-Object System.Windows.Thickness 0, 0, 0, 6
        $p.Inlines.Add((New-ReadRun -Text ('showing the last {0} KB of a longer conversation - press L to load earlier' -f [int]($script:tailBytes / 1KB)) -Brush $Pal.TextDim -Size 11.5 -Italic))
        $doc.Blocks.Add($p)
    }

    $hidden = 0
    foreach ($t in @(Get-ReadTurns $Blocks)) {
        switch ($t.Kind) {
            'you' {
                Add-ReadRule -Doc $doc -Brush $PalEdge.Out -Height 2
                $trail = ''
                if ($hidden -gt 0) { $trail = "$hidden steps hidden"; $hidden = 0 }
                Add-ReadLabel -Doc $doc -Text 'you said' -Brush $Pal.Out -Trailing $trail -TrailBrush $Pal.TextLow -When $t.When
                $inner = New-Object System.Windows.Documents.FlowDocument
                Add-ReadProse -Doc $inner -Text $t.Body -Brush $Pal.TextMax -Size $script:readSize -Line $script:readLead -CodeBg $PalFilm.Out
                # Blocks is a live collection: moving them while enumerating it
                # silently drops every second one, hence the @() snapshot. And
                # $null = on Remove is not tidiness - it returns a BOOL, and an
                # uncaptured value would be emitted, so the function would return
                # an array of $true with the document buried inside it.
                foreach ($blk in @($inner.Blocks)) { $null = $inner.Blocks.Remove($blk); $doc.Blocks.Add($blk) }
            }
            'said' {
                Add-ReadRule -Doc $doc -Brush $PalHair
                $trail = ''
                if ($hidden -gt 0) { $trail = "$hidden steps hidden"; $hidden = 0 }
                Add-ReadLabel -Doc $doc -Text 'claude' -Brush $Pal.In -Trailing $trail -TrailBrush $Pal.TextLow -When $t.When
                $inner = New-Object System.Windows.Documents.FlowDocument
                Add-ReadProse -Doc $inner -Text $t.Body -Brush $Pal.TextHigh -Size $script:readSize -Line $script:readLead -CodeBg $PalGlassHi
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
                $st.HorizontalAlignment = 'Center'
                $null = $st.Children.Add((New-ReadText -Text (Get-TrackedText 'COMPACTED') -Brush $Pal.Ask -Size 9.5 -Semi))
                if ("$($t.Body)".Trim()) {
                    $null = $st.Children.Add((New-ReadText -Text ('        ' + $t.Body) -Brush $Pal.TextLow -Size 11.5))
                }
                $doc.Blocks.Add((New-ReadCard -Child $st -Bg $PalWash.Ask -Stroke $PalEdge.Ask -BW 1 -Radius 10 -PadT 9 -PadB 10 -Top 22 -Bottom 18))
            }
            'hook' {
                # What a hook actually said. It rides on a record with no message
                # at all, which is why none of this ever reached the pane.
                $st = New-Object System.Windows.Controls.StackPanel
                $null = $st.Children.Add((New-ReadText -Text (Get-TrackedText ("HOOK  " + $t.Head)) -Brush $Pal.Tool -Size 9.5 -Semi))
                $body = "$($t.Body)".Trim()
                if ($body.Length -gt 600) { $body = $body.Substring(0, 597) + [string][char]0x2026 }
                $tb = New-ReadText -Text $body -Brush $Pal.TextMid -Size 12 -Wrap -Line 18
                $tb.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
                $null = $st.Children.Add($tb)
                $doc.Blocks.Add((New-ReadCard -Child $st -Bg $PalFilm.Tool -Stroke $PalEdge.Tool -BW 1 -Radius 10 -PadT 10 -PadB 11))
            }
            'system' {
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 0, 10, 0, 6
                $p.Inlines.Add((New-ReadRun -Text (Get-TrackedText $t.Head.ToUpper()) -Brush $Pal.TextLow -Size 9.5 -Weight 'SemiBold'))
                $p.Inlines.Add((New-ReadRun -Text ('        ' + $t.Body) -Brush $Pal.TextLow -Size 12 -Mono))
                $doc.Blocks.Add($p)
            }
            'file' {
                # The list a compact prints when it re-reads what it needs.
                $st = New-Object System.Windows.Controls.StackPanel
                $n = [int]$t.Count
                $word = 'files'; if ($n -eq 1) { $word = 'file' }
                $null = $st.Children.Add((New-ReadText -Text (Get-TrackedText ('{0}  {1} {2}' -f $t.Head, $n, $word)) -Brush $Pal.TextLow -Size 9.5 -Semi))
                $tb = New-ReadText -Text "$($t.Body)".Trim() -Brush $Pal.TextMid -Size 12 -Mono -Wrap -Line 17
                $tb.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
                $null = $st.Children.Add($tb)
                $doc.Blocks.Add((New-ReadCard -Child $st -Bg $PalGlass -Radius 10 -PadT 10 -PadB 10))
            }
            'queued' {
                $body = "$($t.Body)".Trim()
                if ($body.Length -gt 400) { $body = $body.Substring(0, 397) + [string][char]0x2026 }
                $st = New-Object System.Windows.Controls.StackPanel
                $null = $st.Children.Add((New-ReadText -Text (Get-TrackedText 'QUEUED') -Brush $Pal.Out -Size 9.5 -Semi))
                $tb = New-ReadText -Text $body -Brush $Pal.TextMid -Size 12 -Wrap -Line 18
                $tb.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
                $null = $st.Children.Add($tb)
                $doc.Blocks.Add((New-ReadCard -Child $st -Bg $PalFilm.Out -Stroke $PalEdge.Out -BW 1 -Radius 10 -PadT 10 -PadB 11))
            }
            'thinking' {
                if ($script:toolView -eq 'hidden') { break }
                $head = @("$($t.Body)" -replace "`r", '' -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1) -join ' '
                if ($head.Length -gt 150) { $head = $head.Substring(0, 147) + [string][char]0x2026 }
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 0, 10, 0, 4
                $p.Inlines.Add((New-ReadRun -Text 'thinking   ' -Brush $Pal.TextLow -Size 11 -Weight 'SemiBold'))
                $p.Inlines.Add((New-ReadRun -Text $head -Brush $Pal.TextLow -Size 13 -Italic))
                $doc.Blocks.Add($p)
            }
            'run' {
                if ($script:toolView -eq 'hidden') { $hidden += @($t.Calls).Count; break }

                $st = New-Object System.Windows.Controls.StackPanel
                $cap = New-Object System.Windows.Controls.StackPanel
                $cap.Orientation = 'Horizontal'
                $null = $cap.Children.Add((New-ReadText -Text ([string][char]0x25B8 + '   ') -Brush $Pal.Tool -Size 11 -Semi))
                $null = $cap.Children.Add((New-ReadText -Text (Get-TrackedText (Get-RunSummary $t.Calls)) -Brush $Pal.Tool -Size 9.5 -Semi))
                $null = $st.Children.Add($cap)

                if ($script:toolView -eq 'full') {
                    $cap.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
                    $shown = 0
                    foreach ($c in @($t.Calls)) {
                        if ($shown -ge 6) { break }
                        $shown++
                        $ln = New-Object System.Windows.Controls.StackPanel
                        $ln.Margin = New-Object System.Windows.Thickness 0, 0, 0, 7
                        $fg = $Pal.TextHigh
                        if ($c.Bad) { $fg = $Pal.Bad }
                        $null = $ln.Children.Add((New-ReadText -Text ($c.Name + '   ' + (Compress-SRPath $c.Arg)) -Brush $fg -Size 12.5 -Mono))
                        if ($c.Res) {
                            $r = New-ReadText -Text (Compress-SRPath $c.Res) -Brush $Pal.TextLow -Size 12 -Mono
                            $r.Margin = New-Object System.Windows.Thickness 18, 3, 0, 0
                            $null = $ln.Children.Add($r)
                        }
                        $null = $st.Children.Add($ln)
                    }
                    if (@($t.Calls).Count -gt $shown) {
                        $null = $st.Children.Add((New-ReadText -Text ('and {0} more' -f (@($t.Calls).Count - $shown)) -Brush $Pal.TextLow -Size 11.5 -Mono))
                    }
                }
                $doc.Blocks.Add((New-ReadCard -Child $st -Bg $PalGlass -Stroke $PalHair -BW 1 -Radius 12 -PadT 11 -PadB 10 -Hug:($script:toolView -ne 'full')))
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
function Test-AskAllowed { param($R)
    if (-not $R -or -not $R.A -or -not $R.A.Pid) { return $false }
    if ("$($R.A.Status)" -eq 'busy') { return $false }
    return $true
}

function Update-Ask { param($R)
    if (-not (Test-AskAllowed $R)) { Show-Ask $null; return }
    $q = $null
    try { $q = Get-SRScreenQuestion -ProcessId ([int]$R.A.Pid) } catch { }
    Show-Ask $q
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
    $mark.FontSize = 10.5
    $mark.FontFamily = $script:UiFace
    $mark.VerticalAlignment = 'Center'
    $mark.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
    $null = $sp.Children.Add($mark)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Label
    $t.FontSize = 10.5
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
            $qt.FontSize = 12
            $qt.Foreground = $window.FindResource('TextMid')
            $qt.FontFamily = $script:UiFace
            $null = $sp2.Children.Add($qt)
            $at2 = New-Object System.Windows.Controls.TextBlock
            $at2.Text = "$($a.Answer)"
            $at2.TextWrapping = 'Wrap'
            $at2.FontSize = 13.5
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
        $bt.FontSize = 11.5
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
        $lab.FontSize = 13.5
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
            $sub.FontSize = 12
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
        $ui.AskFree.Text = "$($q.FreeText)"
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
        # 🔑 A ROUND DOES NOT END WITH ONE ANSWER. Measured: answering a
        # single-select AUTO-ADVANCES the terminal to the next question, so
        # closing the panel here left the operator staring at a session that was
        # still waiting on them with nothing on screen to say so. Re-read: if
        # another question came up, draw it; only a menu that has actually gone
        # closes the panel and sends the row back to working.
        $seen = $null
        try { $seen = Get-SRScreenQuestion -ProcessId $procId } catch { }
        if ($seen) { Show-Ask $seen } else {
            $ui.AskBox.Visibility = $V_Hide
            $script:lastAsk = $null
            Move-RowToWorking $r
        }
    }

    # The AFTER shot is the evidence, and it is taken on a background thread so
    # it costs the operator nothing. It is still the same measurement: what the
    # screen said once the keys had landed.
    Start-AnswerRecord -SessionId $r.Id -Pid_ $procId -Index $Index -Question $script:lastAsk -Why "$why"
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
    Set-Status $(if ($Delta -lt 0) { 'going back...' } else { 'going on...' })
    $why = $null
    try { $why = Invoke-SRRoundMove -ProcessId ([int]$r.A.Pid) -Delta $Delta } catch { $why = $_.Exception.Message }
    if ($why) { Set-Status $why 'warn' } else { Set-Status '' }
    # Redraw from the screen either way: a refused move still leaves the menu
    # somewhere, and the panel must show where.
    $seen = $null
    try { $seen = Get-SRScreenQuestion -ProcessId ([int]$r.A.Pid) } catch { }
    if ($seen) { Show-Ask $seen }
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
    Set-Status 'typing your answer in...'
    $procId = [int]$r.A.Pid
    $why = $null
    try { $why = Invoke-SRAnswerTypedOnScreen -ProcessId $procId -Text $txt -Who "$($r.Id)" } catch { $why = $_.Exception.Message }
    if ($why) { Set-Status $why 'bad'; return }
    Set-Status 'answered in your own words' 'ok'
    $ui.AskFree.Text = ''
    # A round has more questions after this one, so the panel redraws rather than
    # closing: the terminal has already moved on to the next tab.
    $seen = $null
    try { $seen = Get-SRScreenQuestion -ProcessId $procId } catch { }
    if ($seen) { Show-Ask $seen } else {
        $ui.AskBox.Visibility = $V_Hide
        $script:lastAsk = $null
        Move-RowToWorking $r
    }
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
    try { $why = Send-SRSessionInput -SessionId $r.Id -Text '/compact' } catch { $why = $_.Exception.Message }
    if ($why) { Set-Status $why 'bad' } else {
        Set-Status 'sent /compact' 'ok'
        Move-RowToWorking $r
    }
}

# ===========================================================================
# Selection, and following the selected transcript
# ===========================================================================
function Update-Document { param([switch]$Wait)
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
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('SRHere', $here)
        $rs.SessionStateProxy.SetVariable('SRDoc', @{ Path = $Path; Tail = $script:tailBytes })
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
        Write-SRLog ('  [skip] parsing off-thread failed, reading inline: ' + $_.Exception.Message)
        $script:docPs = $null
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
    # to the conversation it was read from.
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return $false }
    $now = ('{0}|{1}' -f "$($it.Row.S.jsonl)".ToLower(), $script:tailBytes)
    if ($now -ne $script:docFor) { return $false }
    Set-ReadDocument -Blocks $res.Blocks -Truncated $script:docTrunc
    return $true
}

# Building the document and putting it on screen. Separated from the parse so
# the expensive half can move threads and this half - which cannot, because WPF
# objects have thread affinity - stays here and stays inside budget.
function Set-ReadDocument { param($Blocks, [bool]$Truncated = $false)
    $doc = Build-ReadDocument -Blocks $Blocks -Truncated $Truncated
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
$SR_ChipFont = 10.5
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
    $tb.FontSize = $SR_ChipFont
    $tb.FontWeight = $FW_Normal
    $tb.FontFamily = $script:UiFace
    $null = $sp.Children.Add($tb)
    $bd.Child = $sp
    return @{ Border = $bd; Text = $tb }
}

function Update-Chips { param($R, [switch]$Force)
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

    $frac = 0.0
    if ($v.Window -gt 0) { $frac = [double]$v.Tokens / [double]$v.Window }
    $barFg = Get-CtxBrush ([int]$v.Tokens)
    $ctx = ('{0} / {1}   {2}%' -f (Format-Kilo $v.Tokens), (Format-Kilo $v.Window), [int][math]::Round($frac * 100))
    $null = $ui.PaneChips.Children.Add((New-Chip -Text $ctx -Fg $Pal.TextHigh -Bg $glass -Bar $frac -BarFg $barFg -Tip 'Context in use at its last reply. A 1M window is inferred from the usage, because the transcript does not record which one was selected.').Border)

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
            $t.FontSize = $SR_ChipFont; $t.FontWeight = $FW_Normal; $t.FontFamily = $script:UiFace
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
    # setting is already live in this window either way.
    try { Save-SRConfigValue -Name 'transcriptTools' -Value $script:toolView }
    catch { Write-SRLog ('  [skip] could not remember the steps setting: ' + $_.Exception.Message) }
    Show-Selected -Force
}

function Show-Selected { param([switch]$Force)
    $it = $ui.SessionList.SelectedItem
    if (-not $it -or $it.Kind -ne 'session') { return }
    $same = ($script:selId -eq $it.Id)
    $script:selId = $it.Id
    $r = $it.Row
    $t = $r.T
    $ui.PaneName.Text = $t.Text
    $b = @($script:Bands | Where-Object { $_.Key -eq "$($r.Band)" })
    $ui.PaneStateDot.Background = $(if ($b.Count) { $window.FindResource($b[0].Acc) } else { $window.FindResource('AccIdle') })
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
    $ui.RailSort.Text = $(if ($cur.Count) { "$($cur[0].Label)" } else { 'recent first' })
    $ui.RailOnlyLive.Text = $(if ($script:railOnlyLive) { 'only running' } else { 'all projects' })
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
            Update-Model; Update-Surface
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

# Answering a question in your own words. Enter sends it, the same key that
# commits it in the terminal - but only through Invoke-AskTyped, which will not
# send an empty one.
$ui.AskFreeSend.Add_Click({ Invoke-AskTyped })
$ui.AskFree.Add_PreviewKeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Return') { Invoke-AskTyped; $e.Handled = $true }
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
    param([string]$Id, [int]$Shells, [int]$Agents, [string]$Effort = '', [int]$TurnSecs = -1, [bool]$TurnDone = $false)
    if (-not $Id) { return $false }
    $was = $script:rowScreen[$Id]
    # Only the two MARKS decide whether the list needs redrawing; the clock and
    # the effort live on the strip, which repaints on its own tick. A redraw of
    # every row once a second because a timer moved would be the opposite of
    # what the sweep is for.
    $changed = (-not $was) -or ([int]$was.Shells -ne $Shells) -or ([int]$was.Agents -ne $Agents)
    $script:rowScreen[$Id] = @{
        At = (Get-Date); Shells = $Shells; Agents = $Agents
        Effort = "$Effort"; TurnSecs = $TurnSecs; TurnDone = $TurnDone
    }
    return $changed
}

function Get-RowScreenSig { param([string]$Id)
    if (-not $Id) { return $null }
    $v = $script:rowScreen[$Id]
    if (-not $v) { return $null }
    # A count read four minutes ago describes a session that has since done
    # anything at all. Past its life it is not evidence and must not draw.
    if (((Get-Date) - $v.At).TotalSeconds -gt $SR_RowScreenTTL) { return $null }
    return $v
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
            $q = $null
            try { $q = Invoke-SRParseScreenQuestion -Text $screens[$k] } catch { }
            # Same two defaults the single reader uses, and for the same reason:
            # a line that printed no shell count IS zero, and one that named no
            # sub-agents means "ask the transcript" rather than "there are none".
            $out[[int]$k] = @{
                Shells = [int]$v.Shells
                Agents = $(if ($v.SawAgents) { [int]$v.Agents } else { -1 })
                Asking = [bool]($q -and @($q.Options).Count -ge 2)
                # What the session says about its own turn and how hard it is
                # thinking. Both are '' / -1 when the screen did not say, which
                # is not the same as zero.
                Effort   = $(if ($v.SawEffort) { "$($v.Effort)" } else { '' })
                TurnSecs = $(if ($v.SawTurn) { [int]$v.TurnSecs } else { -1 })
                TurnDone = [bool]$v.TurnDone
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
    foreach ($row in @($script:sweepFor)) {
        $got = $res[[int]$row.Pid]
        # 🪤 A CONSOLE THAT COULD NOT BE READ FILES NOTHING. Absent is not zero,
        # and writing a zero here would clear a mark on no evidence - the entry
        # ages out on its own if the reads keep failing.
        if (-not $got) { continue }
        if (Set-RowScreenSig -Id "$($row.Id)" -Shells ([int]$got.Shells) -Agents ([int]$got.Agents) `
                             -Effort "$($got.Effort)" -TurnSecs ([int]$got.TurnSecs) -TurnDone ([bool]$got.TurnDone)) {
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
        $live = @($script:model | Where-Object { "$($_.Id)" -eq "$($row.Id)" })
        if (-not $live.Count) { continue }
        if ([bool]$got.Asking) {
            # 🔴 THROUGH THE SAME ONE-WAY RULE the quiet check uses. Only a
            # WORKING row may be moved into needing you, whatever the screen
            # shows for a row that is done, idle or quiet.
            if (Test-QuietVerdict -Row $live[0] -Asking $true) { $changed = $true }
        } elseif (Set-AskSeen -Id "$($row.Id)" -Asking $false) {
            # Measured absence, which is the half that never used to happen:
            # the row can now leave NEEDS YOU because the menu is gone, not
            # merely because something else recomputed the band.
            if ("$($live[0].Band)" -eq 'needs') { $live[0].Band = Get-Band $live[0] }
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

$script:QuietJob = {
    . (Join-Path $SRHere '_common.ps1')
    $out = @{ Asking = $false; Read = $false; Shells = 0; Agents = -1 }
    try {
        $txt = Get-SRScreenText -ProcessId $SRQuiet.Pid
        if ($txt) {
            $out.Read = $true
            $q = Invoke-SRParseScreenQuestion -Text $txt
            if ($q -and @($q.Options).Count -ge 2) { $out.Asking = $true }
            # The same screen answers the other thing a row wants to know, so
            # it costs nothing beyond the read that was already being made.
            $sv = Read-SRScreenVitals -ScreenText $txt
            if ($sv.SawShells) { $out.Shells = [int]$sv.Shells }
            if ($sv.SawAgents) { $out.Agents = [int]$sv.Agents }
        }
    } catch { }
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
function Test-QuietVerdict { param($Row, [bool]$Asking)
    if (-not $Row -or -not $Asking) { return $false }
    if ("$($Row.Band)" -ne 'working') { return $false }
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
        if ($script:askWanted) {
            $script:askWanted = $false
            try { Start-AskProbe (Get-SelectedRow) } catch { }
        }
        try { Complete-AskProbe } catch { }
        # A transcript parse that has landed becomes the document here, on the
        # lane, so the gesture that asked for it never waited.
        try { $null = Complete-DocParse } catch { }
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
    Update-Model; Update-Surface
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
    Update-Model
} catch {
    $script:startupError = "$($_.Exception.Message)"
    Write-SRLog ('  [FAIL] first paint could not read your sessions: {0}' -f $script:startupError)
    $script:reg    = [PSCustomObject]@{ version = 2; lastScan = $null; directories = @() }
    $script:dirs   = @()
    $script:agents = @{}
    $script:model  = New-Object System.Collections.Generic.List[object]
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
    $out = @{ Reg = $null; Agents = @{}; Said = @{}; Ask = $null; AskFor = ''; RegStamp = '' }
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
    $out = @{ Ask = $null; Read = $false; Shells = -1; Agents = -1 }
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
        }
    } catch { }
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
    if (-not (Test-AskAllowed $R)) { $script:askFor = ''; return }
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
    if (-not (Test-AskAllowed $row)) { Show-Ask $null; return }
    Show-Ask $res.Ask
    # The counts the session printed about itself. -1 means the screen could not
    # be read, which is not the same as zero and must not overwrite anything.
    if ($res.Read) {
        $script:screenShells = [int]$res.Shells
        $script:screenAgents = [int]$res.Agents
        # The row wants the same figure the strip is about to show, and this is
        # the freshest read of it there will be - so the list is told too, and
        # the conversation you just clicked carries its marks immediately
        # instead of waiting for the rotation to come round to it.
        if (Set-RowScreenSig -Id "$($script:askFor)" -Shells ([int]$res.Shells) -Agents ([int]$res.Agents)) {
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
        $script:probeStartedAt = Get-Date
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
    $script:probeStartedAt = $null
    if (-not $res) { return }

    # 🔴 NEVER OVERWRITE UNSAVED TICKS. The probe carries a registry read from
    # disk; adopting it while there are unsaved changes would discard what you
    # just ticked. With unsaved work in hand, only the agent map is taken - and
    # then the ROWS ARE NOT REBOUND EITHER, because the rows must always point
    # into whichever registry $script:reg is.
    if (-not $script:dirty -and $res.Reg) {
        # 🪤 THE STAMP COMES WITH THE DATA. The probe read the registry in its
        # own runspace, so this window is now holding something newer than its
        # own stamp - and the stale-write check would refuse the next save
        # against a file it actually agrees with.
        if ("$($res.RegStamp)") { Set-SRRegistryStamp "$($res.RegStamp)" }
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

$window.Add_ContentRendered({
    Set-Breakpoint
    $null = $ui.SessionList.Focus()
    $script:followTimer.Start()
    $script:fastTimer.Start()
    $script:liveTimer.Start()
    $script:pollTimer.Start()
})
$window.Add_Closed({
    # 🪤 ALL SEVEN, NOT FOUR. searchTimer, launchTimer and castTimer were
    # left running: the dispatcher shuts down with ShowDialog so they do not
    # actually fire, which is exactly why the omission was invisible - and
    # launchTimer is the one that OPENS SESSIONS, so it is not a timer to leave
    # armed on the strength of "the dispatcher probably stops first".
    foreach ($t in @($script:followTimer, $script:fastTimer, $script:liveTimer, $script:pollTimer,
                     $script:searchTimer, $script:launchTimer, $script:castTimer)) {
        try { $t.Stop() } catch { }
    }
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
})

$null = $window.ShowDialog()
