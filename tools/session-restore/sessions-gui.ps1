#requires -Version 5.1
<#
.SYNOPSIS
    The session control panel, as a window. A graphical equivalent of
    restore-sessions.ps1 -- same model, same guards, same registry.

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
    the retired terminal panel are re-implemented here; see gui/gui-model.ps1.

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
        // Group bookkeeping. Plain fields: only PowerShell reads them, and nothing
        // in the XAML binds to them.
        //
        // TickCount is counted while the rows are BUILT, so a header reflects what
        // survived the filter rather than what the registry holds. A header that
        // disagreed with the rows under it would be worse than no header at all.
        public int TickCount = 0;
        // 🪤 The RAW total, kept apart from Counts because Counts is the FORMATTED
        // caption. Re-deriving the number from the caption works exactly once:
        // the second paint parses "12  -  4 armed" and gets 12 or 0 depending on
        // the separator, and the header quietly starts lying.
        public int GroupTotal = 0;
        // 0 project, 1 lane or a session in a single-lane project, 2 a session
        // under a lane. The painter turns it into an indent; nothing else reads it.
        public int Depth = 0;
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

        // ITALIC MEANS NOBODY CHOSE THIS NAME -- it is claude's own generated
        // title for the conversation, shown because the alternative was the word
        // "(untitled)" on 97 of 204 rows.
        //
        // It has to be a channel of its own. NameBrush is already carrying four
        // separate facts (project disabled, live, unticked, stale) and NameSize
        // carries the tree depth, so overloading either would make two unrelated
        // things look the same. Slant is orthogonal to both, and it survives this
        // window being monochrome by design -- which is why nothing here is ever
        // told apart by colour.
        private FontStyle _nameStyle = FontStyles.Normal;
        public FontStyle NameStyle { get { return _nameStyle; } set { if (!_nameStyle.Equals(value)) { _nameStyle = value; N("NameStyle"); } } }

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
        // A PROPERTY, not a field. WPF cannot bind to a field at all: the
        // binding resolves to nothing and the cell renders blank with no error,
        // which is how an entire populated column stayed invisible once already.
        private string _lastPrompt = "";
        public string LastPrompt { get { return _lastPrompt; } set { if (_lastPrompt != value) { _lastPrompt = value; N("LastPrompt"); } } }

        // What the conversation is ABOUT, shown after its name. Ten rows all
        // called "(untitled)" are indistinguishable from each other; the last
        // prompt is the cheapest thing that tells them apart, and the name
        // column is mostly empty anyway.
        private string _subtitle = "";
        public string Subtitle { get { return _subtitle; } set { if (_subtitle != value) { _subtitle = value; N("Subtitle"); } } }
        private Visibility _subtitleVisibility = Visibility.Collapsed;
        public Visibility SubtitleVisibility { get { return _subtitleVisibility; } set { if (_subtitleVisibility != value) { _subtitleVisibility = value; N("SubtitleVisibility"); } } }

        // ------------------------------------------------------------------
        // THE INBOX. Bound only by InboxTemplate; the tree template never sees
        // these. Kept separate from the tree's properties rather than overloaded
        // onto them so that a change to one view provably cannot alter the
        // other -- the two lists are shown one at a time and share nothing but
        // this class.
        //
        // Every one of these is a PROPERTY. WPF cannot bind to a public field:
        // it resolves to nothing, renders blank, and reports no error at all.
        // ------------------------------------------------------------------

        // What the conversation last said. The body of the row.
        private string _said = "";
        public string Said { get { return _said; } set { if (_said != value) { _said = value; N("Said"); } } }

        private Brush _saidBrush;
        public Brush SaidBrush { get { return _saidBrush; } set { if (_saidBrush != value) { _saidBrush = value; N("SaidBrush"); } } }

        private Visibility _saidVisibility = Visibility.Collapsed;
        public Visibility SaidVisibility { get { return _saidVisibility; } set { if (_saidVisibility != value) { _saidVisibility = value; N("SaidVisibility"); } } }

        private string _saidTip = "";
        public string SaidTip { get { return _saidTip; } set { if (_saidTip != value) { _saidTip = value; N("SaidTip"); } } }

        // Which project it belongs to. A label on the row, not a parent of it.
        private string _project = "";
        public string Project { get { return _project; } set { if (_project != value) { _project = value; N("Project"); } } }

        private Visibility _projectVisibility = Visibility.Collapsed;
        public Visibility ProjectVisibility { get { return _projectVisibility; } set { if (_projectVisibility != value) { _projectVisibility = value; N("ProjectVisibility"); } } }

        // How long since it last moved.
        private string _stamp = "";
        public string Stamp { get { return _stamp; } set { if (_stamp != value) { _stamp = value; N("Stamp"); } } }

        private Brush _stampBrush;
        public Brush StampBrush { get { return _stampBrush; } set { if (_stampBrush != value) { _stampBrush = value; N("StampBrush"); } } }

        // A band heading shows its count where a conversation shows its prose.
        private Visibility _countsVisibility = Visibility.Collapsed;
        public Visibility CountsVisibility { get { return _countsVisibility; } set { if (_countsVisibility != value) { _countsVisibility = value; N("CountsVisibility"); } } }

        // The row's action. Present on conversations, never on a band.
        private Visibility _actionVisibility = Visibility.Collapsed;
        public Visibility ActionVisibility { get { return _actionVisibility; } set { if (_actionVisibility != value) { _actionVisibility = value; N("ActionVisibility"); } } }

        private string _jumpLabel = "Open";
        public string JumpLabel { get { return _jumpLabel; } set { if (_jumpLabel != value) { _jumpLabel = value; N("JumpLabel"); } } }

        private bool _canJump = true;
        public bool CanJump { get { return _canJump; } set { if (_canJump != value) { _canJump = value; N("CanJump"); } } }

        private string _jumpTip = "";
        public string JumpTip { get { return _jumpTip; } set { if (_jumpTip != value) { _jumpTip = value; N("JumpTip"); } } }

        // Which band this row sits under. Used to scroll a pill to its band and
        // to keep the selection when the list is rebuilt.
        private string _band = "";
        public string Band { get { return _band; } set { if (_band != value) { _band = value; N("Band"); } } }

        // THE TICK IS A CONVERSATION'S ALONE now that project and lane rows are
        // gone, and the one row that is not a conversation - "N older, show" -
        // must not offer one either.
        private Visibility _tickVisibility = Visibility.Visible;
        public Visibility TickVisibility { get { return _tickVisibility; } set { if (_tickVisibility != value) { _tickVisibility = value; N("TickVisibility"); } } }

        // The age window's own row: what it left out, and the way back in.
        // MOVED SINCE YOU LAST LOOKED. The unread dot.
        private Visibility _movedVisibility = Visibility.Collapsed;
        public Visibility MovedVisibility { get { return _movedVisibility; } set { if (_movedVisibility != value) { _movedVisibility = value; N("MovedVisibility"); } } }

        private Visibility _moreVisibility = Visibility.Collapsed;
        public Visibility MoreVisibility { get { return _moreVisibility; } set { if (_moreVisibility != value) { _moreVisibility = value; N("MoreVisibility"); } } }

        private string _moreLabel = "";
        public string MoreLabel { get { return _moreLabel; } set { if (_moreLabel != value) { _moreLabel = value; N("MoreLabel"); } } }

        private string _moreTip = "";
        public string MoreTip { get { return _moreTip; } set { if (_moreTip != value) { _moreTip = value; N("MoreTip"); } } }

        // Where the id went when it lost its column: eight hex characters are
        // worth having but not worth 88 pixels on every row.
        private string _nameTip = "";
        public string NameTip { get { return _nameTip; } set { if (_nameTip != value) { _nameTip = value; N("NameTip"); } } }
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
# file. $Pal is filled in below the window load.
#
# IT IS CALLED $Pal AND NOT $C ON PURPOSE.
#
# PowerShell variable names are case-insensitive AND its scoping is dynamic: a
# function reads a name by walking up the CALL STACK, so a `foreach ($c in ...)`
# in any caller shadows a global $C for every function that caller invokes. That
# is not a hazard you can avoid by being careful in new code -- three separate
# times in this file a loop variable called $c silently replaced the brush table
# with a Button or a state object, every $C.TextMax afterwards came back $null,
# and the next repaint threw "has text ... with a null brush". The third one was
# in Clear-AllFilters and lay dormant for weeks purely because the button that
# calls it had never been wired up.
#
# A name nobody reaches for as a loop variable removes the whole class.
# ---------------------------------------------------------------------------
$Pal = @{}
$Clear = [System.Windows.Media.Brushes]::Transparent
$Strike = [System.Windows.TextDecorations]::Strikethrough

# Slant, for a name that was GENERATED rather than chosen. Resolved once here
# for the same reason every other shared value in this block is: a row painter
# runs per row per repaint, and [System.Windows.FontStyles]::Italic resolved
# inline 200 times a paint is 200 type lookups for one constant.
$Italic  = [System.Windows.FontStyles]::Italic
$Upright = [System.Windows.FontStyles]::Normal

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
# THE AGE WINDOW for the All view. registryWindowDays (30) bounds what is
# TRACKED; nothing has ever bounded what is SHOWN, which is why 51 of the 143
# conversations on screen were between a week and a month old.
$script:listDays     = [double]$script:cfg.listDays
$script:showOlder    = $false
$script:olderCount   = 0
# The anchor for shift-click ticking: the last conversation whose tick was
# changed by hand, so a shift-click has something to draw a range from.
$script:tickAnchor   = $null
# The fast pass's index and its last-seen mtimes.
$script:byId         = @{}
$script:dirOf        = @{}
$script:mtimes       = @{}
$script:reallyClose  = $false
# The reading pane's share of the window, in pixels, remembered while the tool
# is open so closing and reopening it does not throw the split away.
$script:readHeight   = 340.0
$script:readOpen     = $false
# THE SEEN GATE. What the pane is currently showing, and how far into the
# transcript it had read when it drew it. A reply typed against a stale document
# is a reply to something the session has already moved past, which is exactly
# the failure a tool that can type into thirteen consoles must not make easy.
$script:readShownFor = $null    # sessionId the document belongs to
$script:readShownAt  = $null    # transcript LastWriteTime when it was read
$script:castTargets  = @()

# ---------------------------------------------------------------------------
# THE SORT KEY STACK
#
# An ORDERED list of keys, applied in order, each with its own direction. Click
# a heading and it becomes the only key; shift-click and it joins the end of the
# stack. "Sorted by need, then newest" is a two-item stack and reads off the
# headings as "STATE ^1  WHEN v2".
#
# The DEFAULT is project A-Z, then newest first - which reads like the tree it
# replaced (a project's conversations together, newest at the top) while being
# something the headings can actually express: PROJECT and WHEN both carry an
# arrow from the first frame, so the mechanic teaches itself before it is used.
#
# In the INBOX the bands sit outside this entirely: they are what the inbox IS,
# so a sort reorders within a band and NEEDS YOU never stops being first.
# ---------------------------------------------------------------------------
# ONE STACK PER VIEW, and it is not a nicety.
#
# The two lists do not have the same columns. Sorting All by STATE and then WHEN
# and switching to the inbox showed "WHEN v2" with no "^1" anywhere, because the
# inbox has no STATE heading to put it on - a rank digit pointing at a key the
# operator cannot see or unset. Each list keeps its own stack, which is also
# what anyone expects: a sort belongs to the list you set it on.
$script:SortDefault = @{
    # The inbox is already grouped by band; within a band the only question is
    # what happened most recently.
    inbox = @( @{ Key = 'when'; Desc = $true } )
    # All reads like the tree it replaced - a project's conversations together,
    # newest at the top - and both keys have a heading, so the mechanic is
    # visible from the first frame.
    all   = @( @{ Key = 'project'; Desc = $false }, @{ Key = 'when'; Desc = $true } )
}
$script:sortKeysByView = @{}
foreach ($v in @($script:SortDefault.Keys)) {
    $script:sortKeysByView[$v] = @($script:SortDefault[$v] | ForEach-Object { @{ Key = $_.Key; Desc = $_.Desc } })
}

function Get-SortKeys { param([string]$View)
    if (-not $View) { $View = $script:viewMode }
    if (-not $script:sortKeysByView.ContainsKey($View)) { $View = 'all' }
    return @($script:sortKeysByView[$View])
}
function Set-SortKeys { param([string]$View, $Keys)
    if (-not $View) { $View = $script:viewMode }
    $script:sortKeysByView[$View] = @($Keys)
}
# Where each band sits when STATE is the key: the same order the inbox lists
# them in, so sorting by state and reading the inbox give the same sequence.
$script:BandOrder = @{ needs = 0; working = 1; idle = 2; quiet = 3 }
# The word on the heading, kept here rather than read back off the button: the
# code appends an arrow to Content, so reading Content to rebuild Content
# accumulates arrows.
$script:SortCaptions = @{
    logon   = 'LOGON'
    name    = 'CONVERSATION'
    project = 'PROJECT / LANE'
    state   = 'STATE'
    when    = 'WHEN'
}
$script:dirty        = $false
$script:exitMode     = $null

$script:running      = @{}   # sessionId -> a claude.exe holds it (certain)
$script:live         = @{}   # sessionId -> its transcript moved recently (inferred)
$script:launching    = @{}   # sessionId -> when we launched it (optimistic, expires)
$script:conv         = @{}   # sessionId -> what the TRANSCRIPT implies it is doing
$script:said         = @{}   # sessionId -> what it LAST SAID, live/recent only
$script:agents       = @{}   # sessionId -> what CLAUDE ITSELF says, for live ones
$script:unattributed = 0
$script:probedAt     = $null

