using System.Diagnostics;
using SessionRestore.Core.Acting;
using SessionRestore.Core.Console;
using SessionRestore.Live;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>
/// Plan item 4.2e-1 - the acts that go through a console, proven against a
/// console this test owns.
/// </summary>
/// <remarks>
/// 🔴 NOTHING HERE GOES NEAR A CONVERSATION. Every console these tests type into
/// is <c>tests/term-replica.ps1</c>, started by the test and killed by it. The
/// production target, <see cref="ConsoleTarget.ForSession"/>, is exercised only
/// against THIS process - which is not claude, so it refuses, which is the point.
///
/// 🔑 AND EVERY REFUSAL IS PROVEN TO HAVE WRITTEN NOTHING. A refusal that
/// returned the right sentence and typed the message anyway would pass any test
/// that only read the sentence. After each one, a bare Enter is written straight
/// to the replica: if anything had been typed, it would come out in the file.
/// </remarks>
[Collection("console")]
public sealed class LiveActsTests
{
    private const string Menu = "❯ 1. Yes\n  2. No\n  3. Something else";

    /// <summary>A lookup that answers one session with the replica's pid.</summary>
    private sealed class OneSession(int pid, string kind = "interactive", string waiting = "", string? screen = "") : ISessions
    {
        public SessionFacts? Find(string sessionId) =>
            string.Equals(sessionId, "s1", StringComparison.Ordinal) ? new SessionFacts(pid, kind, waiting) : null;

        public string? Screen(int p) => screen;
    }

    /// <summary>The test's own escape hatch: a console it started, and nothing else.</summary>
    private static ConsoleTarget? Owned(uint pid, out string refusal)
    {
        refusal = string.Empty;
        return ConsoleTarget.ForOwnedConsole(pid);
    }

    private static string Typed(Process proc, string outFile, ConsoleTarget t)
    {
        // A bare Enter ends the replica and writes whatever it had accumulated.
        ConsoleWriter.SendKeys(t, ForwardedKey.Enter);
        Assert.True(proc.WaitForExit(30_000), "the replica never finished");
        return File.ReadAllText(outFile).Trim();
    }

    [Fact]
    public void A_message_is_typed_and_then_committed_with_its_own_enter()
    {
        var (t, proc, outFile) = ConsoleWriterTests.StartReplica();
        try
        {
            var paused = new List<TimeSpan>();
            var acts = new LiveActs(new OneSession(proc.Id), Owned, paused.Add);

            var r = acts.Carry(new ActRequest(Act.Send, "s1", "t", "hello\r\nthere"));

            Assert.True(r.Done, r.Said);

            // 🔴 WELL INSIDE THE REPLICA'S OWN TIMEOUT. The replica writes whatever
            // it has when its thirty seconds run out, so a send with NO Enter still
            // produced "hello there" - after thirty seconds - and this passed. An
            // Enter ends it in well under a second.
            Assert.True(proc.WaitForExit(10_000), "the Enter never arrived - the text was typed and not committed");

            // The line breaks are flattened to spaces, as the shipped body is.
            Assert.Equal("hello there", File.ReadAllText(outFile).Trim());

            // 🔴 AND THE ENTER WAITED. Two writes with the shipped 400 ms between -
            // a paste that arrives with its Enter in the same burst is not submitted.
            Assert.Equal([LiveActs.EnterAfter], paused);
        }
        finally
        {
            ConsoleWriterTests.Cleanup(proc, outFile);
        }
    }

    [Fact]
    public void An_interrupt_is_one_escape()
    {
        var (_, proc, outFile) = ConsoleWriterTests.StartReplica();
        try
        {
            var acts = new LiveActs(new OneSession(proc.Id), Owned);
            Assert.True(acts.Carry(new ActRequest(Act.Interrupt, "s1", "t", string.Empty)).Done);

            Assert.True(proc.WaitForExit(30_000), "the escape never arrived");
            Assert.Equal("<esc>", File.ReadAllText(outFile).Trim());
        }
        finally
        {
            ConsoleWriterTests.Cleanup(proc, outFile);
        }
    }

