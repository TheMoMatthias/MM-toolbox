using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Keys;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 4.3 - the window's keyboard rules, against the shipped handler
/// itself.
/// </summary>
/// <remarks>
/// 🔴 THE ORDER IS THE WHOLE THING, AND GETTING IT WRONG COST THE OPERATOR
/// REWIND. <c>PreviewKeyDown</c> tunnels root to leaf, so the window's handler
/// runs BEFORE the terminal watcher's: Escape was swallowed there AND threw the
/// focus out of the pane, so the second Escape of the rewind gesture went to the
/// conversation list. <c>/</c> and <c>l</c> were being eaten the same way -
/// <c>/compact</c> arrived as <c>compact</c> and <c>hello</c> as <c>heo</c>.
///
/// 🔑 SO WHAT IS COMPARED IS WHICH SINK THE HANDLER REACHES, over every state.
/// Each of the nine things it can do is replaced by a stub that records its own
/// name and nothing else, and <c>$e.Handled</c> is read afterwards - so a key
/// the window must LET PAST is told apart from one it takes, which is the
/// distinction the defect turned on.
///
/// 🪤 TWO STATIC READS ARE SUBSTITUTED BY NAME, and they are inputs rather than
/// behaviour: <c>[Keyboard]::Modifiers</c> and <c>[Keyboard]::FocusedElement</c>
/// cannot be set from outside, and a real keyboard is exactly what a comparison
/// run from a script does not have. Everything between them is the shipped text.
/// </remarks>
public static class KeyCases
{
    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (TermCase(), true, "when a bare letter means a letter, over every state the watcher can be in");
        yield return (Route(), true, "what the window does with every key, from the shipped handler itself");
    }

    // ------------------------------------------------------- the watcher test

    private sealed record Term(string Name, bool Focused, string Shown, string? Streaming, bool On);

    /// <summary>
    /// 🔴 FOUR OPERATORS, AND EACH ONE IS A WAY TO GET IT WRONG. Not focused;
    /// focused on nothing; focused on something with no streaming record at all;
    /// focused on something the record does not mention; and focused on
    /// something it mentions as FALSE - which is the one a port that tested for
    /// the key's PRESENCE would get wrong.
    /// </summary>
    private static readonly Term[] Terms =
    [
        new("not-focused", false, "abc", "abc", true),
        new("focused-on-nothing", true, "", "abc", true),
        new("no-streaming-record", true, "abc", null, true),
        new("only-the-empty-name-streams", true, "abc", "", true),
        new("another-conversation-streams", true, "abc", "zzz", true),
        new("this-one-streams", true, "abc", "abc", true),
        new("this-one-is-recorded-as-not-streaming", true, "abc", "abc", false),
        new("focused-and-streaming-but-showing-nothing", true, "", "abc", true),

        // 🪤 THE SHAPE THAT MAKES THE EMPTY-SHOWN GUARD OBSERVABLE AT ALL.
        // Without it the guard is unreachable: an empty name simply misses in
        // the record and both sides say no anyway, so dropping it stayed green.
        // With an EMPTY KEY in the record the two part company - PowerShell
        // refuses on the name before it ever looks, and a port without the guard
        // finds the entry and says the watcher is typing.
        new("showing-nothing-and-the-record-has-an-empty-name", true, "", "", true),
    ];

    private static OracleCase TermCase() => new(
        "keys/term-typing",
        "Test-SRTermTyping, over every state the watcher can be in",
        TermScript(),
        _ =>
        {
            var rows = new JsonArray();
            foreach (var t in Terms)
            {
                // 🪤 "null" IS NO RECORD AT ALL; "" IS A RECORD WHOSE KEY IS THE
                // EMPTY NAME. The two are different questions and the shipped
                // line answers them with different operators.
                Dictionary<string, bool>? streaming = t.Streaming is null
                    ? null
                    : new Dictionary<string, bool>(StringComparer.Ordinal) { [t.Streaming] = t.On };

                rows.Add(new JsonObject
                {
                    ["n"] = t.Name,
                    ["typing"] = KeyRoute.TermTyping(t.Focused, t.Shown, streaming),
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        });

    private static string TermScript()
    {
        var sb = new StringBuilder();
        sb.Append("""
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        $a = $winSrc.IndexOf('function Test-SRTermTyping')
        if ($a -lt 0) { throw 'could not find Test-SRTermTyping' }
        Invoke-Expression $winSrc.Substring($a, $winSrc.IndexOf("`n}", $a) - $a + 2)

        $rows = @()
        $specs = @(
        """);

        foreach (var t in Terms)
        {
            sb.Append("            @{ n='").Append(t.Name).Append("'; f=$").Append(t.Focused ? "true" : "false")
              .Append("; sh='").Append(t.Shown).Append("'; st=")
              .Append(t.Streaming is null
                  ? "$null"
                  : "@{ '" + t.Streaming + "' = $" + (t.On ? "true" : "false") + " }")
              .Append(" }\n");
        }

        sb.Append("""
        )
        foreach ($s in $specs) {
            $rows += [ordered]@{
                n      = $s.n
                typing = [bool](Test-SRTermTyping -Focused ([bool]$s.f) -Shown "$($s.sh)" -Streaming $s.st)
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 5)
        """);

        return sb.ToString();
    }

    // ----------------------------------------------------------- the ordering

    private sealed record Press(
        string Name, PressedKey Key, string PsKey, bool Ctrl, bool Typing, bool SearchWithText,
        bool ConfigOpen, bool ProjectOpen, bool TermTyping, bool Manage, bool ProjectRow);

    private static readonly Press[] Presses =
    [
        // The three keys the watcher must receive, in the state that broke.
        new("escape-into-the-watcher", PressedKey.Escape, "Escape", false, false, false, false, false, true, false, false),
        new("slash-into-the-watcher", PressedKey.Slash, "Oem2", false, false, false, false, false, true, false, false),
        new("l-into-the-watcher", PressedKey.KeyL, "L", false, false, false, false, false, true, false, false),

        // And the settings panel must still close on Escape, in front of it.
        new("escape-closes-settings-over-the-watcher", PressedKey.Escape, "Escape", false, false, false, true, false, true, false, false),
        new("escape-closes-the-project-panel-over-it", PressedKey.Escape, "Escape", false, false, false, false, true, true, false, false),

        // Ctrl chords sit ABOVE the typing guard on purpose.
        new("ctrl-n-in-a-text-box", PressedKey.KeyN, "N", true, true, false, false, false, false, false, false),
        new("ctrl-1-in-a-text-box", PressedKey.Digit1, "D1", true, true, false, false, false, false, false, false),
        new("ctrl-2-in-a-text-box", PressedKey.Digit2, "D2", true, true, false, false, false, false, false, false),
        new("ctrl-n-over-the-watcher", PressedKey.KeyN, "N", true, false, false, false, false, true, false, false),

        // The typing guard itself.
        new("a-bare-l-in-a-text-box", PressedKey.KeyL, "L", false, true, false, false, false, false, false, false),
        new("a-bare-slash-in-a-text-box", PressedKey.Slash, "Oem2", false, true, false, false, false, false, false, false),
        new("escape-in-a-search-box-with-text", PressedKey.Escape, "Escape", false, true, true, false, false, false, false, false),
        new("escape-in-an-empty-search-box", PressedKey.Escape, "Escape", false, true, false, false, false, false, false, false),

        // The work surface, nothing focused.
        new("escape-on-the-board", PressedKey.Escape, "Escape", false, false, false, false, false, false, false, false),
        new("slash-on-the-board", PressedKey.Slash, "Oem2", false, false, false, false, false, false, false, false),
        new("l-on-the-board", PressedKey.KeyL, "L", false, false, false, false, false, false, false, false),
        new("space-on-the-board", PressedKey.Space, "Space", false, false, false, false, false, false, false, false),
        new("o-on-the-board", PressedKey.KeyO, "O", false, false, false, false, false, false, false, false),
        new("left-on-the-board", PressedKey.Left, "Left", false, false, false, false, false, false, false, false),
        new("an-ordinary-letter", PressedKey.Other, "A", false, false, false, false, false, false, false, false),

        // The manage surface.
        new("space-on-the-manager", PressedKey.Space, "Space", false, false, false, false, false, false, true, false),
        new("o-on-the-manager", PressedKey.KeyO, "O", false, false, false, false, false, false, true, false),
        new("left-on-a-project-row", PressedKey.Left, "Left", false, false, false, false, false, false, true, true),
        new("right-on-a-project-row", PressedKey.Right, "Right", false, false, false, false, false, false, true, true),

        // 🪤 AND THE ARROWS FALL THROUGH WHEN THE SELECTED ROW IS NOT A PROJECT.
        new("left-on-a-conversation-row", PressedKey.Left, "Left", false, false, false, false, false, false, true, false),
        new("right-on-a-conversation-row", PressedKey.Right, "Right", false, false, false, false, false, false, true, false),
        new("l-on-the-manager", PressedKey.KeyL, "L", false, false, false, false, false, false, true, false),
    ];

    private static OracleCase Route() => new(
        "keys/route",
        "which of the window's nine key sinks each press reaches, and whether the key is stopped",
        RouteScript(),
        _ =>
        {
            var rows = new JsonArray();
            foreach (var p in Presses)
            {
                var r = KeyRoute.Of(p.Key, p.Ctrl, p.Typing, p.SearchWithText, p.ConfigOpen,
                                    p.ProjectOpen, p.TermTyping, p.Manage, p.ProjectRow);
                rows.Add(new JsonObject
                {
                    ["n"] = p.Name,
                    ["act"] = Sink(r.Act),
                    ["handled"] = r.Handled,
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        });

    /// <summary>
    /// The name the stub on the other side records for each sink. 🪤 One name
    /// per SINK, not per act: the shipped handler reaches
    /// <c>Invoke-ColumnFold</c> for both columns and tells them apart by an
    /// argument, so the stub records that argument and the two sides agree on
    /// one string.
    /// </summary>
    private static string Sink(KeyAct act) => act switch
    {
        KeyAct.PassOn => string.Empty,
        KeyAct.Spawn => "Show-Spawn",
        KeyAct.FoldRail => "Invoke-ColumnFold rail",
        KeyAct.FoldList => "Invoke-ColumnFold list",
        KeyAct.CloseConfig => "Hide-Config",
        KeyAct.CloseProject => "Hide-Project",
        KeyAct.ClearSearch => "clear the search box",
        KeyAct.FocusList => "focus SessionList",
        KeyAct.FocusSearch => "focus Search",
        KeyAct.ToggleTick => "Toggle-Tick",
        KeyAct.ToggleOlder => "toggle showOlder",
        KeyAct.FoldProject => "fold the project",
        KeyAct.UnfoldProject => "unfold the project",
        KeyAct.LoadWhole => "Expand-SRTailToAll",
        _ => "(unknown)",
    };

    private static string RouteScript()
    {
        var sb = new StringBuilder();
        sb.Append("""
        # 🪤 THE MODIFIER ENUM COMES FROM PresentationCore, WHICH A PLAIN
        # SCRIPT HAS NOT LOADED. Loading it is better than substituting a third
        # piece of the shipped text: the -band against ModifierKeys::Control is
        # the actual line being compared.
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop

        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))

        # Test-SRTermTyping is REAL - it is pure, and it is half of what decides
        # the order. Only the sinks are stubbed.
        $a = $winSrc.IndexOf('function Test-SRTermTyping')
        if ($a -lt 0) { throw 'could not find Test-SRTermTyping' }
        Invoke-Expression $winSrc.Substring($a, $winSrc.IndexOf("`n}", $a) - $a + 2)

        # ---- the handler's body, cut out by the words around it --------------
        # 🪤 THE LAST Add_PreviewKeyDown ON $window IS THE ONE. There are five
        # PreviewKeyDown handlers in the file; this takes the last one attached
        # to the window itself, which is the shortcut handler.
        $mark = $winSrc.LastIndexOf('$window.Add_PreviewKeyDown({')
        if ($mark -lt 0) { throw 'could not find the window key handler' }
        $from = $winSrc.IndexOf("`n", $winSrc.IndexOf('param($sender, $e)', $mark)) + 1
        $to = $winSrc.IndexOf("`n})", $from)
        if ($from -le 0 -or $to -lt 0) { throw 'could not cut the key handler' }
        $body = $winSrc.Substring($from, $to - $from)

        # 🔴 REFUSE TO EVALUATE IT IF IT REACHES ANYTHING THAT ACTS. The
        # handler is shortcuts only, and this says so rather than assuming it.
        foreach ($bad in @('Start-SRSession', 'Stop-Process', 'SRCon', 'Save-SRRegistry')) {
            if ($body -match [regex]::Escape($bad)) { throw "the key handler reaches $bad - refusing to evaluate it" }
        }

        # 🪤 TWO STATIC READS SUBSTITUTED BY NAME. A script has no keyboard, so
        # Modifiers and FocusedElement are inputs this side has to supply. They
        # are the only two edits to the shipped text.
        $body = $body -replace '\[System\.Windows\.Input\.Keyboard\]::Modifiers', '$script:mods'
        $body = $body -replace '\$fe = \[System\.Windows\.Input\.Keyboard\]::FocusedElement', '$fe = $null'

        # ---- the sinks, each one remembering only its own name ---------------
        $script:did = ''
        function Note-Sink { param([string]$What) if (-not $script:did) { $script:did = $What } }
        function Show-Spawn { Note-Sink 'Show-Spawn' }
        function Invoke-ColumnFold { param([string]$Which) Note-Sink ("Invoke-ColumnFold " + $Which) }
        function Hide-Config { Note-Sink 'Hide-Config' }
        function Hide-Project { Note-Sink 'Hide-Project' }
        function Set-Status { param([string]$Text, [string]$Kind = 'info') }
        function Toggle-Tick { Note-Sink 'Toggle-Tick' }
        function Build-Manager { }
        function Expand-SRTailToAll { Note-Sink 'Expand-SRTailToAll' }
        function Update-Document { }
        function Test-SRTypingTarget { param($Element) return $script:typing }

        # A focusable stand-in: it answers the two questions the handler asks of
        # a box, and remembers being focused or emptied.
        function New-Box { param([string]$Name, [bool]$Focus, [string]$Text)
            $o = [PSCustomObject]@{ Name = $Name; IsKeyboardFocusWithin = $Focus; Text = $Text; Visibility = 'Collapsed' }
            $o | Add-Member -MemberType ScriptMethod -Name Focus -Value { Note-Sink ("focus " + $this.Name) } -Force
            # Emptying a search box is an assignment in the shipped line, so it
            # is caught by comparing the text afterwards rather than by a sink.
            return $o
        }

        $V_Show = 'Visible'
        $V_Hide = 'Collapsed'

        $rows = @()
        $specs = @(
        """);

        foreach (var p in Presses)
        {
            sb.Append("            @{ n='").Append(p.Name).Append("'; k='").Append(p.PsKey)
              .Append("'; ctrl=$").Append(p.Ctrl ? "true" : "false")
              .Append("; typing=$").Append(p.Typing ? "true" : "false")
              .Append("; swt=$").Append(p.SearchWithText ? "true" : "false")
              .Append("; cfg=$").Append(p.ConfigOpen ? "true" : "false")
              .Append("; prj=$").Append(p.ProjectOpen ? "true" : "false")
              .Append("; term=$").Append(p.TermTyping ? "true" : "false")
              .Append("; manage=$").Append(p.Manage ? "true" : "false")
              .Append("; prow=$").Append(p.ProjectRow ? "true" : "false")
              .Append(" }\n");
        }

        sb.Append("""
        )
        foreach ($s in $specs) {
            $script:did = ''
            $script:typing = [bool]$s.typing
            $script:mods = $(if ($s.ctrl) { [System.Windows.Input.ModifierKeys]::Control } else { [System.Windows.Input.ModifierKeys]::None })

            # 🔑 THE SEARCH BOX IS THE ONE THE TYPING GUARD NAMES, so "a search
            # box with text" is spelled as the header Search holding both.
            $ui = @{}
            $ui.Search      = New-Box 'Search'      ([bool]$s.swt) $(if ($s.swt) { 'algo' } else { '' })
            $ui.RailSearch  = New-Box 'RailSearch'  $false ''
            $ui.ListSearch  = New-Box 'ListSearch'  $false ''
            $ui.SendBox     = New-Box 'SendBox'     $false ''
            $ui.SessionList = New-Box 'SessionList' $false ''
            $ui.CfgBox      = New-Box 'CfgBox'      $false ''
            $ui.ProjBox     = New-Box 'ProjBox'     $false ''
            $ui.LivePane    = New-Box 'LivePane'    ([bool]$s.term) ''
            $ui.ManageList  = New-Box 'ManageList'  $false ''
            $ui.CfgBox.Visibility  = $(if ($s.cfg) { $V_Show } else { $V_Hide })
            $ui.ProjBox.Visibility = $(if ($s.prj) { $V_Show } else { $V_Hide })
            $ui.ManageList | Add-Member -MemberType NoteProperty -Name SelectedItem -Force -Value $(
                if ($s.prow) { [PSCustomObject]@{ Kind = 'project'; Path = 'p' } }
                else { [PSCustomObject]@{ Kind = 'session'; Path = '' } })

            # The watcher's two facts, spelled so Test-SRTermTyping answers what
            # the case is asking about.
            $script:liveShownFor = $(if ($s.term) { 'abc' } else { '' })
            $script:streamTerm   = @{ 'abc' = $true }
            $script:surface      = $(if ($s.manage) { 'manage' } else { 'work' })
            $script:showOlder    = $false
            $script:fold         = @{}

            $e = [PSCustomObject]@{ Key = $s.k; Handled = $false }
            $sender = $null
            $before = @($ui.Search.Text, $ui.RailSearch.Text, $ui.ListSearch.Text)

            $fn = [ScriptBlock]::Create($body)
            $null = & $fn

            $after = @($ui.Search.Text, $ui.RailSearch.Text, $ui.ListSearch.Text)
            # 🪤 THREE OF THE NINE SINKS ARE ASSIGNMENTS, NOT CALLS. Emptying a
            # search box, flipping showOlder and folding a project are all
            # `$x = ...` in the shipped lines, so there is no function to stub -
            # what they did is read off the state afterwards. A first version
            # stubbed only the calls and reported "nothing happened" for the
            # manager's own O.
            if (-not $script:did) {
                for ($i = 0; $i -lt 3; $i++) {
                    if ($before[$i] -ne $after[$i]) { $script:did = 'clear the search box' }
                }
            }
            if (-not $script:did -and $script:showOlder) { $script:did = 'toggle showOlder' }
            if (-not $script:did -and $script:fold.Count) {
                $script:did = $(if ($script:fold['p']) { 'fold the project' } else { 'unfold the project' })
            }
            # 🪤 A SCRIPTBLOCK'S `return` LEAVES THE BLOCK, NOT THE LOOP, which
            # is what makes cutting the body out of the handler work at all.
            $rows += [ordered]@{
                n       = $s.n
                act     = "$($script:did)"
                handled = [bool]$e.Handled
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 5)
        """);

        return sb.ToString();
    }

    public static string Coverage() => string.Format(CultureInfo.InvariantCulture,
        "{0} key press(es) and {1} watcher state(s) compared", Presses.Length, Terms.Length);
}
