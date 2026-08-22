#requires -Version 5.1
<#
.SYNOPSIS
    The session control panel, as a window. A graphical equivalent of
    select-sessions.ps1 -- same model, same guards, same registry.

.DESCRIPTION
    Three levels. A PROJECT is a repository. Under it sit LANES -- `main` for the
    repo's own tree and one lane per git worktree -- and under those, the
    CONVERSATIONS.

    TWO INDEPENDENT THINGS live on this screen and confusing them is the one way
    to misread it. The window is monochrome, so NOTHING here is told apart by
    colour; the two are separated structurally instead, and every separation is
    doubled so no single one has to carry it:

      the TICK   FIRST column, far LEFT, under the bold heading LOGON, fenced off
                 from the rest of the row by a vertical rule. It is a CHECKBOX --
                 a small square, filled when ticked and hollow when not, and the
                 only square on the screen. It answers "does this reopen
                 automatically at the next logon?" and it NEVER launches anything.
      OPEN       LAST column, far RIGHT, under the bold heading RIGHT NOW, behind
                 its own vertical rule. It is a BUTTON, not a checkbox. It opens a
                 conversation this second, whatever its tick says, and it NEVER
                 reads the tick.

    Opposite ends, two headings, two control shapes, two rules. Nothing here
    launches until an OPEN / New session / Launch everything ticked button is
    pressed.

    Keys:  / or Ctrl+F find    ESC clear the filter    SPACE tick+pin    U unpin
           L open now          S new session here      X launch everything ticked
           LEFT/RIGHT fold     R rescan                Ctrl+S save

    Everything that reads or writes state goes through _common.ps1 -- config,
    registry, discovery, the rolling auto-tick, the launch guards and the registry
    lock. This file adds a window and nothing else. Helpers that exist only inside
    select-sessions.ps1 are re-implemented here and each one cites the original.

.PARAMETER NoScan
    Skip the scan on startup and show whatever the registry already holds.

.PARAMETER Relaunched
    Internal. Set when the script has already re-launched itself into an STA
    apartment, so it cannot do so twice.

.EXAMPLE
    .\sessions-gui.ps1
    powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\sessions-gui.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoScan,
    [switch]$Relaunched
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Where we are. Resolved in the BODY, never in a param() default -- $PSScriptRoot
# is empty while a default is evaluated under `powershell.exe -File`, which is how
# the scheduled tasks run. That failed hidden, at logon, once (README trap 1).
# ---------------------------------------------------------------------------
$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }

$selfPath = Join-Path $here 'sessions-gui.ps1'
$xamlPath = Join-Path $here 'gui-window.xaml'

# ---------------------------------------------------------------------------
# WPF needs a single-threaded apartment. powershell.exe defaults to STA since v3,
# but a host that does not (an MTA runspace, some IDE terminals) would otherwise
# fail deep inside XamlReader with an unhelpful message. Re-launch ourselves once.
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
# DPI. This must run BEFORE the first top-level window exists, which is why it
# sits here and not in Add_SourceInitialized: process DPI awareness is fixed at
# the moment the first HWND is created and cannot be changed afterwards.
#
# Measured 2026-08-22, so the record is straight about what this does and does
# not fix: BOTH of this machine's monitors are 3440x1440 at 100 per cent scaling
# and report an effective DPI of 96. There is therefore NO bitmap scaling
# happening and DPI was NOT the cause of the text looking low resolution -- that
# was TextFormattingMode="Display" in the XAML, now Ideal. This block is
# correctness for a screen this window has not met yet: a 4K panel, a laptop at
# 150 per cent, or a second monitor at a different scale, where a system-aware
# process gets its window bitmap-stretched and every glyph goes soft.
#
# Measured on the same day: SetProcessDpiAwarenessContext returns TRUE here, so
# powershell.exe does NOT pin awareness in its manifest and this is allowed to
# take effect. It is still wrapped, because the call does not exist before
# Windows 10 1703 and both this and the AppContext switch are best-effort.
if (-not ('SRGui.Dpi' -as [type])) {
    Add-Type -Namespace SRGui -Name Dpi -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
'@
}
try {
    # WPF on .NET Framework only honours per-monitor DPI once this switch is off,
    # and it is read during WPF's static initialisation -- so it has to be set
    # before anything touches a visual.
    [System.AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false)
} catch { }
try {
    # -4 is DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2.
    $null = [SRGui.Dpi]::SetProcessDpiAwarenessContext([IntPtr](-4))
} catch { }

# The title bar is drawn by Windows, not by WPF, so a dark page inside a light
# frame is the default and it reads as a dialog rather than a tool. This is the
# documented way to ask for the dark frame (Windows 10 1809 and later); on
# anything older both calls fail and the window is simply light-framed.
if (-not ('SRGui.Dwm' -as [type])) {
    Add-Type -Namespace SRGui -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll", PreserveSig = true)]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
'@
}

# ---------------------------------------------------------------------------
# The row view model.
#
# One class for all three row kinds. WPF binds to properties with change
# notification, so a tick can repaint its row (and its project's counts) without
# rebuilding the list -- which is what keeps ~150 rows responsive. What differs
# between a project, a lane and a conversation is carried in these properties, not
# in three near-identical templates.
#
# Compiled with the in-box C# compiler. No modules, no packages, no downloads.
# ---------------------------------------------------------------------------
if (-not ('SRGui.Row' -as [type])) {
    # Referenced by the assemblies' real locations rather than by simple name, so
    # this does not depend on how the GAC resolves a short name.
    $srRefs = @(
        [System.Windows.Media.Brush].Assembly.Location,
        [System.Windows.Thickness].Assembly.Location,
        [System.Windows.DependencyObject].Assembly.Location,
        [System.Windows.Controls.ScrollViewer].Assembly.Location,
        # System.Xaml is not optional even though nothing here mentions XAML.
        # ScrollViewer implements System.Windows.Markup.IQueryAmbient, which lives
        # in System.Xaml, and the C# compiler refuses a type it cannot resolve on
        # an interface of a referenced type -- so `ScrollViewer sv = o as
        # ScrollViewer;` fails to compile with "the type IQueryAmbient is defined
        # in an assembly that is not referenced". The GUI died at startup on this.
        [System.Windows.Markup.IQueryAmbient].Assembly.Location
    ) | Sort-Object -Unique
    Add-Type -ReferencedAssemblies $srRefs -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace SRGui
{
    // Smooth wheel scrolling. A ScrollViewer has no animatable offset - both
    // VerticalOffset and ScrollToVerticalOffset are read-only / imperative - so
    // there is nothing for a Storyboard to target and the wheel jumps a fixed
    // step per notch. This attached property IS animatable, and its change
    // callback pushes each interpolated value into the ScrollViewer. Animating
    // it with an ease is what turns the jump into a glide.
    // One row of the PROJECT / LANE dropdowns. A real class rather than a
    // PSCustomObject with DisplayMemberPath: WPF reaches a plain object's
    // ToString() with no binding machinery at all, which is one fewer thing that
    // can silently render a list of type names.
    public class Choice
    {
        public string Label;
        public string Value;
        public Choice(string label, string value) { Label = label; Value = value; }
        public override string ToString() { return Label; }
    }

    public static class SmoothScroll
    {
        public static readonly DependencyProperty TargetOffsetProperty =
            DependencyProperty.RegisterAttached("TargetOffset", typeof(double), typeof(SmoothScroll),
                new PropertyMetadata(0.0, OnTargetOffsetChanged));

        public static void SetTargetOffset(DependencyObject o, double v) { o.SetValue(TargetOffsetProperty, v); }
        public static double GetTargetOffset(DependencyObject o) { return (double)o.GetValue(TargetOffsetProperty); }

        private static void OnTargetOffsetChanged(DependencyObject o, DependencyPropertyChangedEventArgs e)
        {
            ScrollViewer sv = o as ScrollViewer;
            if (sv != null) sv.ScrollToVerticalOffset((double)e.NewValue);
        }
    }

    public class Row : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        private void N(string p)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(p));
        }

        // Identity and the links back into the registry objects. Plain fields:
        // only PowerShell touches them, and nothing in the XAML binds to them.
        public string Kind = "";
        public string Key = "";
        public object Dir;
        public object Lane;
        public object Session;

        private double _rowHeight = 24;
        public double RowHeight { get { return _rowHeight; } set { if (_rowHeight != value) { _rowHeight = value; N("RowHeight"); } } }

        // THE TICK. Reopens at logon. Two-way bound to the checkbox; the list's
        // Checked/Unchecked handler is what pushes it into the registry.
        private bool _ticked;
        public bool Ticked { get { return _ticked; } set { if (_ticked != value) { _ticked = value; N("Ticked"); } } }

        private string _tickTip = "";
        public string TickTip { get { return _tickTip; } set { if (_tickTip != value) { _tickTip = value; N("TickTip"); } } }

        private Visibility _pinVisibility = Visibility.Collapsed;
        public Visibility PinVisibility { get { return _pinVisibility; } set { if (_pinVisibility != value) { _pinVisibility = value; N("PinVisibility"); } } }

        private Brush _pinBrush;
        public Brush PinBrush { get { return _pinBrush; } set { if (_pinBrush != value) { _pinBrush = value; N("PinBrush"); } } }

        private Thickness _indent;
        public Thickness Indent { get { return _indent; } set { if (!_indent.Equals(value)) { _indent = value; N("Indent"); } } }

        private Visibility _foldVisibility = Visibility.Collapsed;
        public Visibility FoldVisibility { get { return _foldVisibility; } set { if (_foldVisibility != value) { _foldVisibility = value; N("FoldVisibility"); } } }

        private string _name = "";
        public string Name { get { return _name; } set { if (_name != value) { _name = value; N("Name"); } } }

        // A struck-through name is a conversation whose transcript is gone. With
        // no colour available it is the structural marker that says "this can
        // never be launched", as opposed to merely "no evidence it is open".
        private TextDecorationCollection _nameDecorations;
        public TextDecorationCollection NameDecorations { get { return _nameDecorations; } set { if (_nameDecorations != value) { _nameDecorations = value; N("NameDecorations"); } } }

        private Brush _nameBrush;
        public Brush NameBrush { get { return _nameBrush; } set { if (_nameBrush != value) { _nameBrush = value; N("NameBrush"); } } }

        private FontWeight _nameWeight = FontWeights.Normal;
        public FontWeight NameWeight { get { return _nameWeight; } set { if (!_nameWeight.Equals(value)) { _nameWeight = value; N("NameWeight"); } } }

        private double _nameSize = 12.5;
        public double NameSize { get { return _nameSize; } set { if (_nameSize != value) { _nameSize = value; N("NameSize"); } } }

        private string _note = "";
        public string Note { get { return _note; } set { if (_note != value) { _note = value; N("Note"); } } }

        private Brush _noteBrush;
        public Brush NoteBrush { get { return _noteBrush; } set { if (_noteBrush != value) { _noteBrush = value; N("NoteBrush"); } } }

        private string _counts = "";
        public string Counts { get { return _counts; } set { if (_counts != value) { _counts = value; N("Counts"); } } }

        private Brush _countsBrush;
        public Brush CountsBrush { get { return _countsBrush; } set { if (_countsBrush != value) { _countsBrush = value; N("CountsBrush"); } } }

        private string _idShort = "";
        public string IdShort { get { return _idShort; } set { if (_idShort != value) { _idShort = value; N("IdShort"); } } }

        private string _age = "";
        public string Age { get { return _age; } set { if (_age != value) { _age = value; N("Age"); } } }

        private Brush _ageBrush;
        public Brush AgeBrush { get { return _ageBrush; } set { if (_ageBrush != value) { _ageBrush = value; N("AgeBrush"); } } }

        // LIVE certain / live inferred / GONE / blank = no evidence.
        private string _state = "";
        public string State { get { return _state; } set { if (_state != value) { _state = value; N("State"); } } }

        private Brush _stateBrush;
        public Brush StateBrush { get { return _stateBrush; } set { if (_stateBrush != value) { _stateBrush = value; N("StateBrush"); } } }

        private FontWeight _stateWeight = FontWeights.Normal;
        public FontWeight StateWeight { get { return _stateWeight; } set { if (!_stateWeight.Equals(value)) { _stateWeight = value; N("StateWeight"); } } }

        private string _stateTip = "";
        public string StateTip { get { return _stateTip; } set { if (_stateTip != value) { _stateTip = value; N("StateTip"); } } }

        private TextDecorationCollection _stateDecorations;
        public TextDecorationCollection StateDecorations { get { return _stateDecorations; } set { if (_stateDecorations != value) { _stateDecorations = value; N("StateDecorations"); } } }

        // The mark beside the state word: FILLED for a process holding the id
        // (certain), HOLLOW for a transcript that merely moved (inferred). Fill
        // versus outline reads at a glance where two greys would not.
        private Brush _dotFill;
        public Brush DotFill { get { return _dotFill; } set { if (_dotFill != value) { _dotFill = value; N("DotFill"); } } }

        private Brush _dotStroke;
        public Brush DotStroke { get { return _dotStroke; } set { if (_dotStroke != value) { _dotStroke = value; N("DotStroke"); } } }

        private Visibility _dotVisibility = Visibility.Collapsed;
        public Visibility DotVisibility { get { return _dotVisibility; } set { if (_dotVisibility != value) { _dotVisibility = value; N("DotVisibility"); } } }

        // GONE gets a drawn X rather than a typographic mark. Measured
        // 2026-08-22: a reviewer read the ID column as struck through on rows
        // that were plainly LIVE, because a mono hex id is a row of collinear
        // crossbars (0 8 a e 4) and at 10.5px they read as a rule. A thin line
        // is therefore too fragile to carry the one state that must never be
        // ambiguous. This X is a Path - vector geometry, not a font glyph - so
        // no hinting, size or font substitution can turn it into something else.
        private Visibility _goneMarkVisibility = Visibility.Collapsed;
        public Visibility GoneMarkVisibility { get { return _goneMarkVisibility; } set { if (_goneMarkVisibility != value) { _goneMarkVisibility = value; N("GoneMarkVisibility"); } } }

        private string _launchLabel = "Open";
        public string LaunchLabel { get { return _launchLabel; } set { if (_launchLabel != value) { _launchLabel = value; N("LaunchLabel"); } } }

        private bool _canLaunch = true;
        public bool CanLaunch { get { return _canLaunch; } set { if (_canLaunch != value) { _canLaunch = value; N("CanLaunch"); } } }

        private string _launchTip = "";
        public string LaunchTip { get { return _launchTip; } set { if (_launchTip != value) { _launchTip = value; N("LaunchTip"); } } }

        // ------------------------------------------------------------------
        // DOING: what the conversation is actually doing. A DIFFERENT QUESTION
        // from State/DotFill above, which answer "is anyone holding it".
        // Deliberately its own set of properties rather than more overloads on
        // the liveness ones, so nothing in the template can accidentally render
        // one as the other.
        // ------------------------------------------------------------------
        private string _conv = "";
        public string Conv { get { return _conv; } set { if (_conv != value) { _conv = value; N("Conv"); } } }

        private Brush _convBrush;
        public Brush ConvBrush { get { return _convBrush; } set { if (_convBrush != value) { _convBrush = value; N("ConvBrush"); } } }

        private FontWeight _convWeight = FontWeights.Normal;
        public FontWeight ConvWeight { get { return _convWeight; } set { if (!_convWeight.Equals(value)) { _convWeight = value; N("ConvWeight"); } } }

        private string _convTip = "";
        public string ConvTip { get { return _convTip; } set { if (_convTip != value) { _convTip = value; N("ConvTip"); } } }

        // A frozen Geometry, not a string. A TypeConverter runs when XAML is
        // PARSED, never on a runtime binding, so binding a path string to
        // Path.Data silently renders nothing at all.
        private Geometry _convGeometry;
        public Geometry ConvGeometry { get { return _convGeometry; } set { if (_convGeometry != value) { _convGeometry = value; N("ConvGeometry"); } } }

        private Visibility _convGlyphVisibility = Visibility.Collapsed;
        public Visibility ConvGlyphVisibility { get { return _convGlyphVisibility; } set { if (_convGlyphVisibility != value) { _convGlyphVisibility = value; N("ConvGlyphVisibility"); } } }

        // The fold chevron is ONE drawn path rotated, not two characters, so
        // folded and expanded are provably the same mark at two angles.
        private double _foldAngle;
        public double FoldAngle { get { return _foldAngle; } set { if (_foldAngle != value) { _foldAngle = value; N("FoldAngle"); } } }

        // The operator's last prompt, shown under the selected row. Not bound in
        // the list: it is far too long for a cell and would wreck the row rhythm.
        public string LastPrompt = "";
    }
}
'@
}