    [Fact]
    public void A_key_and_a_chord_arrive_as_themselves()
    {
        var (t, proc, outFile) = ConsoleWriterTests.StartReplica();
        try
        {
            var acts = new LiveActs(new OneSession(proc.Id), Owned);
            Assert.True(acts.Carry(new ActRequest(Act.Key, "s1", "t", "Tab")).Done);
            Assert.True(acts.Carry(new ActRequest(Act.Key, "s1", "t", "ctrl+c")).Done);
            Assert.Equal("<tab><ctrl-c>", Typed(proc, outFile, t));
        }
        finally
        {
            ConsoleWriterTests.Cleanup(proc, outFile);
        }
    }

    [Fact]
    public void A_dialog_refuses_and_types_nothing()
    {
        var (t, proc, outFile) = ConsoleWriterTests.StartReplica();
        try
        {
            var acts = new LiveActs(new OneSession(proc.Id, waiting: "a permission dialog"), Owned);
            var r = acts.Carry(new ActRequest(Act.Send, "s1", "t", "do not type this"));

            Assert.False(r.Done);
            Assert.Equal(SendRefusal.Dialog, r.Said);
            Assert.Equal(string.Empty, Typed(proc, outFile, t));
        }
        finally
        {
            ConsoleWriterTests.Cleanup(proc, outFile);
        }
    }

    [Fact]
    public void A_menu_on_screen_refuses_and_types_nothing()
    {
        // 🔴 A SESSION ON A MENU READS KEYSTROKES AS MENU INPUT. A sentence
        // typed at it would pick an option instead of queueing behind the turn.
        var (t, proc, outFile) = ConsoleWriterTests.StartReplica();
        try
        {
            var acts = new LiveActs(new OneSession(proc.Id, screen: Menu), Owned);
            var r = acts.Carry(new ActRequest(Act.Send, "s1", "t", "1"));

            Assert.False(r.Done);
            Assert.Equal(SendRefusal.Menu, r.Said);
            Assert.Equal(string.Empty, Typed(proc, outFile, t));
        }
        finally
        {
            ConsoleWriterTests.Cleanup(proc, outFile);
        }
    }

    [Fact]
    public void An_unreadable_screen_refuses_nothing()
    {
        // The reader sometimes comes back empty about a menu that is plainly
        // there; the shipped ladder refuses nothing then, rather than everything.
        var (_, proc, outFile) = ConsoleWriterTests.StartReplica();
        try
        {
            var acts = new LiveActs(new OneSession(proc.Id, screen: null), Owned, _ => { });
            Assert.True(acts.Carry(new ActRequest(Act.Send, "s1", "t", "ok")).Done);
            Assert.True(proc.WaitForExit(30_000));
            Assert.Equal("ok", File.ReadAllText(outFile).Trim());
        }
        finally
        {
            ConsoleWriterTests.Cleanup(proc, outFile);
        }
    }

    [Fact]
    public void The_claude_check_comes_before_the_menu_check()
    {
        // 🪤 THE ORDER IS THE PROTECTION. A process that is not claude is refused
        // for THAT, before its screen is read at all - so the refusal names it,
        // not the menu it may happen to be showing.
        var screenRead = false;
        var sessions = new Probe(() => screenRead = true);
        var acts = new LiveActs(sessions);   // the PRODUCTION target

        var r = acts.Carry(new ActRequest(Act.Send, "s1", "t", "hello"));

        Assert.False(r.Done);
        Assert.Contains("not claude", r.Said, StringComparison.Ordinal);
        Assert.False(screenRead, "the screen was read before the process was checked");
    }

    [Fact]
    public void A_dialog_is_refused_before_the_process_is_even_checked()
    {
        // 🪤 THE DIALOG RUNG IS ABOVE THE CLAUDE CHECK. Against a console the test
        // owns the claude check always passes, so a ladder that asked about the
        // dialog LATE would still refuse it - with the same words - and look
        // right. Against a process that is NOT claude, the order shows: the
        // shipped ladder answers with the dialog, not with the process.
        var acts = new LiveActs(new Probe(() => { }, waiting: "a permission dialog"));
        var r = acts.Carry(new ActRequest(Act.Send, "s1", "t", "hello"));

        Assert.Equal(SendRefusal.Dialog, r.Said);
    }

