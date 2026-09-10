using System.Globalization;
using System.Text.Json.Nodes;
using SessionRestore.Core;
using SessionRestore.Core.Launch;
using SessionRestore.Core.Registry;
using SessionRestore.Core.Sessions;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 2.5c - launching and ending, compared as PLANS.
/// </summary>
/// <remarks>
/// 🔴 NOT ONE OF THESE CASES LAUNCHES, ENDS OR TYPES INTO ANYTHING. The operator
/// runs sessions he cannot relaunch, so the launch path is the one place where
/// "prove it by doing it" is never available - and the whole reason both sides
/// are shaped as values is so it never has to be. Every case here asks what a
/// gesture WOULD do and diffs the answer.
///
/// 🔑 TWO OF THEM RUN THE WINDOW'S OWN SOURCE. <c>Get-LaunchBlock</c> and
/// <c>Get-TickedPlan</c> live in lib\sessions-window.ps1, which the oracle must
/// not load - building the window would create timers, read the config and paint
/// against live data. So their source is spliced out by name and defined in the
/// oracle's session: the shipped body, run over the real registry, without the
/// window around it. 🪤 If the splice ever fails the function is simply not
/// defined and the case reports "could not run" - a third state, never a pass.
/// </remarks>
public static class LaunchCases
{
    /// <summary>How many boot scripts the byte-for-byte comparison covers.</summary>
    public static int BootShapes { get; private set; }

