using System.Text;
using System.Text.Json;
using SessionRestore.Core.Launch;
using SessionRestore.Core.Registry;
using SessionRestore.Core.Sessions;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>Plan item 2.5c - launching and ending, as plans.</summary>
/// <remarks>
/// 🔴 NOTHING IN THIS FILE LAUNCHES OR ENDS ANYTHING, AND NOTHING IN THE
/// ASSEMBLY UNDER TEST COULD. The operator runs sessions he cannot relaunch. The
/// oracle proves the plans match the shipped PowerShell on real data; these
/// prove the DECISIONS - the ones a running machine cannot be made to
/// demonstrate on demand, like a process that refuses to die or a conversation
/// launched 89 seconds ago.
/// </remarks>
public sealed class LaunchTests : IDisposable
{
    // 🪤 EVERY FIXTURE ROW OWNS ITS OWN TRANSCRIPT, and the first version of this
    // file did not - so the "launched a moment ago" test came back
    // "its transcript is missing" and looked like a bug in the ordering. It was
    // not: the transcript check genuinely comes first, in both implementations.
    // A test that does not own an input it reads is testing the machine it runs
    // on. [[feedback-test-accidents]]
    private readonly string _dir = Path.Combine(
        Path.GetTempPath(), "sr-launch-" + Guid.NewGuid().ToString("N"));

    public LaunchTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    // -----------------------------------------------------------------
    // The quoting that killed every AlgoTrader tab.
    // -----------------------------------------------------------------

    [Theory]
    [InlineData("plain", "\"plain\"")]
    [InlineData("two words", "\"two words\"")]
    [InlineData("", "\"\"")]
    // A trailing backslash run sits immediately before the CLOSING quote, so
    // every one of them must be doubled or the quote is escaped instead and the
    // next argument is swallowed into this one.
    [InlineData(@"ends\", @"""ends\\""")]
    [InlineData(@"ends\\", @"""ends\\\\""")]
    [InlineData(@"C:\a b\c\", @"""C:\a b\c\\""")]
    // A backslash NOT before a quote is literal and must be left alone.
    [InlineData(@"C:\Users\mauri\Documents\MM-toolbox", @"""C:\Users\mauri\Documents\MM-toolbox""")]
    [InlineData("a\"quote", @"""a\""quote""")]
    [InlineData(@"back\""slashquote", @"""back\\\""slashquote""")]
    public void An_argument_survives_CommandLineToArgvW(string raw, string quoted)
        => Assert.Equal(quoted, CommandLine.Quote(raw));

    [Fact]
    public void A_directory_with_a_space_reaches_the_receiver_whole()
    {
        // 🔴 THE ONE THAT ACTUALLY HAPPENED. Measured 2026-08-18: "Trading Bot"
        // split at the space, wt.exe took `Bot\Python\...` as the command to run,
        // and every AlgoTrader tab died with 0x80070002 while space-free repos
        // launched fine.
        var line = CommandLine.ForNewTab(
            @"C:\Users\mauri\Documents\Trading Bot\Python\AlgoTrader",
            @"C:\x\.state\boot-AlgoTrader-abcdef12.ps1",
            "AlgoTrader");

        Assert.Contains(@"-d ""C:\Users\mauri\Documents\Trading Bot\Python\AlgoTrader""", line, StringComparison.Ordinal);
    }

    [Fact]
    public void A_semicolon_in_a_path_is_refused_and_in_a_title_is_sanitised()
    {
        // wt splits its OWN argv on a bare ';' and quoting does not take that
        // away, so a path carrying one would run something nobody asked for. A
        // title is cosmetic, so it becomes a comma instead.
        Assert.Throws<ArgumentException>(() => CommandLine.ForNewTab(@"C:\a;b", "boot.ps1", "t"));
        Assert.Throws<ArgumentException>(() => CommandLine.ForNewTab(@"C:\a", "bo;ot.ps1", "t"));

        var line = CommandLine.ForNewTab(@"C:\a", "boot.ps1", "one; two");
        Assert.Contains(@"--title ""one, two""", line, StringComparison.Ordinal);
    }