# THE VIEW: 'inbox' | 'all'.
#
#   inbox    flat, cross-project, ordered by what each conversation needs from
#            you. The default, because "who needs me" is why the window gets
#            opened; the tree could only answer it by being read end to end.
#   tree     project / lane / conversation, with folding and per-project counts.
#   restore  the same tree, with the logon tick and its bulk actions in front.
#
# Restore is deliberately a MODE rather than a column now. It is a once-per-
# reboot concern that was holding the leftmost column, a header pole and the
# loudest button on the window.
$script:viewMode = 'inbox'

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
# THE BAND, not the last-known transcript state. $script:fState held the latter
# and made the chip called "waiting" select 110 of 143 conversations while the
# band called NEEDS YOU held 6 -- one word meaning two things on one screen.
# Filtering on Get-InboxBand ties a chip's count to a band's count by
# construction. The last-known state survives as the words on a row ("was
# waiting"), which is the only place it was ever the right answer.
$script:fBand     = @{}     # needs | working | idle | quiet
$script:fLive     = @{}     # live | notlive | gone
$script:fTick     = @{}     # ticked | unticked

# WHICH GROUPS ARE SHUT, keyed by project path and by "path|lane". Absent
# means open. ROSTER opens with everything shut on purpose: 21 projects is an
# index you can read, 173 conversations is the flood that made the operator ask
# for grouping in the first place.
$script:fold     = @{}

# Is the list showing hidden conversations? Off by default, and never persisted:
# revealing them is something you do for a moment, not a mode you leave on.
$script:showHidden = $false

# The question the open conversation is waiting on, as it was when the panel was
# last drawn. Re-read and compared before anything is sent, because the whole
# arrow-key choreography assumes the menu has not moved since.
$script:askPending = $null

# The sessions a confirmed relaunch will CLOSE. Separate from confirmItems, which
# is what it will open: those are different lists and only one of them can lose
# work, so they are never conflated.
$script:confirmKill = $null
$script:fPin      = @{}     # pinned | unpinned
$script:fAge      = @{}     # recent | stale
$script:fProject  = $null   # a project path, or $null for any
$script:fLane     = $null   # a lane name, or $null for any
$script:matchCount = 0
$script:totalCount = 0
# How many conversations sit in each band, over EVERYTHING rather than over what
# is currently shown. The band chips print it, which is what earns them
# permanent space: the line answers "how much is waiting on me" before it is
# clicked. Filled by Update-Header, which already walks every session.
$script:bandCount  = @{}

$script:visCache     = @{}
$script:rows         = New-Object System.Collections.Generic.List[object]
$script:inboxRows    = New-Object System.Collections.Generic.List[object]
$script:tabIndexQueued = $false
$script:pendingSpawn = $null
$script:firstFill    = $true


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
    $said    = @{}
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
            $cs = $null
            try { $cs = Get-SRConversationState -JsonlPath $j; $conv[$key] = $cs } catch { }
            # Same gate as the probe pass, $running included: an idle session is
            # held by a process but its transcript has not moved, so a mtime-only
            # test would silently drop the very rows the inbox is for.
            if ($live[$key] -or $running[$key] -or ($cs -and -not $cs.Stale)) {
                try { $said[$key] = Get-SRLastSaid -JsonlPath $j } catch { }
            }
        }
    }
    # What claude itself says, which beats inference for anything still running.
    # ~960 ms, so it belongs here on the background pass and nowhere near a repaint.
    $agents = Get-SRAgentStatus -Refresh
    [PSCustomObject]@{ Registry = $r; Config = $cfg; Running = $running; Live = $live; Conv = $conv; Said = $said; Agents = $agents; Unattributed = $unattr; At = (Get-Date) }
}

# Liveness only. No scan, nothing written, nothing launched.
$script:ProbeJob = {
    . (Join-Path $SRHere '_common.ps1')
    $running = Get-SRRunningIds -Refresh
    $unattr  = Get-SRUnattributedCount
    $live    = @{}
    $conv    = @{}
    $said    = @{}
    foreach ($s in @($SRData.Sessions)) {
        $j   = Get-SRTranscriptPath -Dir $s.Cwd -SessionId $s.Id -Recorded $s.Jsonl
        $key = "$($s.Id)".ToLower()
        if (Test-SRTranscriptLive -JsonlPath $j) { $live[$key] = $true }
        # DOING has to refresh on the same cadence as liveness or the column
        # would freeze at whatever it said when the window opened, while the
        # "as of" stamp beside it kept moving. That reads as a lie.
        $cs = $null
        try { $cs = Get-SRConversationState -JsonlPath $j; $conv[$key] = $cs } catch { }

        # WHAT IT LAST SAID -- the inbox row's body, and the only genuinely new
        # cost in this loop. Gated per the 2026-08-22 decision: the registry
        # tracks 117 conversations and one nobody has touched in a week cannot
        # have said anything new since the last pass. Measured 0-33 ms each on
        # the ~14 that qualify.
        #
        # $running is part of the gate, not just $live. An IDLE session has been
        # sitting at its prompt saying nothing, so its transcript has NOT moved
        # recently and it reads as stale -- yet a process is holding it and it
        # has a last reply, which is exactly what the inbox exists to show. With
        # only the mtime test, every idle row said "at its prompt, nothing
        # pending" and none of them said what it had actually done.
        if ($live[$key] -or $running[$key] -or ($cs -and -not $cs.Stale)) {
            try { $said[$key] = Get-SRLastSaid -JsonlPath $j } catch { }
        }
    }
    $agents = Get-SRAgentStatus -Refresh
    [PSCustomObject]@{ Running = $running; Live = $live; Conv = $conv; Said = $said; Agents = $agents; Unattributed = $unattr; At = (Get-Date) }
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
    $Pal[$k] = $b
}

$ui = @{}
foreach ($n in @(
    'SubTitle','SearchBox','ClearSearch','BusyText','RescanBtn','LiveSummary','TickSummary',
    'ProbeStamp','Unattributed','TickAll','TickNone','UnpinAll','SeenAll','ReadNote',
    'WorktreeToggle','LaunchTicked','RelaunchTicked','RowList','EmptyNote','SelName','SelPath','SelTick',
    'SelUnpin','SelLaunch','SelSpawn','StatusText','CancelBtn','SaveBtn','Overlay','OvTitle',
    'OvPath','OvWarnBox','OvWarn','OvName','OvCancel','OvOk',
    'ConfirmOverlay','CfTitle','CfMessage','CfNoteBox','CfNote','CfCancel','CfOk',
    'CastOverlay','CastLead','CastList','CastBox','CastWho','CastCancel','CastSend','CastBtn',
    # The filter row and the state summary. Every one of these exists in the XAML;
    # they were simply never added here, so $ui.<name> was $null and the first
    # assignment to one of them took the whole window down at startup with
    # "The property 'Text' cannot be found on this object". A name that is in the
    # markup but not in this list fails at RUNTIME and says nothing about which
    # element it was -- so keep the two in step.
    'WaitSummary','FilterCount','ClearFilters','ProjectFilter','LaneFilter',
    'FlLive','FlNot','FlGone',
    'FbNeeds','FbWorking','FbIdle','FbQuiet',
    'FtOn','FtOff','FpPin','FpFree','FaRecent','FaStale',
    'ListShift','NeedsBand','NeedsLabel','NeedsList',
    'ReadPane','ReadName','ReadWhat','ReadView','ReadBack','ReadRefresh','ReadOpen',
    'ReadSplit','SplitRow','ReadRow',
    'LegendBox','LegendToggle','SendBox','SendBtn','SendNote',
    'FilterBar','BulkBtn','FilterChips','FilterMain','FilterMore',
    'MoreFilters','ActiveTokens',
    # The inbox: its own list, the view switch, and the three count pills that
    # are now buttons rather than decoration.
    'InboxList','ModeInbox','ModeAll','LivePill','WaitPill','TickPill',
    'ListHead','InboxHead','NowCaption','WorktreeCaption','ShowHidden',
    'AskPanel','AskHeader','AskText','AskOptions','AskNote'
)) { $ui[$n] = $window.FindName($n) }

# A name in the markup that is not in the list above is $null here, and the
# failure surfaces far away as a missing property. Say so at startup instead.
$uiMissing = @($ui.Keys | Where-Object { $null -eq $ui[$_] } | Sort-Object)
if ($uiMissing.Count) {
    throw ("these named elements are not in gui-window.xaml: " + ($uiMissing -join ', '))
}