# ---------------------------------------------------------------------------
# Palette.
#
# MONOCHROME: black, white and greys, no hue anywhere. What used to be carried
# by colour is carried by VALUE (this ramp), WEIGHT and CASE (LIVE bold-upper is
# certain, live regular-lower is inferred), GLYPH (a filled square is a tick, a
# filled dot is a held session, a strikethrough is a conversation that can never
# be launched) and SURFACE (a lifted band for the selected row, hairline rules
# rather than tinting between column groups).
#
# The brushes are NOT defined here. They are read out of gui-window.xaml's
# resource dictionary by key once the window has loaded, so the row colours and
# the window chrome cannot drift apart and a palette change is one block in one
# file. $C is filled in by Read-Palette, below the window load.
# ---------------------------------------------------------------------------
$C = @{}
$Clear = [System.Windows.Media.Brushes]::Transparent
$Strike = [System.Windows.TextDecorations]::Strikethrough

# The fold chevron is drawn, not typed, so it is one mark at two angles rather
# than two different characters that a font substitution could take apart.
$FoldAngleOpen   = 90   # pointing down: expanded
$FoldAngleClosed = 0    # pointing right: folded away

# ---------------------------------------------------------------------------
# The DOING glyphs. Vector geometry, parsed once and FROZEN so every row can
# share one instance -- an unfrozen Freezable handed to 150 rows is 150 copies
# and a change-notification graph nobody wants.
#
# A vocabulary deliberately unlike the liveness marks beside them. Liveness uses
# a DOT (round, filled or hollow) and an X. State uses STROKES:
#   waiting      a chevron -- literally the prompt, pointing at you.
#   working      three bars of rising height -- activity.
#   summarising  three rules shrinking to a point -- compaction, which is what
#                the step actually is.
# Nothing here is round, and nothing beside it is a stroke figure, so the two
# columns cannot be read as one another even at a glance.
# ---------------------------------------------------------------------------
function New-SRGlyph { param([string]$Path)
    $g = [System.Windows.Media.Geometry]::Parse($Path)
    $g.Freeze()
    return $g
}
$GlyphWaiting     = New-SRGlyph 'M 2.5,0.5 L 7,5 L 2.5,9.5'
$GlyphWorking     = New-SRGlyph 'M 1,9.5 L 1,5.5 M 5,9.5 L 5,1 M 9,9.5 L 9,6.5'
$GlyphSummarising = New-SRGlyph 'M 0.5,1 L 9.5,1 M 2.5,5 L 7.5,5 M 4.5,9 L 5.5,9'

# Named rather than passed as strings: FontWeight is a struct behind a
# TypeConverter, and leaning on PowerShell's string coercion for it on every row
# is both slower and one silent failure away from a blank column.
$FW_Normal = [System.Windows.FontWeights]::Normal
$FW_Semi   = [System.Windows.FontWeights]::SemiBold
$V_Show    = [System.Windows.Visibility]::Visible
$V_Hide    = [System.Windows.Visibility]::Collapsed

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:cfg          = Get-SRConfig
$script:reg          = $null
$script:dirs         = @()
$script:showWt       = [bool]$script:cfg.includeWorktrees
$script:staleDays    = [double]$script:cfg.recencyDays
$script:collapsed    = @{}
$script:dirty        = $false
$script:exitMode     = $null

$script:running      = @{}   # sessionId -> a claude.exe holds it (certain)
$script:live         = @{}   # sessionId -> its transcript moved recently (inferred)
$script:launching    = @{}   # sessionId -> when we launched it (optimistic, expires)
$script:conv         = @{}   # sessionId -> what the TRANSCRIPT implies it is doing
$script:agents       = @{}   # sessionId -> what CLAUDE ITSELF says, for live ones
$script:unattributed = 0
$script:probedAt     = $null

# ---------------------------------------------------------------------------
# THE FILTERS. Every dimension the window shows, and one rule that has to hold
# for the whole thing to be predictable:
#
#   AND across dimensions, OR within one.
#
# So {waiting, working} + {ticked} means "(waiting OR working) AND ticked". An
# EMPTY set means that dimension is not filtering at all -- which is why these
# are hash sets rather than tri-state flags: "nothing chosen" and "everything
# chosen" have to be the same thing, or the operator would have to tick five
# chips to get back to where they started.
#
# Deliberately NOT a query builder. There is no OR across dimensions, no
# negation and no grouping; every one of those would buy an expressiveness
# nobody asked for at the cost of the one property that makes this usable --
# that the lit chips ARE the whole filter, readable in one glance.
# ---------------------------------------------------------------------------
$script:filter    = $null   # the text box
$script:fState    = @{}     # waiting | working | summarising | idle | unknown
$script:fLive     = @{}     # live | notlive | gone
$script:fTick     = @{}     # ticked | unticked
$script:fPin      = @{}     # pinned
$script:fAge      = @{}     # recent | stale
$script:fProject  = $null   # a project path, or $null for any
$script:fLane     = $null   # a lane name, or $null for any
$script:matchCount = 0
$script:totalCount = 0

$script:visCache     = @{}
$script:rows         = New-Object System.Collections.Generic.List[object]
$script:pendingSpawn = $null
$script:firstFill    = $true

# ---------------------------------------------------------------------------
# Ported helpers. Each cites the original in select-sessions.ps1, which is the
# functional specification for this window and which must not be edited.
# ---------------------------------------------------------------------------

# select-sessions.ps1 Get-Newest. Null-filtered, not just @()-wrapped: a function
# returning an empty array yields $null, and @($null) is an array of ONE $null,
# which sails past a .Count check and then dies in the sort.
function Get-Newest { param($Sessions)
    $s = @(@($Sessions) | Where-Object { $_ })
    if (-not $s.Count) { return [datetime]'1970-01-01' }
    $ordered = @($s | Where-Object { $_.lastActive } | Sort-Object { [datetime]$_.lastActive } -Descending)
    if (-not $ordered.Count) { return [datetime]'1970-01-01' }
    return [datetime]$ordered[0].lastActive
}

# select-sessions.ps1 Get-Visible. Memoised: several passes walk every project.
# Returned UNWRAPPED, so empty arrives as $null and Get-Newest survives it.
function Get-Visible { param($Dir)
    $hit = $script:visCache[[string]$Dir.path]
    if ($null -ne $hit) { return $hit }
    $v = if ($script:showWt) { @($Dir.sessions) } else { @(@($Dir.sessions) | Where-Object { $_.lane -ne 'worktree' }) }
    $script:visCache[[string]$Dir.path] = $v
    return $v
}

function Get-Age { param($Iso)
    $d = ((Get-Date) - [datetime]$Iso)
    if ($d.TotalDays -ge 1) { return ("{0}d" -f [int]$d.TotalDays) }
    return ("{0}h" -f [int]$d.TotalHours)
}
function Test-Stale { param($Iso) return (((Get-Date) - [datetime]$Iso).TotalDays -gt $script:staleDays) }

# Touching a conversation PINS it: the hourly roll then leaves it alone. Without
# this the scan would undo every hand-made choice within the hour and this window
# would be decorative. select-sessions.ps1 Set-Pin / Test-Pinned.
function Set-Pin { param($Session, [bool]$Value)
    if ($null -eq $Session.PSObject.Properties['pinned']) {
        $Session | Add-Member -NotePropertyName pinned -NotePropertyValue $Value -Force
    } else { $Session.pinned = $Value }
}
function Test-Pinned { param($Session) return ([bool]$Session.pinned) }

function Get-LaneName { param($Session)
    if ($Session.lane -eq 'worktree' -and $Session.worktree) { return $Session.worktree }
    return 'main'
}

# main first, then worktree lanes newest-first. select-sessions.ps1 Get-Lanes.
# Returns ,@(...) -- assign it, then wrap. Never pipe the call.
function Get-Lanes { param($Dir)
    $g = @(Get-Visible $Dir) | Group-Object -Property { Get-LaneName $_ }
    $out = @()
    $out += @($g | Where-Object { $_.Name -eq 'main' })
    $out += @($g | Where-Object { $_.Name -ne 'main' } | Sort-Object { Get-Newest $_.Group } -Descending)
    return ,@($out)
}

function Get-SessionCwd { param($Session, $Dir)
    if ($Session.cwd) { return $Session.cwd }
    return $Dir.path
}
function Get-SessionTitle { param($Session, $Dir)
    $t = $Session.title
    if ([string]::IsNullOrWhiteSpace($t)) { $t = (Split-Path (Get-SessionCwd $Session $Dir) -Leaf) }
    return $t
}

# select-sessions.ps1 Test-JustLaunched. The optimistic mark expires on the CLOCK,
# not on the next rescan: claude takes seconds to surface in Win32_Process and a
# row that reads idle in that gap invites a second, duplicate tab.
function Test-JustLaunched { param([string]$Id)
    $t = $script:launching[$Id]
    if (-not $t) { return $false }
    if (((Get-Date) - [datetime]$t).TotalSeconds -gt $SR_LaunchGraceSeconds) {
        $script:launching.Remove($Id)
        return $false
    }
    return $true
}

# select-sessions.ps1 Get-SessionState. GONE outranks everything: there is nothing
# to launch, so nothing else about the row matters.
function Get-SessionState { param($Session)
    $id = "$($Session.sessionId)".ToLower()
    if ($Session.gone)         { return 'gone' }
    if ($script:running[$id])  { return 'run' }
    if (Test-JustLaunched $id) { return 'new' }
    if ($script:live[$id])     { return 'act' }
    return ''
}

# The launch guard, with no side effects. This is select-sessions.ps1
# Invoke-LaunchSession -Preview, verbatim in behaviour: every check here is one
# restore-sessions.ps1 already applies, so this window, L in the terminal panel
# and the logon restore can never disagree. Returns $null to mean "it would go",
# otherwise the reason it would not.
function Get-LaunchBlock { param($Session, $Dir)
    $cwd = Get-SessionCwd $Session $Dir
    $id  = "$($Session.sessionId)".ToLower()
    if ($Session.gone) { return "its transcript is gone from disk - it can never be launched" }
    if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { return "directory no longer exists: $cwd" }
    $jsonl = Get-SRTranscriptPath -Dir $cwd -SessionId $Session.sessionId -Recorded $Session.jsonl
    if (-not (Test-Path -LiteralPath $jsonl)) { return "transcript missing for $($Session.sessionId.Substring(0,8)) - press Rescan" }
    if ($script:running[$id])  { return "already open in a running claude.exe" }
    if (Test-JustLaunched $id) { return "already launched a moment ago" }
    if ($script:live[$id])     { return "already live - its transcript was written less than $SR_LiveWindowMinutes min ago" }
    return $null
}

# The cheap half of the guard, for enabling the row's OPEN button on every
# repaint. It skips the two Test-Path calls, which would be 300 file stats across
# the list; the full guard above still runs when the button is actually pressed,
# and it is the one that names the reason.
function Test-RowLaunchable { param($Session)
    switch (Get-SessionState $Session) {
        'gone' { return $false }
        'run'  { return $false }
        'act'  { return $false }
        'new'  { return $false }
    }
    return $true
}