    // -----------------------------------------------------------------
    // The boot script.
    // -----------------------------------------------------------------

    [Fact]
    public void A_title_that_looks_like_code_never_becomes_code()
    {
        // 🔴 A NAME MUST NOT CROSS A SHELL BOUNDARY AS SYNTAX. The template is
        // substituted rather than interpolated exactly so a conversation called
        // `$(rm -rf)` is a string in the script that opens it.
        var text = BootScript.Text(@"C:\x", "1234567890ab", "it's $(bad) `now`");

        Assert.Contains("$env:CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX = 'it''s $(bad) `now`'", text, StringComparison.Ordinal);
        Assert.Contains("-n 'it''s $(bad) `now`'", text, StringComparison.Ordinal);
    }

    [Fact]
    public void Remote_control_off_omits_the_flag_rather_than_passing_it_empty()
    {
        Assert.DoesNotContain("--remote-control '", BootScript.Text(@"C:\x", "1234567890ab", "t", null, false), StringComparison.Ordinal);
        Assert.Contains("--remote-control 't'", BootScript.Text(@"C:\x", "1234567890ab", "t", null, true), StringComparison.Ordinal);
    }

    [Fact]
    public void A_new_conversation_gets_no_resume_flag()
    {
        // Both paths go through here: a bare `claude` registers Remote Control
        // against an EMPTY conversation and the device then shows
        // "<hostname>-graceful-unicorn" for ever, so -n and --remote-control are
        // not optional on either path - but --resume is only for a resume.
        var fresh = BootScript.Text(@"C:\x", null, "brand new");
        Assert.DoesNotContain("--resume", fresh, StringComparison.Ordinal);
        Assert.Contains("-n 'brand new'", fresh, StringComparison.Ordinal);
    }

