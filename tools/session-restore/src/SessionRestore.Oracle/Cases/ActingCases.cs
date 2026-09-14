using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Acting;
using SessionRestore.Core.Sessions;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 4.2d - the acting decisions, as values, against the shipped window.
/// </summary>
/// <remarks>
/// 🔴 NOTHING HERE IS PERFORMED, AND NOTHING HERE COULD BE. Every comparison is
/// over a REFUSAL, a NOTE or the TEXT OF A SHEET - the things the shipped window
/// decides before it acts. <c>Invoke-RelaunchOne</c> is never evaluated: it calls
/// <c>Stop-Process</c>, and running it under any stub at all is the exact act
/// this rebuild is forbidden to take. What is evaluated is the single line that
/// builds each sentence, with the sink it hands that sentence to replaced by one
/// that only remembers it.
///
/// 🔑 THAT IS THE SAME SPLIT AS PHASE 2: <c>Get-SRLaunchCommandLine</c> out of
/// <c>Start-SRSession</c>, <c>Get-SRSaveRefusal</c> out of the fenced
/// <c>Save-SRRegistry</c>. An act becomes a value, and a value can be compared.
/// </remarks>
public static class ActingCases
{
    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Decisions(), true, "who may be interrupted and typed into, over every state a probe can report");
        yield return (Sentences(), true, "every refusal and sheet the acting handlers say, from the shipped lines themselves");
    }

    // --------------------------------------------------------- the decisions

    /// <param name="Kind">What the probe calls it. Empty is a real answer and must not read as a background agent.</param>
    private sealed record Who(string Name, bool HaveRow, bool HaveAgent, int Pid, string Kind, string Status, bool OnAMenu, int Queued);

    private static readonly Who[] Whos =
    [
        new("nothing-selected", false, false, 0, "interactive", "idle", false, 0),
        new("not-running", true, false, 0, "interactive", "idle", false, 0),
        new("a-probe-with-no-pid", true, true, 0, "interactive", "busy", false, 0),
        new("a-background-agent", true, true, 100, "agent", "busy", false, 0),
        new("idle-and-interactive", true, true, 100, "interactive", "idle", false, 0),
        new("busy-and-interactive", true, true, 100, "interactive", "busy", false, 0),

        // 🪤 POWERSHELL'S -ne IS CASE-INSENSITIVE, so a probe that shouted would
        // still be interactive and still be busy. A port comparing ordinally
        // refuses both.
        new("kind-in-capitals", true, true, 100, "Interactive", "BUSY", false, 0),

        // 🪤 AN EMPTY KIND IS NOT A BACKGROUND AGENT to the send box - the
        // shipped test is `$r.A.Kind -and $r.A.Kind -ne 'interactive'` - but it
        // IS one to the interrupt, whose test has no first half.
        new("no-kind-at-all", true, true, 100, "", "busy", false, 0),
        new("no-kind-and-idle", true, true, 100, "", "idle", false, 0),

        new("on-a-menu", true, true, 100, "interactive", "idle", true, 0),
        new("on-a-menu-and-busy", true, true, 100, "interactive", "busy", true, 0),
        new("busy-with-nothing-queued", true, true, 100, "interactive", "busy", false, 0),
        new("busy-with-one-queued", true, true, 100, "interactive", "busy", false, 1),
        new("busy-with-four-queued", true, true, 100, "interactive", "busy", false, 4),
        new("idle-with-a-queue", true, true, 100, "interactive", "idle", false, 3),
    ];

    private static OracleCase Decisions() => new(
        "acting/decisions",
        "the interrupt blocker and the send box's state, over every state a probe can report",
        DecisionScript(),
        _ =>
        {
            var rows = new JsonArray();
            foreach (var w in Whos)
            {
                var agent = w.HaveAgent
                    ? new AgentStatus("id", w.Status, string.Empty, false, w.Pid, w.Kind, "n", string.Empty, null)
                    : null;
                var typing = Typing.Of(w.HaveRow, agent, w.OnAMenu, w.Queued);
                rows.Add(new JsonObject
                {
                    ["n"] = w.Name,
                    ["interrupt"] = Interrupt.Blocker(w.HaveRow, agent),
                    ["why"] = typing.Blocker,
                    ["note"] = typing.Note,
                    ["canType"] = typing.CanType,
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        });

    private static string DecisionScript()
    {
        var sb = new StringBuilder();
        var inv = CultureInfo.InvariantCulture;

        sb.Append("""
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))

        # Get-InterruptBlocker is a function, so it is CALLED rather than spliced.
        $a = $winSrc.IndexOf('function Get-InterruptBlocker')
        if ($a -lt 0) { throw 'could not find Get-InterruptBlocker' }
        Invoke-Expression $winSrc.Substring($a, $winSrc.IndexOf("`n}", $a) - $a + 2)

        # 🔴 THE SEND BOX'S STATE IS INLINE IN Update-SendState, which ends by
        # writing to four controls - so the region is cut at the last line that
        # decides anything and nothing below it is evaluated.
        $fromS = $winSrc.IndexOf("    `$why = ''      # a real blocker")
        $toS = $winSrc.IndexOf('    try { Update-QueuePanel }', $fromS)
        if ($fromS -lt 0 -or $toS -lt 0) { throw 'could not find the send-state region' }
        $regionS = $winSrc.Substring($fromS, $toS - $fromS)

        $rows = @()
        $specs = @(

        """);

        foreach (var w in Whos)
        {
            sb.Append(inv, $"    @{{ n = '{w.Name}'; row = ${w.HaveRow.ToString().ToLowerInvariant()}; ");
            sb.Append(inv, $"agent = ${w.HaveAgent.ToString().ToLowerInvariant()}; pid = {w.Pid}; ");
            sb.Append(inv, $"kind = {PsText.Literal(w.Kind)}; status = {PsText.Literal(w.Status)}; ");
            sb.Append(inv, $"menu = ${w.OnAMenu.ToString().ToLowerInvariant()}; q = {w.Queued} }},\n");
        }

        sb.Append("""
            $null)
        foreach ($s in $specs) {
            if (-not $s) { continue }
            $r = $null
            if ($s.row) {
                $r = [PSCustomObject]@{
                    Id = 'row'
                    A  = $(if ($s.agent) { [PSCustomObject]@{ Pid = $s.pid; Kind = $s.kind; Status = $s.status } } else { $null })
                    Q  = $(if ($s.q -gt 0) { [PSCustomObject]@{ Count = $s.q } } else { $null })
                }
            }

            $blocker = Get-InterruptBlocker $r

            # What Update-SendState reads: the selected item, and whether this
            # conversation has been seen sitting on a question.
            $it = $(if ($s.row) { [PSCustomObject]@{ Kind = 'session'; Row = $r } } else { $null })
            $script:askSeen = @{}
            if ($s.menu) { $script:askSeen['row'] = $true }
            Invoke-Expression $regionS

            $rows += [ordered]@{
                n = "$($s.n)"; interrupt = "$blocker"; why = "$why"; note = "$note"
                canType = [bool](-not $why)
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 4)

        """);

        return sb.ToString();
    }

    // --------------------------------------------------------- the sentences

    /// <summary>One sentence the window says, found by words that are in it.</summary>
    /// <param name="Name">What the answer calls it.</param>
    /// <param name="Marker">Enough of the shipped line to find it, and nothing that moves.</param>
    /// <param name="Kind">status - a Set-Status line; confirm - a Confirm-Action call.</param>
    private sealed record Line(string Name, string Marker, string Kind);

    private static readonly Line[] Lines =
    [
        new("relaunch-refuses-mid-turn", "is mid-turn - closing it now would lose the reply", "status"),
        new("relaunch-could-not-close", "would not close, so it has NOT been reopened", "status"),
        new("pane-open-sheet", "'{0}' is not running.", "confirm"),
        new("pane-relaunch-sheet", "will be CLOSED and opened again. Anything it has written", "confirm"),
        new("manager-relaunch-sheet", "will be CLOSED and opened again.\" -f", "confirm"),
        new("goto-not-running", "there is no terminal to go to", "status"),
        new("compact-not-running", "so there is nothing to compact", "status"),
        new("compact-pick-one", "pick a conversation first", "status"),
        new("compact-sent", "sent /compact", "status"),
    ];

    private static OracleCase Sentences() => new(
        "acting/sentences",
        "every refusal and every sheet, evaluated from the shipped line itself",
        SentenceScript(),
        _ =>
        {
            var title = "the session";
            var rows = new JsonArray
            {
                Say("relaunch-refuses-mid-turn", Relaunch.Refusal(Busy(), title), "warn"),
                Say("relaunch-could-not-close", Relaunch.WouldNotClose(title), "bad"),
                Sheet("pane-open-sheet", Relaunch.PaneAsk(null, title)),
                Sheet("pane-relaunch-sheet", Relaunch.PaneAsk(Idle(), title)),
                Sheet("manager-relaunch-sheet", Relaunch.ManagerAsk(title)),

                // 🪤 THESE LIVE IN THE SHELL, NOT IN Core.Acting, because they
                // are one sentence with no decision in them. They are compared
                // here so the port cannot drift from the window's own words.
                Say("goto-not-running", "that conversation is not running - there is no terminal to go to", "warn"),
                Say("compact-not-running", "that conversation is not running, so there is nothing to compact", "bad"),
                Say("compact-pick-one", "pick a conversation first", "bad"),
                Say("compact-sent", "sent /compact", "ok"),
            };

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        });

    private static AgentStatus Busy() =>
        new("id", "busy", string.Empty, false, 100, "interactive", "n", string.Empty, null);

    private static AgentStatus Idle() =>
        new("id", "idle", string.Empty, false, 100, "interactive", "n", string.Empty, null);

    private static JsonObject Say(string name, string text, string tone) => new()
    {
        ["n"] = name,
        ["text"] = text,
        ["tone"] = tone,
    };

    private static JsonObject Sheet(string name, Confirm c) => new()
    {
        ["n"] = name,
        ["title"] = c.Title,
        ["body"] = c.Body,
        ["verb"] = c.Verb,
    };

    private static string SentenceScript()
    {
        var sb = new StringBuilder();
        var inv = CultureInfo.InvariantCulture;

        sb.Append("""
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        $lines = $winSrc -split "`n"
        $t = 'the session'
        $script:said = ''; $script:tone = ''
        $script:cTitle = ''; $script:cBody = ''; $script:cVerb = ''

        # 🔴 THE SINKS, REPLACED BY SOMETHING THAT ONLY REMEMBERS. Set-Status
        # writes to a control; Confirm-Action shows a modal sheet and pumps a
        # nested dispatcher. Neither can run here, and neither needs to: what is
        # being compared is the sentence handed to them.
        function Set-Status { param([string]$Text, [string]$Kind = 'info') $script:said = $Text; $script:tone = $Kind }
        function Confirm-Action { param([string]$Title, [string]$Body, [string]$Verb)
            $script:cTitle = $Title; $script:cBody = $Body; $script:cVerb = $Verb; return $false }

        # A Confirm-Action sits inside `if (...) {`, and its argument list can be
        # continued with a backtick - so the call is cut by BALANCING the bracket
        # the `if` opened rather than by reading to the end of a line.
        function Get-SRCallAt { param([string]$Text, [int]$At)
            $open = $Text.LastIndexOf('(', $At)
            if ($open -lt 0) { throw 'no bracket before the call' }
            $depth = 0
            for ($i = $open; $i -lt $Text.Length; $i++) {
                $c = $Text[$i]
                if ($c -eq '(') { $depth++ }
                elseif ($c -eq ')') { $depth--; if ($depth -eq 0) { return $Text.Substring($open + 1, $i - $open - 1) } }
            }
            throw 'the call never closed'
        }

        $rows = @()
        $specs = @(

        """);

        foreach (var l in Lines)
        {
            sb.Append(inv, $"    @{{ n = '{l.Name}'; m = {PsText.Literal(l.Marker)}; k = '{l.Kind}' }},\n");
        }

        sb.Append("""
            $null)
        foreach ($s in $specs) {
            if (-not $s) { continue }
            $at = $winSrc.IndexOf($s.m)
            if ($at -lt 0) { throw ('could not find the line for ' + $s.n) }
            $script:said = ''; $script:tone = ''
            $script:cTitle = ''; $script:cBody = ''; $script:cVerb = ''
            if ($s.k -eq 'confirm') {
                # 🪤 BACK TO THE CALL'S NAME FIRST. The marker sits INSIDE the
                # body argument, so the nearest bracket behind it is that
                # argument's own - and cutting from there evaluated a format
                # string that never called anything, leaving every field empty.
                $ci = $winSrc.LastIndexOf('Confirm-Action', $at)
                if ($ci -lt 0) { throw ('no Confirm-Action before ' + $s.n) }
                $call = Get-SRCallAt -Text $winSrc -At $ci
                $null = Invoke-Expression $call
                $rows += [ordered]@{ n = "$($s.n)"; title = "$($script:cTitle)"; body = "$($script:cBody)"; verb = "$($script:cVerb)" }
            } else {
                # The whole line the marker is on, which is one Set-Status call.
                $ls = $winSrc.LastIndexOf("`n", $at) + 1
                $le = $winSrc.IndexOf("`n", $at)
                $null = Invoke-Expression $winSrc.Substring($ls, $le - $ls)
                $rows += [ordered]@{ n = "$($s.n)"; text = "$($script:said)"; tone = "$($script:tone)" }
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 4)

        """);

        return sb.ToString();
    }
}