    /// <summary>How many conversations the plan cases walked.</summary>
    public static int Rows { get; private set; }

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Quoting(), true, "argument quoting over every real project path");
        yield return (Terminal(), true, "where wt.exe is");
        yield return (WtCommandLine(), true, "the command line a launch would hand wt.exe");
        yield return (TranscriptPaths(), true, "the transcript each conversation would resume");
        yield return (Settings(), true, "every conversation's own launch flags");
        yield return (SettingShapes(), true, "every control-plane setting, including the ones nothing on this machine uses");
        yield return (BootScripts(), true, "the boot script, byte for byte");
        yield return (Processes(), true, "who is running and who started them");
        yield return (Blocked(), true, "why each ticked conversation would or would not open");
        yield return (Ticked(), true, "the whole ticked set, bucketed");
    }

    public static string Coverage() =>
        Rows.ToString(CultureInfo.InvariantCulture) + " conversations planned over, "
        + BootShapes.ToString(CultureInfo.InvariantCulture) + " boot scripts compared byte for byte";

    // ---------------------------------------------------------------------
    // The quoting, which is where the damage was.
    // ---------------------------------------------------------------------

    /// <summary>
    /// 🔴 THIS IS THE DEFECT THAT KILLED EVERY AlgoTrader TAB. Measured
    /// 2026-08-18: a directory under "Trading Bot" reached wt.exe split at the
    /// space, so it took the fragment as the command to run and the tab died with
    /// 0x80070002 while space-free repos launched fine. The torture inputs below
    /// are the CommandLineToArgvW corners - a trailing backslash run, a backslash
    /// before a quote, an embedded quote - and they are checked alongside every
    /// real project path on this machine, because the real ones are what actually
    /// get launched.
    /// </summary>
    private static OracleCase Quoting() => new(
        "launch/quote",
        "one argument, quoted so the receiver's argv splits where we meant",
        """
        $inputs = @(
            'C:\Users\mauri\Documents\MM-toolbox',
            'C:\Users\mauri\Documents\Trading Bot\Python\AlgoTrader',
            'plain', '', ' ', 'two words',
            'ends\', 'ends\\', 'ends\\\',
            'a"quote', 'back\"slashquote', 'C:\a b\c\', 'semi;colon',
            "tick`tand`nnewline", 'dollar$sign', 'brace{}bracket[]',
            'unicode-e' + [char]0x00E9 + '-ok'
        )
        $reg = Get-SRRegistry
        foreach ($d in @($reg.directories)) {
            $inputs += "$($d.path)"
            foreach ($s in @($d.sessions)) {
                if ("$($s.cwd)") { $inputs += "$($s.cwd)" }
                if ("$($s.title)") { $inputs += "$($s.title)" }
            }
        }
        $rows = @()
        foreach ($i in $inputs) { $rows += [ordered]@{ raw = "$i"; q = (ConvertTo-SRArg "$i") } }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 4)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var rows = new JsonArray();
            foreach (var a in asked)
            {
                // The raw value is the QUESTION. The quoting is the answer, and
                // this side computes its own.
                var raw = a?["raw"]?.GetValue<string>() ?? string.Empty;
                rows.Add(new JsonObject { ["raw"] = raw, ["q"] = CommandLine.Quote(raw) });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString();
        });

    private static OracleCase Terminal() => new(
        "launch/terminal",
        "where wt.exe is - a PATH lookup alone has failed here before",
        "(@{ wt = \"$(Resolve-SRWindowsTerminal)\" } | ConvertTo-Json -Compress)",
        () => new JsonObject { ["wt"] = WindowsTerminal.Resolve() ?? string.Empty }.ToJsonString());

    /// <summary>
    /// The whole command line, over real project paths. 🔑 This is only
    /// comparable because <c>Start-SRSession</c> was split: the string is built by
    /// <c>Get-SRLaunchCommandLine</c> and only <c>Start-SRSession</c> hands it to
    /// a process, so what a launch WOULD send can be asked for without launching.
    /// </summary>
    private static OracleCase WtCommandLine() => new(
        "launch/command-line",
        "what wt.exe would be given, including the semicolon refusal",
        """
        $reg = Get-SRRegistry
        $dirs = @()
        foreach ($d in @($reg.directories)) { $dirs += "$($d.path)" }
        $dirs += @('C:\Users\mauri\Documents\Trading Bot\Python\AlgoTrader', 'C:\a b\c\', 'C:\semi;colon\x')
        $rows = @()
        foreach ($p in $dirs) {
            $boot = Join-Path $SR_StateDir 'boot-sample-00000000.ps1'
            $title = 'a title; with a semicolon and a ''quote'''
            $line = $null; $err = $null
            try { $line = Get-SRLaunchCommandLine -Dir "$p" -BootScript $boot -Title $title }
            catch { $err = "$($_.Exception.Message)" }
            $rows += [ordered]@{ dir = "$p"; line = "$line"; err = "$err" }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 4)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var boot = Path.Combine(ToolPaths.State, "boot-sample-00000000.ps1");
            const string Title = "a title; with a semicolon and a 'quote'";
            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var dir = a?["dir"]?.GetValue<string>() ?? string.Empty;
                string line = string.Empty, err = string.Empty;
                try
                {
                    line = CommandLine.ForNewTab(dir, boot, Title);
                }
                catch (ArgumentException ex)
                {
                    err = ex.Message;
                }

                rows.Add(new JsonObject { ["dir"] = dir, ["line"] = line, ["err"] = err });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString();
        });

    // ---------------------------------------------------------------------
    // What a launch would resume, and with which flags.
    // ---------------------------------------------------------------------

    private static OracleCase TranscriptPaths() => new(
        "launch/transcript-path",
        "the transcript each conversation would resume, over every session in the registry",
        """
        $reg = Get-SRRegistry
        $rows = @()
        foreach ($d in @($reg.directories)) {
            foreach ($s in @($d.sessions)) {
                $cwd = $(if ("$($s.cwd)") { "$($s.cwd)" } else { "$($d.path)" })
                $p = $null
                try { $p = Get-SRTranscriptPath -Dir $cwd -SessionId "$($s.sessionId)" -Recorded "$($s.jsonl)" } catch { }
                $rows += [ordered]@{
                    id = "$($s.sessionId)"; dir = $cwd
                    path = "$p"; there = [bool](Test-Path -LiteralPath "$p")
                }
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 4)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var byId = SessionsById();
            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var id = a?["id"]?.GetValue<string>() ?? string.Empty;
                var dir = a?["dir"]?.GetValue<string>() ?? string.Empty;
                byId.TryGetValue(id, out var s);
                var p = TranscriptPath.For(dir, id, s?.Jsonl);
                rows.Add(new JsonObject
                {
                    ["id"] = id,
                    ["dir"] = dir,
                    ["path"] = p,
                    ["there"] = TranscriptPath.Exists(p),
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString();
        })
    {
        // 🪤 A TRANSCRIPT CAN APPEAR OR VANISH BETWEEN THE TWO READS - the
        // operator is working while this runs, and a fresh conversation writes
        // its first record mid-comparison. The PATH is the answer under test and
        // is never forgiven; only `there` may differ, and only for one row.
        Tolerate = d => Differences(d).All(x => x.Contains(".there", StringComparison.Ordinal)),
        ToleranceReason = "a transcript appeared or vanished between the two reads; the PATHS still agreed",
    };

    private static OracleCase Settings() => new(
        "launch/settings",
        "each conversation's own launch flags, its label, and whether it wants remote control",
        """
        $reg = Get-SRRegistry
        $rows = @()
        foreach ($d in @($reg.directories)) {
            foreach ($s in @($d.sessions)) {
                # ASSIGN FIRST, WRAP SECOND.
                $fl = Get-SRSessionArgs $s
                $fl = @($fl)
                $rows += [ordered]@{
                    id     = "$($s.sessionId)"
                    args   = ($fl -join [char]1)
                    n      = [int]$fl.Count
                    label  = "$(Get-SRSessionArgsLabel $s)"
                    remote = [bool](Test-SRRemoteWanted $s)
                    hidden = [bool](Test-SRHiddenWanted $s)
                }
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 4)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var byId = SessionsById();
            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var id = a?["id"]?.GetValue<string>() ?? string.Empty;
                byId.TryGetValue(id, out var s);
                var fl = SessionArgs.For(s);
                rows.Add(new JsonObject
                {
                    ["id"] = id,
                    ["args"] = string.Join('\u0001', fl),
                    ["n"] = fl.Length,
                    ["label"] = SessionArgs.Label(s),
                    ["remote"] = SessionArgs.RemoteWanted(s),
                    ["hidden"] = SessionArgs.HiddenWanted(s),
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString();
        });


    /// <summary>
    /// The control plane, over shapes the registry does not contain.
    /// </summary>
    /// <remarks>
    /// 🔴 WRITTEN IS NOT WORKING. The case above walks all 560 conversations and
    /// every one of them agreed - and then a deliberate break to the --model
    /// branch did not turn it red, because **not one session on this machine has
    /// a `prefs` object at all**. A comparison over live data proves only the
    /// paths live data reaches, and here that was exactly one: the default.
    ///
    /// 🔑 So the DATA SOURCE is substituted rather than the check weakened. The
    /// shapes below are the question, spelled the same way on both sides, and
    /// they cover each branch the operator can reach through the settings sheet
    /// but has not yet used. [[feedback-written-is-not-working]]
    /// </remarks>
    private static OracleCase SettingShapes() => new(
        "launch/settings-shapes",
        "a conversation's flags for every setting the sheet can produce",
        // 🪤 ONE COMPACT SINGLE-QUOTED LINE, NOT A HERE-STRING. PowerShell needs a
        // here-string's closing '@ in COLUMN 1, and a C# raw string literal
        // indents every line it holds - so the here-string never closed, the
        // shell sat waiting for more input, and the case came back only when the
        // read deadline fired 300 seconds later. The shapes carry no single
        // quote, so a quoted literal is exact and cannot run away.
        "$shapes = '" + System.Text.Json.Nodes.JsonNode.Parse(ShapesJson)!.ToJsonString() + "' | ConvertFrom-Json\n" + """
        $rows = @()
        foreach ($sh in @($shapes)) {
            $s = [PSCustomObject]@{ sessionId = "$($sh.k)"; prefs = $sh.prefs }
            $fl = Get-SRSessionArgs $s
            $fl = @($fl)
            $rows += [ordered]@{
                k      = "$($sh.k)"
                args   = ($fl -join [char]1)
                n      = [int]$fl.Count
                label  = "$(Get-SRSessionArgsLabel $s)"
                remote = [bool](Test-SRRemoteWanted $s)
                hidden = [bool](Test-SRHiddenWanted $s)
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 6)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var shapes = JsonNode.Parse(ShapesJson)?.AsArray() ?? [];
            var byKey = new Dictionary<string, JsonNode?>(StringComparer.Ordinal);
            foreach (var sh in shapes)
            {
                byKey[sh?["k"]?.GetValue<string>() ?? string.Empty] = sh?["prefs"];
            }

            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var k = a?["k"]?.GetValue<string>() ?? string.Empty;
                var s = new RegistrySession { SessionId = k };
                if (byKey.TryGetValue(k, out var prefs) && prefs is not null)
                {
                    s.Extra = new Dictionary<string, System.Text.Json.JsonElement>(StringComparer.Ordinal)
                    {
                        ["prefs"] = System.Text.Json.JsonDocument.Parse(prefs.ToJsonString()).RootElement.Clone(),
                    };
                }

                var fl = SessionArgs.For(s);
                rows.Add(new JsonObject
                {
                    ["k"] = k,
                    ["args"] = string.Join('\u0001', fl),
                    ["n"] = fl.Length,
                    ["label"] = SessionArgs.Label(s),
                    ["remote"] = SessionArgs.RemoteWanted(s),
                    ["hidden"] = SessionArgs.HiddenWanted(s),
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString();
        });

    /// <summary>The shapes, spelled once and read by both sides.</summary>
    private const string ShapesJson = """
        [
          { "k": "none",            "prefs": null },
          { "k": "empty",           "prefs": {} },
          { "k": "model",           "prefs": { "model": "claude-opus-5" } },
          { "k": "model-spaced",    "prefs": { "model": "  claude-sonnet-5  " } },
          { "k": "effort-ok",       "prefs": { "effort": "xhigh" } },
          { "k": "effort-bad",      "prefs": { "effort": "ludicrous" } },
          { "k": "effort-case",     "prefs": { "effort": "High" } },
          { "k": "perm-ok",         "prefs": { "permissionMode": "bypassPermissions" } },
          { "k": "perm-bad",        "prefs": { "permissionMode": "whatever" } },
          { "k": "perm-case",       "prefs": { "permissionMode": "AcceptEdits" } },
          { "k": "tools-array",     "prefs": { "allowedTools": ["Bash", "Read"] } },
          { "k": "tools-one",       "prefs": { "allowedTools": "Bash" } },
          { "k": "tools-blank",     "prefs": { "allowedTools": ["Bash", "", "  "] } },
          { "k": "tools-dis",       "prefs": { "disallowedTools": ["Write"] } },
          { "k": "tools-both",      "prefs": { "allowedTools": ["Bash"], "disallowedTools": ["Write", "Edit"] } },
          { "k": "no-remote",       "prefs": { "remoteControl": false } },
          { "k": "yes-remote",      "prefs": { "remoteControl": true } },
          { "k": "hidden",          "prefs": { "hidden": true } },
          { "k": "not-hidden",      "prefs": { "hidden": false } },
          { "k": "everything",      "prefs": { "model": "claude-opus-5", "effort": "max", "permissionMode": "plan",
                                               "allowedTools": ["Bash"], "disallowedTools": ["Write"],
                                               "remoteControl": false, "hidden": true } },
          { "k": "unknown-key",     "prefs": { "somethingNew": "ignored" } },
          { "k": "null-model",      "prefs": { "model": null } }
        ]
        """;

    /// <summary>
    /// The boot script, byte for byte.
    /// </summary>
    /// <remarks>
    /// 🔴 SYNTHETIC SESSION IDS AND UNMISTAKABLE FOLDER NAMES, ON PURPOSE. The
    /// boot path is deterministic - <c>boot-&lt;slug&gt;-&lt;first 8 of the
    /// id&gt;.ps1</c> - so a shape borrowed from a real conversation would
    /// overwrite the boot script that conversation is restored with. Ids of all
    /// zeroes and ones cannot collide with a real one, the leaf names say whose
    /// they are, and every file written is deleted in a finally.
    ///
    /// 🪤 THE POWERSHELL SIDE WRITES; THIS SIDE DOES NOT. New-SRBootScript's whole
    /// job is to leave a file behind, so the comparison reads back what it wrote -
    /// and the C# answers with the bytes it WOULD have written, from a class that
    /// has no writer at all.
    /// </remarks>
    private static OracleCase BootScripts() => new(
        "launch/boot-script",
        "the script a conversation is opened with, as bytes",
        """
        $shapes = @(
            @{ k='resume';    dir='C:\sr-oracle-plain';            id='00000000-1111-2222-3333-444444444444'; title='plain'; args=@(); rc=$true },
            @{ k='no-remote'; dir='C:\sr-oracle-plain';            id='11111111-2222-3333-4444-555555555555'; title='no remote'; args=@(); rc=$false },
            @{ k='flags';     dir='C:\sr-oracle with a space';     id='22222222-3333-4444-5555-666666666666'; title='flags'; args=@('--model','claude-opus-5','--effort','high'); rc=$true },
            @{ k='nasty';     dir="C:\sr-oracle-o'brien";          id='33333333-4444-5555-6666-777777777777'; title="it's a `$title with a ``tick"; args=@(); rc=$true }
        )
        $rows = @()
        $made = @()
        try {
            foreach ($sh in $shapes) {
                $p = New-SRBootScript -Dir $sh.dir -SessionId $sh.id -Title $sh.title -ClaudeArgs ([string[]]@($sh.args)) -RemoteControl ([bool]$sh.rc)
                $made += $p
                $bytes = [System.IO.File]::ReadAllBytes($p)
                $rows += [ordered]@{
                    k = "$($sh.k)"; path = "$p"; len = [int]$bytes.Length
                    sha = (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
                }
            }
        } finally {
            foreach ($m in $made) { try { Remove-Item -LiteralPath $m -Force -ErrorAction Stop } catch { } }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 4)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var shapes = new (string K, string Dir, string Id, string Title, string[] Args, bool Rc)[]
            {
                ("resume", @"C:\sr-oracle-plain", "00000000-1111-2222-3333-444444444444", "plain", [], true),
                ("no-remote", @"C:\sr-oracle-plain", "11111111-2222-3333-4444-555555555555", "no remote", [], false),
                ("flags", @"C:\sr-oracle with a space", "22222222-3333-4444-5555-666666666666", "flags",
                    ["--model", "claude-opus-5", "--effort", "high"], true),
                ("nasty", @"C:\sr-oracle-o'brien", "33333333-4444-5555-6666-777777777777",
                    "it's a $title with a `tick", [], true),
            };

            BootShapes = shapes.Length;
            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var k = a?["k"]?.GetValue<string>() ?? string.Empty;
                var sh = shapes.FirstOrDefault(x => string.Equals(x.K, k, StringComparison.Ordinal));
                if (sh.K is null)
                {
                    rows.Add(new JsonObject { ["k"] = k, ["path"] = "(no such shape on this side)" });
                    continue;
                }

                var bytes = BootScript.FileBytes(sh.Dir, sh.Id, sh.Title, sh.Args, sh.Rc);
                rows.Add(new JsonObject
                {
                    ["k"] = k,
                    ["path"] = BootScript.PathFor(sh.Dir, sh.Id),
                    ["len"] = bytes.Length,
                    ["sha"] = Convert.ToHexString(bytes).ToLowerInvariant(),
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString();
        });

    // ---------------------------------------------------------------------
    // The end plan's only input that is not the registry.
    // ---------------------------------------------------------------------

    /// <summary>
    /// 🔑 THE READER IS COMPARED, AND THE DECISION IS UNIT-TESTED ON TOP OF IT.
    /// The end plan turns on three facts about a live process - its name, its
    /// parent, and whether that parent's command line names a boot script - and
    /// those are the only part a running machine can settle. Comparing them
    /// against WMI over every claude and every powershell on the box is a real
    /// oracle; the decision they feed is a pure function and is proved in
    /// LaunchTests, which can go red without anything being running at all.
    /// </summary>
    private static OracleCase Processes() => new(
        "launch/processes",
        "every claude and every boot shell: name, parent, and whether the parent is one of ours",
        """
        $rows = @()
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='claude.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
            $rows += [ordered]@{
                pid    = [int]$p.ProcessId
                name   = "$($p.Name)"
                parent = [int]$p.ParentProcessId
                boot   = [bool]("$($p.CommandLine)" -like '*.state*boot-*')
            }
        }
        (@{ rows = ($rows | Sort-Object { $_.pid }) } | ConvertTo-Json -Compress -Depth 4)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var snap = ProcessTree.All();
            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var pid = (uint)(a?["pid"]?.GetValue<int>() ?? 0);
                var p = ProcessTree.Of(pid, snap);
                if (p is null)
                {
                    // 🔴 THE MARKER GOES IN EVERY FIELD, NOT JUST THE FIRST. A
                    // row that is only PARTLY marked reports its other fields as
                    // "present in PowerShell, missing in C#", and those lines
                    // carry nothing an allowance can match on - so the case goes
                    // red for a process that merely ended. Same lesson the block
                    // cases learned: emit one marker per row the other side
                    // emitted.
                    rows.Add(new JsonObject
                    {
                        ["pid"] = (int)pid,
                        ["name"] = "(ended)",
                        ["parent"] = "(ended)",
                        ["boot"] = "(ended)",
                    });
                    continue;
                }

                var cl = ProcessTree.CommandLineOf(pid);
                rows.Add(new JsonObject
                {
                    ["pid"] = (int)pid,
                    ["name"] = p.Name,
                    ["parent"] = (int)p.ParentPid,
                    // 🔑 THREE STATES, NOT TWO. "could not read" is not "not a
                    // boot shell" - a gate that cannot tell must not print an
                    // answer - and keeping them apart is what lets the allowance
                    // below forgive an unreadable command line while a genuine
                    // disagreement about a readable one still goes red.
                    ["boot"] = cl is null ? "(could not read)" : (EndPlans.LooksLikeBootShell(cl) ? "true" : "false"),
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString();
        })
    {
        // 🪤 PROCESSES START AND END WHILE THIS RUNS, and this machine runs two
        // dozen conversations plus whatever the operator is doing. A pid that WMI
        // saw and the snapshot did not is a process that ended in between, and it
        // is the only difference forgiven - a name or a parent that disagrees is
        // a defect. `boot` is forgiven for the same reason plus one more, named
        // in ProcessTree: reading a command line needs PROCESS_VM_READ, so an
        // elevated shell answers "could not read" here and WMI answers for it.
        Tolerate = d => Differences(d).All(x =>
            x.Contains("(ended)", StringComparison.Ordinal)
            || x.Contains("(could not read)", StringComparison.Ordinal)),
        ToleranceReason = "a process ended between the two reads, or its command line needed rights the snapshot does not take",
    };

    // ---------------------------------------------------------------------
    // The window's own two functions, run without the window.
    // ---------------------------------------------------------------------

    /// <summary>
    /// The PowerShell preamble every plan case shares: splice the window's
    /// functions in, and build the model they walk.
    /// </summary>
    /// <remarks>
    /// 🔴 THE SPLICE TAKES A FUNCTION'S OWN SOURCE, NEVER A COPY OF IT. A
    /// re-implementation in this file would be a test of what I believe the
    /// window does; this runs what it actually does. The bound is the closing
    /// brace in column 1, which is how every function in that file ends - and if
    /// it ever is not, Invoke-Expression throws and the case reports "could not
    /// run" rather than agreeing with itself.
    ///
    /// 🪤 -Adopt IS NEVER PASSED. It is the switch that makes Get-TickedPlan
    /// WRITE: it copies live names over the recorded ones and sets $script:dirty.
    /// The read-only form is the one a confirmation sheet paints with, and the
    /// only one a comparison may use.
    /// </remarks>
    private const string PlanPreamble = """
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        $want = @('Set-Field', 'Get-LaunchBlock', 'Get-TickedPlan', 'Limit-ToCap')
        # A foreach body shares its caller's scope; a FUNCTION does not, and the
        # first version of this wrapped the Invoke-Expression in one - so every
        # spliced function was defined and discarded on the same line, and the
        # case failed with "Get-LaunchBlock is not recognized".
        foreach ($fn in $want) {
            $a = $winSrc.IndexOf("function $fn")
            if ($a -lt 0) { throw "could not find $fn in sessions-window.ps1" }
            $b = $winSrc.IndexOf("`n}", $a)
            if ($b -lt 0) { throw "could not find the end of $fn" }
            Invoke-Expression $winSrc.Substring($a, $b - $a + 2)
        }
        foreach ($fn in $want) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { throw "$fn did not define" }
        }

        $script:justLaunched = @{}
        $script:dirty = $false
        $script:cfg = [PSCustomObject]@{ maxSessions = 0 }
        $agentMap = Get-SRAgentStatus -Refresh
        $script:model = @()
        $reg = Get-SRRegistry
        foreach ($d in @($reg.directories)) {
            if ($d.missing) { continue }
            foreach ($s in @($d.sessions)) {
                if ($s.gone) { continue }
                $id = "$($s.sessionId)".ToLower()
                $script:model += [PSCustomObject]@{ Id = $id; S = $s; D = $d; A = $agentMap[$id] }
            }
        }
        $agents = @()
        foreach ($r in $script:model) {
            if (-not $r.A) { continue }
            $agents += [ordered]@{
                id = "$($r.Id)"; status = "$($r.A.Status)"; name = "$($r.A.Name)"; agentPid = [int]$r.A.Pid
            }
        }
        """;

    private static OracleCase Blocked() => new(
        "launch/blocked",
        "why each conversation would or would not open - the window's own Get-LaunchBlock",
        PlanPreamble + """

        $rows = @()
        foreach ($r in $script:model) {
            $rows += [ordered]@{ id = "$($r.Id)"; why = "$(Get-LaunchBlock $r)" }
        }
        (@{ rows = $rows; agents = $agents } | ConvertTo-Json -Compress -Depth 5)
        """,
        psOut =>
        {
            var doc = JsonNode.Parse(psOut);
            var asked = doc?["rows"]?.AsArray() ?? [];
            var rows = new JsonArray();
            var model = ModelRows(doc, out var agentsBack);
            foreach (var r in model)
            {
                rows.Add(new JsonObject
                {
                    ["id"] = r.Id,
                    ["why"] = LaunchPlan.Blocked(r) ?? string.Empty,
                });
            }

            Rows = asked.Count;
            return new JsonObject { ["rows"] = rows, ["agents"] = agentsBack }.ToJsonString();
        })
    {
        // Same moving target as the transcript-path case, and narrower: only the
        // "its transcript is missing" verdict can flip, and only for a
        // conversation whose first record landed mid-comparison.
        Tolerate = d => Differences(d).All(x => x.Contains("transcript is missing", StringComparison.Ordinal)),
        ToleranceReason = "a transcript appeared or vanished between the two reads",
    };

    private static OracleCase Ticked() => new(
        "launch/ticked",
        "the whole ticked set bucketed - the window's own Get-TickedPlan, read-only form",
        PlanPreamble + """

        $plan = Get-TickedPlan
        # 🪤 A List, NOT `,(...)`. The leading comma is for a RETURN, where it
        # stops a multi-element array being unrolled; in an ASSIGNMENT it simply
        # wraps - and this emitted one element holding all 26 blocked rows, which
        # read as "1 item in PowerShell, 26 in C#". The ",@()" trap from the other
        # side. [[feedback-array-wrap-trap]]
        $bl = New-Object System.Collections.Generic.List[object]
        foreach ($x in @($plan.Blocked)) { $bl.Add([ordered]@{ id = "$($x.R.Id)"; why = "$($x.Why)" }) }
        # PowerShell 5.1 serialises an EMPTY `return @(pipeline)` as {} rather
        # than [] - measured, and it read as "the two sides disagree about the
        # type of an empty bucket". A [string[]] guarded against unrolling gives
        # [] for none and ["a"] for one, which is what an id list is.
        function Ids { param($Set)
            $l = New-Object System.Collections.Generic.List[string]
            foreach ($x in @($Set)) { if ($null -ne $x) { $l.Add("$($x.Id)") } }
            return ,([string[]]$l.ToArray())
        }
        $capped = Limit-ToCap (@($plan.Fresh)) 0
        (@{
            fresh   = (Ids $plan.Fresh)
            restart = (Ids $plan.Restart)
            busy    = (Ids $plan.Busy)
            freshSet   = @((Ids $plan.Fresh)   | Sort-Object)
            restartSet = @((Ids $plan.Restart) | Sort-Object)
            blocked = $bl.ToArray()
            dirty   = [bool]$script:dirty
            agents  = $agents
        } | ConvertTo-Json -Compress -Depth 6)
        """,
        psOut =>
        {
            var doc = JsonNode.Parse(psOut);
            var adoptions = new List<NameAdoption>();
            var plan = LaunchPlan.Ticked(ModelRows(doc, out var agentsBack), adoptions: adoptions);

            return new JsonObject
            {
                ["fresh"] = Ids(plan.Fresh),
                ["restart"] = Ids(plan.Restart),
                ["busy"] = Ids(plan.Busy),
                // 🔴 THE SETS ARE WHAT MAKES THE ORDERING ALLOWANCE SAFE. Forgiving
                // "$.fresh[7] differs" on its own would forgive a conversation
                // being REPLACED as readily as two being swapped, because one
                // changed member shifts every index after it. Sorted alongside,
                // a membership change lands in freshSet - which nothing forgives.
                ["freshSet"] = Sorted(plan.Fresh),
                ["restartSet"] = Sorted(plan.Restart),
                ["blocked"] = new JsonArray([.. plan.Blocked.Select(b =>
                    (JsonNode)new JsonObject { ["id"] = b.Row.Id, ["why"] = b.Why })]),
                // 🔴 THE READ-ONLY FORM MUST LEAVE THE REGISTRY ALONE. The
                // PowerShell reports $script:dirty; this side reports whether it
                // applied an adoption, which it never does - the adoptions are
                // RETURNED. If either ever says true without -Adopt, that is the
                // defect this row exists to catch.
                ["dirty"] = false,
                ["agents"] = agentsBack,
            }.ToJsonString();
        })
    {
        // 🪤 THE ORDER OF TIES IS A NAMED, DELIBERATE DIFFERENCE. PowerShell 5.1's
        // Sort-Object is not stable (-Stable arrived in PowerShell 6) and LINQ's
        // OrderByDescending is, so two conversations sharing a lastActive to the
        // tick can come back swapped. The SET is never forgiven - only an
        // ordering difference inside fresh or restart is, and only when both
        // sides hold the same ids.
        Tolerate = SameSetDifferentOrder,
        ToleranceReason = "two conversations share a lastActive to the tick and PowerShell 5.1's sort is not stable; the SETS matched",
    };

    // ---------------------------------------------------------------------

    private static JsonArray Ids(IEnumerable<PlanRow> rows) =>
        new([.. rows.Select(r => (JsonNode)r.Id)]);

    private static JsonArray Sorted(IEnumerable<PlanRow> rows) =>
        new([.. rows.Select(r => r.Id).OrderBy(x => x, StringComparer.Ordinal).Select(x => (JsonNode)x)]);

    /// <summary>
    /// Rebuilds the rows the PowerShell walked.
    /// </summary>
    /// <remarks>
    /// 🔑 THE AGENT SNAPSHOT COMES FROM THE POWERSHELL, AND THAT IS NOT ECHOING.
    /// What is under test here is the PLAN, and its input is "who is running
    /// right now" - a fact that changes between two reads seconds apart, on a
    /// machine with two dozen live conversations. Handing both sides the same
    /// snapshot isolates the thing being compared; the snapshot itself is what
    /// case 2.5a compares, field by field, on its own. 🪤 The VERDICTS are still
    /// computed here, from the registry this side reads for itself.
    /// </remarks>
    private static List<PlanRow> ModelRows(JsonNode? doc, out JsonArray agentsBack)
    {
        var agents = new Dictionary<string, AgentStatus>(StringComparer.OrdinalIgnoreCase);
        foreach (var a in doc?["agents"]?.AsArray() ?? [])
        {
            var id = a?["id"]?.GetValue<string>() ?? string.Empty;
            if (id.Length == 0)
            {
                continue;
            }

            agents[id] = new AgentStatus(
                id,
                a?["status"]?.GetValue<string>() ?? string.Empty,
                string.Empty, false,
                a?["agentPid"]?.GetValue<int>() ?? 0,
                string.Empty,
                a?["name"]?.GetValue<string>() ?? string.Empty,
                string.Empty, null);
        }

        // 🔑 THE SNAPSHOT GOES BACK OUT HAVING BEEN THROUGH AgentStatus, AND THAT
        // IS A CHECK RATHER THAN AN ECHO. It is the one row here whose input and
        // output are the same values - what it proves is that this side READ the
        // question correctly, so a pid dropped or a name lost while building the
        // rows shows up as a difference instead of quietly making every verdict
        // wrong in the same direction. 🪤 The VERDICTS below are computed, from
        // the registry this side opens for itself.
        agentsBack = new JsonArray();
        foreach (var a in doc?["agents"]?.AsArray() ?? [])
        {
            var id = a?["id"]?.GetValue<string>() ?? string.Empty;
            if (!agents.TryGetValue(id, out var got))
            {
                agentsBack.Add(new JsonObject { ["id"] = "(this side did not parse " + id + ")" });
                continue;
            }

            agentsBack.Add(new JsonObject
            {
                ["id"] = got.SessionId,
                ["status"] = got.Status,
                ["name"] = got.Name,
                ["agentPid"] = got.Pid,
            });
        }

        var rows = new List<PlanRow>();
        foreach (var d in SessionRegistry.Read().Directories)
        {
            if (d.Missing)
            {
                continue;
            }

            foreach (var s in d.Sessions)
            {
                if (s.Gone)
                {
                    continue;
                }

                var id = s.SessionId.ToLowerInvariant();
                rows.Add(new PlanRow(id, s, d, agents.GetValueOrDefault(id)));
            }
        }

        return rows;
    }

    private static Dictionary<string, RegistrySession> SessionsById()
    {
        var map = new Dictionary<string, RegistrySession>(StringComparer.OrdinalIgnoreCase);
        foreach (var s in SessionRegistry.Read().AllSessions)
        {
            map[s.SessionId] = s;
        }

        return map;
    }

    /// <summary>Every line of a difference report that names a row.</summary>
    private static IEnumerable<string> Differences(string d) =>
        (d ?? string.Empty).Split('\n').Select(x => x.Trim()).Where(x => x.Length > 0);

    /// <summary>
    /// True when the only disagreement is the ORDER of a bucket whose membership
    /// both sides agree on.
    /// </summary>
    private static bool SameSetDifferentOrder(string difference)
    {
        // Every named difference must be an index inside fresh or restart. A
        // count difference, a blocked row or a dirty flag is never forgiven.
        return Differences(difference).All(x =>
            (x.Contains("$.fresh[", StringComparison.Ordinal)
             || x.Contains("$.restart[", StringComparison.Ordinal))
            && !x.Contains("item(s)", StringComparison.Ordinal));
    }
}
