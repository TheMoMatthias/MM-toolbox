using System.Diagnostics;
using SessionRestore.Core.Console;
using Xunit;
using Xunit.Abstractions;

namespace SessionRestore.Tests;

/// <summary>Plan item 2.4b - the held-open helper.</summary>
public sealed class ScreenServerTests(ITestOutputHelper output)
{
    [Fact]
    public void The_server_answers_and_agrees_with_the_spawned_form()
    {
        // 🔑 THE TWO FORMS MUST SAY THE SAME THING, or the fast path is a
        // different reader wearing the same name. Compared on a process that is
        // NOT a conversation - its own refusal string is a perfectly good
        // answer to agree about, and nothing here goes near a session.
        using var client = new ScreenServerClient();

        var viaPipe = client.Rows(0);
        var viaSpawn = ScreenReader.Read(0);

        Assert.Equal(viaSpawn, viaPipe);
        Assert.StartsWith("!", viaPipe, StringComparison.Ordinal);
    }

    [Fact]
    public void It_is_faster_than_spawning_and_the_run_says_by_how_much()
    {
        // 🔴 THE REASON THE SERVER EXISTS IS A NUMBER, so the number is checked
        // rather than assumed. Measured 2026-09-09 before it was built: 51,7 ms
        // median to spawn per read, 1.673 ms for 26 consoles.
        //
        // 🪤 IT ASSERTS A DIRECTION, NOT A FIGURE. A threshold in milliseconds
        // is a fact about whichever machine happens to run it, and this repo has
        // already withdrawn speed claims made that way. What must hold anywhere
        // is that not starting a process beats starting one.
        using var client = new ScreenServerClient();
        _ = client.Rows(0);   // pay the start-up once, outside the measurement

        const int n = 12;
        var spawn = Stopwatch.StartNew();
        for (var i = 0; i < n; i++)
        {
            _ = ScreenReader.Read(0);
        }

        spawn.Stop();

        var served = Stopwatch.StartNew();
        for (var i = 0; i < n; i++)
        {
            _ = client.Rows(0);
        }

        served.Stop();

        output.WriteLine($"{n} reads: spawned {spawn.ElapsedMilliseconds} ms, served {served.ElapsedMilliseconds} ms");
        Assert.True(client.Connected, "the read never went down the pipe");
        Assert.True(served.ElapsedMilliseconds < spawn.ElapsedMilliseconds,
            $"served {served.ElapsedMilliseconds} ms was not faster than spawned {spawn.ElapsedMilliseconds} ms");
    }

    [Theory]
    [InlineData("1234", 1234u, 0, false)]
    [InlineData("1234:600", 1234u, 600, false)]
    [InlineData("a1234", 1234u, 0, true)]
    [InlineData("a1234:12", 1234u, 12, true)]
    public void The_wire_format_round_trips(string line, uint pid, int back, bool attrs)
    {
        // 🔑 THE CLIENT AND THE SERVER SHARE THIS TYPE rather than each keeping
        // a copy of the format. Two copies of a wire format is two things to
        // keep in step, and the one that drifts is the one nobody looks at.
        var parsed = ScreenRequest.Parse(line);

        Assert.NotNull(parsed);
        Assert.Equal(new ScreenRequest(pid, back, attrs), parsed!.Value);
        Assert.Equal(line, parsed.Value.ToString());
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-a-pid")]
    [InlineData("a")]
    [InlineData("12:notanumber")]
    [InlineData("12:-4")]
    public void A_request_it_cannot_read_is_refused_rather_than_guessed(string line)
    {
        // A malformed request must never resolve to SOME pid. The pid is the
        // whole of what says which conversation is being read.
        Assert.Null(ScreenRequest.Parse(line));
    }

    [Fact]
    public void Disposing_leaves_no_helper_behind()
    {
        // A leaked server holds a pipe name and sits on the machine until a
        // reboot. The idle timeout would get it eventually; Dispose must not
        // rely on that.
        var before = Process.GetProcessesByName("sr-screen").Length;
        using (var client = new ScreenServerClient())
        {
            _ = client.Rows(0);
            Assert.True(client.Connected);
        }

        // Give the kill a moment to be reflected.
        Thread.Sleep(400);
        Assert.True(Process.GetProcessesByName("sr-screen").Length <= before,
            "a helper was left running");
    }

}
