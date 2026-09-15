using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Console;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// The menu probe - the second of the two things blocking an implementation
/// that can act.
/// </summary>
/// <remarks>
/// 🔴 THE SEND BOX HAS BEEN PASSING <c>onAMenu: false</c>, which was honest
/// while nothing in the rebuild could type and is a hazard the moment something
/// can: a session sitting on a menu reads keystrokes as MENU INPUT, so a
/// sentence typed at it picks an option instead of queueing behind the turn.
///
/// 🔑 TWO CASES, AND THE FIRST IS THE ONE THAT PROVES ANYTHING. Fourteen
/// CAPTURED screens are a substituted data source in the sense this plan keeps
/// insisting on: every branch is reachable, they do not move, and they include
/// the screens the shipped parser was actually wrong about - a numbered list in
/// scrollback ABOVE a live menu, and the same with the highlight arrowed onto
/// one of the scrollback rows. The live case then says the agreement holds on
/// the real thing, over whatever the operator happens to be running.
/// </remarks>
public static class MenuCases
{
    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Fixtures(), true, "the same menu verdict on all fourteen captured screens, line for line");
        yield return (Live(), true, "the same menu verdict on every live console that held still");
        yield return (Shapes(), true, "the same verdict on twenty screens written to reach every rule");
    }

    /// <summary>
    /// Every captured screen, and for each one every question the probe can be
    /// asked.
    /// </summary>
    /// <remarks>
    /// 🪤 IT REPORTS THE PROMPT LINES BY INDEX, NOT JUST A COUNT. The prompt
    /// test is what DISQUALIFIES a run, so a port that found the right number of
    /// status lines in the wrong places would reach the same verdict on these
    /// screens by luck and a different one on the next screen captured. The
    /// indexes make the disagreement land where it happened.
    ///
    /// 🔴 AND THE START LINE, NOT ONLY THE BOOLEAN. <c>IsOn</c> is
    /// <c>Start &gt;= 0</c>, so a case that compared only the boolean would
    /// forgive a parser that found a menu in the wrong place - which is
    /// precisely the welding defect the shipped one was fixed for.
    /// </remarks>
    private static OracleCase Fixtures() => new(
        "screen/menu-fixtures",
        "Get-SRLiveMenuStart, Test-SRLiveMenu and Test-SRPromptLine over the fourteen captured screens",
        PsFixtures,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var rows = new JsonArray();
            var dir = Path.Combine(Core.ToolPaths.Root, "tests", "screens");

            foreach (var a in asked)
            {
                // The NAME is the question; the answer is computed here from the
                // same bytes on disk, never read out of the other side's reply.
                var name = a?["name"]?.GetValue<string>() ?? string.Empty;
                var text = File.ReadAllText(Path.Combine(dir, name));
                var lines = text.Split('\n');

                var prompt = new JsonArray();
                for (var i = 0; i < lines.Length; i++)
                {
                    if (LiveMenu.IsPromptLine(lines[i]))
                    {
                        prompt.Add(JsonValue.Create(i));
                    }
                }

                Screens++;
                rows.Add(new JsonObject
                {
                    ["name"] = name,
                    ["lines"] = lines.Length,
                    ["start"] = LiveMenu.Start(text),
                    ["menu"] = LiveMenu.IsOn(text),
                    ["prompt"] = prompt,
                });
            }

            if (Screens == 0)
            {
                rows.Add(new JsonObject
                {
                    ["name"] = "NOTHING WAS COMPARED - tests/screens held no capture, so this run proved nothing",
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        });

    /// <summary>
    /// The same question put to both sides about the operator's own live
    /// sessions.
    /// </summary>
    /// <remarks>
    /// 🔑 THE SCREEN IS READ ONCE, BY THE POWERSHELL, AND HANDED OVER AS THE
    /// QUESTION. That is the difference between this and
    /// <c>console/screens</c>: there the screen IS the answer and each side must
    /// read its own, here the screen is the INPUT and two readers of the same
    /// input must agree. So there is nothing to move between the two sides, and
    /// no allowance is needed or offered - a difference here is real.
    ///
    /// 🔴 WHICH MAKES THE STANDING-STILL GUARD THE OTHER SIDE'S JOB, and it
    /// still matters: a screen caught mid-repaint is a screen neither side
    /// should be held to, so the PowerShell reads twice and skips any that
    /// moved.
    /// </remarks>
    private static OracleCase Live() => new(
        "screen/menu-live",
        "the menu verdict over the operator's own consoles, on the screens that stood still",
        PsLive,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var rows = new JsonArray();

            foreach (var a in asked)
            {
                var text = a?["text"]?.GetValue<string>() ?? string.Empty;
                LiveScreens++;
                if (LiveMenu.IsOn(text))
                {
                    LiveMenus++;
                }

                rows.Add(new JsonObject
                {
                    ["pid"] = a?["pid"]?.GetValue<int>() ?? 0,
                    ["text"] = text,
                    ["start"] = LiveMenu.Start(text),
                    ["menu"] = LiveMenu.IsOn(text),
                });
            }

            // 🔴 A CHECK THAT CANNOT TELL MUST NOT PRINT GREEN. With no live
            // session standing still there is nothing here at all, and an empty
            // agreement is not an agreement.
            if (LiveScreens == 0)
            {
                rows.Add(new JsonObject
                {
                    ["pid"] = 0,
                    ["text"] = "NOTHING WAS COMPARED - no live console held still, so this run proved nothing",
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        });

    /// <summary>How many captured screens were put to both sides.</summary>
    public static int Screens { get; private set; }

    /// <summary>How many live consoles held still long enough to be asked about.</summary>
    public static int LiveScreens { get; private set; }

    /// <summary>How many of those were showing a menu.</summary>
    public static int LiveMenus { get; private set; }

    public static string Coverage() => string.Format(CultureInfo.InvariantCulture,
        "{0} captured screen(s), {1} written shape(s), {2} live console(s) that held still, {3} of them on a menu",
        Screens, Shaped, LiveScreens, LiveMenus);

    /// <summary>
    /// Twenty screens written to reach the rules the captures do not.
    /// </summary>
    /// <remarks>
    /// 🔴 THIS IS THE CASE THAT CAN GO RED, AND THE CAPTURES ARE NOT. Seven
    /// rules were broken one at a time against <c>screen/menu-fixtures</c> and
    /// FOUR OF THE SEVEN STAYED GREEN: a run of one counting as a menu, the
    /// shortcuts status line dropped from the prompt patterns, the option
    /// pattern loosened to three digits and an empty label, and the patterns
    /// losing the case-insensitivity PowerShell's <c>-match</c> gives them. The
    /// fourteen real screens simply never contain those shapes.
    ///
    /// 🪤 WHICH IS THE SAME TRAP AS "A GREEN OVER LIVE DATA", ONE LEVEL UP. A
    /// captured corpus is still a data source, and a corpus is not a spec: it
    /// covers the branches the captures happened to walk. The answer is the one
    /// this plan keeps reaching for - substitute the data source, spell the
    /// shapes identically on both sides, and break each rule again.
    ///
    /// 🔑 EACH SIDE SPELLS ITS OWN COPY OF EVERY SCREEN. Handing the text over
    /// would make this a test of one parser run twice; two independent copies
    /// keyed by name mean a difference in the TEXT shows up as loudly as a
    /// difference in the verdict.
    /// </remarks>
    private static OracleCase Shapes() => new(
        "screen/menu-shapes",
        "every rule in the menu probe, on screens written to reach it",
        PsShapes,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var rows = new JsonArray();

            foreach (var a in asked)
            {
                var k = a?["k"]?.GetValue<string>() ?? string.Empty;
                var shape = Written.FirstOrDefault(x => string.Equals(x.K, k, StringComparison.Ordinal));
                if (shape.K is null)
                {
                    rows.Add(new JsonObject { ["k"] = k, ["start"] = -99, ["menu"] = false });
                    continue;
                }

                var text = string.Join("\n", shape.Lines);
                Shaped++;
                rows.Add(new JsonObject
                {
                    ["k"] = k,
                    ["start"] = LiveMenu.Start(text),
                    ["menu"] = LiveMenu.IsOn(text),
                });
            }

            if (Shaped == 0)
            {
                rows.Add(new JsonObject { ["k"] = "NOTHING WAS COMPARED - no shape reached this side" });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        });

    private const char Cur = '\u276F';

    /// <summary>
    /// The C# half of the twenty screens. The PowerShell spells its own.
    /// </summary>
    private static readonly (string K, string[] Lines)[] Written =
    [
        ("empty", []),
        ("run-of-one", ["some prose", "1. only one", "more prose"]),
        ("run-of-two", ["some prose", "  1. alpha", "  2. bravo"]),
        ("shortcuts-kills", ["1. alpha", "2. bravo", "? for shortcuts"]),
        ("model-lower-kills", ["1. alpha", "2. bravo", "model: opus 5"]),
        ("cycle-upper-kills", ["1. alpha", "2. bravo", "  SHIFT+TAB TO CYCLE  "]),
        ("cycle-midline-kills", ["1. alpha", "2. bravo", "press shift+tab to cycle modes"]),
        ("model-midline-keeps", ["1. alpha", "2. bravo", "the model: is named here"]),
        ("prompt-above-keeps", ["Model: Opus 5", "1. alpha", "2. bravo"]),
        ("three-digits", ["100. alpha", "101. bravo"]),
        ("bare-number", ["1.", "2."]),
        ("no-space", ["1.alpha", "2.bravo"]),
        ("empty-label", ["1.   ", "2.   "]),
        ("from-zero", ["0. zero", "1. alpha", "2. bravo"]),
        ("out-of-order", ["1. alpha", "7. wandered off", "2. bravo"]),
        ("ten-options", ["1. a", "2. b", "3. c", "4. d", "5. e", "6. f", "7. g", "8. h", "9. i", "10. j"]),
        ("cursor-first", [Cur + " 1. alpha", "  2. bravo"]),
        ("last-run-wins", ["1. s one", "2. s two", "3. s three", "", Cur + " 1. real one", "  2. real two"]),
        ("carriage-returns", ["1. alpha\r", "2. bravo\r"]),
        ("never-started-at-one", ["9. nine", "10. ten"]),
    ];

    /// <summary>How many written shapes were put to both sides.</summary>
    public static int Shaped { get; private set; }

    private const string PsShapes = """
        $c = [string][char]0x276F
        $shapes = @(
            @{ k='empty';                ln=@() }
            @{ k='run-of-one';           ln=@('some prose', '1. only one', 'more prose') }
            @{ k='run-of-two';           ln=@('some prose', '  1. alpha', '  2. bravo') }
            @{ k='shortcuts-kills';      ln=@('1. alpha', '2. bravo', '? for shortcuts') }
            @{ k='model-lower-kills';    ln=@('1. alpha', '2. bravo', 'model: opus 5') }
            @{ k='cycle-upper-kills';    ln=@('1. alpha', '2. bravo', '  SHIFT+TAB TO CYCLE  ') }
            @{ k='cycle-midline-kills';  ln=@('1. alpha', '2. bravo', 'press shift+tab to cycle modes') }
            @{ k='model-midline-keeps';  ln=@('1. alpha', '2. bravo', 'the model: is named here') }
            @{ k='prompt-above-keeps';   ln=@('Model: Opus 5', '1. alpha', '2. bravo') }
            @{ k='three-digits';         ln=@('100. alpha', '101. bravo') }
            @{ k='bare-number';          ln=@('1.', '2.') }
            @{ k='no-space';             ln=@('1.alpha', '2.bravo') }
            @{ k='empty-label';          ln=@('1.   ', '2.   ') }
            @{ k='from-zero';            ln=@('0. zero', '1. alpha', '2. bravo') }
            @{ k='out-of-order';         ln=@('1. alpha', '7. wandered off', '2. bravo') }
            @{ k='ten-options';          ln=@('1. a','2. b','3. c','4. d','5. e','6. f','7. g','8. h','9. i','10. j') }
            @{ k='cursor-first';         ln=@(($c + ' 1. alpha'), '  2. bravo') }
            @{ k='last-run-wins';        ln=@('1. s one', '2. s two', '3. s three', '', ($c + ' 1. real one'), '  2. real two') }
            @{ k='carriage-returns';     ln=@("1. alpha`r", "2. bravo`r") }
            @{ k='never-started-at-one'; ln=@('9. nine', '10. ten') }
        )
        $rows = @()
        foreach ($sh in $shapes) {
            $txt = (@($sh.ln) -join "`n")
            $rows += [ordered]@{
                k     = $sh.k
                start = (Get-SRLiveMenuStart -Text $txt)
                menu  = [bool](Test-SRLiveMenu -Text $txt)
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 5)
        """;

    private const string PsFixtures = """
        $dir = Join-Path $SR_Root 'tests\screens'
        $rows = @()
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter *.txt | Sort-Object Name)) {
            # Read as one string exactly as a screen read hands it over, with the
            # line endings the capture actually has.
            $txt = [System.IO.File]::ReadAllText($f.FullName)
            $ls = @($txt -split "`n")
            $prompt = @()
            for ($i = 0; $i -lt $ls.Count; $i++) {
                if (Test-SRPromptLine $ls[$i]) { $prompt += $i }
            }
            $rows += [ordered]@{
                name   = $f.Name
                lines  = $ls.Count
                start  = (Get-SRLiveMenuStart -Text $txt)
                menu   = [bool](Test-SRLiveMenu -Text $txt)
                prompt = @($prompt)
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 5)
        """;

    private const string PsLive = """
        $procs = @(Get-Process -Name claude -ErrorAction SilentlyContinue |
            Where-Object { "$($_.Path)" -notlike '*\WindowsApps\*' } |
            Select-Object -First 30)
        $rows = @()
        foreach ($p in $procs) {
            $a = $null
            $b = $null
            try { $a = Get-SRScreenText -ProcessId $p.Id } catch { }
            Start-Sleep -Milliseconds 250
            try { $b = Get-SRScreenText -ProcessId $p.Id } catch { }
            # Nothing to ask about a screen that could not be read, and nothing
            # to hold either side to on one that moved between the two reads.
            if ($null -eq $b -or $a -ne $b) { continue }
            $rows += [ordered]@{
                pid   = $p.Id
                text  = "$b"
                start = (Get-SRLiveMenuStart -Text "$b")
                menu  = [bool](Test-SRLiveMenu -Text "$b")
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 5)
        """;
}