    [Fact]
    public void The_child_session_environment_is_scrubbed()
    {
        // Without this claude writes NO TRANSCRIPT AT ALL and the conversation
        // cannot be resumed afterwards - a session that looks fine until you try
        // to come back to it.
        var text = BootScript.Text(@"C:\x", "1234567890ab", "t");
        foreach (var v in BootScript.ChildVars)
        {
            Assert.Contains("'" + v + "'", text, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void The_boot_path_carries_the_session_id_not_just_the_folder()
    {
        // 🔴 Keying on the directory alone was fine while only one conversation
        // per tree could be restored; with several it had them overwrite each
        // other's boot script mid-launch.
        var a = BootScript.PathFor(@"C:\repos\MM-toolbox", "aaaaaaaa-1111-2222-3333-444444444444");
        var b = BootScript.PathFor(@"C:\repos\MM-toolbox", "bbbbbbbb-1111-2222-3333-444444444444");

        Assert.NotEqual(a, b);
        Assert.EndsWith(@"boot-MM-toolbox-aaaaaaaa.ps1", a, StringComparison.Ordinal);
    }

    [Fact]
    public void A_new_conversation_keys_its_boot_script_on_the_clock()
    {
        // It has no id yet, so there is nothing stable to key on and two
        // rapid-fire spawns in one directory would otherwise share a filename.
        var at = new DateTime(2026, 9, 10, 14, 5, 6, 789, DateTimeKind.Local);
        Assert.EndsWith(@"boot-new-MM-toolbox-0910-140506-789.ps1", BootScript.PathFor(@"C:\repos\MM-toolbox", null, at), StringComparison.Ordinal);
    }

    [Fact]
    public void The_bytes_are_a_BOM_LF_lines_and_a_CRLF_terminator()
    {
        // 🔴 POWERSHELL 5.1 READS A .ps1 AS ANSI UNLESS A BOM SAYS OTHERWISE, so
        // "the same text" is not the same file, and this is a script whose
        // mis-parse would be silent.
        var b = BootScript.FileBytes(@"C:\x", "1234567890ab", "t");

        Assert.Equal(new byte[] { 0xEF, 0xBB, 0xBF }, b[..3]);
        Assert.Equal("\r\n", Encoding.UTF8.GetString(b[^2..]));
        Assert.DoesNotContain("\r\n", Encoding.UTF8.GetString(b[..^2]), StringComparison.Ordinal);
    }

    // -----------------------------------------------------------------
    // The flags a conversation launches with.
    // -----------------------------------------------------------------

    [Fact]
    public void A_conversation_with_no_settings_produces_no_flags()
    {
        // 🪤 The ",@()" trap read backwards: `return ,$arr` on an EMPTY array
        // emits ONE element holding the empty array, so a conversation with no
        // settings reported a count of 1 and the first real flag landed at index
        // 1 instead of 0.
        Assert.Empty(SessionArgs.For(Session("{}")));
        Assert.Empty(SessionArgs.For(Session(null)));
        Assert.Equal(string.Empty, SessionArgs.Label(Session(null)));
    }

    [Fact]
    public void A_value_claude_would_reject_is_shown_but_never_passed()
    {
        // 🔴 A BAD VALUE DOES NOT FAIL POLITELY - IT FAILS THE LAUNCH, and the
        // conversation just never opens. So it is dropped from the argv while the
        // label still shows it, which is the only way the operator can tell a
        // setting is present but inert.
        var s = Session("""{"effort":"ludicrous","permissionMode":"whatever","model":"claude-opus-5"}""");

        Assert.Equal<IEnumerable<string>>(["--model", "claude-opus-5"], SessionArgs.For(s));
        Assert.Contains("ludicrous", SessionArgs.Label(s), StringComparison.Ordinal);
        Assert.Contains("whatever", SessionArgs.Label(s), StringComparison.Ordinal);
    }

    [Fact]
    public void Remote_control_is_on_unless_a_conversation_says_otherwise()
    {
        // That is what every session on this machine has done since the tool
        // shipped; a settings feature must not quietly switch it off for all of
        // them.
        Assert.True(SessionArgs.RemoteWanted(Session(null)));
        Assert.True(SessionArgs.RemoteWanted(Session("{}")));
        Assert.False(SessionArgs.RemoteWanted(Session("""{"remoteControl":false}""")));
    }

    [Fact]
    public void Hidden_is_a_launch_choice_and_never_a_claude_flag()
    {
        var s = Session("""{"hidden":true}""");
        Assert.True(SessionArgs.HiddenWanted(s));
        Assert.DoesNotContain("hidden", string.Join(' ', SessionArgs.For(s)), StringComparison.Ordinal);
        Assert.Contains("hidden", SessionArgs.Label(s), StringComparison.Ordinal);
    }

    [Fact]
    public void A_single_tool_rule_is_one_rule_and_not_six_characters()
    {
        // 🪤 PowerShell's @() wraps a bare string into ONE element. A port that
        // enumerated the string instead would emit --allowedTools per character.
        var s = Session("""{"allowedTools":"Bash"}""");
        Assert.Equal<IEnumerable<string>>(["--allowedTools", "Bash"], SessionArgs.For(s));
        Assert.Contains("1 tool rule(s)", SessionArgs.Label(s), StringComparison.Ordinal);
    }

    // -----------------------------------------------------------------
    // The plan.
    // -----------------------------------------------------------------

    [Fact]
    public void A_conversation_launched_a_moment_ago_is_not_launched_again()
    {
        // 🔴 A session opened seconds ago has no claude.exe yet - the boot shell
        // is still starting one - so without this window, pressing the button
        // twice opens everything twice.
        var row = Row("a", enabled: true);
        var now = new DateTime(2026, 9, 10, 12, 0, 0, DateTimeKind.Local);

        Assert.Equal("it was launched a moment ago", LaunchPlan.Blocked(row, now.AddSeconds(-89), now));
        // 91 seconds later the claim has expired; whatever the verdict is now, it
        // is not this one.
        Assert.NotEqual("it was launched a moment ago", LaunchPlan.Blocked(row, now.AddSeconds(-91), now));
    }

    [Fact]
    public void A_conversation_whose_directory_is_gone_says_which_directory()
    {
        var row = Row("a", enabled: true, cwd: @"C:\this\does\not\exist\sr-test");
        Assert.Equal(@"its directory no longer exists: C:\this\does\not\exist\sr-test", LaunchPlan.Blocked(row));
    }

    [Fact]
    public void Mid_turn_is_bucketed_apart_from_merely_running()
    {
        // 'busy' is claude's OWN word for a turn in progress. Anything else that
        // is running - idle, waiting, at a login prompt - is safe to take, and a
        // conversation mid-turn is never taken: the whole promise of relaunch is
        // that it does not interrupt work.
        var busy = Row("busy", enabled: true, agent: Agent("busy", 100, "busy"));
        var idle = Row("idle", enabled: true, agent: Agent("idle", 101, "idle"));

        var plan = LaunchPlan.Ticked([busy, idle]);

        Assert.Equal(["busy"], plan.Busy.Select(r => r.Id));
        Assert.Equal(["idle"], plan.Restart.Select(r => r.Id));
        Assert.Empty(plan.Fresh);
    }

    [Fact]
    public void An_unticked_conversation_is_in_no_bucket_at_all()
    {
        var plan = LaunchPlan.Ticked([
            Row("off", enabled: false),
            Row("dir-off", enabled: true, dirEnabled: false),
            Row("dir-gone", enabled: true, dirMissing: true),
        ]);

        Assert.Empty(plan.Fresh);
        Assert.Empty(plan.Restart);
        Assert.Empty(plan.Busy);
        Assert.Empty(plan.Blocked);
    }

    [Fact]
    public void A_live_name_is_reported_for_adoption_and_never_applied_by_the_plan()
    {
        // 🔴 THE LIVE NAME OUTRANKS THE REGISTRY, and getting this wrong UNDOES
        // the operator's own work: relaunching from a stale title passes it to -n
        // and renames the conversation BACK, inside an action pressed to FIX
        // names. But a function asked for a PLAN must not dirty the registry - so
        // the adoption is returned, not applied.
        var row = Row("a", enabled: true, title: "old name", agent: Agent("a", 5, "idle", "new name"));
        var adoptions = new List<NameAdoption>();

        LaunchPlan.Ticked([row], adoptions: adoptions);

        Assert.Equal("new name", Assert.Single(adoptions).Live);
        Assert.Equal("old name", row.Session.Title);
    }

    [Fact]
    public void An_untitled_live_session_never_overwrites_a_real_name()
    {
        var row = Row("a", enabled: true, title: "a real name", agent: Agent("a", 5, "idle", "(untitled)"));
        var adoptions = new List<NameAdoption>();

        LaunchPlan.Ticked([row], adoptions: adoptions);

        Assert.Empty(adoptions);
    }

    [Fact]
    public void The_cap_is_shared_between_the_two_halves_of_one_press()
    {
        // Relaunch restarts the running set AND opens the not-running set in one
        // press, and the cap is about how many sessions the machine ends up with
        // - not how many each half started.
        var rows = (IReadOnlyList<PlanRow>)[Row("a"), Row("b"), Row("c")];

        var first = LaunchPlan.Cap(rows, cap: 4);
        Assert.Equal(3, first.Go.Count);
        Assert.Equal(0, first.Over);

        var second = LaunchPlan.Cap(rows, cap: 4, already: first.Go.Count);
        Assert.Single(second.Go);
        Assert.Equal(2, second.Over);
    }

    [Fact]
    public void No_cap_means_no_cap_and_an_overrun_never_goes_negative()
    {
        var rows = (IReadOnlyList<PlanRow>)[Row("a"), Row("b")];
        Assert.Equal(2, LaunchPlan.Cap(rows, cap: 0).Go.Count);
        Assert.Empty(LaunchPlan.Cap(rows, cap: 1, already: 9).Go);
        Assert.Equal(2, LaunchPlan.Cap(rows, cap: 1, already: 9).Over);
    }

    // -----------------------------------------------------------------
    // The end plan.
    // -----------------------------------------------------------------

    [Fact]
    public void A_reused_pid_is_never_mistaken_for_the_conversation_that_had_it()
    {
        // 🔴 A PID IS REUSABLE. Confirming the process at a recorded pid is still
        // the claude that owns the conversation is what stops a relaunch killing
        // whatever inherited the number.
        var row = Row("a", enabled: true, agent: Agent("a", 4321, "idle"));
        var snap = Snapshot((4321, "notepad.exe", 1));

        var plan = EndPlans.For(row, snap, "t", _ => null);

        Assert.Equal(EndVerdict.AlreadyEnded, plan.Verdict);
        Assert.False(plan.EndsAnything);
    }

    [Fact]
    public void A_boot_shell_of_ours_is_ended_with_it_and_a_borrowed_terminal_is_not()
    {
        // The parent of a claude is usually the little powershell.exe that ran
        // its boot script - but it can also be a terminal the operator started by
        // hand, and ending THAT closes a window full of unrelated work.
        var row = Row("a", enabled: true, agent: Agent("a", 10, "idle"));
        var snap = Snapshot((10, "claude.exe", 20), (20, "powershell.exe", 1));

        var ours = EndPlans.For(row, snap, "t", _ => @"powershell.exe -NoExit -File C:\x\.state\boot-x-1234abcd.ps1");
        Assert.Equal(EndVerdict.Close, ours.Verdict);
        Assert.Equal(20u, ours.BootShellPid);

        var theirs = EndPlans.For(row, snap, "t", _ => "powershell.exe -NoExit -Command Get-Process");
        Assert.Equal(EndVerdict.Close, theirs.Verdict);
        Assert.Null(theirs.BootShellPid);
    }

    [Fact]
    public void An_unreadable_command_line_is_not_read_as_someone_elses_shell()
    {
        // 🔴 A GATE THAT CANNOT TELL MUST NOT PRINT AN ANSWER. Reading a command
        // line needs PROCESS_VM_READ, so an elevated parent answers null - and
        // null must mean "leave it alone", which is the safe side: an orphaned
        // boot shell is untidy, someone's terminal closing is not.
        var row = Row("a", enabled: true, agent: Agent("a", 10, "idle"));
        var snap = Snapshot((10, "claude.exe", 20), (20, "powershell.exe", 1));

        Assert.Null(EndPlans.For(row, snap, "t", _ => null).BootShellPid);
        Assert.False(EndPlans.LooksLikeBootShell(null));
        Assert.False(EndPlans.LooksLikeBootShell(""));
    }

    [Fact]
    public void A_mid_turn_conversation_is_refused_before_anything_is_looked_up()
    {
        var row = Row("a", enabled: true, agent: Agent("a", 10, "busy"));
        var plan = EndPlans.For(row, Snapshot((10, "claude.exe", 20)), "t", _ => null);

        Assert.Equal(EndVerdict.MidTurn, plan.Verdict);
        Assert.False(plan.EndsAnything);
    }

    [Fact]
    public void A_close_that_failed_is_not_reopened_on_top_of_itself()
    {
        // 🔴 THE DEFECT THIS SHAPE EXISTS TO PREVENT. A `continue` once skipped
        // the rest of an iteration while leaving the row in the launch set, so a
        // process that refused to die left the OLD conversation running while a
        // NEW one started on the same transcript - two claude processes holding
        // one file, arrived at silently.
        var stuck = Row("stuck", enabled: true, agent: Agent("stuck", 10, "idle"));
        var went = Row("went", enabled: true, agent: Agent("went", 11, "idle"));
        var never = Row("never", enabled: true);
        var snap = Snapshot((10, "claude.exe", 1), (11, "claude.exe", 1));

        var reopen = EndPlans.Reopenable(
        [
            (stuck, EndPlans.For(stuck, snap, "t", _ => null), false),
            (went, EndPlans.For(went, snap, "t", _ => null), true),
            (never, EndPlans.For(never, snap, "t", _ => null), false),
        ]);

        Assert.Equal(["went", "never"], reopen.Select(r => r.Id));
    }

    [Fact]
    public void The_tab_name_prefers_the_live_name_over_the_recorded_title()
    {
        // Killing the processes does NOT close the tab - measured 2026-08-28,
        // 40 tabs for 18 live sessions after one relaunch - and a title only
        // identifies a dead tab while the session that owned it is dead.
        var named = Row("a", enabled: true, agent: Agent("a", 10, "idle", "live name"));
        var unnamed = Row("a", enabled: true, agent: Agent("a", 10, "idle", "   "));
        var snap = Snapshot((10, "claude.exe", 1));

        Assert.Equal("live name", EndPlans.For(named, snap, "recorded", _ => null).TabName);
        Assert.Equal("recorded", EndPlans.For(unnamed, snap, "recorded", _ => null).TabName);
    }

    [Fact]
    public void The_snapshot_finds_this_very_process()
    {
        // The only claim about the live machine these tests make, and it is the
        // one that would catch a P/Invoke that silently returns nothing: this
        // process is definitely running, and it definitely has a parent.
        var me = (uint)Environment.ProcessId;
        var snap = ProcessTree.All();

        var p = Assert.IsType<ProcessFacts>(ProcessTree.Of(me, snap));
        Assert.Contains("testhost", p.Name, StringComparison.OrdinalIgnoreCase);
        Assert.NotEqual(0u, p.ParentPid);
        Assert.Contains("testhost", ProcessTree.CommandLineOf(me) ?? string.Empty, StringComparison.OrdinalIgnoreCase);
    }

    // -----------------------------------------------------------------

    private static Dictionary<uint, ProcessFacts> Snapshot(params (uint Pid, string Name, uint Parent)[] procs)
        => procs.ToDictionary(p => p.Pid, p => new ProcessFacts(p.Pid, p.Name, p.Parent));

    private static AgentStatus Agent(string id, int pid, string status, string name = "")
        => new(id, status, string.Empty, false, pid, "interactive", name, string.Empty, null);

    private static RegistrySession Session(string? prefsJson)
    {
        var s = new RegistrySession { SessionId = "1234567890ab", Enabled = true };
        if (prefsJson is not null)
        {
            s.Extra = new Dictionary<string, JsonElement>(StringComparer.Ordinal)
            {
                ["prefs"] = JsonDocument.Parse(prefsJson).RootElement.Clone(),
            };
        }

        return s;
    }

    private PlanRow Row(
        string id,
        bool enabled = true,
        bool dirEnabled = true,
        bool dirMissing = false,
        string title = "",
        string? cwd = null,
        AgentStatus? agent = null)
    {
        // A transcript named after the session, so Get-SRTranscriptPath's
        // ownership check accepts the recorded path and the launch-block checks
        // reach the clause each test is actually about.
        var jsonl = Path.Combine(_dir, id + ".jsonl");
        File.WriteAllText(jsonl, "{}");

        var s = new RegistrySession
        {
            SessionId = id,
            Enabled = enabled,
            Title = title,
            Cwd = cwd ?? _dir,
            Jsonl = jsonl,
            LastActive = DateTimeOffset.UnixEpoch,
        };
        var d = new RegistryDirectory { Path = _dir, Enabled = dirEnabled, Missing = dirMissing };
        return new PlanRow(id, s, d, agent);
    }
}
