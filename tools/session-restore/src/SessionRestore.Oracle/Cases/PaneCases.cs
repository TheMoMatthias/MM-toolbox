using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Rows;
using SessionRestore.Core.Sessions;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 4.2c - the reading pane's header, against <c>Show-Selected</c> itself.
/// </summary>
/// <remarks>
/// 🔴 SHOW-SELECTED IS SPLICED, NOT COPIED. The header is built inline in the
/// selection handler - three assignments into <c>$ui</c> and a resource lookup -
/// so the case cuts the two regions out of <c>lib/sessions-window.ps1</c> by
/// their first and last lines and runs them over each spec. A change to the
/// shipped header that the port does not follow goes red.
///
/// 🔑 THE SUBSTITUTION THAT MAKES THE DOT COMPARABLE: <c>$window.FindResource</c>
/// is stubbed to return the KEY it was asked for. The shipped code looks up a
/// brush; what the port produces is the band key the view resolves a brush from,
/// so returning the key is what puts the two answers in the same units - and it
/// still fails if the shipped code ever asks for a different resource.
///
/// 🪤 <c>$ui</c> IS STUBBED, AND THAT IS THE WHOLE RISK HERE. A stub that
/// swallowed an assignment would make this case agree with itself, so every
/// field it holds is read back into the answer and the specs include a band the
/// table does not contain - the one case where the shipped line leaves the label
/// empty.
/// </remarks>
public static class PaneCases
{
    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Header(), true, "the pane's name, dot and state line, against Show-Selected's own lines");
    }

    /// <param name="Band">A band key, or something not in the table.</param>
    private sealed record Sess(string Name, string Title, string Band, string? Detail, string Project, bool Busy, bool Running);

    private sealed record Ag(string Name, string Label, string Kind, string Description, string ParentTitle);

    private static readonly Sess[] Sessions =
    [
        new("needs-you-and-busy", "the session", "needs", "writing a reply", "AlgoTrader", true, true),
        new("working", "the session", "working", "thinking", "AlgoTrader", true, true),
        new("something-open", "a long title that does not get trimmed here", "open", "idle", "MM-toolbox", false, true),
        new("finished", "the session", "done", "idle", "MM-toolbox", false, true),
        new("idle", "the session", "idle", "waiting on you", "MM-toolbox", false, true),
        new("not-running-has-no-detail", "the session", "quiet", null, "MM-toolbox", false, false),
        new("an-empty-detail-reads-as-no-process", "the session", "quiet", "", "MM-toolbox", false, true),
        new("a-blank-detail-is-not-empty", "the session", "quiet", "   ", "MM-toolbox", false, true),
        // 🪤 A BAND THE TABLE DOES NOT HOLD. The shipped line leaves the label
        // empty and uses the idle accent; nothing else in the suite reaches it.
        new("an-unknown-band", "the session", "not-a-band", "idle", "MM-toolbox", false, true),
        new("no-project-label", "the session", "quiet", null, "", false, false),
        new("busy-without-a-process-does-not-pulse", "the session", "working", "thinking", "MM-toolbox", true, false),
        new("a-title-with-a-bar-in-it", "one | two", "quiet", null, "MM-toolbox", false, false),
    ];

    private static readonly Ag[] Agents =
    [
        new("a-task-agent", "explorer", "task", "find every caller", "the parent"),
        new("a-teammate", "I7", "in_process_teammate", "hold the interface", "the parent"),
        new("no-description", "explorer", "task", "", "the parent"),
        new("no-parent-title", "explorer", "task", "find every caller", ""),
        new("neither", "explorer", "in_process_teammate", "", ""),
    ];

    private static OracleCase Header() => new(
        "pane/header",
        "the name, the dot and the state line for a conversation and for a sub-agent",
        Script(),
        _ =>
        {
            var rows = new JsonArray();
            foreach (var s in Sessions)
            {
                // The shipped header pulses only while a process is holding it
                // AND that process says busy - two conditions, and the spec can
                // set them apart.
                var head = PaneHeader.OfSession(s.Title, s.Band, s.Detail, s.Project, s.Running && s.Busy);
                rows.Add(Row(s.Name, head));
            }

            foreach (var a in Agents)
            {
                var agent = new SubAgent(
                    Id: "a1",
                    Label: a.Label,
                    AgentType: "general-purpose",
                    Description: a.Description,
                    TaskKind: a.Kind,
                    Model: string.Empty,
                    Team: string.Empty,
                    ToolUseId: string.Empty,
                    Path: string.Empty,
                    HasTranscript: true,
                    Bytes: 0,
                    When: DateTimeOffset.Now);
                rows.Add(Row(a.Name, PaneHeader.OfAgent(agent, a.ParentTitle)));
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        });

    private static JsonObject Row(string name, PaneHead h) => new()
    {
        ["name"] = name,
        ["paneName"] = h.Name,
        // The shipped dot is a resource NAME once FindResource is stubbed; the
        // port names the band and the view resolves it. Mapped here, in one place.
        ["dot"] = Resource(h.Accent),
        ["state"] = h.State,
        ["pulse"] = h.Pulse,
    };

    /// <summary>The window resource the shipped header asks for, for a band key.</summary>
    /// <remarks>
    /// 🪤 AN UNKNOWN BAND GETS <c>AccIdle</c>, WHICH IS NOT THE QUIET ACCENT.
    /// The shipped line falls back to AccIdle when the table has no row, and
    /// "quiet" is a row in the table with AccQuiet - so the two are different
    /// answers and a port that collapsed them would be wrong on one spec.
    /// </remarks>
    private static string Resource(string accent) => accent switch
    {
        PaneHeader.Ask => "HueAsk",
        Bands.Needs => "AccNeeds",
        Bands.Open => "AccOpen",
        Bands.Working => "AccWorking",
        Bands.Done => "AccDone",
        Bands.Idle => "AccIdle",
        Bands.Quiet => "AccQuiet",
        _ => "AccIdle",
    };

    private static string Script()
    {
        var sb = new StringBuilder();
        var inv = CultureInfo.InvariantCulture;

        sb.Append("""
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))

        # The band table itself, so a band added to the window is a band this case
        # answers about without being told.
        $ba = $winSrc.IndexOf('$script:Bands = @(')
        $bb = $winSrc.IndexOf("`n)", $ba)
        if ($ba -lt 0 -or $bb -lt 0) { throw 'could not find the band table' }
        Invoke-Expression $winSrc.Substring($ba, $bb - $ba + 2)

        $pl = $winSrc.IndexOf('function Get-ProjectLabel')
        Invoke-Expression $winSrc.Substring($pl, $winSrc.IndexOf("`n}", $pl) - $pl + 2)

        # 🔴 THE TWO REGIONS OF Show-Selected, CUT BY THEIR OWN LINES. The end
        # markers are found by their ASCII words and backed up to the line start:
        # an emoji in a literal sent down the oracle's pipe is one codepage from
        # not matching.
        $fromA = $winSrc.IndexOf('        $ui.PaneName.Text = "$($sa.Label)"')
        $toA = $winSrc.IndexOf('The vitals strip describes a LIVE session', $fromA)
        if ($toA -ge 0) { $toA = $winSrc.LastIndexOf("`n", $toA) + 1 }
        $fromB = $winSrc.IndexOf('    $ui.PaneName.Text = $t.Text')
        $toB = $winSrc.IndexOf('NOT ON THE CLICK. Reading the vitals costs', $fromB)
        if ($toB -ge 0) { $toB = $winSrc.LastIndexOf("`n", $toB) + 1 }
        if ($fromA -lt 0 -or $toA -lt 0 -or $fromB -lt 0 -or $toB -lt 0) { throw 'could not find the header regions in Show-Selected' }
        $regionA = $winSrc.Substring($fromA, $toA - $fromA)
        $regionB = $winSrc.Substring($fromB, $toB - $fromB)

        # The stubs. Each field is read back into the answer, so a stub that
        # swallowed an assignment would show up as an empty column rather than as
        # agreement.
        $ui = @{
            PaneName     = [PSCustomObject]@{ Text = '(never set)' }
            PaneState    = [PSCustomObject]@{ Text = '(never set)' }
            PaneStateDot = [PSCustomObject]@{ Background = '(never set)' }
        }
        $window = New-Object PSObject
        $window | Add-Member -MemberType ScriptMethod -Name FindResource -Value { param($k) "$k" }
        $script:pulse = $null
        function Set-WorkingPulse { param($On) $script:pulse = [bool]$On }

        $rows = @()
        $sessions = @(

        """);

        foreach (var s in Sessions)
        {
            sb.Append(inv, $"    @{{ n = '{s.Name}'; title = {PsText.Literal(s.Title)}; band = '{s.Band}'; ");
            sb.Append(inv, $"detail = {(s.Detail is null ? "$null" : PsText.Literal(s.Detail))}; ");
            sb.Append(inv, $"proj = {PsText.Literal(s.Project)}; busy = ${s.Busy.ToString().ToLowerInvariant()}; ");
            sb.Append(inv, $"running = ${s.Running.ToString().ToLowerInvariant()} }},\n");
        }

        sb.Append("""
            $null)
        foreach ($s in $sessions) {
            if (-not $s) { continue }
            $script:projLabel = @{ 'C:\proj' = $s.proj }
            $t = @{ Text = $s.title }
            $r = [PSCustomObject]@{
                Band = $s.band
                A    = $(if ($s.running) { [PSCustomObject]@{ Pid = 1; Status = $(if ($s.busy) { 'busy' } else { 'idle' }) } } else { $null })
                Conv = $(if ($null -ne $s.detail) { [PSCustomObject]@{ Detail = $s.detail } } else { $null })
                D    = [PSCustomObject]@{ path = 'C:\proj' }
            }
            $ui.PaneName.Text = '(never set)'
            $ui.PaneState.Text = '(never set)'
            $ui.PaneStateDot.Background = '(never set)'
            $script:pulse = $null

            Invoke-Expression $regionB

            $rows += [ordered]@{
                name = "$($s.n)"; paneName = "$($ui.PaneName.Text)"
                dot = "$($ui.PaneStateDot.Background)"; state = "$($ui.PaneState.Text)"
                pulse = [bool]$script:pulse
            }
        }

        $agents = @(

        """);

        foreach (var a in Agents)
        {
            sb.Append(inv, $"    @{{ n = '{a.Name}'; label = {PsText.Literal(a.Label)}; kind = '{a.Kind}'; ");
            sb.Append(inv, $"desc = {PsText.Literal(a.Description)}; parent = {PsText.Literal(a.ParentTitle)} }},\n");
        }

        sb.Append("""
            $null)
        foreach ($a in $agents) {
            if (-not $a) { continue }
            $sa = [PSCustomObject]@{
                Label       = $a.label
                Description = $a.desc
                IsTeammate  = ($a.kind -eq 'in_process_teammate')
            }
            $it = [PSCustomObject]@{ Row = [PSCustomObject]@{ T = @{ Text = $a.parent } } }
            $ui.PaneName.Text = '(never set)'
            $ui.PaneState.Text = '(never set)'
            $ui.PaneStateDot.Background = '(never set)'
            $script:pulse = $null

            Invoke-Expression $regionA

            $rows += [ordered]@{
                name = "$($a.n)"; paneName = "$($ui.PaneName.Text)"
                dot = "$($ui.PaneStateDot.Background)"; state = "$($ui.PaneState.Text)"
                pulse = [bool]$script:pulse
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 4)

        """);

        return sb.ToString();
    }
}