# ---------------------------------------------------------------------------
# THE REST OF THE WINDOW, in five files.
#
# sessions-gui.ps1 was 4,867 lines. What stays here is the part that has to run
# IN ORDER: the types, the palette, the markup, $ui, then the handlers that bind
# them together. What moves out is everything that is just definitions, and it
# moves out HERE because a definition only has to exist before its first CALL -
# which is later, in the wiring below.
#
#   gui-model.ps1    what a conversation IS
#   gui-rows.ps1     what a row SHOWS
#   gui-notify.ps1   reaching you when you are not looking
#   gui-read.ps1     reading one conversation, and replying to it
#   gui-actions.ps1  doing things TO sessions
#
# Dot-sourced, not imported as modules: these need the SAME scope, because that
# is where $script:dirs, $ui and $Pal live. A module would get its own.
# ---------------------------------------------------------------------------
foreach ($part in @('gui-model.ps1', 'gui-rows.ps1', 'gui-notify.ps1', 'gui-read.ps1', 'gui-actions.ps1')) {
    $partPath = Join-Path $here (Join-Path 'gui' $part)
    if (-not (Test-Path -LiteralPath $partPath)) { throw "missing part of the window: $partPath" }
    . $partPath
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
        'bad'  { $ui.StatusText.Text = $(if ($Message) { '!  ' + $Message } else { '' }); $ui.StatusText.Foreground = $Pal.TextMax }
        'warn' { $ui.StatusText.Text = $Message; $ui.StatusText.Foreground = $Pal.TextHigh }
        'ok'   { $ui.StatusText.Text = $Message; $ui.StatusText.Foreground = $Pal.TextHigh }
        default { $ui.StatusText.Text = $Message; $ui.StatusText.Foreground = $Pal.TextMid }
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
# Building the rows. Same shape as the ported Build-Rows: while
# filtering, a project or lane is kept only if something under it survived --
# an empty repo header is just noise -- and a fold is ignored, because it would
# hide the very rows that were searched for.
# ---------------------------------------------------------------------------
function New-Row { param([string]$Kind, [string]$Key, $Dir, $Lane, $Session)
    $r = New-Object SRGui.Row
    $r.Kind = $Kind; $r.Key = $Key; $r.Dir = $Dir; $r.Lane = $Lane; $r.Session = $Session
    return $r
}

# ONE CONVERSATION, ONE ROW, ACROSS EVERY PROJECT.
#
# This was a tree: a project row, a lane row under it, conversations under that.
# 143 conversations rendered as 195 rows, and ELEVEN OF THE FIFTEEN PROJECTS had
# exactly one lane, called "main" - a row that said nothing, under a row that
# said the same thing. AlgoTrader alone was 89 conversations across 23 lanes.
#
# It is flat now because of the SORT. A hierarchy cannot answer "the ten
# youngest across every project" however it is ordered; the tree could only ever
# sort within a lane. Project and lane became columns, which is also what let 52
# header rows go.
#
# THE AGE WINDOW is the other half. registryWindowDays bounds what is TRACKED at
# 30 days; nothing has ever bounded what is SHOWN, so 51 of the 143 on screen
# were between a week and a month old. Now the list is the last $listDays days -
# and NOTHING IS HIDDEN SILENTLY: what falls outside is counted and offered on a
# row of its own at the end.
#
# Two things the window never hides: anything a filter asked for (searching has
# to reach the whole registry, or the search is lying), and anything that is not
# in the NOT RUNNING band. Age is a proxy for attention, and a live conversation
# has your attention whatever its timestamp says.
# One key's value for one conversation. Every branch returns a value of a single
# comparable type: Sort-Object over a mixed column silently orders by the type
# name first, which looks like a sort that nearly works.
function Get-SortValue { param($Pick, [string]$Key)
    switch ($Key) {
        'when'    { return $Pick.At }
        'name'    { return "$(Get-SessionTitle $Pick.S $Pick.D)".ToLowerInvariant() }
        'project' {
            # BY THE STRING THE COLUMN SHOWS. It sorted by the project's
            # recency rank and then by lane, which reproduced the tree's own
            # order - and meant clicking a heading labelled "PROJECT / LANE"
            # ordered the list by something that is not on screen. A column
            # heading has to sort by its column.
            $lane = $(if ($Pick.L) { "$($Pick.L.Name)" } else { 'main' })
            $proj = Split-Path $Pick.D.path -Leaf
            return $(if ($lane -and $lane -ne 'main') { "$proj / $lane" } else { $proj }).ToLowerInvariant()
        }
        'logon'   { return $(if ($Pick.S.enabled) { 0 } else { 1 }) }
        'state'   {
            # BY WHAT IT WANTS FROM YOU, not alphabetically: "idle" before
            # "needs" before "working" is an ordering of words, not of urgency.
            $b = Get-InboxBand $Pick.S
            $r = $script:BandOrder[$b]
            if ($null -eq $r) { $r = 9 }
            return [int]$r
        }
    }
    return ''
}

# Apply the stack. Sort-Object is stable in PowerShell, so passing every key at
# once and passing them one at a time are the same answer; one call is cheaper.
function Sort-Picked { param($Picked)
    # COPIED ELEMENT BY ELEMENT, and returned WITHOUT a leading comma. Two traps
    # meet in this one function:
    #   @($Picked) throws "Argument types do not match" when $Picked is a
    #     List[object] -- which Build-Rows hands it -- on PowerShell 5.1;
    #   ",@()" around an EMPTY result is a one-element array holding the empty
    #     array, so an empty band came back with Count 1, the "nothing here"
    #     guard did not fire, and New-Row was handed @() as its directory. The
    #     symptom was Get-SessionTitle dying on a null path at startup.
    $items = New-Object System.Collections.ArrayList
    foreach ($x in $Picked) { $null = $items.Add($x) }
    if (-not $items.Count) { return @() }
    $props = @()
    foreach ($k in @(Get-SortKeys)) {
        $key = $k.Key
        $props += @{ Expression = [scriptblock]::Create("Get-SortValue `$_ '$key'"); Descending = [bool]$k.Desc }
    }
    if (-not $props.Count) { return $items }
    return $items | Sort-Object $props
}

# Click: this column alone, and clicking the column that is already the only key
# flips it. Shift-click: add to the end of the stack, or flip it where it is.
function Invoke-SortHead { param([string]$Key, [bool]$Add, [string]$View)
    if (-not $Key) { return }
    if (-not $View) { $View = $script:viewMode }
    $cur = @(Get-SortKeys $View)
    $existing = $null
    foreach ($k in $cur) { if ($k.Key -eq $Key) { $existing = $k; break } }
    if ($Add) {
        if ($existing) { $existing.Desc = -not $existing.Desc }
        else { Set-SortKeys $View (@($cur) + @{ Key = $Key; Desc = $(if ($Key -eq 'when') { $true } else { $false }) }) }
    } else {
        $wasOnly = ($cur.Count -eq 1 -and $existing)
        $desc = $(if ($wasOnly) { -not $existing.Desc } else { ($Key -eq 'when') })
        Set-SortKeys $View @(@{ Key = $Key; Desc = $desc })
    }
    Update-List -ToTop
    Set-Status ("sorted by " + (Get-SortSummary)) 'info'
}

function Get-SortSummary {
    $words = @{ when = 'newest'; name = 'name'; project = 'project'; state = 'what it needs'; logon = 'the logon tick' }
    $bits = @()
    foreach ($k in @(Get-SortKeys)) {
        $w = $words[$k.Key]; if (-not $w) { $w = $k.Key }
        if ($k.Key -eq 'when') { $bits += $(if ($k.Desc) { 'newest first' } else { 'oldest first' }) }
        else { $bits += ("$w" + $(if ($k.Desc) { ' (reversed)' } else { '' })) }
    }
    if (-not $bits.Count) { return 'nothing' }
    return ($bits -join ', then ')
}

# The arrow IS the readout: a column with no arrow is not sorting, and the digit
# says where it sits in the stack. Nothing else on the heading changes, so the
# row of captions still reads as a row of captions.
$script:SortUp   = [string][char]0x2191
$script:SortDown = [string][char]0x2193
# Both heading rows at once. They are two Borders each wrapping a Grid, and the
# sortable captions are the Buttons in them - no per-column names to keep in
# step with the markup.
function Get-SortHeadControls {
    $out = @()
    foreach ($bar in @($ui.ListHead, $ui.InboxHead)) {
        if (-not $bar -or -not $bar.Child) { continue }
        foreach ($ch in $bar.Child.Children) {
            $b = $ch -as [System.Windows.Controls.Button]
            if ($b -and $b.Tag) { $out += $b }
        }
    }
    # NO LEADING COMMA: see Get-FilterDescription. ",@()" around an empty array
    # is a one-element array holding the empty array.
    return $out
}

function Update-SortHeads {
    foreach ($btn in @(Get-SortHeadControls)) {
        $key = "$($btn.Tag)"
        $base = "$($btn.Tag)"
        if ($btn.Tag -and $script:SortCaptions.ContainsKey($key)) { $base = $script:SortCaptions[$key] }
        # WHICH BAR THIS BUTTON IS IN decides both the caption and the stack it
        # is reporting on - the two lists have different columns and each keeps
        # its own sort.
        $inInbox = ($ui.InboxHead -and $btn.Parent -eq $ui.InboxHead.Child)
        $keys = @(Get-SortKeys $(if ($inInbox) { 'inbox' } else { 'all' }))
        # The inbox's project column is narrower and carries no lane, so it says
        # the shorter word.
        if ($key -eq 'project' -and $inInbox) { $base = 'PROJECT' }
        $idx = -1
        for ($i = 0; $i -lt $keys.Count; $i++) { if ($keys[$i].Key -eq $key) { $idx = $i; break } }
        if ($idx -lt 0) {
            $btn.Content = $base
            $btn.Foreground = $Pal.TextDim
        } else {
            $arrow = $(if ($keys[$idx].Desc) { $script:SortDown } else { $script:SortUp })
            $rank = $(if ($keys.Count -gt 1) { [string]($idx + 1) } else { '' })
            $btn.Content = "$base  $arrow$rank"
            # The PRIMARY key is the brightest thing on the row; a secondary key
            # is present but is not what you are reading the list by.
            $btn.Foreground = $(if ($idx -eq 0) { $Pal.TextMax } else { $Pal.TextMid })
        }
        $btn.ToolTip = "Sort by $base. Shift-click to add it after the keys already set, or to flip one. This list is sorted by $(Get-SortSummary)."
    }
}

function Build-Rows {
    $out = New-Object System.Collections.Generic.List[object]
    $filtering = Test-AnyFilter
    $script:dirRank = @{}
    for ($i = 0; $i -lt $script:dirs.Count; $i++) { $script:dirRank[[string]$script:dirs[$i].path] = $i }
    $matched = 0; $total = 0; $older = 0
    $cut = (Get-Date).AddDays(-$script:listDays)

    # 🪤 ORDERED BY NAME, NOT BY RECENCY RANK. $script:dirs is newest-project-first,
    # which is the right order for a list you SCAN and the wrong one for a list you
    # SEARCH -- and it splits projects that share a leaf name. Eight of these are
    # called "repo" (Millwright-experiments uns\R* epo), so recency order scatters
    # them down the screen and the answer to "where is my repo" becomes eight
    # answers. Name first, path second so the order is total and stable.
    $rosterDirs = @($script:dirs | Sort-Object @{ E = { Split-Path $_.path -Leaf } }, @{ E = { [string]$_.path } })
    foreach ($d in $rosterDirs) {
        # ASSIGN, THEN WRAP: Get-Lanes returns ",@(...)".
        $lanes = Get-Lanes $d

        # COLLECT BEFORE EMITTING. A header over an empty group is noise when
        # nothing is filtering and a lie about what matched when something is.
        $kept = New-Object System.Collections.Generic.List[object]
        $projTotal = 0; $projTicked = 0
        foreach ($lane in @($lanes)) {
            $inLane = New-Object System.Collections.Generic.List[object]
            foreach ($s in @($lane.Group)) {
                $total++
                if ([bool]$s.enabled) { $projTicked++ }
                $projTotal++
                if (-not (Test-RowMatch -Session $s -Dir $d -Lane $lane.Name)) { continue }
                if (-not $filtering -and -not $script:showOlder) {
                    $at = $(if ($s.lastActive) { [datetime]$s.lastActive } else { [datetime]'1970-01-01' })
                    if ($at -lt $cut -and (Get-InboxBand $s) -eq 'quiet') { $older++; continue }
                }
                $matched++
                $inLane.Add([PSCustomObject]@{
                    S = $s; D = $d; L = $lane
                    Rank = [int]$script:dirRank[[string]$d.path]
                    At = $(if ($s.lastActive) { [datetime]$s.lastActive } else { [datetime]'1970-01-01' })
                })
            }
            if ($inLane.Count) { $kept.Add([PSCustomObject]@{ Lane = $lane; Items = $inLane }) }
        }
        if (-not $kept.Count) { continue }

        $projKey = [string]$d.path
        $projRow = New-Row 'project' "project|$projKey" $d $null $null
        $projRow.GroupTotal = $projTotal
        $projRow.TickCount = $projTicked
        $projRow.Depth = 0
        $out.Add($projRow)

        # A FOLD IS IGNORED WHILE FILTERING. Hiding the very rows that were
        # searched for is the one thing a filter must never do.
        if ((-not $filtering) -and [bool]$script:fold[$projKey]) { continue }

        # 🪤 ONE LANE IS NOT A HIERARCHY. This was a tree once: 143 conversations
        # became 195 rows because ELEVEN OF FIFTEEN projects had a single lane
        # called 'main' -- a row that said nothing, under a row that said the same
        # thing. That is what retired it. A lane row is emitted only where a
        # project genuinely HAS more than one, which is where it carries
        # information: AlgoTrader's 23 lanes group, and a single-lane project goes
        # straight to its conversations.
        $showLanes = ($kept.Count -gt 1)
        foreach ($grp in $kept) {
            if ($showLanes) {
                $laneKey = "$projKey|$($grp.Lane.Name)"
                $laneRow = New-Row 'lane' "lane|$laneKey" $d $grp.Lane $null
                # 🪤 NOT @($grp.Items).Count. Items is a List[object], and wrapping one
                # in @() throws "Argument types do not match" on PowerShell 5.1. Ask
                # the list for its own Count, or enumerate it with .ToArray().
                $laneRow.GroupTotal = $grp.Items.Count
                $laneRow.TickCount = @($grp.Items.ToArray() | Where-Object { [bool]$_.S.enabled }).Count
                $laneRow.Depth = 1
                $out.Add($laneRow)
                if ((-not $filtering) -and [bool]$script:fold[$laneKey]) { continue }
            }
            $sorted = Sort-Picked $grp.Items.ToArray()
            foreach ($pk in @($sorted)) {
                $srow = New-Row 'session' "$($pk.D.path)|$($pk.L.Name)|$($pk.S.sessionId)" $pk.D $pk.L $pk.S
                $srow.Depth = $(if ($showLanes) { 2 } else { 1 })
                $out.Add($srow)
            }
        }
    }

    if ($older -gt 0 -or $script:showOlder) {
        $r = New-Row 'more' 'more|older' $null $null $null
        $r.Band = 'more'
        $out.Add($r)
    }

    $script:matchCount = $matched
    $script:totalCount = $total
    $script:olderCount = $older
    return ,$out
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
    if ($script:fBand.Count)  { $n++ }
    if ($script:fLive.Count)  { $n++ }
    if ($script:fTick.Count)  { $n++ }
    if ($script:fPin.Count)   { $n++ }
    if ($script:fAge.Count)   { $n++ }
    return $n
}

# A band chip says what it selects AND how much of it there is. Counted over
# every conversation, not over what survives the current filter: a count that
# shrank as you filtered would be telling you about the screen rather than about
# the machine, and the question it answers is about the machine.
function Update-BandChips {
    foreach ($pair in @(
        @{ C = $ui.FbNeeds;   K = 'needs';   L = 'Needs you' }
        @{ C = $ui.FbWorking; K = 'working'; L = 'Working' }
        @{ C = $ui.FbIdle;    K = 'idle';    L = 'Idle' }
        @{ C = $ui.FbQuiet;   K = 'quiet';   L = 'Not running' }
    )) {
        if (-not $pair.C) { continue }
        $k = [int]$script:bandCount[$pair.K]
        $pair.C.Content = $(if ($k) { "$($pair.L)  $k" } else { $pair.L })
        # A band with nothing in it is still worth showing -- its absence is
        # information -- but it is not worth clicking, and a chip that selects
        # nothing looks broken the moment it is pressed.
        $pair.C.IsEnabled = ($k -gt 0 -or $pair.C.IsChecked)
    }
}

# Every filter currently applied, as a token you can take off on its own. The
# chips are self-describing; the text box and the two dropdowns are not, and a
# filter you cannot see reads as missing data rather than as a filter.
function Update-ActiveTokens {
    if (-not $ui.ActiveTokens) { return }
    $ui.ActiveTokens.Children.Clear()
    foreach ($t in @(Get-FilterTokens)) {
        $b = New-Object System.Windows.Controls.Border
        $b.Background      = $Pal.Raised
        $b.BorderBrush     = $Pal.Hairline
        $b.BorderThickness = New-Object System.Windows.Thickness 1
        $b.CornerRadius    = New-Object System.Windows.CornerRadius 9
        $b.Padding         = New-Object System.Windows.Thickness 9, 2, 4, 2
        $b.Margin          = New-Object System.Windows.Thickness 0, 0, 6, 0
        $b.VerticalAlignment = 'Center'

        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'

        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $t.Label
        $tb.Foreground = $Pal.TextHigh
        $tb.FontSize = 11.5
        $tb.VerticalAlignment = 'Center'
        $null = $sp.Children.Add($tb)

        # The x carries the token's key in its Tag; one handler on the strip
        # reads it back. Building thirteen closures that each capture a
        # different key is the version of this that leaks.
        $x = New-Object System.Windows.Controls.Button
        $x.Content = 'x'
        $x.Tag     = $t.Key
        $x.Style   = $window.FindResource('BtnBare')
        $x.Width   = 16
        $x.Height  = 16
        $x.Margin  = New-Object System.Windows.Thickness 6, 0, 0, 0
        $x.Foreground = $Pal.TextMid
        $x.FontSize = 11
        $x.ToolTip = "Drop this filter"
        $x.SetValue([System.Windows.Automation.AutomationProperties]::NameProperty, "drop $($t.Label)")
        $null = $sp.Children.Add($x)

        $b.Child = $sp
        $null = $ui.ActiveTokens.Children.Add($b)
    }
}

function Update-FilterReadout {
    if (-not $ui.FilterCount) { return }
    $dims = Get-FilterDimensionCount
    Update-BandChips
    Update-ActiveTokens
    if ($dims -eq 0) {
        $ui.FilterCount.Text = "all {0} conversations" -f $script:totalCount
        $ui.FilterCount.Foreground = $Pal.TextDim
    } else {
        $ui.FilterCount.Text = "{0} of {1} shown" -f $script:matchCount, $script:totalCount
        # A filter that matches nothing is the loudest thing on the strip, because
        # it is the one state the operator most needs to notice.
        $ui.FilterCount.Foreground = $(if ($script:matchCount) { $Pal.TextHigh } else { $Pal.TextMax })
    }
    $ui.ClearFilters.IsEnabled = ($dims -gt 0)

    # The More fold carries the count of what is hidden inside it, so folding it
    # away can never conceal that something in there is filtering. The permanent
    # line needs no such badge: its chips ARE its readout.
    if ($ui.MoreFilters) {
        $hidden = 0
        if ($script:fLive.Count) { $hidden++ }
        if ($script:fTick.Count) { $hidden++ }
        if ($script:fPin.Count)  { $hidden++ }
        if ($script:fAge.Count)  { $hidden++ }
        $ui.MoreFilters.Content = $(if ($hidden) { "More  $hidden" } else { 'More' })
        # Open it on its own the moment one of ITS filters is applied from
        # somewhere else -- a keyboard shortcut, Clear undoing a chip. Being
        # filtered without being able to see by what is the harm this prevents.
        if ($hidden -gt 0 -and $ui.FilterMore.Visibility -ne $V_Show) {
            $ui.MoreFilters.IsChecked = $true
            $ui.FilterMore.Visibility = $V_Show
        }
    }
}

function Get-ChipControls {
    return @(
        $ui.FbNeeds, $ui.FbWorking, $ui.FbIdle, $ui.FbQuiet,
        $ui.FlLive, $ui.FlNot, $ui.FlGone,
        $ui.FtOn, $ui.FtOff, $ui.FpPin, $ui.FpFree,
        $ui.FaRecent, $ui.FaStale
    ) | Where-Object { $_ }
}

# One action clears everything: chips, both dropdowns and the text box. Anything
# less means the operator has to remember where they left a filter on, and a
# forgotten filter reads as missing data.
function Clear-AllFilters {
    $script:filter   = $null
    $script:fBand    = @{}
    $script:fLive    = @{}
    $script:fTick    = @{}
    $script:fPin     = @{}
    $script:fAge     = @{}
    $script:fProject = $null
    $script:fLane    = $null
    try {
        $script:suppress = $true
        $ui.SearchBox.Text = ''
        foreach ($chip in Get-ChipControls) { $chip.IsChecked = $false }
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
    $bands = @{ needs = 0; working = 0; idle = 0; quiet = 0 }
    foreach ($d in $script:dirs) {
        $v = @(Get-Visible $d)
        # THE BANDS COUNT EVERY DIRECTORY, INCLUDING THE ONES WHOSE FOLDER HAS GONE.
        #
        # This loop used to skip them, and it made the summary a count of a
        # DIFFERENT SET from the rows beneath it: 18 conversations live in
        # directories that no longer exist, the list shows all of them, and the
        # header quietly left them out. It is the same failure this function was
        # already rewritten once to make impossible, surviving in the one place
        # the rewrite did not look -- which is why the band chips now assert their
        # printed count against what they actually select.
        #
        # The TICK totals below keep the skip, and should: a directory that is
        # gone restores nothing, so counting its conversations as "ticked to
        # reopen" would be a promise the tool cannot keep.
        foreach ($s in $v) {
            # THE SAME PREDICATE THE BANDS USE, not merely similar evidence.
            #
            # Get-SessionState answers from the command line alone and put "12
            # live now" over an inbox listing 14, because `claude agents --json`
            # reports sessions whose id never appears on a command line. Trying
            # to fix it by ORing the three liveness tables then over-counted the
            # other way: a warm transcript with no process is NOT RUNNING to the
            # bands but looked live to the pill.
            #
            # Asking Get-InboxBand makes the two agree by construction -- the
            # pill is exactly the count of everything not in NOT RUNNING -- so
            # they cannot drift apart again whatever the evidence looks like.
            # It is hashtable lookups, no file or process access.
            # ONE call, then everything derived from it. It used to be called
            # twice per session for two of the four bands; the chips need all
            # four, and a second walk would be a second chance to disagree.
            $bnd = Get-InboxBand $s
            $bands[$bnd] = 1 + [int]$bands[$bnd]
            if ($bnd -ne 'quiet') { $liveTotal++ }
            if ($s.pinned) { $pinned++ }
            # ALL THREE COUNTS COME FROM Get-InboxBand, for the same reason the
            # live count does: a summary that is computed differently from the
            # rows beneath it will eventually disagree with them, and when it
            # does it reads as the tool failing to recognise sessions.
            #
            # An earlier version counted every conversation whose LAST KNOWN
            # state was 'waiting' and put "98 waiting for you" over a band
            # showing 2, because ~110 of them are not running and cannot be
            # waiting for anything. Deriving from the band makes that class of
            # disagreement impossible rather than merely fixed once.
            switch ($bnd) {
                'needs'   { $waiting++ }
                'working' { $working++ }
            }
        }
        if ($d.missing) { continue }
        $tot += $v.Count
        if ($d.enabled) {
            $n = @($v | Where-Object { $_.enabled }).Count
            if ($n -gt 0) { $projOn++ }
            $on += $n
        }
    }
    $script:bandCount = $bands
    $ui.LiveSummary.Text = "{0} live now" -f $liveTotal
    # Two counts, two questions, two pills. "live" is how many are being held;
    # "waiting" is how many are asking for the operator. They are routinely
    # different numbers and the whole point of the DOING column is that they are.
    $ui.WaitSummary.Text = "{0} waiting for you   |   {1} working" -f $waiting, $working
    # 🔴 SAY WHAT THE CAP WILL DROP, BEFORE it drops it. On 2026-08-24 the logon
    # restore took the 12 most recent and left 8 behind, and said so only in
    # .state estore.log, which nobody reads. The operator lost a morning of
    # AlgoTrader lanes to a number that was never on the screen. A roster that
    # shows what is ticked and stays silent about what will not fit is lying by
    # omission -- the same class of failure as a tick under a switched-off project.
    $cap = [int]$script:cfg.maxSessions
    $overflow = $(if ($cap -gt 0 -and $on -gt $cap) { $on - $cap } else { 0 })
    # 🪤 SHORT ENOUGH TO SURVIVE THE PILL. The first version of this ran to
    # "only the 20 most recent will open, 8 will not" and the pill clipped it to
    # "...in 12 project(s) - only the" -- a warning that stops mid-sentence is worse
    # than none, because it reads as a rendering fault rather than a fact about
    # tomorrow morning. The full sentence is on the tooltip, which has the room.
    $capNote = $(if ($overflow) { "  -  $overflow will not fit" } else { '' })
    # 🪤 THE PILL HAS A FIXED WIDTH, AND IT WILL CLIP WITHOUT SAYING SO. Twice now a
    # cap warning has been cut mid-sentence -- 'in 12 project(s) - only the', then
    # 'in 15 project(s) - 24 wil'. A warning that stops mid-word reads as a rendering
    # fault rather than as a fact about tomorrow morning, which is worse than not
    # warning at all. So the pill gets the SHORT form and the tooltip carries the
    # sentence: '44 of 184 ticked, 15 projects' and, when it matters, '24 over'.
    $ui.TickSummary.Text = $(if ($overflow) {
        "{0} ticked, {1} over the cap{2}" -f $on, $overflow, $(if ($script:dirty) { '  *unsaved*' } else { '' })
    } else {
        "{0} of {1} ticked for logon{2}" -f $on, $tot, $(if ($script:dirty) { '  *unsaved*' } else { '' })
    })
    # Two facts, not three. The auto-tick rule is a standing rule that never
    # changes -- it was a sentence of teaching text on the one line that also has
    # to hold every action, and it pushed "Launch everything ticked" off the
    # window. It lives in the legend now, behind the "?", with the rest of the
    # things you read once.
    # "pinned" is a restore concept -- it means the hourly auto-tick roll leaves
    # this conversation alone -- so it only earns space in the view that owns the
    # tick. Everywhere else the stamp is just how fresh this screen is.
    $ui.ProbeStamp.Text  = $(if (-not $script:probedAt) { '' }
        elseif ($script:viewMode -eq 'all') {
            "{0} pinned   |   as of {1}" -f $pinned, ([datetime]$script:probedAt).ToString('HH:mm:ss')
        } else {
            "as of {0}" -f ([datetime]$script:probedAt).ToString('HH:mm:ss')
        })

    # Keep each pill's ACCESSIBLE name equal to the text it is showing. A Button
    # whose Content is a panel rather than a string has no name at all in the
    # automation tree -- a screen reader announces nothing, and the button cannot
    # be found by name. The markup carries a static fallback; this keeps the live
    # counts in it, so what is announced and what is drawn cannot drift apart.
    $nameProp = [System.Windows.Automation.AutomationProperties]::NameProperty
    $ui.LivePill.SetValue($nameProp, $ui.LiveSummary.Text)
    $ui.WaitPill.SetValue($nameProp, $ui.WaitSummary.Text)
    $ui.TickPill.SetValue($nameProp, $ui.TickSummary.Text)
    $ui.TickPill.ToolTip = $(if ($overflow) {
        "Only the $cap most recent ticked conversations open at logon; $overflow will not. Raise maxSessions in session-restore.config.json if you want more."
    } else {
        "$on of $tot conversations are ticked to reopen at logon, across $projOn project(s). The cap is $cap."
    })

    Update-FilterReadout
    Update-SortHeads

    if ($script:unattributed -gt 0) {
        # Honest about the blind spot rather than implying LIVE is complete.
        $ui.Unattributed.Text = "{0} running claude.exe cannot be matched to any conversation - started bare, with no id on the command line. LIVE is a floor, not a total." -f $script:unattributed
        $ui.Unattributed.Visibility = $V_Show
    } else { $ui.Unattributed.Visibility = $V_Hide }

    # The subtitle explains the view you are in. Teaching the tick and the OPEN?
    # column while looking at an inbox that has neither is how a tool reads as
    # generic: the words on screen have to be about what is on screen.
    $ui.SubTitle.Text = $(switch ($script:viewMode) {
        'inbox' { 'what each one last said, and which are waiting on you   |   press / to find' }
        default { $(if ($script:showOlder) {
                      'every conversation on this machine   |   the tick reopens it at logon'
                  } else {
                      "the last $([int]$script:listDays) days   |   the tick reopens it at logon"
                  }) }
    })
}

# Every filter currently applied, in words. Used when nothing matched, which is
# the moment the operator most needs to be told what is cutting the list down
# rather than left looking at an empty screen.
function Get-FilterDescription {
    $bits = @()
    foreach ($t in @(Get-FilterTokens)) { $bits += $t.Label }
    # NO LEADING COMMA. ",@()" around an EMPTY array is a one-element array whose
    # element is the empty array, so @(Get-FilterDescription) came back with
    # Count 1 when nothing was filtering and Get-FilterSummary never once reached
    # its "no filters" branch. The comma exists to stop a ONE-element array
    # unrolling to a scalar; @(...) at every call site already handles that, and
    # a bare return is the only form that is right at zero, one and many.
    return $bits
}

# One filter, one token: a label and the key that removes it. The words used to
# be built twice -- once for the status line, once for nothing at all -- so the
# tokens and the sentence are generated from this single list and cannot drift.
#
# The key is "<dimension>:<value>" for a chip, matching the chip's own Tag, so
# dropping a token and unticking a chip go through exactly the same code.
$script:BandWords = @{ needs = 'Needs you'; working = 'Working'; idle = 'Idle'; quiet = 'Not running' }
function Get-FilterTokens {
    $out = @()
    if ($script:filter)   { $out += @{ Key = 'text:';    Label = "text '$($script:filter)'" } }
    if ($script:fProject) { $out += @{ Key = 'project:'; Label = "in " + (Split-Path $script:fProject -Leaf) } }
    if ($script:fLane)    { $out += @{ Key = 'lane:';    Label = "lane $script:fLane" } }
    foreach ($k in @($script:fBand.Keys | Sort-Object)) {
        $w = $script:BandWords[$k]; if (-not $w) { $w = $k }
        $out += @{ Key = "band:$k"; Label = $w }
    }
    foreach ($k in @($script:fLive.Keys | Sort-Object)) { $out += @{ Key = "live:$k"; Label = $k } }
    foreach ($k in @($script:fTick.Keys | Sort-Object)) { $out += @{ Key = "tick:$k"; Label = $k } }
    foreach ($k in @($script:fPin.Keys  | Sort-Object)) { $out += @{ Key = "pin:$k";  Label = $k } }
    foreach ($k in @($script:fAge.Keys  | Sort-Object)) { $out += @{ Key = "age:$k";  Label = $k } }
    # See Get-FilterDescription: no leading comma. With one, an unfiltered window
    # drew a phantom token with an empty label and a live x next to it.
    return $out
}

# Take one filter off, whatever kind it is. Chips are unticked rather than
# cleared behind their own backs: setting IsChecked raises the routed event the
# container already listens to, so the chip, the set and the list stay in step
# without a second code path that could get them out of it.
function Remove-Filter { param([string]$Key)
    $bits = "$Key" -split ':', 2
    if ($bits.Count -ne 2) { return }
    switch ($bits[0]) {
        'text'    { $script:filter = $null
                    try { $script:suppress = $true; $ui.SearchBox.Text = '' } finally { $script:suppress = $false }
                    Update-List -ToTop }
        'project' { try { $script:suppress = $true
                          $script:fProject = $null
                          if ($ui.ProjectFilter.Items.Count) { $ui.ProjectFilter.SelectedIndex = 0 }
                      } finally { $script:suppress = $false }
                    Update-List -ToTop }
        'lane'    { try { $script:suppress = $true
                          $script:fLane = $null
                          if ($ui.LaneFilter.Items.Count) { $ui.LaneFilter.SelectedIndex = 0 }
                      } finally { $script:suppress = $false }
                    Update-List -ToTop }
        default   {
            $chip = @(Get-ChipControls | Where-Object { "$($_.Tag)" -eq $Key })
            if ($chip.Count) { $chip[0].IsChecked = $false; return }
            # No chip carries it -- drop it from the set directly rather than
            # leaving a token that cannot be removed.
            $set = Get-FilterSet $bits[0]
            if ($set) { $set.Remove($bits[1]); Update-List -ToTop }
        }
    }
    Set-Status (Get-FilterSummary) 'info'
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

# Which list the operator is actually looking at. Everything that reads a
# selection goes through here, so a keyboard handler or a selection readout
# cannot end up talking to the hidden list.
function Get-ActiveList {
    if ($script:viewMode -eq 'inbox') { return $ui.InboxList }
    return $ui.RowList
}

# The inbox's own fill. Deliberately not a branch inside Update-List: the two
# views build different rows, decorate different properties and live in
# different controls, and interleaving them in one function is how a change to
# one silently breaks the other.
function Update-InboxList { param([string]$KeepKey, [switch]$ToTop)
    if (-not $KeepKey -and -not $ToTop -and $ui.InboxList.SelectedItem) { $KeepKey = $ui.InboxList.SelectedItem.Key }
    if ($ToTop) { $KeepKey = $null }

    $script:inboxRows = Build-InboxRows
    foreach ($r in $script:inboxRows) { Update-InboxRow $r }

    # Same guard the tree carries, for the same reason: a row whose text has no
    # brush renders as NOTHING, and a blank cell reads as "no data" rather than
    # as a bug. That is exactly how a fully populated column once stayed
    # invisible for an afternoon.
    foreach ($r in $script:inboxRows) {
        if ($r.Said -and $null -eq $r.SaidBrush) {
            throw "inbox row '$($r.Name)' has text '$($r.Said)' with a null brush - it would render invisible"
        }
    }

    $ui.InboxList.ItemsSource = $script:inboxRows
    Update-Header
    # Hides the strip. Called here as well as on the tree path so that switching
    # INTO the inbox takes the band down with it, rather than leaving the same
    # names on screen twice.
    Update-NeedsBand

    if ($script:inboxRows.Count -eq 0) {
        $desc = Get-FilterDescription
        $ui.EmptyNote.Text = $(if (@($desc).Count) {
            "Nothing matches. {0} filter(s) on:  {1}.`n`nPress Clear all filters, or Esc." -f @($desc).Count, (@($desc) -join '   +   ')
        } else {
            "No conversation is running and none has been active recently.`n`nThe Projects view lists everything on this machine, or type to search."
        })
        $ui.EmptyNote.Visibility = $V_Show
    } else {
        $ui.EmptyNote.Visibility = $V_Hide
        $idx = -1
        if ($KeepKey) {
            for ($i = 0; $i -lt $script:inboxRows.Count; $i++) { if ($script:inboxRows[$i].Key -eq $KeepKey) { $idx = $i; break } }
        }
        # Never land on a band heading: it is a label, not something you can act
        # on, and a selection you cannot do anything with is a dead end.
        if ($idx -lt 0) {
            for ($i = 0; $i -lt $script:inboxRows.Count; $i++) { if ($script:inboxRows[$i].Kind -eq 'session') { $idx = $i; break } }
        }
        if ($idx -ge 0) {
            $ui.InboxList.SelectedIndex = $idx
            $ui.InboxList.ScrollIntoView($script:inboxRows[$idx])
        }
    }
    Update-Selection
}

function Update-List { param([string]$KeepKey, [switch]$ToTop)
    if ($script:viewMode -eq 'inbox') { Update-InboxList -KeepKey $KeepKey -ToTop:$ToTop; return }
    if (-not $KeepKey -and -not $ToTop -and $ui.RowList.SelectedItem) { $KeepKey = $ui.RowList.SelectedItem.Key }
    if ($ToTop) { $KeepKey = $null }
    $script:rows = Build-Rows
    foreach ($r in $script:rows) { Update-RowStatic $r; Update-RowTicks $r; Update-RowLive $r; Update-RowConv $r }
    # Parallel agent runs share one prompt, so the subtitle that tells two
    # untitled conversations apart becomes THIRTEEN IDENTICAL LINES that tell you
    # nothing and read as if the rows were duplicates. Show it on the first of a
    # run and blank the repeats: the information is still there, once, where it
    # is actually information.
    $prevSub = $null; $prevKey = $null
    foreach ($r in $script:rows) {
        if ($r.Kind -ne 'session') { $prevSub = $null; $prevKey = $r.Key; continue }
        if ($r.Subtitle -and $r.Subtitle -eq $prevSub) {
            $r.Subtitle = ''
            $r.SubtitleVisibility = $V_Hide
        } elseif ($r.Subtitle) {
            $prevSub = $r.Subtitle
        }
    }

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
# Switching view
#
# Restore is a MODE, not a column. What moves with it: the logon tick, the bulk
# tick menu, the launch-everything-ticked button and the tick summary. What does
# not move: the search box, the filters and the status line, which mean the same
# thing wherever you are.
# ---------------------------------------------------------------------------
# FOLDING A GROUP, and where the fold LIVES.
#
# In memory it is $script:fold, keyed by project path and by "path|lane". On disk
# it rides on the project itself -- `folded`, and `foldedLanes` for the lanes
# under it -- so it is saved by the same write that saves the ticks and comes
# back on the next launch. A fold you have to redo every morning is a fold
# nobody uses.
function Invoke-RowFold { param($Row)
    if (-not $Row -or -not $Row.Dir) { return }
    $d = $Row.Dir
    $projKey = [string]$d.path
    if ($Row.Kind -eq 'project') {
        $shut = -not [bool]$script:fold[$projKey]
        if ($shut) { $script:fold[$projKey] = $true } else { $script:fold.Remove($projKey) }
        Set-SessionField $d 'folded' $shut
    } elseif ($Row.Kind -eq 'lane') {
        $laneName = "$($Row.Lane.Name)"
        $laneKey  = "$projKey|$laneName"
        $shut = -not [bool]$script:fold[$laneKey]
        if ($shut) { $script:fold[$laneKey] = $true } else { $script:fold.Remove($laneKey) }
        $keep = @(@($d.foldedLanes) | Where-Object { $_ -and "$_" -ne $laneName })
        if ($shut) { $keep += $laneName }
        Set-SessionField $d 'foldedLanes' $keep
    } else { return }
    $script:dirty = $true
    Update-List -KeepKey $Row.Key
}

# Read the folds back off the registry. Called when a registry is set, so a
# rescan does not silently throw every fold away.
function Sync-FoldState {
    $script:fold = @{}
    foreach ($d in @($script:dirs)) {
        if ([bool]$d.folded) { $script:fold[[string]$d.path] = $true }
        foreach ($ln in @($d.foldedLanes)) {
            if ($ln) { $script:fold["$($d.path)|$ln"] = $true }
        }
    }
}
function Set-ViewMode { param([string]$Mode)
    # 'tree' and 'restore' both meant the SAME 195 rows in the same order - the
    # comparison was run row for row and they were identical. They are one mode
    # called 'all' now. The old names are accepted so nothing that remembers
    # them breaks in the middle of a switch.
    if ($Mode -eq 'tree' -or $Mode -eq 'restore') { $Mode = 'all' }
    if ($Mode -ne 'inbox' -and $Mode -ne 'all') { return }
    $script:viewMode = $Mode
    $inbox = ($Mode -eq 'inbox')

    $ui.InboxList.Visibility = $(if ($inbox) { $V_Show } else { $V_Hide })
    $ui.RowList.Visibility   = $(if ($inbox) { $V_Hide } else { $V_Show })

    # Restore-only furniture. Hidden rather than disabled: a greyed-out control
    # still asks to be read, and the whole point is to stop this competing for
    # attention on the days you are not rebooting.
    # $ctl, NOT $c. PowerShell variable names are CASE-INSENSITIVE, so a loop
    # over "$c" IS the palette table $C -- these three loops replaced the whole
    # brush table with a Button, every later $Pal.TextMax came back $null, and the
    # next repaint threw "has DOING text '2 waiting' with a null brush". Exactly
    # the collision already documented in Update-RowConv, walked into again in a
    # brand-new function. The guard that caught it is the one added the last time
    # this happened.
    # The logon furniture lives in All. It used to be a whole THIRD VIEW whose
    # rows were identical to the second one's; what actually distinguished it
    # was these four controls, so these four controls are the difference now.
    # 🔑 THE LOGON CHIPS COME OUT OF THE FOLD ON THIS SCREEN. `ticked` and `not
    # ticked` were built and wired, and the operator still asked for a filter to
    # show what reopens at logon -- because they sit inside `More`, collapsed, on a
    # bar whose first four chips are about what a conversation is DOING. A chip
    # nobody can find is indistinguishable from a chip that does not exist.
    #
    # Which dimension is primary depends on the question the screen answers: on
    # NOW it is the band, on the ROSTER it is the tick. So the fold opens itself
    # here rather than the chips being moved, and nothing that already works moves.
    $restore = ($Mode -eq 'all')
    if ($restore -and $ui.MoreFilters -and -not $ui.MoreFilters.IsChecked) {
        $ui.MoreFilters.IsChecked = $true
    }
    foreach ($ctl in @($ui.LaunchTicked, $ui.RelaunchTicked, $ui.BulkBtn, $ui.TickPill, $ui.NowCaption)) {
        if ($ctl) { $ctl.Visibility = $(if ($restore) { $V_Show } else { $V_Hide }) }
    }

    # The tree's column captions, and the worktree lane toggle. Both describe a
    # hierarchy: LOGON / TICKED / ID / OPEN? name columns the inbox does not
    # have, and "show a lane per worktree" means nothing in a flat list where the
    # worktree is printed on the row itself.
    foreach ($ctl in @($ui.ListHead, $ui.WorktreeToggle, $ui.WorktreeCaption)) {
        if ($ctl) { $ctl.Visibility = $(if ($inbox) { $V_Hide } else { $V_Show }) }
    }
    # The inbox has its own, narrower heading row. Both live in the same grid
    # row, so exactly one of them is ever up.
    if ($ui.InboxHead) { $ui.InboxHead.Visibility = $(if ($inbox) { $V_Show } else { $V_Hide }) }

    # The selection footer, same rule: Tick / untick and Unpin only mean anything
    # where the tick is on screen.
    foreach ($ctl in @($ui.SelTick, $ui.SelUnpin)) {
        if ($ctl) { $ctl.Visibility = $(if ($restore) { $V_Show } else { $V_Hide }) }
    }

    # The reading pane belongs to no mode; leaving it open across a switch would
    # show one conversation while the list behind it changed shape.
    if ($ui.ReadPane.Visibility -eq $V_Show) { Hide-ReadPane }

    Update-List -ToTop
    $null = (Get-ActiveList).Focus()
    Set-Status $(switch ($Mode) {
        'inbox' { 'Now: every conversation that is running or was, grouped by what it needs from you.' }
        'all'   { "Roster: what reopens at logon, grouped by project. Fold a repo you are not working in; tick what should come back. Searching ignores folds." }
    }) 'info'
}

# ---------------------------------------------------------------------------
# Loading the registry into the window
# ---------------------------------------------------------------------------
function Set-Registry { param($Registry, $Config)
    if ($Config) {
        $script:cfg       = $Config
        # CLAMP, DO NOT OVERWRITE. Hiding worktree lanes is a display choice
        # now, and a rescan must not undo it - but showing them when discovery
        # is off would promise rows nothing scanned for, so config-false still
        # wins in that one direction.
        if (-not [bool]$Config.includeWorktrees) { $script:showWt = $false }
        $script:staleDays = [double]$Config.recencyDays
    }
    $script:reg = $Registry
    $script:visCache = @{}
    # Before the sort, not after: the cache holds the OLD session objects, and
    # sorting on them would order the new list by the previous scan's timestamps.
    $script:dirs = @($script:reg.directories | Sort-Object { Get-Newest (Get-Visible $_) } -Descending)
    Sync-FoldState
    # NOTHING EVER CALLED THIS. Update-FilterSources fills the PROJECT and LANE
    # dropdowns from the registry, and it had no caller anywhere in the file --
    # so both combos have been empty since the day they were added, exactly like
    # the chips that carried the right Tag and had no handler. It belongs here
    # because this is the one place $script:dirs changes.
    Update-FilterSources
    Update-SessionIndex
}

function Set-ProbeResult { param($Result)
    $script:running      = $Result.Running
    $script:live         = $Result.Live
    if ($Result.PSObject.Properties['Conv'] -and $Result.Conv) { $script:conv = $Result.Conv }
    # NOT gated on being non-empty, unlike Conv above. An empty Said table is a
    # real answer -- every live session was mid-tool-call and none had prose --
    # and keeping the previous pass's text would show words no session has said
    # for minutes, which is worse than showing none.
    if ($Result.PSObject.Properties['Said']) { $script:said = $Result.Said }
    if ($Result.PSObject.Properties['Agents']) { $script:agents = $Result.Agents }
    Update-TabIndexSoon
    $script:unattributed = [int]$Result.Unattributed
    $script:probedAt     = $Result.At
}

# KEEP THE TAB INDEX WARM.
#
# A tab is found by its title, but a title is not stable: measured 2026-08-22, a
# session's tab read "<glyph> RC-WORKFLOW" one minute and plain "claude" the
# next, because the console title follows whatever child process is attached.
# The drift happens exactly while a session is busy -- which is when you most
# want to reach it.
#
# So the mapping is built WHILE the titles are right, after each background
# pass, and the jump uses the remembered UIA element afterwards. Runtime ids
# were verified stable across re-enumeration, so the element survives a rename.
#
# At Background dispatcher priority because enumerating 16 tabs across 6 windows
# costs 250-500 ms measured, and that on a click is a visibly stuck window.
# UI Automation must be called from the UI thread here -- the background runspace
# cannot hand an AutomationElement back across a job boundary.
function Update-TabIndexSoon {
    if ($script:tabIndexQueued) { return }
    $script:tabIndexQueued = $true
    $null = $window.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [action]{
            try {
                $titles = @{}
                foreach ($k in @($script:agents.Keys)) {
                    $a = $script:agents[$k]
                    if ($a -and $a.Name -and $a.Kind -eq 'interactive') { $titles[$k] = $a.Name }
                }
                if ($titles.Count) {
                    $n = Update-SRTabIndex -Titles $titles
                    Write-SRLog ("tab index: {0} of {1} interactive session(s) located" -f $n, $titles.Count)
                }
            } catch {
                # Never fatal. A missing tab index costs a fallback, not the window.
                Write-SRLog "tab index failed: $($_.Exception.Message)"
            } finally { $script:tabIndexQueued = $false }
        })
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
    # same order the ported Invoke-Rescan uses.
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

# ---------------------------------------------------------------------------
# TWO SPEEDS, because the two questions cost three orders of magnitude apart.
#
#   SLOW   the full probe: WMI for command lines, `claude agents --json` at a
#          MEASURED 653 ms median. That answers "what is each session doing",
#          and it is far too expensive to ask every few seconds.
#   FAST   file mtimes for the handful of conversations that are live or recent.
#          That answers "has anything moved", which is the question behind the
#          unread dot and the "3m ago" stamp, and it is a dozen Get-Item calls.
#
# The fast pass NEVER changes what a session is doing - it only refreshes when
# it last spoke. Letting it infer state from a file timestamp is how a tool ends
# up disagreeing with itself between two refresh rates.
# ---------------------------------------------------------------------------
function Invoke-FastPass {
    if ($script:busy -or $script:hidden) { return }
    $changed = 0
    foreach ($key in @($script:live.Keys) + @($script:running.Keys)) {
        $sess = $script:byId[$key]
        if (-not $sess) { continue }
        $dir = $script:dirOf[$key]
        if (-not $dir) { continue }
        try {
            $j = Get-SRTranscriptPath -Dir (Get-SessionCwd $sess $dir) -SessionId $sess.sessionId -Recorded $sess.jsonl
            if (-not (Test-Path -LiteralPath $j)) { continue }
            $mt = (Get-Item -LiteralPath $j).LastWriteTime
            $was = $script:mtimes[$key]
            if ($was -and $mt -le $was) { continue }
            $script:mtimes[$key] = $mt
            if ($was) {
                # It moved. lastActive is what every stamp, sort and unread mark
                # reads, so it is the one field worth writing here.
                $sess.lastActive = $mt.ToString('o')
                try { $script:said[$key] = Get-SRLastSaid -JsonlPath $j } catch { }
                $changed++
            }
        } catch { }
    }
    if (-not $changed) { return }
    Update-RowSeenMarks
    # Repaint rather than rebuild: a rebuild reorders the list, and reordering
    # under someone who is reading it is worse than a slightly stale sort.
    foreach ($lst in @($script:rows, $script:inboxRows)) {
        foreach ($r in $lst) { if ($r.Kind -eq 'session') { if ($r.Band) { Update-InboxRow $r } } }
    }
    Update-Header
    if ($script:readOpen -and $script:readSession) { Update-SendState }
}

# An index from session id to its objects, so the fast pass does not walk every
# project to find twelve conversations. Rebuilt whenever the registry is.
function Update-SessionIndex {
    $script:byId  = @{}
    $script:dirOf = @{}
    foreach ($d in $script:dirs) {
        foreach ($sn in @($d.sessions)) {
            if (-not $sn.sessionId) { continue }
            $k = "$($sn.sessionId)".ToLower()
            $script:byId[$k]  = $sn
            $script:dirOf[$k] = $d
        }
    }
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
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Tick mutations. Every one of them pins what it changes, because every one of
# them is a deliberate act -- exactly as SPACE, A, N, -Enable and -Disable do.
# ---------------------------------------------------------------------------
function Set-RowTick { param($Row, [Nullable[bool]]$Value)
    if (-not $Row -or $Row.Kind -ne 'session') { return }
    $v = if ($null -ne $Value) { [bool]$Value } else { -not [bool]$Row.Session.enabled }
    $Row.Session.enabled = $v
    Set-Pin $Row.Session $true
    # THE PROJECT MASTER TICK. It had its own checkbox on the project row and
    # there are no project rows now. Ticking a conversation in a switched-off
    # project would otherwise be a tick that does nothing at logon, silently -
    # the restore consults the project first. So ticking a conversation turns
    # its project on, which is what the operator meant by ticking it.
    if ($v -and $Row.Dir -and -not $Row.Dir.missing -and -not $Row.Dir.enabled) {
        $Row.Dir.enabled = $true
    }
    $script:dirty = $true
    Update-AllTicks
}

# SHIFT-CLICK TICKS A RANGE. What the project and lane checkboxes were really
# for was "tick these twelve at once", and that is a selection gesture, not a
# hierarchy. The anchor is the last conversation ticked by hand.
function Set-TickRange { param($Row, [bool]$Value)
    $list = Get-ActiveList
    $rows = @()
    foreach ($r in $list.ItemsSource) { $rows += $r }
    $to = [array]::IndexOf($rows, $Row)
    $from = $(if ($script:tickAnchor) { [array]::IndexOf($rows, $script:tickAnchor) } else { -1 })
    if ($to -lt 0 -or $from -lt 0) { Set-RowTick -Row $Row -Value $Value; return }
    if ($from -gt $to) { $t = $from; $from = $to; $to = $t }
    $touched = 0
    for ($i = $from; $i -le $to; $i++) {
        $r = $rows[$i]
        if ($r.Kind -ne 'session') { continue }
        $r.Session.enabled = $Value
        Set-Pin $r.Session $true
        if ($Value -and $r.Dir -and -not $r.Dir.missing) { $r.Dir.enabled = $true }
        $touched++
    }
    $script:dirty = $true
    Update-AllTicks
    Set-Status ("{0} conversation(s) {1}" -f $touched, $(if ($Value) { 'ticked' } else { 'unticked' })) 'info'
}

function Set-RowUnpin { param($Row)
    if (-not $Row -or $Row.Kind -ne 'session') { return }
    Set-Pin $Row.Session $false
    $script:dirty = $true
    Update-AllTicks
    Set-Status 'handed back to the rolling auto-tick - its tick is recomputed by the next scan' 'info'
}

# ON WHAT IS SHOWN. It used to reach every conversation in every project,
# including the ones a filter had taken off screen -- a bulk action whose extent
# the operator could not see. Now it does exactly what the list shows, and says
# how many that was.
function Set-AllTicks { param([bool]$Value)
    $n = 0
    foreach ($r in $script:rows) {
        if ($r.Kind -ne 'session') { continue }
        $r.Session.enabled = $Value
        Set-Pin $r.Session $true
        if ($Value -and $r.Dir -and -not $r.Dir.missing) { $r.Dir.enabled = $true }
        $n++
    }
    $script:dirty = $true
    Update-AllTicks
    Set-Status ("{0} shown conversation(s) {1} and pinned - nothing has been {2}" -f $n,
        $(if ($Value) { 'ticked' } else { 'unticked' }),
        $(if ($Value) { 'launched' } else { 'closed' })) 'info'
}

function Set-AllUnpinned {
    $n = 0
    foreach ($r in $script:rows) {
        if ($r.Kind -ne 'session') { continue }
        Set-Pin $r.Session $false
        $n++
    }
    $script:dirty = $true
    Update-AllTicks
    Set-Status "$n shown conversation(s) handed back to the rolling auto-tick" 'info'
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
    if ($row.Kind -ne 'session') { return }
    $want = [bool]$cb.IsChecked
    $cur = [bool]$row.Session.enabled
    if ($cur -eq $want) { return }
    $shift = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift
    try {
        $script:suppress = $true
        if ($shift -and $script:tickAnchor) { Set-TickRange -Row $row -Value $want }
        else { Set-RowTick -Row $row -Value $want }
        $script:tickAnchor = $row
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

# The legend is folded away by default -- three dense lines you read once and
# then never again, which was costing a tenth of the window permanently. The
# choice sticks for the session; it is not worth a config entry.
# ---------------------------------------------------------------------------
# THE FILTER BAR
#
# Every one of these controls existed, carried the right Tag, and did NOTHING.
# $script:fBand / fLive / fTick / fPin / fAge were declared, read by
# Test-RowMatch, counted by Get-FilterDimensionCount, described by
# Get-FilterDescription and emptied by Clear-AllFilters -- and never once
# WRITTEN, because no handler was ever attached. Clicking a chip lit it up and
# changed nothing, which is exactly what it looked like from the outside.
# ---------------------------------------------------------------------------

# The hashtable behind a chip's dimension. Returned by reference, so callers
# mutate the real filter rather than a copy.
function Get-FilterSet { param([string]$Dim)
    switch ($Dim) {
        'band'  { return $script:fBand }
        'live'  { return $script:fLive }
        'tick'  { return $script:fTick }
        'age'   { return $script:fAge }
        'pin'   { return $script:fPin }
    }
    return $null
}

function Invoke-ChipToggle { param($Chip)
    if ($script:suppress -or -not $Chip) { return }
    $tag = "$($Chip.Tag)"
    if (-not $tag) { return }
    $bits = $tag -split ':', 2
    if ($bits.Count -ne 2) { return }
    $set = Get-FilterSet $bits[0]
    if ($null -eq $set) { Set-Status "unknown filter dimension '$($bits[0])'" 'warn'; return }

    if ($Chip.IsChecked) { $set[$bits[1]] = $true } else { $set.Remove($bits[1]) }

    # Rebuild NOW. The operator asked for the list to follow the filter without
    # being told to; a filter that needs a separate refresh is a filter that
    # looks broken.
    Update-List -ToTop
    Set-Status (Get-FilterSummary) 'info'
}

# One line saying what is applied, or that nothing is.
function Get-FilterSummary {
    $desc = @(Get-FilterDescription)
    if (-not $desc.Count) { return "no filters - showing everything the view holds" }
    return ("{0} of {1} match:  {2}" -f $script:matchCount, $script:totalCount, ($desc -join '   +   '))
}

# ONE handler on the container rather than one per chip: Checked and Unchecked
# are routed events, so they bubble to the panel, and a chip added to the markup
# later is wired the moment it exists.
$ui.FilterChips.AddHandler(
    [System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent,
    [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        Invoke-Guarded { Invoke-ChipToggle ($e.OriginalSource -as [System.Windows.Controls.Primitives.ToggleButton]) } 'that filter'
    })
$ui.FilterChips.AddHandler(
    [System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent,
    [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        Invoke-Guarded { Invoke-ChipToggle ($e.OriginalSource -as [System.Windows.Controls.Primitives.ToggleButton]) } 'that filter'
    })

# The two dimensions whose values come from the data. Their items are SRGui
# .Choice objects carrying a Value; a null Value is the "(any ...)" row.
$ui.ProjectFilter.Add_SelectionChanged({
    if ($script:suppress) { return }
    Invoke-Guarded {
        $sel = $ui.ProjectFilter.SelectedItem
        $script:fProject = $(if ($sel -and $sel.Value) { "$($sel.Value)" } else { $null })
        Update-List -ToTop
        Set-Status (Get-FilterSummary) 'info'
    } 'the project filter'
})
$ui.LaneFilter.Add_SelectionChanged({
    if ($script:suppress) { return }
    Invoke-Guarded {
        $sel = $ui.LaneFilter.SelectedItem
        $script:fLane = $(if ($sel -and $sel.Value) { "$($sel.Value)" } else { $null })
        Update-List -ToTop
        Set-Status (Get-FilterSummary) 'info'
    } 'the lane filter'
})

# Clear-AllFilters existed too, and nothing called it.
$ui.ClearFilters.Add_Click({ Invoke-Guarded { Clear-AllFilters } 'clear the filters' })

$ui.MoreFilters.Add_Click({
    Invoke-Guarded {
        $ui.FilterMore.Visibility = $(if ($ui.MoreFilters.IsChecked) { $V_Show } else { $V_Hide })
    } 'toggle the extra filters'
})

# ONE handler for every token's x, on the strip rather than on each button, for
# the same reason the chips share one: the tokens are rebuilt on every readout,
# and per-button handlers would be re-attached 13 times a second.
$ui.ActiveTokens.AddHandler(
    [System.Windows.Controls.Button]::ClickEvent,
    [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        Invoke-Guarded {
            $b = $e.OriginalSource -as [System.Windows.Controls.Button]
            if ($b -and $b.Tag) { Remove-Filter "$($b.Tag)" }
        } 'drop that filter'
    })

# A menu, because these are occasional. Opening it from the button's own click
# rather than a right-click: nobody right-clicks a button expecting a menu.
$ui.CastBtn.Add_Click({ Invoke-Guarded { Show-Cast } 'open the broadcast' })
$ui.CastCancel.Add_Click({ Invoke-Guarded { Close-Cast } 'close the broadcast' })
$ui.CastSend.Add_Click({ Invoke-Guarded { Invoke-Cast } 'send to several sessions' })
$ui.CastBox.Add_TextChanged({ Invoke-Guarded { Update-CastState } 'the broadcast' })
# One handler for every recipient tick, on the strip: the list is rebuilt each
# time the overlay opens, so per-box handlers would be re-attached every time.
foreach ($ev in @([System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent,
                  [System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent)) {
    $ui.CastList.AddHandler($ev, [System.Windows.RoutedEventHandler]{
        param($sender, $e) Invoke-Guarded { Update-CastState } 'the recipients'
    })
}

$ui.BulkBtn.Add_Click({
    Invoke-Guarded {
        $ui.BulkBtn.ContextMenu.PlacementTarget = $ui.BulkBtn
        $ui.BulkBtn.ContextMenu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
        $ui.BulkBtn.ContextMenu.IsOpen = $true
    } 'open the bulk menu'
})

$ui.LegendToggle.Add_Click({
    Invoke-Guarded {
        $showing = ($ui.LegendBox.Visibility -eq $V_Show)
        $ui.LegendBox.Visibility = $(if ($showing) { $V_Hide } else { $V_Show })
        $ui.LegendToggle.Content = $(if ($showing) { '?' } else { 'x' })
    } 'toggle the legend'
})

# --- the reading pane's own controls ---------------------------------------
# SAVED AS YOU TYPE, debounced. A note behind a Save button is a note that does
# not get written: the moment worth capturing is while you are still looking at
# the thing, not after you have decided to commit to writing it down.
$script:noteTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:noteTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:noteTimer.Add_Tick({
    $script:noteTimer.Stop()
    Invoke-Guarded {
        if (-not $script:readSession) { return }
        $was = Get-SessionNote $script:readSession
        $now = "$($ui.ReadNote.Text)".Trim()
        if ($was -eq $now) { return }
        Set-SessionNote $script:readSession $now
        # Only the row's own text, not a rebuild: rebuilding while someone is
        # typing into the pane moves the list under them.
        foreach ($lst in @($script:rows, $script:inboxRows)) {
            foreach ($r in $lst) {
                if ($r.Kind -eq 'session' -and "$($r.Session.sessionId)" -eq "$($script:readSession.sessionId)") {
                    if ($r.Band) { Update-InboxRow $r } else { Update-RowStatic $r; Update-RowLive $r }
                }
            }
        }
        Update-Header
        Set-Status $(if ($now) { 'note saved' } else { 'note cleared' }) 'ok'
    } 'the note'
})
$ui.ReadNote.Add_TextChanged({ $script:noteTimer.Stop(); $script:noteTimer.Start() })

$ui.ReadBack.Add_Click({    Invoke-Guarded { Hide-ReadPane }        'close the reading pane' })
$ui.SendBtn.Add_Click({     Invoke-Guarded { Invoke-SendReply }      'send that line to the session' })
$ui.SendBox.Add_KeyDown({
    param($s, $e)
    # Ctrl+Enter sends. Plain Enter does not: a stray Enter typing into somebody
    # else's session is not a mistake worth making easy.
    if ($e.Key -eq 'Return' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
        $e.Handled = $true
        Invoke-Guarded { Invoke-SendReply } 'send that line to the session'
    }
})
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

# ---------------------------------------------------------------------------
# The inbox's own input. Kept beside the tree's rather than merged into it: the
# two lists show different rows and answer to different keys.
# ---------------------------------------------------------------------------
$ui.InboxList.Add_SelectionChanged({ Invoke-Guarded { Update-Selection } 'the selection' })

$ui.InboxList.Add_MouseDoubleClick({
    param($sender, $e)
    Invoke-Guarded {
        $row = $ui.InboxList.SelectedItem
        if ($row -and $row.Kind -eq 'session') { $e.Handled = $true; Show-ReadPane $row }
    } 'open the reading pane'
})

# The row's own action button. One handler on the list rather than one per row:
# the list is virtualised and recycles its containers, so per-row handlers would
# be attached and detached as you scroll.
$ui.InboxList.AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    $btn = $e.OriginalSource -as [System.Windows.Controls.Button]
    if (-not $btn) { return }
    $e.Handled = $true
    Invoke-Guarded {
        # System.Windows.CONTROLS.ItemsControl. The Data namespace has no such
        # type, and the failure surfaces only as "that row's action failed" in
        # the log while the button silently does nothing.
        $row = [System.Windows.Controls.ItemsControl]::ContainerFromElement($ui.InboxList, $btn)
        $item = $(if ($row) { $row.DataContext } else { $null })
        if (-not $item -or $item.Kind -ne 'session') { return }
        $ui.InboxList.SelectedItem = $item
        Invoke-RowJump $item
    } 'that row''s action'
})

# THE COUNT PILLS. They were Borders holding TextBlocks, which is exactly why
# clicking "live now" did nothing and read as broken. Each now takes you to the
# band it counts.
function Show-InboxBand { param([string]$Band)
    if ($script:viewMode -ne 'inbox') { Set-ViewMode 'inbox'; $ui.ModeInbox.IsChecked = $true }
    # $script:inboxRows.Count, NOT @($script:inboxRows).Count.
    #
    # MEASURED on PowerShell 5.1.26100.9168: the array subexpression @() throws
    # "Argument types do not match" when applied to a System.Collections.Generic
    # .List[object] -- an empty one, a full one, either way. List[string] is fine.
    # ArrayList is fine. [object[]]$list, $list.ToArray() and piping are all
    # fine. It is specific to List[object], and this file returns exactly that
    # from Build-Rows and Build-InboxRows.
    #
    # It was silent here because the whole handler runs inside Invoke-Guarded:
    # clicking a count pill reported "that did not work" and did nothing.
    $idx = -1
    for ($i = 0; $i -lt $script:inboxRows.Count; $i++) {
        if ($script:inboxRows[$i].Band -eq $Band -and $script:inboxRows[$i].Kind -eq 'session') { $idx = $i; break }
    }
    if ($idx -lt 0) {
        $label = @($script:InboxBands | Where-Object { $_.Key -eq $Band } | ForEach-Object { $_.Label })
        Set-Status ("nothing is in {0} right now" -f $(if ($label.Count) { $label[0] } else { $Band })) 'info'
        return
    }
    $ui.InboxList.SelectedIndex = $idx
    $ui.InboxList.ScrollIntoView($script:inboxRows[$idx])
    $null = $ui.InboxList.Focus()
}

$ui.LivePill.Add_Click({ Invoke-Guarded { Show-InboxBand 'working' } 'show what is running' })
$ui.WaitPill.Add_Click({ Invoke-Guarded { Show-InboxBand 'needs' }   'show what is waiting' })
$ui.TickPill.Add_Click({ Invoke-Guarded {
    # The tick lives in All, and the pill that counts it goes there.
    $ui.ModeAll.IsChecked = $true
} 'show what reopens at logon' })

# ONE handler per heading row rather than one per column: the captions are
# Buttons inside a Grid inside a Border, Click is routed, and a column added to
# the markup later is wired the moment it exists. OriginalSource, never Source -
# a routed event that crosses a template boundary is retargeted, and that
# mistake once left every button in the list silently dead.
$sortHandler = [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    Invoke-Guarded {
        $b = $e.OriginalSource -as [System.Windows.Controls.Button]
        if (-not $b -or -not $b.Tag) { return }
        $shift = [bool]([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift)
        $view = $(if ($ui.InboxHead -and $b.Parent -eq $ui.InboxHead.Child) { 'inbox' } else { 'all' })
        Invoke-SortHead -Key "$($b.Tag)" -Add $shift -View $view
    } 'that sort'
}
$ui.ListHead.AddHandler([System.Windows.Controls.Button]::ClickEvent,  $sortHandler)
$ui.InboxHead.AddHandler([System.Windows.Controls.Button]::ClickEvent, $sortHandler)

$ui.ModeInbox.Add_Checked({ Invoke-Guarded { Set-ViewMode 'inbox' } 'switch to the inbox' })
$ui.ModeAll.Add_Checked({   Invoke-Guarded { Set-ViewMode 'all' }   'switch to all conversations' })

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
        # Straight into the conversation with the cursor in the reply box. The
        # band exists because something is ASKING; landing on a highlighted row
        # in a list and making the operator press ENTER, find the box and click
        # it was three deliberate steps between "it wants you" and being able to
        # type a character.
        Show-ReadPane $script:rows[$idx]
        $null = $window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Input,
            [action]{ if ($ui.SendBox.IsEnabled) { $null = $ui.SendBox.Focus() } })
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
            # 'fold' is back, with the grouping. 'more' is the age window's own row.
            'fold'   { Invoke-RowFold $row }
            'more'   { $script:showOlder = -not $script:showOlder; Update-List -KeepKey $row.Key }
            'unpin'  { $ui.RowList.SelectedItem = $row; Set-RowUnpin $row }
            'launch' { $ui.RowList.SelectedItem = $row; Invoke-RowLaunch $row }
            'spawn'  { $ui.RowList.SelectedItem = $row; Invoke-RowSpawn $row }
        }
    } catch {
        Write-SRLog "gui row action failed: $($_.Exception.Message)"
        Set-Status "that did not work: $($_.Exception.Message)" 'bad'
    }
})

# ---------------------------------------------------------------------------
# RIGHT-CLICK, ON ANY ROW, IN EITHER SCREEN.
#
# The operator asked for this after hunting for where ticking happens: the answer
# should be "wherever the conversation is". Tick, untick, hide and open are all
# things you want to do to the row under the pointer, not to whatever the footer
# happens to be pointing at.
#
# ONE MENU PER LIST, BUILT IN CODE. A ContextMenu declared inside a DataTemplate
# is instantiated once per row and its MenuItems cannot be wired from here; a
# menu built once and hung on the ListBox can. A ContextMenu also has a single
# parent, so the two lists get one each rather than sharing.
function Invoke-RowMenu { param([string]$Tag)
    $list = Get-ActiveList
    $row  = $list.SelectedItem -as [SRGui.Row]
    if (-not $row) { Set-Status 'nothing is selected' 'warn'; return }
    if ($row.Kind -ne 'session') { Set-Status 'that is a heading, not a conversation' 'warn'; return }
    switch ($Tag) {
        'tick'   { Set-RowTick -Row $row -Value $true;  Set-Status "$($row.Name) will reopen at logon" }
        'untick' { Set-RowTick -Row $row -Value $false; Set-Status "$($row.Name) will not reopen" }
        'hide'   {
            Set-SessionField $row.Session 'hidden' $true
            $script:dirty = $true
            Set-Status "$($row.Name) hidden - Bulk > Show hidden brings it back"
            Update-List
        }
        'unhide' {
            Set-SessionField $row.Session 'hidden' $false
            $script:dirty = $true
            Set-Status "$($row.Name) is no longer hidden"
            Update-List
        }
        'open'   { Invoke-RowLaunch $row }
        'jump'   { Invoke-RowJump $row }
    }
}

function New-RowMenu {
    $m = New-Object System.Windows.Controls.ContextMenu
    $specs = @(
        @{ Tag = 'tick';   Header = 'Tick - reopen this at logon' },
        @{ Tag = 'untick'; Header = 'Untick - do not reopen this' },
        @{ Tag = '-' },
        @{ Tag = 'hide';   Header = 'Hide this conversation' },
        @{ Tag = 'unhide'; Header = 'Stop hiding it' },
        @{ Tag = '-' },
        @{ Tag = 'open';   Header = 'Open it now' },
        @{ Tag = 'jump';   Header = 'Go to its terminal' }
    )
    foreach ($spec in $specs) {
        if ($spec.Tag -eq '-') { $null = $m.Items.Add((New-Object System.Windows.Controls.Separator)); continue }
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $spec.Header
        $mi.Tag    = $spec.Tag
        $mi.Add_Click({ param($sender, $e) Invoke-Guarded { Invoke-RowMenu -Tag "$($sender.Tag)" } 'that row action' })
        $null = $m.Items.Add($mi)
    }
    return $m
}

# A right-click does NOT select a row on its own, so the menu would act on
# whatever was selected before -- which is how a context menu ends up ticking the
# wrong conversation. Walk up from what was hit to its ListBoxItem and select it
# first. OriginalSource, never Source: the click lands on a TextBlock inside a
# template and Source has already been retargeted by the time it arrives.
$rowRightClick = [System.Windows.Input.MouseButtonEventHandler]{
    param($sender, $e)
    $dep = $e.OriginalSource -as [System.Windows.DependencyObject]
    while ($dep -and -not ($dep -is [System.Windows.Controls.ListBoxItem])) {
        $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep)
    }
    if ($dep) { $dep.IsSelected = $true }
}
$ui.RowList.ContextMenu   = New-RowMenu
$ui.InboxList.ContextMenu = New-RowMenu
$ui.RowList.Add_PreviewMouseRightButtonDown($rowRightClick)
$ui.InboxList.Add_PreviewMouseRightButtonDown($rowRightClick)

$ui.ShowHidden.Add_Click({ Invoke-Guarded {
    $script:showHidden = [bool]$ui.ShowHidden.IsChecked
    Update-List
    Set-Status $(if ($script:showHidden) { 'showing hidden conversations' } else { 'hidden conversations are hidden again' })
} 'show hidden' })
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
$ui.ClearSearch.Add_Click({ Invoke-Guarded { $ui.SearchBox.Text = ''; $null = (Get-ActiveList).Focus() } 'clear the filter' })

# --- toolbar ---
$ui.RescanBtn.Add_Click({ Invoke-Guarded { Start-Rescan } 'rescan' })
$ui.TickAll.Add_Click({ Invoke-Guarded { Set-AllTicks $true } 'tick all shown' })
$ui.TickNone.Add_Click({ Invoke-Guarded { Set-AllTicks $false } 'untick all shown' })
$ui.UnpinAll.Add_Click({ Invoke-Guarded { Set-AllUnpinned } 'unpin all shown' })
$ui.SeenAll.Add_Click({ Invoke-Guarded {
    $n = 0
    foreach ($r in $script:rows) { if ($r.Kind -eq 'session' -and (Test-Moved $r.Session)) { Set-Seen $r.Session; $n++ } }
    Update-RowSeenMarks
    Set-Status "$n conversation(s) marked seen" 'info'
} 'mark all seen' })
# Collapse all / Expand all went with the tree: a flat list has nothing to
# fold. What they were really for -- getting AlgoTrader's 89 conversations out
# of the way -- is the age window and the project filter now.

# W. Turning worktrees ON needs a rescan, because discovery skips them entirely
# while they are off. The config write is the same targeted replacement the
# terminal panel makes, so the hand-laid-out _README block is never reflowed.
# UNTICKING THIS ONLY HIDES ROWS.
#
# It used to write includeWorktrees=false to the config and rescan, which does
# far more than the checkbox looks like it does: config-false means worktree
# conversations are not discovered AND NEVER RESTORED AT LOGON. Measured on this
# machine, three of the four live sessions are in worktree lanes - so a tick box
# labelled "worktrees" could quietly stop most of the day's work coming back.
#
# Hiding is now display-only. The config is still written in the one direction
# where it has to be: turning worktrees ON when discovery is off, because
# otherwise the tool would promise rows that were never scanned for.
function Invoke-WorktreeToggle {
    if ($script:suppress) { return }
    $want = [bool]$ui.WorktreeToggle.IsChecked
    if (-not $want -or [bool]$script:cfg.includeWorktrees) {
        $script:showWt = $want
        $script:visCache = @{}
        Update-List -ToTop
        Set-Status $(if ($want) { 'worktree lanes shown' } else { 'worktree lanes hidden here - they are still discovered, and they still reopen at logon' }) 'info'
        return
    }
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
$ui.RelaunchTicked.Add_Click({ Invoke-Guarded { Invoke-RelaunchTicked } 'relaunch the ticked conversations' })

# --- the selected row ---
$ui.SelTick.Add_Click({ Invoke-Guarded { $r = (Get-ActiveList).SelectedItem; if ($r -and $r.Kind -ne 'band') { Set-RowTick -Row $r -Value $null } } 'the tick' })
$ui.SelUnpin.Add_Click({ Invoke-Guarded { $r = (Get-ActiveList).SelectedItem; if ($r -and $r.Kind -ne 'band') { Set-RowUnpin $r } } 'unpin' })
$ui.SelLaunch.Add_Click({ Invoke-Guarded { $r = (Get-ActiveList).SelectedItem; if ($r -and $r.Kind -ne 'band') { Invoke-RowLaunch $r } } 'open now' })
$ui.SelSpawn.Add_Click({ Invoke-Guarded { $r = (Get-ActiveList).SelectedItem; if ($r -and $r.Kind -ne 'band') { Invoke-RowSpawn $r } } 'new session here' })

# --- the spawn overlay ---
# --- the launch confirmation ---
$ui.CfCancel.Add_Click({ Invoke-Guarded { Close-Confirm; Set-Status 'cancelled - nothing was opened' 'warn' } 'cancel' })
$ui.CfOk.Add_Click({ Invoke-Guarded {
    # Read the decision out of script scope, then clear it BEFORE launching, so a
    # second press cannot open the same tabs twice.
    $items = $script:confirmItems
    $what  = $script:confirmWhat
    # The kill list is read and CLEARED with the rest, before anything happens, so
    # a second press cannot kill a set that has already been relaunched.
    $kill  = $script:confirmKill
    $script:confirmKill = $null
    Close-Confirm
    if ($kill -and @($kill).Count) {
        $n = Stop-SRSessions -Items $kill
        # A session spared at the last moment must be SAID. It keeps whatever the
        # relaunch was meant to fix, and the operator would otherwise believe it was
        # dealt with -- the same failure as a silent skip, arriving later.
        $late = @($script:relaunchLate)
        if ($late.Count) {
            Set-Status ("closed {0} - {1} started working while you decided and were left alone: {2}" -f $n, $late.Count, ($late -join ', ')) 'warn'
        } else {
            Set-Status ("closed {0} session(s) - reopening" -f $n)
        }
        # The liveness table still says they are running. Clearing it here stops the
        # relaunch being judged against processes that no longer exist.
        foreach ($it in @($kill)) { $script:running.Remove("$($it.S.sessionId)".ToLower()) }
    }
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
            if ($ui.SearchBox.Text) { $ui.SearchBox.Text = '' } else { $null = (Get-ActiveList).Focus() }
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
    # Whichever list is showing. Reading the tree's selection while the inbox is
    # on screen would act on a row nobody can see.
    $row  = (Get-ActiveList).SelectedItem
    # A band heading is a label, not a target. Every shortcut below that takes a
    # row would otherwise act on the heading, or on nothing, without saying so.
    if ($row -and $row.Kind -eq 'band') { $row = $null }
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
            # The three views, in the order they sit on screen.
            'D1'     { $e.Handled = $true; $ui.ModeInbox.IsChecked = $true }
            'D2'     { $e.Handled = $true; $ui.ModeAll.IsChecked = $true }
            'Escape' {
                $e.Handled = $true
                if ($ui.SearchBox.Text) { $ui.SearchBox.Text = '' }
                else { $ui.CancelBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent))) }
            }
            'Space'  { if ($row -and -not $script:busy) { $e.Handled = $true; Set-RowTick -Row $row -Value $null } }
            # LEFT / RIGHT folded a project away. There is nothing to fold in a
            # flat list, so they are the age window instead: the same gesture,
            # aimed at the thing that is actually making the list long.
            'Left'   { $e.Handled = $true; if ($script:showOlder) { $script:showOlder = $false; Update-List } }
            'Right'  { $e.Handled = $true; if (-not $script:showOlder) { $script:showOlder = $true;  Update-List } }
            'L'      { if ($row -and -not $script:busy) { $e.Handled = $true; Invoke-RowLaunch $row } }
            # G for "go to": the terminal itself, as opposed to ENTER, which
            # reads the conversation inside this window.
            'G'      { if ($row -and $row.Kind -eq 'session' -and -not $script:busy) { $e.Handled = $true; Invoke-RowJump $row } }
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

# --- TEST PLACEMENT ---------------------------------------------------------
# SR_GUI_PLACE lets a test run put this window somewhere harmless and, more
# importantly, open it WITHOUT taking focus. The suites launch the GUI several
# times per run; on a machine someone is actually using, each launch yanks the
# foreground away mid-keystroke or mid-game.
#
# Format: "<left>,<top>[,noactivate]" in virtual-screen coordinates, so a
# monitor to the left of the primary is a negative X.
#
# Deliberately an environment variable rather than a parameter: the drivers
# start this script through Start-Process with a fixed argument list, and an env
# var needs no change to any of them.
if ($env:SR_GUI_PLACE) {
    try {
        $bits = @("$env:SR_GUI_PLACE" -split ',')
        if ($bits.Count -ge 2) {
            $window.WindowStartupLocation = 'Manual'
            $window.Left = [double]$bits[0]
            $window.Top  = [double]$bits[1]
        }
        if ($bits -contains 'noactivate') {
            # The window appears without stealing the foreground. It still
            # renders, still answers UI Automation, and can still be given focus
            # deliberately by a suite that needs it.
            $window.ShowActivated = $false
        }
        Write-SRLog "gui placed for testing: $env:SR_GUI_PLACE"
    } catch {
        Write-SRLog "SR_GUI_PLACE ignored: $($_.Exception.Message)"
    }
}

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

# --- minimising goes to the tray ---
# MINIMISE, not close. Close means close: a tool that will not go away when you
# press its close button is a tool people learn to kill from Task Manager. The
# minimise button is the one gesture that already means "out of my way but not
# gone", so that is the one that hands it to the tray.
$window.Add_StateChanged({
    Invoke-Guarded {
        if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) { Hide-ToTray }
    } 'minimise'
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
    foreach ($t in @($script:searchTimer, $script:pollTimer, $script:liveTimer,
                     $script:readTimer, $script:noteTimer, $script:fastTimer)) { if ($t) { $t.Stop() } }
    # The tray icon outlives the window unless it is told not to: an orphaned
    # NotifyIcon sits in the tray until something hovers over it.
    if ($script:tray) {
        try { $script:tray.Visible = $false } catch { }
        try { $script:tray.Dispose() } catch { }
        $script:tray = $null
    }
    if ($script:fsw) {
        try { $script:fsw.EnableRaisingEvents = $false } catch { }
        try { $script:fsw.Dispose() } catch { }
        $script:fsw = $null
    }
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
# THE FAST PASS. Six seconds is chosen against what it costs: a dozen file
# stats, no WMI, no agents --json, no rebuild unless something actually moved.
$script:fastIntervalSeconds = 6
$script:fastTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:fastTimer.Interval = [TimeSpan]::FromSeconds($script:fastIntervalSeconds)
$script:fastTimer.Add_Tick({ try { Invoke-Guarded { Invoke-FastPass } 'the refresh' } catch { } })
$script:fastTimer.Start()

# A WATCHER ON TOP OF THE TIMER, not instead of it. FileSystemWatcher misses
# events under load and dies quietly when a directory is replaced, so it is
# here to make the common case feel instant, and the timer is what makes the
# tool correct. Its handler does nothing but poke the fast timer: the callback
# arrives on a threadpool thread, and touching the UI from there is a crash.
try {
    $root = $SR_Projects
    if ($root -and (Test-Path -LiteralPath $root)) {
        $script:fsw = New-Object System.IO.FileSystemWatcher $root, '*.jsonl'
        $script:fsw.IncludeSubdirectories = $true
        $script:fsw.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
        $onChange = {
            try {
                $script:fastTimer.Dispatcher.BeginInvoke([action]{
                    $script:fastTimer.Stop(); $script:fastTimer.Start()
                    Invoke-Guarded { Invoke-FastPass } 'the refresh'
                }) | Out-Null
            } catch { }
        }
        $null = Register-ObjectEvent -InputObject $script:fsw -EventName Changed -Action $onChange
        $script:fsw.EnableRaisingEvents = $true
        Write-SRLog "watching $root for transcript writes"
    }
} catch { Write-SRLog "file watcher unavailable: $($_.Exception.Message)" }

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
# ModeInbox carries IsChecked="True" in the markup, but Add_Checked is attached
# after the window loads, so that initial state raises nothing. Apply the mode
# explicitly or the window opens claiming Inbox while showing the tree.
Initialize-Tray
Set-ViewMode $script:viewMode
Set-Status 'Now: what each conversation last said, and which of them are waiting on you. Roster is where you choose what comes back at logon.' 'info'

$window.Add_ContentRendered({
    $list = Get-ActiveList
    $null = $list.Focus()
    if ($script:viewMode -ne 'inbox' -and $script:rows.Count) { $ui.RowList.SelectedIndex = 0 }
    if (-not $NoScan) { Start-Rescan } else { Start-Rescan -NoScanPass }
})

$null = $window.ShowDialog()

switch ($script:exitMode) {
    'saved'     { Write-Host "  Saved. Registry: $SR_RegistryPath" }
    'closed'    { Write-Host "  Closed. Registry: $SR_RegistryPath" }
    'cancelled' { Write-Host "  Closed - unsaved tick changes discarded." }
}
exit 0
