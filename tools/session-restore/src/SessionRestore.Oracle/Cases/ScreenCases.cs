using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Console;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 2.4a - reading a live session's console.
/// </summary>
/// <remarks>
/// 🔴 READ-ONLY, AND THE CODE THAT COULD DO OTHERWISE DOES NOT EXIST YET.
/// <c>WriteConsoleInputW</c> - the call that types into a live conversation - is
/// absent from the C# entirely at this point. These comparisons attach to the
/// operator's real sessions and read their screens, which is what the shipped
/// tool already does several times a second.
///
/// 🔑 A LIVE SCREEN MOVES, and that is the hard part of comparing two readers of
/// one. Both sides read TWICE and only screens that did not change between
/// their own two reads are compared - so a busy session is reported as moving
/// rather than as a difference. A harness that called a working reader wrong
/// every time a session was thinking would be switched off within a day.
/// </remarks>
public static class ScreenCases
{
    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Screens(), true, "the same screen, character for character, on every session standing still");
    }

    private static OracleCase Screens() => new(
        "console/screens",
        "every live session's visible screen, read by both and compared where it stood still",
        """
        # Two reads a moment apart. A screen that changed between them was
        # moving, and neither side can be held to it.
        #
        # 🪤 NOT THE DESKTOP APP. `-Name claude` also matches the Claude desktop
        # app's own processes, which have no console - eleven of fourteen on
        # 2026-09-13, filling the sample with things that are not sessions.
        $procs = @(Get-Process -Name claude -ErrorAction SilentlyContinue |
            Where-Object { "$($_.Path)" -notlike '*\WindowsApps\*' } |
            Select-Object -First 30)
        # 🔴 AND ONE PROCESS THAT HAS NO CONSOLE AT ALL, on purpose. "Could not
        # read" is a path live data reaches only by accident - the desktop app
        # reached it on 2026-09-13 and nothing had before - so breaking either
        # side's handling of it stayed green. Explorer never has a console; the
        # attach fails inside the disposable helper and touches nothing else.
        $procs += @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Select-Object -First 1)
        $rows = @()
        foreach ($p in $procs) {
            $a = ''
            $b = ''
            try { $a = Get-SRScreenText -ProcessId $p.Id } catch { $a = '!threw' }
            # A full second. A screen that held still that long is idle, and an
            # idle session is still idle two seconds later when the other side
            # looks; 220 ms was not a long enough gap to mean anything.
            Start-Sleep -Milliseconds 1000
            try { $b = Get-SRScreenText -ProcessId $p.Id } catch { $b = '!threw' }
            # 🔴 $null IS "COULD NOT READ", and it is said in words. The C#
            # reader says the same thing as "!reason"; comparing the raw values
            # made a console-less process read as "" against "!attach 6" - two
            # readers agreeing, reported as a difference.
            $unreadable = ($null -eq $a -and $null -eq $b)
            $stable = ($a -eq $b)
            $rows += [ordered]@{
                pid    = $p.Id
                stable = $stable
                lines  = $(if ($unreadable) { 0 } elseif ($stable) { @("$b" -split "`n").Count } else { -1 })
                text   = $(if ($unreadable) { '(unreadable)' } elseif ($stable) { "$b" } else { '(moving)' })
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 5)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var rows = new JsonArray();

            foreach (var a in asked)
            {
                var pid = (uint)(a?["pid"]?.GetValue<int>() ?? 0);
                var psStable = a?["stable"]?.GetValue<bool>() ?? false;

                if (!psStable)
                {
                    // The other side already said this one was moving. Agreeing
                    // that it moved is the only honest answer available.
                    rows.Add(new JsonObject { ["pid"] = (int)pid, ["stable"] = false, ["lines"] = -1, ["text"] = "(moving)" });
                    continue;
                }

                var (text, stable) = ScreenReader.ReadStable(pid);

                // The reader's own "could not read", in the words both sides use.
                if (stable && text.StartsWith('!'))
                {
                    rows.Add(new JsonObject { ["pid"] = (int)pid, ["stable"] = true, ["lines"] = 0, ["text"] = "(unreadable)" });
                    continue;
                }

                // 🔴 THIS SIDE NEVER ECHOES THE OTHER SIDE'S ANSWER. A first
                // version handled "still for them, moving for us" by copying
                // their text back, which turns a limitation into a pass - the
                // one thing the oracle's contract forbids outright. A screen
                // that will not hold still for this side says so, in its own
                // words, and the difference gets reported like any other.
                rows.Add(new JsonObject
                {
                    ["pid"] = (int)pid,
                    ["stable"] = true,
                    ["lines"] = stable ? text.Split('\n').Length : -2,
                    ["text"] = stable ? text : "(moved between the two sides)",
                });

                if (stable)
                {
                    Compared++;
                }
                else
                {
                    Moved++;
                }
            }

            // 🔴 A CHECK THAT CANNOT TELL MUST NOT PRINT GREEN. If every session
            // happened to be working, this would compare nothing at all and pass
            // - reporting agreement it never established. That is the
            // abstaining-gate defect this repo already has a note about, so it
            // is made loud rather than left to whoever reads the log.
            if (Compared == 0)
            {
                rows.Add(new JsonObject
                {
                    ["pid"] = 0,
                    ["stable"] = true,
                    ["lines"] = -3,
                    ["text"] = "NOTHING WAS COMPARED - every session was moving, so this run proved nothing",
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString(Compact);
        })
    {
        // 🔴 THE ONE DIFFERENCE THIS CASE IS ALLOWED, AND ONLY THIS SHAPE. A
        // session that was idle when the PowerShell looked and working when the
        // C# looked produces a row this side marked as moved - and that is a
        // fact about the session, not about either reader. Any OTHER difference,
        // including one character in one line of one screen, still fails.
        // Exactly the two shapes a moved row makes and nothing else: the line
        // count coming back as the -2 sentinel, and the text coming back as the
        // marker. A difference in any other field, or any other value, fails.
        Tolerate = d => d.EndsWith("C# \"-2\"", StringComparison.Ordinal)
                     || d.EndsWith("C# \"(moved between the two sides)\"", StringComparison.Ordinal),
        ToleranceReason =
            "a session that was idle for the PowerShell's two reads and busy for the C#'s - "
            + "a moving screen, not a differing reader",
    };

    /// <summary>How many screens were actually held to a comparison.</summary>
    public static int Compared { get; private set; }

    /// <summary>How many were still for one side and not for the other.</summary>
    public static int Moved { get; private set; }

    /// <summary>What the run was actually able to check.</summary>
    public static string Coverage() => string.Format(CultureInfo.InvariantCulture,
        "{0} screen(s) compared character for character, {1} moved between the two sides", Compared, Moved);
}