# select-sessions.ps1 Get-LiveInDirectory. What stops a new session being spawned
# onto a tree somebody is already working -- they would share the tree's git index.
#
# DIVERGENCE, deliberate: the original compares $cwd.TrimEnd('') which trims
# whitespace rather than a trailing separator, so `C:\foo` and `C:\foo\` read as
# different trees. This trims '\'.
function Get-LiveInDirectory { param([Parameter(Mandatory)][string]$Dir)
    $out = @()
    foreach ($d in @($script:dirs)) {
        foreach ($s in @($d.sessions)) {
            $cwd = if ($s.cwd) { $s.cwd } else { $d.path }
            if ($cwd -and ($cwd.TrimEnd('\') -ieq $Dir.TrimEnd('\')) -and ((Get-SessionState $s) -in @('run','act','new'))) {
                $out += $s
            }
        }
    }
    return ,@($out)
}

# select-sessions.ps1 Get-RowPath. A lane's path comes from its own sessions: a
# worktree lives somewhere else entirely, not under the project root.
function Get-RowPath { param($Row)
    switch ($Row.Kind) {
        'session' { return (Get-SessionCwd $Row.Session $Row.Dir) }
        'lane'    {
            $first = @($Row.Lane.Group)[0]
            if ($first) { return (Get-SessionCwd $first $Row.Dir) }
            return $Row.Dir.path
        }
        default   { return $Row.Dir.path }
    }
}

# select-sessions.ps1 Get-RowSessions. Every session a row covers, newest first.
# Returns ,@(...) -- assign, then wrap. Piping the call hands ForEach-Object the
# whole array as ONE item, which is how a project row once built a single entry
# holding every session at once.
function Get-RowSessions { param($Row)
    $out = switch ($Row.Kind) {
        'session' { @($Row.Session) }
        'lane'    { @($Row.Lane.Group) }
        default   { @(Get-Visible $Row.Dir) }
    }
    return ,@($out | Sort-Object { [datetime]$_.lastActive } -Descending)
}

# select-sessions.ps1 Invoke-SpawnNew's naming rule, so a session spawned from
# this window and one spawned from the shell are indistinguishable afterwards.
function Resolve-SpawnName { param([string]$Dir, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = (Split-Path $Dir -Leaf) + '-' + (Get-Date -Format 'MMdd-HHmm') }
    $Name = ($Name -replace '\s+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = 'claude-' + (Get-Date -Format 'MMdd-HHmm') }
    return $Name
}

# What _common.ps1 Get-SRConversationState last said about this conversation, or
# $null before the first probe has landed.
# claude's own answer where there is a process to ask, the transcript tail where
# there is not. Measured 2026-08-22 across the 13 live sessions on this machine:
# THE TRANSCRIPT DISAGREED WITH CLAUDE ON SEVEN OF THEM. It called four idle
# sessions "working", one busy session "waiting", and it cannot see a permission
# dialog at all -- a dialog writes nothing to a transcript, so a session sitting
# on one is indistinguishable from a session mid-tool-call. That is the case the
# operator most wants to see, which is why inference lost.
#
# The tail is still the right answer for a conversation that is NOT running:
# there is no process to ask, and a last-known state beats nothing.
function Get-Conv { param($Session)
    if (-not $Session -or -not $Session.sessionId) { return $null }
    $key = "$($Session.sessionId)".ToLower()
    $a = $script:agents[$key]
    $c = $script:conv[$key]
    if (-not $a -and -not $c) { return $null }
    return (Resolve-SRSessionState -Agent $a -Conv $c)
}

# The bucket a conversation falls in for the DOING dimension.
#
# This is a PARTITION: every conversation is in exactly one bucket, so the chips
# never overlap, OR-within-the-dimension adds up, and the counts cannot
# double-count. That is the whole reason 'idle' exists here and does not exist in
# _common.ps1: Get-SRConversationState returns the LAST state a conversation was
# seen in plus a Stale flag, deliberately, so that the last-known state is not
# thrown away. Measured 2026-08-22 across all 119 conversations: 113 of them are
# stale. Collapsing those into one bucket in the DISPLAY would erase almost
# everything the function works to preserve, so the display keeps the state word
# and marks staleness with "was". The FILTER is the one place a flat partition is
# worth more than the detail, because a chip has to select a set the operator can
# point at: 'idle' selects exactly the rows that read "was ...".
function Get-ConvBucket { param($Session)
    # $cv rather than $c: see the note in Update-RowConv. $c IS $C, the palette.
    $cv = Get-Conv $Session
    if (-not $cv) { return 'unknown' }
    $s = "$($cv.State)"
    if ($s -eq 'unknown' -or -not $s) { return 'unknown' }
    # 'idle' is claude's own word now -- at its prompt, nothing pending -- rather
    # than the staleness collapse it used to be. A conversation that is NOT
    # running is not idle, it is a last-known state, and it buckets as that.
    if ($cv.Stale -and $s -ne 'idle') { return $s }
    return $s
}

# Is anything filtering at all? A fold is IGNORED while it is, because hiding the
# very rows that were searched for is the one thing a filter must never do.
function Test-AnyFilter {
    return [bool]($script:filter -or $script:fProject -or $script:fLane -or
                  $script:fState.Count -or $script:fLive.Count -or $script:fTick.Count -or
                  $script:fPin.Count -or $script:fAge.Count)
}

# select-sessions.ps1 Test-RowMatch, widened to every dimension this window
# shows. The text box is one clause among several now and composes with the rest.
#
# AND across dimensions, OR within one. An EMPTY dimension does not filter -- so
# "no chips lit" and "every chip lit" mean the same thing, which is what keeps a
# half-set filter from silently hiding rows.
function Test-RowMatch { param($Session, $Dir, $Lane)
    # Text. Same fields -Launch matches on, so what you can find here you can
    # also launch by name from the terminal.
    if ($script:filter) {
        $f = $script:filter
        $hit = $false
        foreach ($hay in @($Session.title, $Session.sessionId, $Lane, (Split-Path $Dir.path -Leaf), $Dir.path)) {
            if ("$hay" -like "*$f*") { $hit = $true; break }
        }
        if (-not $hit) { return $false }
    }

    if ($script:fProject -and ("$($Dir.path)" -ne $script:fProject)) { return $false }
    if ($script:fLane    -and ("$Lane" -ne $script:fLane))           { return $false }

    if ($script:fState.Count -and -not $script:fState[(Get-ConvBucket $Session)]) { return $false }

    if ($script:fLive.Count) {
        # LIVENESS, not state. run / act / new are all "something is holding it";
        # the certain-versus-inferred distinction matters on the row, not here.
        $l = switch (Get-SessionState $Session) {
            'gone'  { 'gone' }
            'run'   { 'live' }
            'act'   { 'live' }
            'new'   { 'live' }
            default { 'notlive' }
        }
        if (-not $script:fLive[$l]) { return $false }
    }

    if ($script:fTick.Count) {
        $t = $(if ($Session.enabled) { 'ticked' } else { 'unticked' })
        if (-not $script:fTick[$t]) { return $false }
    }

    if ($script:fPin.Count -and -not (Test-Pinned $Session)) { return $false }

    if ($script:fAge.Count) {
        # The band the tool already understands: recencyDays, the same rule that
        # puts STALE on a row.
        $a = $(if (Test-Stale $Session.lastActive) { 'stale' } else { 'recent' })
        if (-not $script:fAge[$a]) { return $false }
    }

    return $true
}

# ---------------------------------------------------------------------------
# Background work. The scan re-reads every changed transcript and the liveness
# probe is a WMI round trip; both belong off the UI thread. Workers dot-source
# _common.ps1 themselves and talk to the registry through its named mutex, so
# they are safe against the hourly task and a concurrent restore exactly as any
# other process is.
# ---------------------------------------------------------------------------
$script:jobPs     = $null
$script:jobRs     = $null
$script:jobHandle = $null
$script:jobDone   = $null
$script:jobName   = $null

function Start-SRJob {
    param(
        [Parameter(Mandatory)][scriptblock]$Body,
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Data = @{},
        [scriptblock]$OnDone
    )
    if ($script:jobPs) { return $false }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('SRHere', $script:here)
    $rs.SessionStateProxy.SetVariable('SRData', $Data)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($Body)
    $script:jobPs     = $ps
    $script:jobRs     = $rs
    $script:jobDone   = $OnDone
    $script:jobName   = $Name
    $script:jobHandle = $ps.BeginInvoke()
    Set-Busy $Name
    return $true
}

function Complete-SRJob {
    if (-not $script:jobPs -or -not $script:jobHandle.IsCompleted) { return }
    $out = $null; $err = $null
    try { $out = $script:jobPs.EndInvoke($script:jobHandle) }
    catch { $err = $_.Exception.Message }
    if (-not $err -and $script:jobPs.Streams.Error.Count) {
        $err = ($script:jobPs.Streams.Error | Select-Object -First 1).ToString()
    }
    $done = $script:jobDone
    try { $script:jobPs.Dispose() } catch { }
    try { $script:jobRs.Close(); $script:jobRs.Dispose() } catch { }
    $script:jobPs = $null; $script:jobRs = $null; $script:jobHandle = $null; $script:jobDone = $null
    Set-Busy ''
    if ($err) {
        Write-SRLog "gui job '$script:jobName' failed: $err"
        Set-Status "$script:jobName failed: $err" 'bad'
        return
    }
    if ($done) { & $done (@($out) | Select-Object -Last 1) }
}

# Scan + probe in one pass, so opening or refreshing costs a single round trip.
$script:ScanJob = {
    . (Join-Path $SRHere '_common.ps1')
    $cfg = Get-SRConfig
    $r = $null
    if (-not $SRData.NoScan) {
        try { $r = Update-SRRegistry -Config $cfg -Quiet } catch { }
    }
    if (-not $r) { $r = Get-SRRegistry }
    $running = Get-SRRunningIds -Refresh
    $unattr  = Get-SRUnattributedCount
    $live    = @{}
    $conv    = @{}
    foreach ($d in @($r.directories)) {
        foreach ($s in @($d.sessions)) {
            if (-not $s.sessionId) { continue }
            $cwd = if ($s.cwd) { $s.cwd } else { $d.path }
            # Resolved once and used twice. Liveness is a file mtime; DOING reads
            # the tail of the same file, ~3.5 ms each measured across 121
            # conversations, so it rides along rather than costing its own pass.
            $j   = Get-SRTranscriptPath -Dir $cwd -SessionId $s.sessionId -Recorded $s.jsonl
            $key = "$($s.sessionId)".ToLower()
            if (Test-SRTranscriptLive -JsonlPath $j) { $live[$key] = $true }
            try { $conv[$key] = Get-SRConversationState -JsonlPath $j } catch { }
        }
    }
    # What claude itself says, which beats inference for anything still running.
    # ~960 ms, so it belongs here on the background pass and nowhere near a repaint.
    $agents = Get-SRAgentStatus -Refresh
    [PSCustomObject]@{ Registry = $r; Config = $cfg; Running = $running; Live = $live; Conv = $conv; Agents = $agents; Unattributed = $unattr; At = (Get-Date) }
}

# Liveness only. No scan, nothing written, nothing launched.
$script:ProbeJob = {
    . (Join-Path $SRHere '_common.ps1')
    $running = Get-SRRunningIds -Refresh
    $unattr  = Get-SRUnattributedCount
    $live    = @{}
    $conv    = @{}
    foreach ($s in @($SRData.Sessions)) {
        $j   = Get-SRTranscriptPath -Dir $s.Cwd -SessionId $s.Id -Recorded $s.Jsonl
        $key = "$($s.Id)".ToLower()
        if (Test-SRTranscriptLive -JsonlPath $j) { $live[$key] = $true }
        # DOING has to refresh on the same cadence as liveness or the column
        # would freeze at whatever it said when the window opened, while the
        # "as of" stamp beside it kept moving. That reads as a lie.
        try { $conv[$key] = Get-SRConversationState -JsonlPath $j } catch { }
    }
    $agents = Get-SRAgentStatus -Refresh
    [PSCustomObject]@{ Running = $running; Live = $live; Conv = $conv; Agents = $agents; Unattributed = $unattr; At = (Get-Date) }
}

# Launching. Windows Terminal needs breathing room between tabs, and a launch
# reports only that wt.exe started -- the tab's CHILD is what fails -- so the ids
# are polled for afterwards and the ones that never appeared are named.
$script:LaunchJob = {
    . (Join-Path $SRHere '_common.ps1')
    $ok = @(); $fail = @()
    foreach ($it in @($SRData.Items)) {
        try {
            $boot = New-SRBootScript -Dir $it.Cwd -SessionId $it.Id -Title $it.Title
            Start-SRSession -Dir $it.Cwd -BootScript $boot -Title $it.Title
            Write-SRLog ("  [ok]   gui launch   {0}  {1}  {2}" -f $it.Title, $it.Id, $it.Cwd)
            $ok += $it.Id
        } catch {
            Write-SRLog ("  [FAIL] gui launch   {0}  {1}" -f $it.Title, $_.Exception.Message)
            $fail += ("{0}: {1}" -f $it.Title, $_.Exception.Message)
        }
        Start-Sleep -Milliseconds 500
    }
    $never = @()
    if ($ok.Count) { $n = Wait-SRSessionsUp -SessionIds $ok; $never = @($n) }
    [PSCustomObject]@{ Ok = @($ok); Fail = @($fail); Never = @($never) }
}

$script:SpawnJob = {
    . (Join-Path $SRHere '_common.ps1')
    try {
        $boot = New-SRBootScript -Dir $SRData.Dir -Title $SRData.Name
        Start-SRSession -Dir $SRData.Dir -BootScript $boot -Title $SRData.Name
        Write-SRLog ("  [ok]   gui spawn    {0}  {1}" -f $SRData.Name, $SRData.Dir)
        [PSCustomObject]@{ Ok = $true; Why = $null }
    } catch {
        Write-SRLog ("  [FAIL] gui spawn    {0}  {1}" -f $SRData.Name, $_.Exception.Message)
        [PSCustomObject]@{ Ok = $false; Why = $_.Exception.Message }
    }
}

$script:WorktreeJob = {
    . (Join-Path $SRHere '_common.ps1')
    try { $null = Set-SRIncludeWorktrees -Value ([bool]$SRData.Value); [PSCustomObject]@{ Ok = $true; Why = $null } }
    catch { [PSCustomObject]@{ Ok = $false; Why = $_.Exception.Message } }
}

# ---------------------------------------------------------------------------
# The window
# ---------------------------------------------------------------------------
# Both failures below are fatal before there is a window to say so in, and the
# launcher runs hidden -- so they go to the log as well as the console. That log
# is the file to read when the GUI seems to do nothing.
if (-not (Test-Path -LiteralPath $xamlPath)) {
    Write-SRLog "gui: gui-window.xaml is missing from $here"
    Write-Error "gui-window.xaml is missing from $here - the GUI cannot be built without it."
    exit 1
}
try {
    $reader = [System.Xml.XmlReader]::Create((New-Object System.IO.StringReader ([System.IO.File]::ReadAllText($xamlPath))))
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
} catch {
    Write-SRLog "gui: could not parse gui-window.xaml - $($_.Exception.Message)"
    Write-Error "could not parse gui-window.xaml: $($_.Exception.Message)"
    exit 1
}

# The greyscale ramp, read back out of the XAML by key. One definition, in the
# PALETTE block of gui-window.xaml; nothing here invents a colour of its own.
# A missing key is fatal rather than silently $null: a row with no brush renders
# as invisible text, which is a bug that looks like a blank column.
# The type system, read back the same way the palette is: one definition, in the
# XAML, and nothing here invents a face of its own.
$script:UiFace   = $window.TryFindResource('FontText')
$script:MonoFace = $window.TryFindResource('FontMono')
if (-not $script:UiFace -or -not $script:MonoFace) { throw 'gui-window.xaml is missing FontText or FontMono' }

foreach ($k in @('TextMax','TextHigh','TextMid','TextLow','TextDim','Hairline','HairlineHi','Ink','Panel','Raised')) {
    $b = $window.TryFindResource($k)
    if (-not $b) { throw "gui-window.xaml is missing the palette brush '$k'" }
    $C[$k] = $b
}

$ui = @{}
foreach ($n in @(
    'SubTitle','SearchBox','ClearSearch','BusyText','RescanBtn','LiveSummary','TickSummary',
    'ProbeStamp','Unattributed','TickAll','TickNone','UnpinAll','CollapseAll','ExpandAll',
    'WorktreeToggle','LaunchTicked','RowList','EmptyNote','SelName','SelPath','SelTick',
    'SelUnpin','SelLaunch','SelSpawn','StatusText','CancelBtn','SaveBtn','Overlay','OvTitle',
    'OvPath','OvWarnBox','OvWarn','OvName','OvCancel','OvOk',
    'ConfirmOverlay','CfTitle','CfMessage','CfNoteBox','CfNote','CfCancel','CfOk',
    # The filter row and the state summary. Every one of these exists in the XAML;
    # they were simply never added here, so $ui.<name> was $null and the first
    # assignment to one of them took the whole window down at startup with
    # "The property 'Text' cannot be found on this object". A name that is in the
    # markup but not in this list fails at RUNTIME and says nothing about which
    # element it was -- so keep the two in step.
    'WaitSummary','FilterCount','ClearFilters','ProjectFilter','LaneFilter',
    'FlLive','FlNot','FlGone',
    'FsWaiting','FsWorking','FsSumm','FsIdle','FsUnknown',
    'FtOn','FtOff','FpPin','FaRecent','FaStale',
    'ListShift','NeedsBand','NeedsLabel','NeedsList',
    'ReadPane','ReadName','ReadWhat','ReadView','ReadBack','ReadRefresh','ReadOpen'
)) { $ui[$n] = $window.FindName($n) }

# A name in the markup that is not in the list above is $null here, and the
# failure surfaces far away as a missing property. Say so at startup instead.
$uiMissing = @($ui.Keys | Where-Object { $null -eq $ui[$_] } | Sort-Object)
if ($uiMissing.Count) {
    throw ("these named elements are not in gui-window.xaml: " + ($uiMissing -join ', '))
}

$script:here = $here
$script:busyButtons = @(
    $ui.RescanBtn, $ui.TickAll, $ui.TickNone, $ui.UnpinAll, $ui.LaunchTicked,
    $ui.SelTick, $ui.SelUnpin, $ui.SelLaunch, $ui.SelSpawn, $ui.SaveBtn, $ui.WorktreeToggle
)

function Set-Busy { param([string]$What)
    $script:busy = [bool]$What
    $ui.BusyText.Text = $(if ($What) { $What + ' ...' } else { '' })
    foreach ($b in $script:busyButtons) { if ($b) { $b.IsEnabled = -not $script:busy } }
    $window.Cursor = $(if ($script:busy) { [System.Windows.Input.Cursors]::AppStarting } else { $null })
    # The four selection buttons are only meaningful with a row under them, and
    # re-enabling everything above would have handed them back with nothing selected.
    if (-not $script:busy) { Update-Selection }
}

# Four tones, and with no colour to spend they are told apart by VALUE plus, for
# the one that matters, a mark. A failure is the most important thing that can
# appear here, so it takes the brightest grey on the screen AND a leading '!' --
# brightness alone would only say "important", not "wrong".
#   bad   something did not work, or will not
#   warn  it did not happen, and here is why
#   ok    it happened
#   info  neutral running commentary
function Set-Status { param([string]$Message, [string]$Tone = 'info')
    switch ($Tone) {
        'bad'  { $ui.StatusText.Text = $(if ($Message) { '!  ' + $Message } else { '' }); $ui.StatusText.Foreground = $C.TextMax }
        'warn' { $ui.StatusText.Text = $Message; $ui.StatusText.Foreground = $C.TextHigh }
        'ok'   { $ui.StatusText.Text = $Message; $ui.StatusText.Foreground = $C.TextHigh }
        default { $ui.StatusText.Text = $Message; $ui.StatusText.Foreground = $C.TextMid }
    }
}

# TRAP: PowerShell SWALLOWS an exception thrown inside a WPF event handler. It is
# not on any pipeline, so it reaches neither the console nor the dispatcher's
# unhandled-exception path -- the button simply does nothing, forever, and says
# nothing about why. Measured 2026-08-22: "Launch everything ticked" was inert and
# left no trace anywhere. Every handler goes through here instead, so a failure
# lands on the status line and in .state\restore.log.
function Invoke-Guarded { param([Parameter(Mandatory)][scriptblock]$Body, [string]$What = 'that')
    try { & $Body }
    catch {
        Write-SRLog ("gui: {0} failed - {1}" -f $What, $_.Exception.Message)
        try { Set-Status ("{0} failed: {1}" -f $What, $_.Exception.Message) 'bad' } catch { }
    }
}

# ---------------------------------------------------------------------------
# Building the rows. Same shape as select-sessions.ps1 Build-Rows: while
# filtering, a project or lane is kept only if something under it survived --
# an empty repo header is just noise -- and a fold is ignored, because it would
# hide the very rows that were searched for.
# ---------------------------------------------------------------------------
function New-Row { param([string]$Kind, [string]$Key, $Dir, $Lane, $Session)
    $r = New-Object SRGui.Row
    $r.Kind = $Kind; $r.Key = $Key; $r.Dir = $Dir; $r.Lane = $Lane; $r.Session = $Session
    return $r
}

function Build-Rows {
    $out = New-Object System.Collections.Generic.List[object]
    $filtering = Test-AnyFilter
    # Counted here rather than in a second pass: this loop already visits every
    # conversation exactly once and already knows which ones survived.
    $matched = 0; $total = 0
    foreach ($d in $script:dirs) {
        $sub = New-Object System.Collections.Generic.List[object]
        $lanes = Get-Lanes $d
        foreach ($lane in @($lanes)) {
            $lkey = "$($d.path)|$($lane.Name)"
            $kids = New-Object System.Collections.Generic.List[object]
            foreach ($s in (@($lane.Group) | Sort-Object { [datetime]$_.lastActive } -Descending)) {
                $total++
                if (-not (Test-RowMatch -Session $s -Dir $d -Lane $lane.Name)) { continue }
                $matched++
                $kids.Add((New-Row 'session' "$lkey|$($s.sessionId)" $d $lane $s))
            }
            if ($filtering -and $kids.Count -eq 0) { continue }
            $sub.Add((New-Row 'lane' $lkey $d $lane $null))
            if (-not $filtering -and $script:collapsed[$lkey]) { continue }
            foreach ($k in $kids) { $sub.Add($k) }
        }
        if ($filtering -and $sub.Count -eq 0) { continue }
        $out.Add((New-Row 'dir' $d.path $d $null $null))
        if (-not $filtering -and $script:collapsed[$d.path]) { continue }
        foreach ($s in $sub) { $out.Add($s) }
    }
    $script:matchCount = $matched
    $script:totalCount = $total
    return ,$out
}

# Everything about a row that depends on the TICKS: the checkbox, the counts, the
# pin, the name's weight and colour. No file access, so this can run on every
# click without the list feeling heavy.
function Update-RowTicks { param($Row)
    switch ($Row.Kind) {
        'dir' {
            $d = $Row.Dir
            $v = @(Get-Visible $d)
            $n = @($v | Where-Object { $_.enabled }).Count
            $Row.Ticked  = [bool]$d.enabled -and -not $d.missing
            $Row.Counts  = "{0}/{1}" -f $n, $v.Count
            $Row.CountsBrush = $(if ($d.enabled -and $n -gt 0) { $C.TextHigh } else { $C.TextDim })
            $Row.NameBrush = $(if ($d.missing) { $C.TextDim } elseif ($d.enabled) { $C.TextMax } else { $C.TextLow })
            $Row.TickTip = "Project master tick. Untick it and nothing in this repo reopens at logon, whatever its conversations say."
        }
        'lane' {
            $g = @($Row.Lane.Group)
            $n = @($g | Where-Object { $_.enabled }).Count
            $Row.Ticked = ($g.Count -gt 0 -and $n -eq $g.Count)
            $Row.Counts = "{0}/{1}" -f $n, $g.Count
            $Row.CountsBrush = $(if ($n -gt 0) { $C.TextHigh } else { $C.TextDim })
            $Row.TickTip = "Tick or untick every conversation in this lane, and pin them."
        }
        'session' {
            $d = $Row.Dir; $s = $Row.Session
            $Row.Ticked = [bool]$s.enabled
            $Row.PinVisibility = $(if (Test-Pinned $s) { $V_Show } else { $V_Hide })
            $Row.PinBrush = $C.TextHigh
            $Row.AgeBrush = $(if (Test-Stale $s.lastActive) { $C.TextMid } else { $C.TextDim })
            $Row.TickTip = "Reopen this conversation at the next logon. Ticking pins it, so the hourly roll leaves it alone. It does NOT open anything now."
            Update-RowName $Row
        }
    }
}

# A conversation's name is where the value ramp does most of its work, and it
# depends on the tick AND on the live probe -- so it is computed in one place
# and called from both refresh paths rather than half-set by each.
#
# Brightest to dimmest, most important first:
#   live now      TextMax   the thing you are most likely to be looking for
#   ticked        TextHigh  comes back at logon
#   ticked, stale TextMid   comes back, but has not been touched in a while
#   not ticked    TextLow   known, not coming back
#   project off   TextDim   its project is switched off, so the tick is moot
#   gone          TextDim + STRUCK THROUGH -- not merely quiet: unlaunchable.
function Update-RowName { param($Row)
    if ($Row.Kind -ne 'session') { return }
    $d = $Row.Dir; $s = $Row.Session
    $st = Get-SessionState $s
    if ($st -eq 'gone') {
        $Row.NameBrush = $C.TextDim
        $Row.NameDecorations = $Strike
        return
    }
    $Row.NameDecorations = $null
    $Row.NameBrush =
        if (-not $d.enabled)             { $C.TextDim }
        elseif ($st -in @('run','act','new')) { $C.TextMax }
        elseif (-not $s.enabled)         { $C.TextLow }
        elseif (Test-Stale $s.lastActive){ $C.TextMid }
        else                             { $C.TextHigh }
}

# Everything about a row that depends on the PROBES and the clock: the live mark,
# the notes, whether OPEN is available.
function Update-RowLive { param($Row)
    switch ($Row.Kind) {
        'dir' {
            $d = $Row.Dir
            $v = @(Get-Visible $d)
            $liveN = @($v | Where-Object { (Get-SessionState $_) -in @('run','act','new') }).Count
            $Row.Note = $(if ($d.missing) { 'MISSING' } elseif ($liveN -gt 0) { "$liveN live" } else { '' })
            $Row.NoteBrush = $(if ($d.missing) { $C.TextMid } else { $C.TextHigh })
            $Row.CanLaunch = (@($v | Where-Object { Test-RowLaunchable $_ }).Count -gt 0)
            $Row.LaunchTip = "Open every conversation in this project that is not already open. Confirmed by count first. Ticks are not consulted."
        }
        'lane' {
            $g = @($Row.Lane.Group)
            $n = @($g | Where-Object { $_.enabled }).Count
            # Two conversations in ONE tree share a git index. Main and each
            # worktree are DIFFERENT trees, so they are counted separately.
            $Row.Note = $(if ($Row.Dir.enabled -and $n -ge 2) { "$n in one tree" } else { '' })
            $Row.NoteBrush = $C.TextMid
            $Row.CanLaunch = (@($g | Where-Object { Test-RowLaunchable $_ }).Count -gt 0)
            $Row.LaunchTip = "Open every conversation in this lane that is not already open. Ticks are not consulted."
        }
        'session' {
            $d = $Row.Dir; $s = $Row.Session
            $st = Get-SessionState $s
            # Three channels at once, because one grey against another is not
            # enough on its own: CASE and WEIGHT (LIVE bold-upper is certain,
            # live regular-lower is inferred), the DOT (filled = a process holds
            # the id, hollow = only the transcript moved), and VALUE.
            $Row.StateDecorations = $null
            $Row.DotVisibility = $V_Show
            $Row.GoneMarkVisibility = $V_Hide
            switch ($st) {
                'run'  { $Row.State = 'LIVE'; $Row.StateBrush = $C.TextMax; $Row.StateWeight = $FW_Semi
                         $Row.DotFill = $C.TextMax; $Row.DotStroke = $C.TextMax
                         $Row.StateTip = 'A running claude.exe carries this id on its command line. Certain. Filled mark, upper case.' }
                'act'  { $Row.State = 'live'; $Row.StateBrush = $C.TextLow; $Row.StateWeight = $FW_Normal
                         $Row.DotFill = $Clear; $Row.DotStroke = $C.TextLow
                         $Row.StateTip = "Its transcript was written in the last $SR_LiveWindowMinutes minutes. Inferred, not certain. Hollow mark, lower case." }
                'new'  { $Row.State = '..';   $Row.StateBrush = $C.TextLow; $Row.StateWeight = $FW_Normal
                         $Row.DotFill = $Clear; $Row.DotStroke = $C.TextDim
                         $Row.StateTip = 'Just launched from here. claude takes a few seconds to appear in the process table.' }
                # Four independent signals, and the primary one is the drawn X,
                # NOT a line: a struck-through word at 11px is exactly the mark a
                # reviewer already mistook a mono hex id for. The strikethrough on
                # the NAME stays - measured 100% contiguous across the whole run,
                # unmistakable at 12.5px - but it is now corroboration, not the
                # thing GONE rests on.
                'gone' { $Row.State = 'GONE'; $Row.StateBrush = $C.TextMid; $Row.StateWeight = $FW_Semi
                         $Row.StateDecorations = $null
                         $Row.DotVisibility = $V_Hide
                         $Row.GoneMarkVisibility = $V_Show
                         $Row.StateTip = 'Its transcript is no longer on disk. It can NEVER be launched, and the roll will not spend a lane budget on it. Marked four ways: the X, the word GONE, the struck-through name, and a dead Open button.' }
                default { $Row.State = ''; $Row.StateBrush = $C.TextDim; $Row.StateWeight = $FW_Normal
                          $Row.DotVisibility = $V_Hide
                          $Row.StateTip = 'No evidence it is open - which is not the same as closed. A bare claude that resumed later carries no id, and an idle session writes nothing.' }
            }
            $note = ''
            # Spelled out rather than left to a mark: without colour, "gone" has
            # to say what it means somewhere the operator can read it.
            if ($st -eq 'gone') { $note = 'cannot be launched' }
            elseif (-not $d.enabled) { $note = '(project off)' }
            elseif ($s.enabled -and (Test-Stale $s.lastActive)) { $note = 'STALE' }
            $Row.Note = $note
            $Row.NoteBrush = $(if ($st -eq 'gone') { $C.TextMid } else { $C.TextLow })
            $Row.CanLaunch = (Test-RowLaunchable $s)
            $Row.LaunchTip = $(if ($Row.CanLaunch) { 'Open this conversation NOW, in its own tab, whatever its tick says.' } else { 'Nothing to open: it already looks live, or its transcript is gone.' })
            Update-RowName $Row
        }
    }
}

# ---------------------------------------------------------------------------
# DOING. What the conversation is actually doing, from _common.ps1
# Get-SRConversationState.
#
# THIS IS NOT LIVENESS AND MUST NEVER READ AS IT. Update-RowLive above answers
# "is a process holding this conversation"; this answers "what is that process
# doing". They are independent: a conversation can be LIVE and waiting, LIVE and
# working, or not live at all and still carry the last state it was seen in.
# They are kept apart in four ways at once -- separate view-model properties so
# the template cannot cross them, a separate column behind its own rule, a
# proportional face against the liveness column's mono, and a vocabulary of
# stroke glyphs against its dots and X.
#
# now versus then. Get-SRConversationState returns the LAST state a conversation
# was seen in plus Stale. Measured 2026-08-22 over all 119 conversations, 113 are
# stale -- so rendering only what is CURRENT would leave 113 rows saying nothing
# and would throw away the very distinction that function exists to keep. The
# word is therefore always the last-known state, and staleness is carried by the
# literal word "was" plus a drop to TextLow. Six bright rows against 113 dim ones
# is exactly the thing the operator asked to be able to see.
# ---------------------------------------------------------------------------
function Update-RowConv { param($Row)
    switch ($Row.Kind) {
        'session' {
            $s = $Row.Session
            # $cv, NOT $c. PowerShell variable names are CASE-INSENSITIVE, so a
            # local $c is the same variable as the palette $C -- assigning to it
            # here replaced the brush table with a conversation-state object for
            # the rest of this function, every $C.TextHigh came back $null, and a
            # TextBlock with a null Foreground draws NOTHING. The column was
            # populated and invisible: 'working' was in the row, correctly, and
            # the screen was blank. Only the rollup branch rendered, because it
            # never declares a $c.
            $cv = Get-Conv $s
            $Row.ConvWeight = $FW_Normal
            $Row.ConvGeometry = $null
            $Row.ConvGlyphVisibility = $V_Hide
            $Row.LastPrompt = ''

            if (-not $cv) {
                $Row.Conv = ''
                $Row.ConvBrush = $C.TextDim
                $Row.ConvTip = 'Not read yet. The state of every conversation is read on the background pass, alongside the liveness probe.'
                return
            }

            $Row.LastPrompt = "$($cv.LastPrompt)"
            # 'idle' now comes from claude and means something specific: at its
            # prompt with nothing pending. That is NOT the same as 'waiting',
            # which means it is actively asking you for something.
            $word = switch ("$($cv.State)") {
                'waiting'     { 'waiting' }
                'working'     { 'working' }
                'summarising' { 'summarising' }
                'idle'        { 'idle' }
                default       { '' }
            }
            $geom = switch ("$($cv.State)") {
                'waiting'     { $GlyphWaiting }
                'working'     { $GlyphWorking }
                'summarising' { $GlyphSummarising }
                'idle'        { $null }
                default       { $null }
            }

            if (-not $word) {
                # Blank, exactly as an unknown LIVENESS is blank: no evidence is
                # not a state, and inventing a word for it would be a lie with a
                # glyph on it.
                $Row.Conv = ''
                $Row.ConvBrush = $C.TextDim
            } elseif ($cv.Stale) {
                $Row.Conv = 'was ' + $word
                $Row.ConvBrush = $C.TextLow
                $Row.ConvGeometry = $geom
                $Row.ConvGlyphVisibility = $V_Show
            } else {
                $Row.Conv = $word
                $Row.ConvGeometry = $geom
                $Row.ConvGlyphVisibility = $V_Show
                # Waiting is the loudest thing this column can say: it is the one
                # state that is asking the operator for something.
                if ($cv.Needs) {
                    # It is asking for something RIGHT NOW -- input, or an answer
                    # to a dialog. Nothing else on this screen outranks that.
                    $Row.ConvBrush = $C.TextMax; $Row.ConvWeight = $FW_Semi
                } elseif ("$($cv.State)" -eq 'idle') {
                    # At its prompt but not asking. Present, not urgent.
                    $Row.ConvBrush = $C.TextMid
                } else {
                    $Row.ConvBrush = $C.TextHigh
                }
            }

            $tip = "DOING (not the same question as OPEN?): $($cv.Detail)."
            if ($cv.Stale) { $tip += "  Nothing has moved for at least $SR_LiveWindowMinutes min, so that is the LAST state it was seen in, not a current one." }
            if ($cv.Mode)  { $tip += "`npermission mode: $($cv.Mode)" }
            if ($cv.Title) { $tip += "`ntranscript title: $($cv.Title)" }
            if ($cv.LastPrompt) { $tip += "`nlast prompt: $($cv.LastPrompt)" }
            $Row.ConvTip = $tip
        }
        default {
            # A project or lane rolls its children up, so a FOLDED parent still
            # says that something underneath it wants attention. Waiting outranks
            # working: one is asking for you, the other is busy without you.
            $kids = $(if ($Row.Kind -eq 'lane') { @($Row.Lane.Group) } else { @(Get-Visible $Row.Dir) })
            # Live demands only. A rollup counting last-known states said
            # "9 waiting" for a project with nothing running in it.
            $wait = 0; $work = 0
            foreach ($s in $kids) {
                $k = Get-Conv $s
                if (-not $k) { continue }
                if ($k.Needs) { $wait++ }
                elseif (-not $k.Stale -and "$($k.State)" -eq 'working') { $work++ }
            }
            $Row.ConvWeight = $FW_Normal
            if ($wait -gt 0) {
                $Row.Conv = "{0} waiting" -f $wait
                $Row.ConvBrush = $C.TextMax
                $Row.ConvWeight = $FW_Semi
                $Row.ConvGeometry = $GlyphWaiting
                $Row.ConvGlyphVisibility = $V_Show
                $Row.ConvTip = "$wait conversation(s) under this row are asking you for something right now."
            } elseif ($work -gt 0) {
                $Row.Conv = "{0} working" -f $work
                $Row.ConvBrush = $C.TextHigh
                $Row.ConvGeometry = $GlyphWorking
                $Row.ConvGlyphVisibility = $V_Show
                $Row.ConvTip = "$work conversation(s) under this row are running a tool or owe a reply right now."
            } else {
                $Row.Conv = ''
                $Row.ConvBrush = $C.TextDim
                $Row.ConvGeometry = $null
                $Row.ConvGlyphVisibility = $V_Hide
                $Row.ConvTip = 'Nothing under this row is doing anything right now.'
            }
        }
    }
}

# The parts that never change once a row is built.
function Update-RowStatic { param($Row)
    switch ($Row.Kind) {
        'dir' {
            # Roomier than it was. The three levels are 44 / 36 / 34 rather than
            # 32 / 26 / 24: the hierarchy still steps down, but no line is
            # cramped, and a project header now has room to read as a header.
            $Row.RowHeight = 44
            $Row.Indent = New-Object System.Windows.Thickness (8, 0, 0, 0)
            $Row.Name = Split-Path $Row.Dir.path -Leaf
            $Row.NameWeight = $FW_Semi
            $Row.NameSize = 15
            $Row.FoldVisibility = $V_Show
            $Row.LaunchLabel = 'Open all'
            $Row.IdShort = ''
            $Row.Age = ''
        }
        'lane' {
            $Row.RowHeight = 36
            $Row.Indent = New-Object System.Windows.Thickness (34, 0, 0, 0)
            # A worktree lane used to be told apart by hue. The literal prefix
            # "worktree: " now carries that entirely, which is more explicit than
            # the colour ever was.
            $wt = ($Row.Lane.Name -ne 'main')
            $Row.Name = $(if ($wt) { 'worktree: ' + $Row.Lane.Name } else { 'main' })
            $Row.NameBrush = $C.TextMid
            $Row.NameWeight = $FW_Normal
            $Row.NameSize = 13
            $Row.FoldVisibility = $V_Show
            $Row.LaunchLabel = 'Open all'
            $Row.IdShort = ''
            $Row.Age = ''
        }
        'session' {
            $Row.RowHeight = 34
            $Row.Indent = New-Object System.Windows.Thickness (62, 0, 0, 0)
            $Row.Name = Get-SessionTitle $Row.Session $Row.Dir
            $Row.NameWeight = $FW_Normal
            $Row.NameSize = 13.5
            $Row.FoldVisibility = $V_Hide
            $Row.LaunchLabel = 'Open'
            $Row.IdShort = "$($Row.Session.sessionId)".Substring(0, 8)
            $Row.Age = Get-Age $Row.Session.lastActive
            $Row.Counts = ''
        }
    }
    Update-RowFold $Row
}

function Update-RowFold { param($Row)
    if ($Row.Kind -eq 'session') { return }
    $folded = [bool]$script:collapsed[$Row.Key]
    $Row.FoldAngle = $(if ($folded) { $FoldAngleClosed } else { $FoldAngleOpen })
}

function Update-AllTicks {
    foreach ($r in $script:rows) { Update-RowTicks $r }
    Update-Header
}
# Liveness and state land on the same background pass, so they refresh together
# -- but they are computed by two functions and written to two sets of
# properties, because they are two different questions and the moment they share
# a code path is the moment one starts standing in for the other.
function Update-AllLive {
    foreach ($r in $script:rows) { Update-RowLive $r; Update-RowConv $r }
    Update-Header
    Update-NeedsBand
    Update-Selection
}

# The taskbar button, flashed until the window is looked at. FLASHW_TIMERNOFG
# keeps it flashing until the window comes to the FOREGROUND rather than for a
# fixed count, so it is still flashing when the operator comes back from
# somewhere else -- which is the only case where it is any use.
#
# It is a flash, not a foreground steal. Windows would refuse a foreground steal
# from a background process anyway, and a window that jumps in front of what
# somebody is typing into is a worse bug than the one it is solving.
if (-not ('SRGui.Flash' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SRGui
{
    public static class Flash
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct FLASHWINFO
        {
            public uint cbSize; public IntPtr hwnd; public uint dwFlags;
            public uint uCount; public uint dwTimeout;
        }
        [DllImport("user32.dll")] private static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

        private const uint FLASHW_TRAY = 2;          // the taskbar button only
        private const uint FLASHW_TIMERNOFG = 12;    // until it comes to the foreground
        private const uint FLASHW_STOP = 0;

        public static void Start(IntPtr hwnd)
        {
            FLASHWINFO fi = new FLASHWINFO();
            fi.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
            fi.hwnd = hwnd;
            fi.dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG;
            fi.uCount = 0;
            fi.dwTimeout = 0;
            FlashWindowEx(ref fi);
        }
        public static void Stop(IntPtr hwnd)
        {
            FLASHWINFO fi = new FLASHWINFO();
            fi.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
            fi.hwnd = hwnd;
            fi.dwFlags = FLASHW_STOP;
            FlashWindowEx(ref fi);
        }
    }
}
'@
}

function Start-TaskbarFlash {
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        if ($h -ne [IntPtr]::Zero) { [SRGui.Flash]::Start($h) }
    } catch { }
}
function Stop-TaskbarFlash {
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        if ($h -ne [IntPtr]::Zero) { [SRGui.Flash]::Stop($h) }
    } catch { }
}

# --- NEEDS YOU -------------------------------------------------------------
# Which conversations are at their prompt waiting for the operator RIGHT NOW --
# state 'waiting' and not stale. The DOING column already says this per row, but
# only if you happen to be looking at the right row: with ~127 conversations the
# one that wants you is usually somewhere off screen. This is the same
# information, gathered where it cannot be missed.
#
# Deliberately NOT a toast. The operator asked for the quiet version, and a
# window that shouts is a window you end up closing.
$script:needsPrev = @{}

function Get-WaitingNow {
    $out = @()
    foreach ($d in @($script:dirs)) {
        foreach ($s in @(Get-Visible $d)) {
            if (-not $s.sessionId) { continue }
            $cv = Get-Conv $s
            if (-not $cv) { continue }
            # Needs, not merely 'waiting': claude distinguishes a session that
            # is asking for something from one simply sitting at its prompt, and
            # a band that lists all seven idle sessions is a band nobody reads.
            if (-not $cv.Needs) { continue }
            $out += [PSCustomObject]@{
                Id    = "$($s.sessionId)".ToLower()
                Key   = "$($d.path)|$(Get-LaneName $s)|$($s.sessionId)"
                Label = "$(Get-SessionTitle $s $d)"
                Tip   = "$(Get-SessionTitle $s $d) is at its prompt in $($d.path).`n$($cv.Detail)." +
                        $(if ($cv.LastPrompt) { "`nlast prompt: $($cv.LastPrompt)" } else { '' })
            }
        }
    }
    return ,@($out)
}

function Update-NeedsBand {
    $now = Get-WaitingNow
    $now = @($now)

    if (-not $now.Count) {
        $ui.NeedsBand.Visibility = $V_Hide
        $ui.NeedsList.ItemsSource = $null
        $script:needsPrev = @{}
        return
    }

    $ui.NeedsLabel.Text = $(if ($now.Count -eq 1) { '1 waiting for you' } else { "$($now.Count) waiting for you" })
    $ui.NeedsList.ItemsSource = $now
    $ui.NeedsBand.Visibility = $V_Show

    # Flash only for a conversation that has JUST started waiting. Flashing again
    # for one that has been waiting since the window opened would train the
    # operator to ignore the taskbar, which is the opposite of the point.
    $fresh = @($now | Where-Object { -not $script:needsPrev[$_.Id] })
    $next = @{}
    foreach ($n in $now) { $next[$n.Id] = $true }
    $script:needsPrev = $next
    if ($fresh.Count -and -not $window.IsActive) { Start-TaskbarFlash }
}

# ---------------------------------------------------------------------------
# The filter readout.
#
# The lit chips say WHAT is being filtered. This says WHAT IT COST: how many
# conversations survived, out of how many, and how many dimensions are doing the
# cutting. Without it, a filter that matches nothing looks exactly like a
# registry that is empty -- which is the failure mode every filter UI has, and
# the reason the count sits on the same strip as the chips rather than in a
# status line somewhere else.
# ---------------------------------------------------------------------------
function Get-FilterDimensionCount {
    $n = 0
    if ($script:filter)       { $n++ }
    if ($script:fProject)     { $n++ }
    if ($script:fLane)        { $n++ }
    if ($script:fState.Count) { $n++ }
    if ($script:fLive.Count)  { $n++ }
    if ($script:fTick.Count)  { $n++ }
    if ($script:fPin.Count)   { $n++ }
    if ($script:fAge.Count)   { $n++ }
    return $n
}

function Update-FilterReadout {
    if (-not $ui.FilterCount) { return }
    $dims = Get-FilterDimensionCount
    if ($dims -eq 0) {
        $ui.FilterCount.Text = "all {0} conversations" -f $script:totalCount
        $ui.FilterCount.Foreground = $C.TextDim
    } else {
        $ui.FilterCount.Text = "{0} of {1} conversations   |   {2} filter{3} on" -f `
            $script:matchCount, $script:totalCount, $dims, $(if ($dims -eq 1) { '' } else { 's' })
        # A filter that matches nothing is the loudest thing on the strip, because
        # it is the one state the operator most needs to notice.
        $ui.FilterCount.Foreground = $(if ($script:matchCount) { $C.TextHigh } else { $C.TextMax })
    }
    $ui.ClearFilters.IsEnabled = ($dims -gt 0)
}

function Get-ChipControls {
    return @(
        $ui.FsWaiting, $ui.FsWorking, $ui.FsSumm, $ui.FsIdle, $ui.FsUnknown,
        $ui.FlLive, $ui.FlNot, $ui.FlGone,
        $ui.FtOn, $ui.FtOff, $ui.FpPin,
        $ui.FaRecent, $ui.FaStale
    ) | Where-Object { $_ }
}

# One action clears everything: chips, both dropdowns and the text box. Anything
# less means the operator has to remember where they left a filter on, and a
# forgotten filter reads as missing data.
function Clear-AllFilters {
    $script:filter   = $null
    $script:fState   = @{}
    $script:fLive    = @{}
    $script:fTick    = @{}
    $script:fPin     = @{}
    $script:fAge     = @{}
    $script:fProject = $null
    $script:fLane    = $null
    try {
        $script:suppress = $true
        $ui.SearchBox.Text = ''
        foreach ($c in Get-ChipControls) { $c.IsChecked = $false }
        if ($ui.ProjectFilter.Items.Count) { $ui.ProjectFilter.SelectedIndex = 0 }
        if ($ui.LaneFilter.Items.Count)    { $ui.LaneFilter.SelectedIndex = 0 }
    } finally { $script:suppress = $false }
    Update-List -ToTop
    Set-Status 'every filter cleared' 'info'
}

# PROJECT and LANE are the only two dimensions whose values come from the data
# rather than from a fixed vocabulary, so their lists are rebuilt after every
# scan -- a project discovered a minute ago has to be selectable now. The
# current choice is preserved across the rebuild if it still exists, and
# silently dropped if the project has gone.
function Update-FilterSources {
    if (-not $ui.ProjectFilter) { return }
    $keepP = $script:fProject
    $keepL = $script:fLane
    try {
        $script:suppress = $true

        # Two repos can share a leaf name. Where they do, the label carries the
        # parent as well, because a dropdown with two identical rows is worse
        # than no dropdown at all.
        $leaves = @{}
        foreach ($d in @($script:dirs)) {
            $leaf = Split-Path $d.path -Leaf
            $leaves[$leaf] = [int]$leaves[$leaf] + 1
        }

        $ui.ProjectFilter.Items.Clear()
        $null = $ui.ProjectFilter.Items.Add((New-Object SRGui.Choice '(any project)', $null))
        foreach ($d in @($script:dirs | Sort-Object { Split-Path $_.path -Leaf })) {
            $leaf = Split-Path $d.path -Leaf
            $label = $leaf
            if ($leaves[$leaf] -gt 1) {
                $parent = Split-Path (Split-Path $d.path -Parent) -Leaf
                if ($parent) { $label = "$leaf  ($parent)" }
            }
            $null = $ui.ProjectFilter.Items.Add((New-Object SRGui.Choice $label, $d.path))
        }

        $laneNames = @{}
        foreach ($d in @($script:dirs)) {
            foreach ($s in @(Get-Visible $d)) { $laneNames[(Get-LaneName $s)] = $true }
        }
        $ui.LaneFilter.Items.Clear()
        $null = $ui.LaneFilter.Items.Add((New-Object SRGui.Choice '(any lane)', $null))
        $null = $ui.LaneFilter.Items.Add((New-Object SRGui.Choice 'main', 'main'))
        foreach ($n in @($laneNames.Keys | Where-Object { $_ -ne 'main' } | Sort-Object)) {
            $null = $ui.LaneFilter.Items.Add((New-Object SRGui.Choice ('worktree: ' + $n), $n))
        }

        Set-DropSelection $ui.ProjectFilter $keepP
        Set-DropSelection $ui.LaneFilter    $keepL
    } finally { $script:suppress = $false }
}

function Set-DropSelection { param($Combo, [string]$Value)
    $idx = 0
    if ($Value) {
        for ($i = 0; $i -lt $Combo.Items.Count; $i++) {
            if ("$($Combo.Items[$i].Value)" -eq $Value) { $idx = $i; break }
        }
    }
    $Combo.SelectedIndex = $idx
    # If the chosen value has vanished with its project, the filter goes with it
    # rather than quietly matching nothing forever.
    if ($idx -eq 0 -and $Value) {
        if ($Combo -eq $ui.ProjectFilter) { $script:fProject = $null } else { $script:fLane = $null }
    }
}

function Update-Header {
    $on = 0; $tot = 0; $projOn = 0; $liveTotal = 0; $pinned = 0; $waiting = 0; $working = 0
    foreach ($d in $script:dirs) {
        if ($d.missing) { continue }
        $v = @(Get-Visible $d)
        $tot += $v.Count
        foreach ($s in $v) {
            if ((Get-SessionState $s) -in @('run','act','new')) { $liveTotal++ }
            if ($s.pinned) { $pinned++ }
            # NEEDS, not last-known state. Counting every conversation whose
            # last recorded state was 'waiting' put "98 waiting for you" in the
            # header while the band said 2 -- because ~110 of them are not
            # running and cannot be waiting for anything. A number that large is
            # not a summary, it is noise, and it disagreed with the band six
            # inches below it.
            $cvh = Get-Conv $s
            if ($cvh) {
                if ($cvh.Needs) { $waiting++ }
                elseif (-not $cvh.Stale -and "$($cvh.State)" -eq 'working') { $working++ }
            }
        }
        if ($d.enabled) {
            $n = @($v | Where-Object { $_.enabled }).Count
            if ($n -gt 0) { $projOn++ }
            $on += $n
        }
    }
    $ui.LiveSummary.Text = "{0} live now" -f $liveTotal
    # Two counts, two questions, two pills. "live" is how many are being held;
    # "waiting" is how many are asking for the operator. They are routinely
    # different numbers and the whole point of the DOING column is that they are.
    $ui.WaitSummary.Text = "{0} waiting for you   |   {1} working" -f $waiting, $working
    $ui.TickSummary.Text = "{0} of {1} ticked to reopen at logon, in {2} project(s){3}" -f $on, $tot, $projOn, $(if ($script:dirty) { '  *unsaved*' } else { '' })
    $ui.ProbeStamp.Text  = $(if ($script:probedAt) {
        "{0} pinned   |   live + doing as of {1}   |   auto: newest {2} from main, {3} from each worktree" -f `
            $pinned, ([datetime]$script:probedAt).ToString('HH:mm:ss'), $script:cfg.autoTickPerDirectory, $script:cfg.autoTickPerWorktree
    } else { '' })

    Update-FilterReadout

    if ($script:unattributed -gt 0) {
        # Honest about the blind spot rather than implying LIVE is complete.
        $ui.Unattributed.Text = "{0} running claude.exe cannot be matched to any conversation - started bare, with no id on the command line. LIVE is a floor, not a total." -f $script:unattributed
        $ui.Unattributed.Visibility = $V_Show
    } else { $ui.Unattributed.Visibility = $V_Hide }

    $ui.SubTitle.Text = $(if ($script:showWt) {
        'the tick reopens it at logon   |   OPEN? is who holds it, DOING is what it is doing   |   press / to find'
    } else {
        'worktree lanes are OFF - hidden and never restored   |   press / to find'
    })
}