    private sealed class Probe(Action onScreen, string waiting = "") : ISessions
    {
        public SessionFacts? Find(string sessionId) => new(Environment.ProcessId, "interactive", waiting);

        public string? Screen(int pid)
        {
            onScreen();
            return Menu;
        }
    }

    [Theory]
    [InlineData(Act.Interrupt)]
    [InlineData(Act.Send)]
    [InlineData(Act.Key)]
    public void The_production_target_refuses_a_process_that_is_not_claude(Act what)
    {
        // THIS process - the test host - is the only real pid these tests hand
        // to the production path, and it must be refused by name.
        var acts = new LiveActs(new Probe(() => { }));
        var r = acts.Carry(new ActRequest(what, "s1", "t", what == Act.Key ? "Tab" : "hello"));

        Assert.False(r.Done);
        Assert.Contains("not claude", r.Said, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(Act.Interrupt, "there is no console to interrupt")]
    [InlineData(Act.Send, SendRefusal.NoProcess)]
    [InlineData(Act.Key, "there is no console to send a key to")]
    public void A_conversation_that_is_not_running_is_refused(Act what, string said)
    {
        var acts = new LiveActs(new OneSession(0), Owned);
        var r = acts.Carry(new ActRequest(what, "s1", "t", what == Act.Key ? "Tab" : "hello"));

        Assert.False(r.Done);
        Assert.Equal(said, r.Said);
    }

    [Fact]
    public void A_background_agent_is_not_typed_into()
    {
        var acts = new LiveActs(new OneSession(4242, kind: "task"), Owned);
        var r = acts.Carry(new ActRequest(Act.Send, "s1", "t", "hello"));
        Assert.Equal(SendRefusal.NotInteractive, r.Said);
    }

    [Theory]
    [InlineData("Escape", ForwardedKey.Escape, null)]
    [InlineData("tab", ForwardedKey.Tab, null)]
    [InlineData("Ctrl+C", null, ForwardedChord.C)]
    [InlineData("ctrl+d", null, ForwardedChord.D)]
    [InlineData("C", null, null)]
    [InlineData("Ctrl+Q", null, null)]
    [InlineData("Ctrl+CC", null, null)]
    [InlineData("13", null, null)]
    [InlineData("Ctrl+1", null, null)]
    [InlineData("Ctrl+0", null, null)]
    [InlineData("Ctrl+C,D", null, null)]
    [InlineData("", null, null)]
    public void A_key_is_a_named_key_or_a_chord_and_nothing_else(string detail, ForwardedKey? key, ForwardedChord? chord)
    {
        // 🪤 A CHORD IS THREE FIELDS, NOT A LETTER: "C" parses to nothing, and a
        // number that happens to be a virtual-key code is not a key name.
        Assert.Equal((key, chord), LiveActs.ParseKey(detail));
    }

    [Fact]
    public void A_write_that_fails_says_so_in_the_shipped_sentence()
    {
        // A console write cannot be made to fail on purpose against the replica,
        // so the sentence is pinned directly: it is what the status line shows.
        Assert.Equal("could not reach that session's console (win32 error 6)", LiveActs.Unreachable(-6));
    }

    [Theory]
    [InlineData(Act.Open)]
    [InlineData(Act.Relaunch)]
    [InlineData(Act.Close)]
    [InlineData(Act.GoTo)]
    [InlineData(Act.SignIn)]
    [InlineData(Act.SaveRegistry)]
    [InlineData(Act.WriteConfig)]
    public void An_act_that_is_not_built_refuses_by_name(Act what)
    {
        var acts = new LiveActs(new OneSession(0), Owned);
        var r = acts.Carry(new ActRequest(what, "s1", "t", string.Empty));
        Assert.False(r.Done);
        Assert.Contains("not built yet", r.Said, StringComparison.Ordinal);
    }
}