# Every filter currently applied, in words. Used when nothing matched, which is
# the moment the operator most needs to be told what is cutting the list down
# rather than left looking at an empty screen.
function Get-FilterDescription {
    $bits = @()
    if ($script:filter)       { $bits += "text '$($script:filter)'" }
    if ($script:fProject)     { $bits += "PROJECT " + (Split-Path $script:fProject -Leaf) }
    if ($script:fLane)        { $bits += "LANE $script:fLane" }
    if ($script:fState.Count) { $bits += "DOING " + (@($script:fState.Keys | Sort-Object) -join '/') }
    if ($script:fLive.Count)  { $bits += "OPEN? " + (@($script:fLive.Keys | Sort-Object) -join '/') }
    if ($script:fTick.Count)  { $bits += "LOGON " + (@($script:fTick.Keys | Sort-Object) -join '/') }
    if ($script:fPin.Count)   { $bits += "pinned" }
    if ($script:fAge.Count)   { $bits += "AGE " + (@($script:fAge.Keys | Sort-Object) -join '/') }
    return ,@($bits)
}

# The list just changed under the operator -- a filter, a fold, a rescan. A hard
# swap of 150 rows gives no clue that anything happened; a short settle does, and
# it points DOWNWARD because that is the direction content arrives from.
#
# Animated on the transform rather than on a Storyboard in the XAML because the
# trigger is a code path, not a visual state: Update-List is reached from six
# different places and none of them is expressible as a XAML trigger.
#
# 170 ms with an EaseOut. Long enough to register, short enough that a fast
# sequence of filter keystrokes does not feel like wading.
function Start-ListSettle {
    $t = $ui.ListShift
    if (-not $t) { return }
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.From     = 6
    $a.To       = 0
    $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(170))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $a.EasingFunction = $ease
    $t.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $a)
}

function Update-List { param([string]$KeepKey, [switch]$ToTop)
    if (-not $KeepKey -and -not $ToTop -and $ui.RowList.SelectedItem) { $KeepKey = $ui.RowList.SelectedItem.Key }
    if ($ToTop) { $KeepKey = $null }
    $script:rows = Build-Rows
    foreach ($r in $script:rows) { Update-RowStatic $r; Update-RowTicks $r; Update-RowLive $r; Update-RowConv $r }
    # A row whose text has no brush renders as NOTHING, and a blank column reads
    # as "no data" rather than as a bug -- which is exactly how a case-insensitive
    # $c/$C collision hid a fully populated DOING column. Turn it into noise.
    foreach ($r in $script:rows) {
        if ($r.Conv -and $null -eq $r.ConvBrush) {
            throw "row '$($r.Name)' has DOING text '$($r.Conv)' with a null brush - it would render invisible"
        }
    }
    $ui.RowList.ItemsSource = $script:rows
    Update-Header
    # The hierarchy just changed under the operator. A 170 ms settle says so;
    # a hard swap of 150 rows does not.
    Start-ListSettle

    if ($script:rows.Count -eq 0) {
        $desc = Get-FilterDescription
        $ui.EmptyNote.Text = $(if (@($desc).Count) {
            "Nothing matches. {0} filter(s) on:  {1}.`n`nPress Clear all filters, or Esc." -f @($desc).Count, (@($desc) -join '   +   ')
        } elseif (@($script:dirs).Count -eq 0) {
            'No projects discovered yet. Run claude in a project once, then press Rescan.'
        } else { 'nothing to show' })
        $ui.EmptyNote.Visibility = $V_Show
    } else {
        $ui.EmptyNote.Visibility = $V_Hide
        $idx = -1
        if ($KeepKey) {
            for ($i = 0; $i -lt $script:rows.Count; $i++) { if ($script:rows[$i].Key -eq $KeepKey) { $idx = $i; break } }
        }
        if ($idx -lt 0) { $idx = 0 }
        $ui.RowList.SelectedIndex = $idx
        $ui.RowList.ScrollIntoView($script:rows[$idx])
    }
    Update-NeedsBand
    Update-Selection
}

# ---------------------------------------------------------------------------
# Reading one conversation
#
# Four kinds of block, told apart by FORM rather than by hue, because the window
# has no hue to spend:
#
#   you        a bar down the left edge and the brightest text. It is the only
#              thing on the page with a bar, so your own words are findable by
#              shape while scrolling past everything else.
#   said       plain prose at reading weight. The default, so it needs no mark.
#   thinking   indented, dimmest, italic. Present but clearly not addressed to
#              you -- and folded to a couple of lines unless you ask for it.
#   tool       one mono line, dim, with a chevron. Tool traffic outnumbers prose
#              five to one in a real transcript; giving each call more than a
#              line would bury the conversation inside its own machinery.
#
# Code is monospaced on a lifted panel with its own left rule. No syntax colour
# yet, by decision: structure first, polish once it has been used.
# ---------------------------------------------------------------------------
$script:readSession = $null
$script:readDir     = $null

function New-ReadRun {
    param([string]$Text, $Brush, [double]$Size = 13, [string]$Weight = 'Normal', [switch]$Mono, [switch]$Italic)
    $r = New-Object System.Windows.Documents.Run ([string]$Text)
    if ($Brush) { $r.Foreground = $Brush }
    $r.FontSize = $Size
    if ($Mono)   { $r.FontFamily = $script:MonoFace }
    if ($Italic) { $r.FontStyle = [System.Windows.FontStyles]::Italic }
    $r.FontWeight = $(if ($Weight -eq 'SemiBold') { $FW_Semi } elseif ($Weight -eq 'Bold') { [System.Windows.FontWeights]::Bold } else { $FW_Normal })
    return $r
}

# Markdown, but only the parts that change how a line READS: fenced code, a
# heading, a bullet, and inline `code`. Anything more elaborate would be a
# markdown engine, which is not what this needs to be.
function Add-ReadProse {
    param($Doc, [string]$Text, $Brush)
    $lines = @($Text -replace "`r", '' -split "`n")
    $i = 0
    while ($i -lt $lines.Count) {
        $ln = $lines[$i]

        if ($ln.TrimStart().StartsWith('```')) {
            $code = New-Object System.Collections.Generic.List[string]
            $i++
            while ($i -lt $lines.Count -and -not $lines[$i].TrimStart().StartsWith('```')) {
                $code.Add($lines[$i]); $i++
            }
            $i++
            $p = New-Object System.Windows.Documents.Paragraph
            $p.Margin = New-Object System.Windows.Thickness 0, 6, 0, 6
            $p.Padding = New-Object System.Windows.Thickness 12, 8, 12, 8
            $p.Background = $C.Raised
            $p.BorderBrush = $C.HairlineHi
            $p.BorderThickness = New-Object System.Windows.Thickness 2, 0, 0, 0
            $p.Inlines.Add((New-ReadRun -Text ($code -join "`n") -Brush $C.TextHigh -Size 12 -Mono))
            $Doc.Blocks.Add($p)
            continue
        }

        $p = New-Object System.Windows.Documents.Paragraph
        $p.Margin = New-Object System.Windows.Thickness 0, 2, 0, 2
        $body = $ln
        $size = 13; $weight = 'Normal'; $indent = 0

        if ($body -match '^\s*#{1,6}\s+(.*)$') { $body = $Matches[1]; $weight = 'SemiBold'; $size = 14 }
        elseif ($body -match '^\s*[-*]\s+(.*)$') { $body = [char]0x2022 + '  ' + $Matches[1]; $indent = 14 }
        elseif ($body -match '^\s*(\d+)\.\s+(.*)$') { $body = $Matches[1] + '.  ' + $Matches[2]; $indent = 14 }
        if ($indent) { $p.Margin = New-Object System.Windows.Thickness $indent, 2, 0, 2 }

        # Inline `code` and **bold**, split in one pass so a line can carry both.
        $rest = $body
        while ($rest -match '^(.*?)(`([^`]+)`|\*\*([^*]+)\*\*)(.*)$') {
            $before = $Matches[1]; $codeTxt = $Matches[3]; $boldTxt = $Matches[4]; $rest = $Matches[5]
            if ($before) { $p.Inlines.Add((New-ReadRun -Text $before -Brush $Brush -Size $size -Weight $weight)) }
            if ($codeTxt) { $p.Inlines.Add((New-ReadRun -Text $codeTxt -Brush $C.TextMax -Size ($size - 1) -Mono)) }
            elseif ($boldTxt) { $p.Inlines.Add((New-ReadRun -Text $boldTxt -Brush $C.TextMax -Size $size -Weight 'SemiBold')) }
        }
        if ($rest) { $p.Inlines.Add((New-ReadRun -Text $rest -Brush $Brush -Size $size -Weight $weight)) }
        if ($p.Inlines.Count -eq 0) { $p.Inlines.Add((New-ReadRun -Text ' ' -Brush $Brush -Size $size)) }
        $Doc.Blocks.Add($p)
        $i++
    }
}

function Build-ReadDocument {
    param($Blocks)
    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.FontFamily        = $script:UiFace
    $doc.Background        = $C.Ink
    $doc.Foreground        = $C.TextHigh
    $doc.PagePadding       = New-Object System.Windows.Thickness 26, 18, 26, 26
    $doc.ColumnWidth       = [double]::PositiveInfinity   # one column, never split
    $doc.IsOptimalParagraphEnabled = $false

    if (-not @($Blocks).Count) {
        $p = New-Object System.Windows.Documents.Paragraph
        $p.Inlines.Add((New-ReadRun -Text 'Nothing readable in this transcript yet.' -Brush $C.TextMid -Size 13))
        $doc.Blocks.Add($p)
        return $doc
    }

    foreach ($b in @($Blocks)) {
        switch ($b.Kind) {
            'you' {
                $s = New-Object System.Windows.Documents.Section
                $s.Margin = New-Object System.Windows.Thickness 0, 12, 0, 6
                $s.Padding = New-Object System.Windows.Thickness 12, 2, 0, 2
                $s.BorderBrush = $C.TextMax
                $s.BorderThickness = New-Object System.Windows.Thickness 2, 0, 0, 0
                $lab = New-Object System.Windows.Documents.Paragraph
                $lab.Margin = New-Object System.Windows.Thickness 0, 0, 0, 3
                $lab.Inlines.Add((New-ReadRun -Text 'YOU' -Brush $C.TextMax -Size 10.5 -Weight 'SemiBold'))
                $s.Blocks.Add($lab)
                $inner = New-Object System.Windows.Documents.FlowDocument
                Add-ReadProse -Doc $inner -Text $b.Body -Brush $C.TextMax
                # Blocks is a live collection: moving them while enumerating it
                # silently drops every second one, hence the @() snapshot.
                #
                # $null = on the Remove is NOT tidiness. BlockCollection.Remove
                # returns a BOOL, PowerShell emits every uncaptured value, and a
                # function that emits anything returns all of it -- so this
                # returned an array of $true with the document buried inside, and
                # the pane failed with "Cannot convert System.Object[] to
                # FlowDocument". Void-looking methods are not all void.
                foreach ($blk in @($inner.Blocks)) { $null = $inner.Blocks.Remove($blk); $s.Blocks.Add($blk) }
                $doc.Blocks.Add($s)
            }
            'said' {
                $inner = New-Object System.Windows.Documents.FlowDocument
                Add-ReadProse -Doc $inner -Text $b.Body -Brush $C.TextHigh
                foreach ($blk in @($inner.Blocks)) { $null = $inner.Blocks.Remove($blk); $doc.Blocks.Add($blk) }
                $sp = New-Object System.Windows.Documents.Paragraph
                $sp.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
                $sp.Inlines.Add((New-ReadRun -Text ' ' -Brush $C.TextDim -Size 4))
                $doc.Blocks.Add($sp)
            }
            'thinking' {
                $head = @($b.Body -replace "`r", '' -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' '
                if ($head.Length -gt 170) { $head = $head.Substring(0, 167) + '...' }
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 18, 3, 0, 6
                $p.Inlines.Add((New-ReadRun -Text ('thinking  ' + $b.Meta + '   ') -Brush $C.TextDim -Size 10.5 -Weight 'SemiBold'))
                $p.Inlines.Add((New-ReadRun -Text $head -Brush $C.TextDim -Size 12 -Italic))
                $doc.Blocks.Add($p)
            }
            'tool' {
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 4, 1, 0, 1
                $p.Inlines.Add((New-ReadRun -Text ([char]0x203A + '  ') -Brush $C.TextLow -Size 12 -Mono))
                $p.Inlines.Add((New-ReadRun -Text ($b.Head + '  ') -Brush $C.TextMid -Size 11.5 -Weight 'SemiBold' -Mono))
                $p.Inlines.Add((New-ReadRun -Text $b.Body -Brush $C.TextLow -Size 11.5 -Mono))
                $doc.Blocks.Add($p)
            }
            'result' {
                $first = @($b.Body -replace "`r", '' -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                $first = "$first"
                if ($first.Length -gt 120) { $first = $first.Substring(0, 117) + '...' }
                $p = New-Object System.Windows.Documents.Paragraph
                $p.Margin = New-Object System.Windows.Thickness 22, 0, 0, 4
                $p.Inlines.Add((New-ReadRun -Text ($b.Head + '  ' + $b.Meta + '   ') -Brush $C.TextDim -Size 10.5 -Mono))
                $p.Inlines.Add((New-ReadRun -Text $first -Brush $C.TextDim -Size 11 -Mono))
                $doc.Blocks.Add($p)
            }
        }
    }
    return $doc
}

# FlowDocumentScrollViewer has no ScrollToEnd of its own -- it OWNS a
# ScrollViewer inside its template rather than being one. Walk the visual tree
# for it. Guarded because the template is only realised once the control has been
# laid out, so this is $null on the very first call.
function Get-ReadScroller {
    $q = New-Object System.Collections.Generic.Queue[object]
    $q.Enqueue($ui.ReadView)
    while ($q.Count) {
        $n = $q.Dequeue()
        if ($n -is [System.Windows.Controls.ScrollViewer]) { return $n }
        $c = 0
        try { $c = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($n) } catch { $c = 0 }
        for ($i = 0; $i -lt $c; $i++) { $q.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($n, $i)) }
    }
    return $null
}

function Show-ReadPane {
    param($Row)
    if (-not $Row -or $Row.Kind -ne 'session') {
        Set-Status 'select a conversation to read it' 'warn'
        return
    }
    $script:readSession = $Row.Session
    $script:readDir     = $Row.Dir
    $ui.ReadName.Text   = "$(Get-SessionTitle $Row.Session $Row.Dir)"
    $cv = Get-Conv $Row.Session
    $ui.ReadWhat.Text   = $(if ($cv) { "$($cv.State)  -  $($cv.Detail)" } else { '' })
    $ui.ReadPane.Visibility = $V_Show
    $ui.RowList.Visibility  = $V_Hide
    $ui.NeedsBand.Visibility = $V_Hide
    Update-ReadDocument
}

function Update-ReadDocument {
    if (-not $script:readSession) { return }
    $s = $script:readSession
    $j = Get-SRTranscriptPath -Dir (Get-SessionCwd $s $script:readDir) -SessionId $s.sessionId -Recorded $s.jsonl
    # ~680 ms on a 15 MB transcript, so it is announced rather than looking hung.
    Set-Busy 'reading the conversation'
    try {
        $blocks = Get-SRTranscriptBlocks -JsonlPath $j
        $docObj = Build-ReadDocument -Blocks $blocks
        if ($docObj -isnot [System.Windows.Documents.FlowDocument]) {
            throw ("Build-ReadDocument returned {0}, not a FlowDocument - something in it emitted to the pipeline" -f $docObj.GetType().Name)
        }
        $ui.ReadView.Document = $docObj
        # Newest last, so the end is where the conversation is. Deferred to
        # Loaded priority: the document has only just been set and the scroller
        # does not know how tall it is until layout has run.
        $null = $window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Loaded,
            [action]{ $sv = Get-ReadScroller; if ($sv) { $sv.ScrollToEnd() } })
        Set-Status ("read {0} block(s) from the end of the transcript" -f @($blocks).Count) 'ok'
    } finally { Set-Busy '' }
}

function Hide-ReadPane {
    $script:readSession = $null
    $ui.ReadPane.Visibility = $V_Hide
    $ui.RowList.Visibility  = $V_Show
    Update-NeedsBand
    $null = $ui.RowList.Focus()
}

function Update-Selection {
    $row = $ui.RowList.SelectedItem
    if (-not $row) {
        $ui.SelName.Text = 'nothing selected'
        $ui.SelPath.Text = ''
        foreach ($b in @($ui.SelTick, $ui.SelUnpin, $ui.SelLaunch, $ui.SelSpawn)) { $b.IsEnabled = $false }
        return
    }
    if (-not $script:busy) {
        foreach ($b in @($ui.SelTick, $ui.SelUnpin, $ui.SelLaunch, $ui.SelSpawn)) { $b.IsEnabled = $true }
    }
    $what = switch ($row.Kind) { 'dir' { 'project' } 'lane' { 'lane' } default { 'conversation' } }
    $ui.SelName.Text = "{0}   {1}" -f $row.Name, $what
    $ui.SelPath.Text = Get-RowPath $row
}

# ---------------------------------------------------------------------------
# Loading the registry into the window
# ---------------------------------------------------------------------------
function Set-Registry { param($Registry, $Config)
    if ($Config) {
        $script:cfg       = $Config
        $script:showWt    = [bool]$Config.includeWorktrees
        $script:staleDays = [double]$Config.recencyDays
    }
    $script:reg = $Registry
    $script:visCache = @{}
    # Before the sort, not after: the cache holds the OLD session objects, and
    # sorting on them would order the new list by the previous scan's timestamps.
    $script:dirs = @($script:reg.directories | Sort-Object { Get-Newest (Get-Visible $_) } -Descending)
}

function Set-ProbeResult { param($Result)
    $script:running      = $Result.Running
    $script:live         = $Result.Live
    if ($Result.PSObject.Properties['Conv'] -and $Result.Conv) { $script:conv = $Result.Conv }
    if ($Result.PSObject.Properties['Agents']) { $script:agents = $Result.Agents }
    $script:unattributed = [int]$Result.Unattributed
    $script:probedAt     = $Result.At
}

function Get-ProbeSnapshot {
    $out = @()
    foreach ($d in @($script:dirs)) {
        foreach ($s in @($d.sessions)) {
            if (-not $s.sessionId) { continue }
            $out += [PSCustomObject]@{
                Id    = $s.sessionId
                Cwd   = $(if ($s.cwd) { $s.cwd } else { $d.path })
                Jsonl = $s.jsonl
            }
        }
    }
    return ,@($out)
}

function Start-Rescan { param([switch]$NoScanPass)
    # The panel holds a copy in memory while you browse; the scan reads from disk.
    # Save first or the scan's copy wins and the ticks changed here are gone -- the
    # same order select-sessions.ps1 Invoke-Rescan uses.
    if ($script:dirty) { Save-SRRegistry -Registry $script:reg; $script:dirty = $false }
    # TRAP: script scope, not a local. A scriptblock invoked after its defining
    # function has returned resolves variables against the CURRENT scope chain,
    # and this function's locals are long gone by the time the job completes.
    $script:rescanNoScan = [bool]$NoScanPass
    $started = Start-SRJob -Name $(if ($NoScanPass) { 'checking what is live' } else { 'scanning' }) -Body $script:ScanJob -Data @{ NoScan = [bool]$NoScanPass } -OnDone {
        param($res)
        if (-not $res) { Set-Status 'the scan returned nothing' 'warn'; return }
        Set-Registry -Registry $res.Registry -Config $res.Config
        Set-ProbeResult $res
        $script:launching = @{}
        try { $script:suppress = $true; $ui.WorktreeToggle.IsChecked = $script:showWt } finally { $script:suppress = $false }
        # The opening scan re-sorts the projects, so the row that was selected
        # before it can end up halfway down -- and the window would open scrolled
        # into the middle of a list nobody had touched yet. A later rescan keeps
        # the selection, because by then it is the operator's.
        Update-List -ToTop:$script:firstFill
        $script:firstFill = $false
        Set-Status $(if ($script:rescanNoScan) { 'live state refreshed' } else { 'rescanned - the registry and the live state are both current' }) 'info'
    }
    if (-not $started) { Set-Status 'still busy - one background pass at a time' 'warn' }
}

function Start-LiveProbe {
    if ($script:jobPs) { return }
    $snap = Get-ProbeSnapshot
    $null = Start-SRJob -Name 'checking what is live' -Body $script:ProbeJob -Data @{ Sessions = @($snap) } -OnDone {
        param($res)
        if (-not $res) { return }
        Set-ProbeResult $res
        Update-AllLive
    }
}

# ---------------------------------------------------------------------------
# Launching. The UI thread decides (the guards live here, with the probe tables);
# the worker executes -- boot script, wt.exe, the half-second between tabs and the
# poll that proves each tab's child actually came up.
# ---------------------------------------------------------------------------
function Start-Launch { param($Items, [string]$What)
    if (-not @($Items).Count) { return }
    $payload = @()
    foreach ($it in @($Items)) {
        $id = "$($it.S.sessionId)"
        $payload += [PSCustomObject]@{
            Id    = $id
            Cwd   = (Get-SessionCwd $it.S $it.D)
            Title = (Get-SessionTitle $it.S $it.D)
        }
        $script:launching[$id.ToLower()] = (Get-Date)
    }
    Update-AllLive
    $n = @($payload).Count
    $started = Start-SRJob -Name ("opening {0} {1}" -f $n, $What) -Body $script:LaunchJob -Data @{ Items = $payload } -OnDone {
        param($res)
        if (-not $res) { Set-Status 'the launch returned nothing - read .state\restore.log' 'bad'; return }
        $ok = @($res.Ok).Count; $never = @($res.Never); $fail = @($res.Fail)
        $msg = "launched {0}   verified {1}" -f $ok, ($ok - $never.Count)
        $tone = 'ok'
        if ($fail.Count)  { $msg += "   |   {0} could not be started: {1}" -f $fail.Count, ($fail -join '; '); $tone = 'bad' }
        if ($never.Count) {
            # A launch reports only that wt.exe started; the tab's child is what
            # fails, and a session that never appears must be named.
            $msg += "   |   no claude.exe ever appeared for {0} ({1}) - the tab opened and died, read .state\restore.log" -f `
                $never.Count, (($never | ForEach-Object { $_.Substring(0,8) }) -join ', ')
            $tone = 'bad'
        }
        Set-Status $msg $tone
        Start-LiveProbe
    }
    if ($started) { Set-Status ("opening {0} {1} - Windows Terminal needs half a second between tabs" -f $n, $What) 'ok' }
    else { Set-Status 'still busy - one background pass at a time' 'warn' }
}

# L, on any row. Ticks are not consulted anywhere in here: the logon set and
# "what I want open right now" are different questions.
function Invoke-RowLaunch { param($Row)
    if (-not $Row) { return }
    $rowSessions = Get-RowSessions $Row
    $all = @(@($rowSessions) | ForEach-Object { [PSCustomObject]@{ S = $_; D = $Row.Dir } })
    $go  = @($all | Where-Object { $null -eq (Get-LaunchBlock -Session $_.S -Dir $_.D) })

    if ($go.Count -eq 0) {
        # Name the reason. "Already open" and "transcript missing" call for
        # completely different reactions.
        $why = $null
        if ($all.Count -eq 1) { $why = Get-LaunchBlock -Session $all[0].S -Dir $all[0].D }
        Set-Status $(if ($why) { "not launched - $why" } else { "nothing to open here - all of it is open already" }) 'warn'
        return
    }
    if ($go.Count -eq 1) { Start-Launch -Items $go -What 'conversation'; return }

    # A project row can stand for a dozen conversations, so anything beyond one is
    # confirmed by count first.
    $cap = [int]$script:cfg.maxSessions
    $over = 0
    if ($cap -gt 0 -and $go.Count -gt $cap) { $over = $go.Count - $cap; $go = @($go | Select-Object -First $cap) }
    Request-Confirm -Title ("Open {0} conversations now" -f $go.Count) `
        -Message ("{0} conversation(s) under {1} are not open. Each one gets its own tab, half a second apart. Their ticks are not consulted - this is `"now`", not `"at logon`"." -f $go.Count, (Split-Path (Get-RowPath $Row) -Leaf)) `
        -Note $(if ($over) { "{0} more matched but are over the maxSessions cap of {1}, so they will be skipped." -f $over, $cap } else { '' }) `
        -OkLabel ("Open {0} tabs" -f $go.Count) -Items $go -What 'conversations'
}

# The two rare prompts on the way out. A native box, deliberately: it is the OS
# convention for "save before closing?", and a window that is already closing
# needs a BLOCKING answer to decide whether to stay open at all -- which an
# in-window overlay cannot give. Everything the operator meets routinely goes
# through Request-Confirm instead.
function Show-Confirm { param([string]$Message, [string]$Title)
    return [System.Windows.MessageBox]::Show($window, $Message, $Title,
        [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
}

# The in-window confirmation. It cannot block, so the decision is carried in
# script scope and acted on by the CfOk handler -- a scriptblock closed over
# these values would find them gone by the time the button is pressed.
function Request-Confirm {
    param([string]$Title, [string]$Message, [string]$Note, [string]$OkLabel, $Items, [string]$What)
    $script:confirmItems = $Items
    $script:confirmWhat  = $What
    $ui.CfTitle.Text   = $Title
    $ui.CfMessage.Text = $Message
    $ui.CfOk.Content   = $OkLabel
    if ($Note) { $ui.CfNote.Text = $Note; $ui.CfNoteBox.Visibility = $V_Show } else { $ui.CfNoteBox.Visibility = $V_Hide }
    $ui.ConfirmOverlay.Visibility = $V_Show
    $null = $ui.CfOk.Focus()
}
function Close-Confirm {
    $ui.ConfirmOverlay.Visibility = $V_Hide
    $script:confirmItems = $null
    $script:confirmWhat  = $null
}

# X. Same cap as the logon restore, and said out loud rather than applied
# silently -- a truncated list reads exactly like a complete one.
function Invoke-LaunchTicked {
    if ($script:dirty) { Save-SRRegistry -Registry $script:reg; $script:dirty = $false; Update-AllTicks }
    $all = @()
    foreach ($d in $script:dirs) {
        if ($d.missing -or -not $d.enabled) { continue }
        foreach ($s in @(Get-Visible $d)) {
            if (-not $s.enabled) { continue }
            $all += [PSCustomObject]@{ S = $s; D = $d }
        }
    }
    $all = @($all | Sort-Object { [datetime]$_.S.lastActive } -Descending)
    $go  = @($all | Where-Object { $null -eq (Get-LaunchBlock -Session $_.S -Dir $_.D) })

    $cap = [int]$script:cfg.maxSessions
    $over = 0
    if ($cap -gt 0 -and $go.Count -gt $cap) { $over = $go.Count - $cap; $go = @($go | Select-Object -First $cap) }

    if ($all.Count -eq 0) {
        Set-Status 'nothing is ticked - the checkbox on the left is what decides' 'warn'
    } elseif ($go.Count -eq 0) {
        Set-Status ("nothing to open - all {0} ticked conversation(s) are open already" -f $all.Count) 'warn'
    } else {
        Request-Confirm -Title ("Open {0} ticked conversations now" -f $go.Count) `
            -Message ("Of the {0} ticked conversation(s), {1} are not open yet. Each one gets its own tab, half a second apart." -f $all.Count, $go.Count) `
            -Note $(if ($over) { "{0} more are ticked but over the maxSessions cap of {1}, so they will be skipped. The cap is in session-restore.config.json." -f $over, $cap } else { '' }) `
            -OkLabel ("Open {0} tabs" -f $go.Count) -Items $go -What 'ticked conversation(s)'
    }
}

# S. The same refusal spawn-claude-session makes, for the same reason: a session
# was once spawned onto a lane a live one had held for 73 minutes.
function Invoke-RowSpawn { param($Row)
    if (-not $Row) { return }
    $path = Get-RowPath $Row
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Set-Status "directory no longer exists: $path" 'bad'
        return
    }
    $script:pendingSpawn = $path
    $ui.OvPath.Text = $path
    $busy = Get-LiveInDirectory $path
    if (@($busy).Count) {
        $ui.OvWarn.Text = "ALREADY LIVE IN THIS TREE: " + ((@($busy) | ForEach-Object { '"' + $_.title + '"' }) -join ', ')
        $ui.OvWarnBox.Visibility = $V_Show
        $ui.OvOk.Content = 'Spawn a second one anyway'
    } else {
        $ui.OvWarnBox.Visibility = $V_Hide
        $ui.OvOk.Content = 'Spawn it'
    }
    $ui.OvName.Text = ''
    $ui.Overlay.Visibility = $V_Show
    $null = $ui.OvName.Focus()
}

function Close-Overlay { $ui.Overlay.Visibility = $V_Hide; $script:pendingSpawn = $null; $null = $ui.RowList.Focus() }

function Confirm-Spawn {
    $dir = $script:pendingSpawn
    if (-not $dir) { Close-Overlay; return }
    # Script scope for the same reason Start-Rescan uses it: the completion
    # scriptblock runs long after this function has returned, so a local would
    # read back as $null and the message would name nothing.
    $script:spawnDir  = $dir
    $script:spawnName = Resolve-SpawnName -Dir $dir -Name $ui.OvName.Text
    Close-Overlay
    $started = Start-SRJob -Name 'spawning' -Body $script:SpawnJob -Data @{ Dir = $script:spawnDir; Name = $script:spawnName } -OnDone {
        param($res)
        if ($res -and $res.Ok) {
            # It has no session id until claude writes one, so it cannot appear in
            # the list until the next scan.
            Set-Status ("spawned `"{0}`" in {1} - press Rescan once it has settled to see it listed" -f $script:spawnName, (Split-Path $script:spawnDir -Leaf)) 'ok'
        } else {
            Set-Status ("not spawned - {0}" -f $(if ($res) { $res.Why } else { 'the spawn returned nothing' })) 'bad'
        }
    }
    if (-not $started) { Set-Status 'still busy - one background pass at a time' 'warn' }
}

# ---------------------------------------------------------------------------
# Tick mutations. Every one of them pins what it changes, because every one of
# them is a deliberate act -- exactly as SPACE, A, N, -Enable and -Disable do.
# ---------------------------------------------------------------------------
function Set-RowTick { param($Row, [Nullable[bool]]$Value)
    switch ($Row.Kind) {
        'dir' {
            if ($Row.Dir.missing) { return }
            $v = if ($null -ne $Value) { [bool]$Value } else { -not [bool]$Row.Dir.enabled }
            $Row.Dir.enabled = $v
        }
        'lane' {
            $g = @($Row.Lane.Group)
            # Toggle the whole lane to whatever it is NOT already all-on.
            $allOn = ($g.Count -gt 0 -and -not @($g | Where-Object { -not $_.enabled }).Count)
            $v = if ($null -ne $Value) { [bool]$Value } else { -not $allOn }
            foreach ($s in $g) { $s.enabled = $v; Set-Pin $s $true }
        }
        'session' {
            $v = if ($null -ne $Value) { [bool]$Value } else { -not [bool]$Row.Session.enabled }
            $Row.Session.enabled = $v
            Set-Pin $Row.Session $true
        }
    }
    $script:dirty = $true
    Update-AllTicks
}

function Set-RowUnpin { param($Row)
    if (-not $Row) { return }
    switch ($Row.Kind) {
        'dir'     { foreach ($s in @(Get-Visible $Row.Dir)) { Set-Pin $s $false } }
        'lane'    { foreach ($s in @($Row.Lane.Group))      { Set-Pin $s $false } }
        'session' { Set-Pin $Row.Session $false }
    }
    $script:dirty = $true
    Update-AllTicks
    Set-Status 'handed back to the rolling auto-tick - its tick is recomputed by the next scan' 'info'
}

function Set-AllTicks { param([bool]$Value)
    foreach ($d in $script:dirs) {
        if ($d.missing) { continue }
        $d.enabled = $Value
        foreach ($s in @(Get-Visible $d)) { $s.enabled = $Value; Set-Pin $s $true }
    }
    $script:dirty = $true
    Update-AllTicks
    Set-Status $(if ($Value) { 'everything ticked and pinned - nothing has been launched' } else { 'everything unticked and pinned - nothing has been closed' }) 'info'
}

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------
$script:suppress = $false

# ONE handler for every tick in the list, reached by routed event rather than by
# wiring each row.
#
# It syncs the model TO the checkbox instead of toggling it, and bails when the
# two already agree. That is not a nicety: the list recycles its containers, so a
# scrolled-away row's checkbox is re-bound to a different conversation and raises
# Checked/Unchecked with no user involved. Toggling there would silently flip
# ticks while you scrolled.
$tickHandler = [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    if ($script:suppress) { return }
    # TRAP: OriginalSource, NEVER Source. A routed event that leaves a template has
    # its Source RETARGETED to the templated parent, once per boundary -- so by
    # the time a checkbox inside the row's DataTemplate reaches a handler on the
    # ListBox, e.Source is the LISTBOX. Measured 2026-08-22: every tick, fold,
    # unpin and launch button in the list was dead, and silently so, because the
    # handler cast e.Source to CheckBox, got $null, and returned. OriginalSource
    # is set once when the event is raised and is never retargeted.
    $cb = $e.OriginalSource -as [System.Windows.Controls.CheckBox]
    if (-not $cb -or "$($cb.Tag)" -ne 'tick') { return }
    $row = $cb.DataContext -as [SRGui.Row]
    if (-not $row) { return }
    $want = [bool]$cb.IsChecked
    $cur = switch ($row.Kind) {
        'dir'  { [bool]$row.Dir.enabled -and -not $row.Dir.missing }
        'lane' { $g = @($row.Lane.Group); ($g.Count -gt 0 -and -not @($g | Where-Object { -not $_.enabled }).Count) }
        default { [bool]$row.Session.enabled }
    }
    if ($cur -eq $want) { return }
    try {
        $script:suppress = $true
        Set-RowTick -Row $row -Value $want
    } catch {
        Write-SRLog "gui tick failed: $($_.Exception.Message)"
        Set-Status "could not change that tick: $($_.Exception.Message)" 'bad'
    } finally { $script:suppress = $false }
}
$ui.RowList.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent,   $tickHandler)
$ui.RowList.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent, $tickHandler)

# ONE handler for every button inside the list, told apart by its Tag.
# OriginalSource for the same reason as the tick handler above.
# A name in the NEEDS YOU band goes to its row. The band exists to shorten the
# distance between "something wants you" and "you are looking at it"; making the
# operator find the row by hand would leave most of that distance in place.
#
# OriginalSource, never Source: a routed event that crosses a template boundary
# has its Source RETARGETED to the templated parent, so Source here is the
# ItemsControl and the cast to Button yields $null. That mistake made every
# control in a row silently dead once already.
# The flash is set to run until the window reaches the foreground, so stopping it
# on Activated is belt and braces -- and it also covers the case where the window
# is brought up by something other than a click on the flashing button.
$window.Add_Activated({ Stop-TaskbarFlash })

# --- the reading pane's own controls ---------------------------------------
$ui.ReadBack.Add_Click({    Invoke-Guarded { Hide-ReadPane }        'close the reading pane' })
$ui.ReadRefresh.Add_Click({ Invoke-Guarded { Update-ReadDocument }  'reread the conversation' })
$ui.ReadOpen.Add_Click({
    Invoke-Guarded {
        # The pane is for reading. Anything you want to DO still happens in the
        # real session, so this is the handoff rather than a second front end.
        if (-not $script:readSession) { return }
        $row = $null
        foreach ($r in $script:rows) {
            if ($r.Kind -eq 'session' -and $r.Session.sessionId -eq $script:readSession.sessionId) { $row = $r; break }
        }
        if ($row) { Invoke-RowLaunch $row } else { Set-Status 'that conversation is no longer in the list' 'warn' }
    } 'open the terminal for this conversation'
})

# Double-click a conversation to read it -- the gesture people already try.
$ui.RowList.Add_MouseDoubleClick({
    param($sender, $e)
    Invoke-Guarded {
        $row = $ui.RowList.SelectedItem
        if ($row -and $row.Kind -eq 'session') { $e.Handled = $true; Show-ReadPane $row }
    } 'open the reading pane'
})

$ui.NeedsList.AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    $btn = $e.OriginalSource -as [System.Windows.Controls.Button]
    if (-not $btn) { return }
    $e.Handled = $true
    Invoke-Guarded {
        $key = "$($btn.Tag)"
        if (-not $key) { return }
        $idx = -1
        for ($i = 0; $i -lt $script:rows.Count; $i++) { if ($script:rows[$i].Key -eq $key) { $idx = $i; break } }
        if ($idx -lt 0) {
            # Filtered or folded out of the list. Say so rather than doing nothing
            # -- a button that silently declines is indistinguishable from broken.
            Set-Status 'that conversation is not in the current view - clear the filters, or expand its project' 'warn'
            return
        }
        $ui.RowList.SelectedIndex = $idx
        $ui.RowList.ScrollIntoView($script:rows[$idx])
        $null = $ui.RowList.Focus()
    } 'go to the waiting conversation'
})

$ui.RowList.AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    $btn = $e.OriginalSource -as [System.Windows.Controls.Button]
    if (-not $btn) { return }
    $row = $btn.DataContext -as [SRGui.Row]
    if (-not $row) { return }
    $e.Handled = $true
    try {
        switch ("$($btn.Tag)") {
            'fold' {
                $script:collapsed[$row.Key] = -not [bool]$script:collapsed[$row.Key]
                Update-List -KeepKey $row.Key
            }
            'unpin'  { $ui.RowList.SelectedItem = $row; Set-RowUnpin $row }
            'launch' { $ui.RowList.SelectedItem = $row; Invoke-RowLaunch $row }
            'spawn'  { $ui.RowList.SelectedItem = $row; Invoke-RowSpawn $row }
        }
    } catch {
        Write-SRLog "gui row action failed: $($_.Exception.Message)"
        Set-Status "that did not work: $($_.Exception.Message)" 'bad'
    }
})

$ui.RowList.Add_SelectionChanged({ Invoke-Guarded { Update-Selection } 'the selection' })

# --- search, debounced so 150 rows are not rebuilt on every keystroke ---
$script:searchTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:searchTimer.Interval = [TimeSpan]::FromMilliseconds(160)
$script:searchTimer.Add_Tick({
    $script:searchTimer.Stop()
    $t = $ui.SearchBox.Text
    $script:filter = $(if ([string]::IsNullOrWhiteSpace($t)) { $null } else { $t.Trim() })
    Update-List
    if ($script:filter) {
        $n = @($script:rows | Where-Object { $_.Kind -eq 'session' }).Count
        Set-Status $(if ($n) { "$n conversation(s) match '$($script:filter)'" } else { "nothing matches '$($script:filter)'" }) $(if ($n) { 'info' } else { 'warn' })
    } else { Set-Status '' 'info' }
})
$ui.SearchBox.Add_TextChanged({ $script:searchTimer.Stop(); $script:searchTimer.Start() })
$ui.ClearSearch.Add_Click({ Invoke-Guarded { $ui.SearchBox.Text = ''; $null = $ui.RowList.Focus() } 'clear the filter' })

# --- toolbar ---
$ui.RescanBtn.Add_Click({ Invoke-Guarded { Start-Rescan } 'rescan' })
$ui.TickAll.Add_Click({ Invoke-Guarded { Set-AllTicks $true } 'tick all' })
$ui.TickNone.Add_Click({ Invoke-Guarded { Set-AllTicks $false } 'tick none' })
$ui.UnpinAll.Add_Click({ Invoke-Guarded {
    foreach ($d in $script:dirs) { foreach ($s in @(Get-Visible $d)) { Set-Pin $s $false } }
    $script:dirty = $true
    Update-AllTicks
    Set-Status 'every conversation handed back to the rolling auto-tick' 'info'
} 'unpin all' })
$ui.CollapseAll.Add_Click({ Invoke-Guarded {
    foreach ($d in $script:dirs) {
        $script:collapsed[$d.path] = $true
        $lanes = Get-Lanes $d
        foreach ($lane in @($lanes)) { $script:collapsed["$($d.path)|$($lane.Name)"] = $true }
    }
    Update-List
} 'collapse all' })
$ui.ExpandAll.Add_Click({ Invoke-Guarded { $script:collapsed = @{}; Update-List } 'expand all' })

# W. Turning worktrees ON needs a rescan, because discovery skips them entirely
# while they are off. The config write is the same targeted replacement the
# terminal panel makes, so the hand-laid-out _README block is never reflowed.
function Invoke-WorktreeToggle {
    if ($script:suppress) { return }
    $want = [bool]$ui.WorktreeToggle.IsChecked
    if ($script:dirty) { Save-SRRegistry -Registry $script:reg; $script:dirty = $false }
    $started = Start-SRJob -Name 'writing the config' -Body $script:WorktreeJob -Data @{ Value = $want } -OnDone {
        param($res)
        if (-not $res -or -not $res.Ok) {
            Set-Status ("could not write includeWorktrees: {0}" -f $(if ($res) { $res.Why } else { 'no result' })) 'bad'
            try { $script:suppress = $true; $ui.WorktreeToggle.IsChecked = $script:showWt } finally { $script:suppress = $false }
            return
        }
        Start-Rescan
    }
    if (-not $started) {
        Set-Status 'still busy - one background pass at a time' 'warn'
        try { $script:suppress = $true; $ui.WorktreeToggle.IsChecked = $script:showWt } finally { $script:suppress = $false }
    }
}
$ui.WorktreeToggle.Add_Click({ Invoke-Guarded { Invoke-WorktreeToggle } 'the worktree toggle' })

$ui.LaunchTicked.Add_Click({ Invoke-Guarded { Invoke-LaunchTicked } 'launch everything ticked' })

# --- the selected row ---
$ui.SelTick.Add_Click({ Invoke-Guarded { if ($ui.RowList.SelectedItem) { Set-RowTick -Row $ui.RowList.SelectedItem -Value $null } } 'the tick' })
$ui.SelUnpin.Add_Click({ Invoke-Guarded { Set-RowUnpin $ui.RowList.SelectedItem } 'unpin' })
$ui.SelLaunch.Add_Click({ Invoke-Guarded { Invoke-RowLaunch $ui.RowList.SelectedItem } 'open now' })
$ui.SelSpawn.Add_Click({ Invoke-Guarded { Invoke-RowSpawn $ui.RowList.SelectedItem } 'new session here' })

# --- the spawn overlay ---
# --- the launch confirmation ---
$ui.CfCancel.Add_Click({ Invoke-Guarded { Close-Confirm; Set-Status 'cancelled - nothing was opened' 'warn' } 'cancel' })
$ui.CfOk.Add_Click({ Invoke-Guarded {
    # Read the decision out of script scope, then clear it BEFORE launching, so a
    # second press cannot open the same tabs twice.
    $items = $script:confirmItems
    $what  = $script:confirmWhat
    Close-Confirm
    if ($items) { Start-Launch -Items $items -What $what }
} 'open' })

$ui.OvCancel.Add_Click({ Invoke-Guarded { Close-Overlay; Set-Status 'not spawned' 'info' } 'cancel' })
$ui.OvOk.Add_Click({ Invoke-Guarded { Confirm-Spawn } 'spawn' })
$ui.OvName.Add_KeyDown({ param($s, $e)
    if ($e.Key -eq 'Return') { $e.Handled = $true; Confirm-Spawn }
    elseif ($e.Key -eq 'Escape') { $e.Handled = $true; Close-Overlay }
})

# --- save / close ---
function Save-Now {
    Save-SRRegistry -Registry $script:reg
    $script:dirty = $false
    Update-Header
}

# SAVING DOES NOT CLOSE THE WINDOW. It used to, and that was the defect: this is
# a panel the operator keeps open and adjusts, so writing the ticks is a
# CHECKPOINT, not a way out. Measured 2026-08-22: the Save button called
# $window.Close() while Ctrl+S did not, so the same act had two different
# outcomes depending on how it was reached. Both now go through here, and the
# only things that close the window are Close, ESC on an empty filter, and the
# title bar.
function Invoke-Save {
    if ($script:busy) { Set-Status 'still busy - one background pass at a time' 'warn'; return }
    try { Save-Now } catch {
        Set-Status "could not save: $($_.Exception.Message)" 'bad'
        return
    }
    # Says what was written and when, so a second press is visibly a second save
    # rather than a button that might not have done anything.
    Set-Status ("saved at {0} - the ticks are in sessions-registry.json. The window stays open." -f (Get-Date -Format 'HH:mm:ss')) 'ok'
}
$ui.SaveBtn.Add_Click({ Invoke-Guarded { Invoke-Save } 'save' })

$ui.CancelBtn.Add_Click({
    if ($script:dirty -and (Show-Confirm "Discard the tick changes made in this window?`n`nNothing that has been launched is affected - only the logon selection." 'Close without saving') -ne 'Yes') { return }
    $script:exitMode = $(if ($script:dirty) { 'cancelled' } else { 'closed' })
    $window.Close()
})

# --- keyboard, mirroring the terminal panel ---
$window.Add_PreviewKeyDown({ param($s, $e)
    # Typing in a text box must never reach the single-key shortcuts.
    if ($e.OriginalSource -is [System.Windows.Controls.TextBox]) {
        if ($e.Key -eq 'Escape' -and $e.OriginalSource -eq $ui.SearchBox) {
            $e.Handled = $true
            if ($ui.SearchBox.Text) { $ui.SearchBox.Text = '' } else { $null = $ui.RowList.Focus() }
        }
        return
    }
    # While the reading pane is up it owns the keyboard, except for the two keys
    # that get you out of it. Letting L or SPACE through would act on a row that
    # is not on screen -- the list is hidden, so there is nothing to aim at.
    if ($ui.ReadPane.Visibility -eq $V_Show) {
        if ($e.Key -eq 'Escape') { $e.Handled = $true; Hide-ReadPane }
        elseif ($e.Key -eq 'R' -and -not $script:busy) { $e.Handled = $true; Update-ReadDocument }
        return
    }
    if ($ui.Overlay.Visibility -eq $V_Show) { return }
    if ($ui.ConfirmOverlay.Visibility -eq $V_Show) {
        # While a confirmation is up it is the only thing on the screen that can
        # be answered: ESC declines it, ENTER takes it, everything else waits.
        if ($e.Key -eq 'Escape') { $e.Handled = $true; Close-Confirm; Set-Status 'cancelled - nothing was opened' 'warn' }
        elseif ($e.Key -eq 'Return') { $e.Handled = $true; $ui.CfOk.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        return
    }

    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    $row  = $ui.RowList.SelectedItem
    try {
        if ($ctrl) {
            switch ($e.Key) {
                'F' { $e.Handled = $true; $null = $ui.SearchBox.Focus(); $ui.SearchBox.SelectAll() }
                'S' { $e.Handled = $true; Invoke-Save }
            }
            return
        }
        switch ($e.Key) {
            'F3'     { $e.Handled = $true; $null = $ui.SearchBox.Focus(); $ui.SearchBox.SelectAll() }
            'Escape' {
                $e.Handled = $true
                if ($ui.SearchBox.Text) { $ui.SearchBox.Text = '' }
                else { $ui.CancelBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent))) }
            }
            'Space'  { if ($row -and -not $script:busy) { $e.Handled = $true; Set-RowTick -Row $row -Value $null } }
            'Left'   { if ($row -and $row.Kind -ne 'session') { $e.Handled = $true; $script:collapsed[$row.Key] = $true;  Update-List -KeepKey $row.Key } }
            'Right'  { if ($row -and $row.Kind -ne 'session') { $e.Handled = $true; $script:collapsed[$row.Key] = $false; Update-List -KeepKey $row.Key } }
            'L'      { if ($row -and -not $script:busy) { $e.Handled = $true; Invoke-RowLaunch $row } }
            'S'      { if ($row -and -not $script:busy) { $e.Handled = $true; Invoke-RowSpawn $row } }
            'X'      { if (-not $script:busy) { $e.Handled = $true; Invoke-LaunchTicked } }
            'R'      { if (-not $script:busy) { $e.Handled = $true; Start-Rescan } }
            'U'      { if ($row -and -not $script:busy) { $e.Handled = $true; Set-RowUnpin $row } }
            # ENTER reads the conversation. It is the one gesture with no other
            # meaning on a list row, and reading is now the commonest thing to
            # want to do with one.
            'Return' { if ($row -and $row.Kind -eq 'session' -and -not $script:busy) { $e.Handled = $true; Show-ReadPane $row } }
            'A'      { if (-not $script:busy) { $e.Handled = $true; Set-AllTicks $true } }
            'N'      { if (-not $script:busy) { $e.Handled = $true; Set-AllTicks $false } }
            'W'      { if (-not $script:busy) {
                           $e.Handled = $true
                           try { $script:suppress = $true; $ui.WorktreeToggle.IsChecked = -not [bool]$ui.WorktreeToggle.IsChecked } finally { $script:suppress = $false }
                           Invoke-WorktreeToggle
                       } }
            'Oem2'   { $e.Handled = $true; $null = $ui.SearchBox.Focus(); $ui.SearchBox.SelectAll() }
        }
    } catch {
        Write-SRLog "gui key failed: $($_.Exception.Message)"
        Set-Status "that did not work: $($_.Exception.Message)" 'bad'
    }
})

$window.Add_SourceInitialized({
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
        # 20 is DWMWA_USE_IMMERSIVE_DARK_MODE; it was 19 on the builds that first
        # carried it, so fall back rather than leaving a light frame.
        $on = 1
        if ([SRGui.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$on, 4) -ne 0) {
            $on = 1
            $null = [SRGui.Dwm]::DwmSetWindowAttribute($h, 19, [ref]$on, 4)
        }
    } catch { }
})

# --- closing ---
$window.Add_Closing({ param($s, $e)
    if (-not $script:exitMode -and $script:dirty) {
        $r = [System.Windows.MessageBox]::Show($window,
            "Save the tick changes made in this window before closing?",
            'Claude sessions',
            [System.Windows.MessageBoxButton]::YesNoCancel,
            [System.Windows.MessageBoxImage]::Question)
        if ($r -eq 'Cancel') { $e.Cancel = $true; return }
        if ($r -eq 'Yes') { try { Save-Now } catch { } }
    }
    foreach ($t in @($script:searchTimer, $script:pollTimer, $script:liveTimer)) { if ($t) { $t.Stop() } }
    # A worker still running would keep the process alive after the window has
    # gone. Stopping it is safe: nothing here half-writes the registry -- every
    # write is an atomic replace under the named mutex.
    if ($script:jobPs) {
        try { $script:jobPs.Stop() } catch { }
        try { $script:jobPs.Dispose() } catch { }
        try { $script:jobRs.Dispose() } catch { }
        $script:jobPs = $null
    }
})

# --- the two timers that keep the window honest ---
$script:pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:pollTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:pollTimer.Add_Tick({ try { Complete-SRJob } catch { Write-SRLog "gui poll failed: $($_.Exception.Message)" } })
$script:pollTimer.Start()

# DIVERGENCE from the terminal panel, deliberate: there, R is the only thing that
# re-checks what is live. A window that sits open all day would go stale, so the
# liveness probe (and only the probe -- no scan, no writes, no launches) repeats
# on a timer, and the header says when it last ran. Set the interval to 0 to turn
# this off and rely on Rescan alone.
$script:liveIntervalSeconds = 60
if ($script:liveIntervalSeconds -gt 0) {
    $script:liveTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:liveTimer.Interval = [TimeSpan]::FromSeconds($script:liveIntervalSeconds)
    $script:liveTimer.Add_Tick({ try { if (-not $script:busy) { Start-LiveProbe } } catch { } })
    $script:liveTimer.Start()
}

# ---------------------------------------------------------------------------
# First fill: show the registry as it stands immediately, then scan behind it, so
# the window is on screen and readable rather than blank while the scan runs.
# ---------------------------------------------------------------------------
Set-Registry -Registry (Get-SRRegistry) -Config $script:cfg
try { $script:suppress = $true; $ui.WorktreeToggle.IsChecked = $script:showWt } finally { $script:suppress = $false }
Update-List
Set-Status 'the checkbox on the left decides what reopens at logon. Open, on the right, launches now - the two never touch.' 'info'

$window.Add_ContentRendered({
    $null = $ui.RowList.Focus()
    if ($script:rows.Count) { $ui.RowList.SelectedIndex = 0 }
    if (-not $NoScan) { Start-Rescan } else { Start-Rescan -NoScanPass }
})

$null = $window.ShowDialog()

switch ($script:exitMode) {
    'saved'     { Write-Host "  Saved. Registry: $SR_RegistryPath" }
    'closed'    { Write-Host "  Closed. Registry: $SR_RegistryPath" }
    'cancelled' { Write-Host "  Closed - unsaved tick changes discarded." }
}
exit 0
