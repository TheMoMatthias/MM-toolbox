using System.Diagnostics;
using System.Globalization;
using SessionRestore.Core;
using SessionRestore.Core.Console;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>
/// Plan item 2.4b - typing into a console, proven against one this test owns.
/// </summary>
/// <remarks>
/// 🔴 NOTHING HERE GOES NEAR A CONVERSATION. The standing rule in this repo is
/// that nothing may type into a session - not to test, not once, not against
/// what somebody believes is a spare. What these drive is
/// <c>tests/term-replica.ps1</c>: a REAL console with a REAL input queue, read
/// through <c>[Console]::ReadKey</c>, which is what consumes the INPUT_RECORDs
/// this code writes.
///
/// 🔑 IT IS THE SAME REPLICA THE POWERSHELL SUITE USES, deliberately. Two
/// implementations proven against one stand-in are comparable; two proven
/// against two are not.
/// </remarks>
[Collection("console")]
public sealed class ConsoleWriterTests
{
    private static string ReplicaScript => Path.Combine(ToolPaths.Root, "tests", "term-replica.ps1");

    [Fact]
    public void The_replica_the_powershell_suite_uses_is_still_there()
    {
        // If this moves, the tests below stop proving anything and start
        // skipping - which is the failure mode worth catching loudly.
        Assert.True(File.Exists(ReplicaScript), ReplicaScript + " is missing");
    }

    [Fact]
    public void Characters_a_key_and_a_chord_all_arrive_as_themselves()
    {
        // 🔑 THE THREE PATHS IN ONE RUN, because they are three different record
        // shapes and only the last of them is obvious. A character record
        // carries UnicodeChar with no virtual key; a key record carries the
        // virtual key with no character; a chord carries BOTH plus the control
        // bit - and a chord sent as a bare key arrives as a plain "c".
        var (target, proc, outFile) = StartReplica();
        try
        {
            Assert.True(ConsoleWriter.Send(target, "hello") > 0, "characters were refused");
            Assert.True(ConsoleWriter.SendKeys(target, ForwardedKey.Tab) > 0, "the tab was refused");
            Assert.True(ConsoleWriter.SendChord(target, ForwardedChord.C) > 0, "the chord was refused");
            Assert.True(ConsoleWriter.SendKeys(target, ForwardedKey.Enter) > 0, "the enter was refused");

            Assert.True(proc.WaitForExit(30_000), "the replica never finished");
            Assert.Equal("hello<tab><ctrl-c>", File.ReadAllText(outFile).Trim());
        }
        finally
        {
            Cleanup(proc, outFile);
        }
    }

    [Fact]
    public void Escape_arrives_as_a_key_and_not_as_a_character()
    {
        // The key the operator reported as not working, on the path that carries
        // it. The replica writes "<esc>" for it precisely so a virtual-key
        // record can be told apart from anything with a character in it.
        var (target, proc, outFile) = StartReplica();
        try
        {
            Assert.True(ConsoleWriter.Send(target, "ab") > 0);
            Assert.True(ConsoleWriter.SendKeys(target, ForwardedKey.Escape) > 0);

            Assert.True(proc.WaitForExit(30_000), "the replica never finished");
            Assert.Equal("ab<esc>", File.ReadAllText(outFile).Trim());
        }
        finally
        {
            Cleanup(proc, outFile);
        }
    }

    [Fact]
    public void Backspace_removes_what_was_typed_before_it()
    {
        var (target, proc, outFile) = StartReplica();
        try
        {
            Assert.True(ConsoleWriter.Send(target, "abc") > 0);
            Assert.True(ConsoleWriter.SendKeys(target, ForwardedKey.Backspace) > 0);
            Assert.True(ConsoleWriter.SendKeys(target, ForwardedKey.Enter) > 0);

            Assert.True(proc.WaitForExit(30_000), "the replica never finished");
            Assert.Equal("ab", File.ReadAllText(outFile).Trim());
        }
        finally
        {
            Cleanup(proc, outFile);
        }
    }

    [Fact]
    public void A_pid_that_is_not_a_conversation_is_refused_by_name()
    {
        // 🔴 A PID IS REUSABLE. The number belonging to a conversation five
        // minutes ago may belong to anything now, so the guard runs before every
        // send - and it says WHAT it found rather than just "no".
        var me = (uint)Environment.ProcessId;
        var target = ConsoleTarget.ForSession(me, out var refusal);

        Assert.Null(target);
        Assert.Contains("not claude", refusal, StringComparison.Ordinal);
        Assert.Contains("refusing to type into it", refusal, StringComparison.Ordinal);
    }

    [Fact]
    public void A_process_that_has_gone_is_refused_without_throwing()
    {
        // The common case: a session that closed while a card was still on
        // screen. It must not throw - this runs behind a window.
        var target = ConsoleTarget.ForSession(uint.MaxValue - 3, out var refusal);

        Assert.Null(target);
        Assert.Equal("that session has exited", refusal);
    }

    [Fact]
    public void Pid_zero_is_refused()
    {
        Assert.Null(ConsoleTarget.ForSession(0, out var refusal));
        Assert.Equal("there is no console to type into", refusal);
    }

    /// <summary>
    /// Starts the replica in a console of its own and waits until it is reading.
    /// </summary>
    /// <remarks>
    /// 🪤 UseShellExecute IS WHAT GIVES IT A CONSOLE. A child started without it
    /// inherits the parent's, and a test host has none - so there would be no
    /// input queue to write into and every assertion here would fail for a
    /// reason that has nothing to do with the code under test.
    /// </remarks>
    private static (ConsoleTarget Target, Process Proc, string OutFile) StartReplica()
    {
        var outFile = Path.Combine(Path.GetTempPath(),
            "sr-replica-" + Guid.NewGuid().ToString("N", CultureInfo.InvariantCulture) + ".txt");

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = true,
            WindowStyle = ProcessWindowStyle.Minimized,
        };
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-ExecutionPolicy");
        psi.ArgumentList.Add("Bypass");
        psi.ArgumentList.Add("-File");
        psi.ArgumentList.Add(ReplicaScript);
        psi.ArgumentList.Add("-Out");
        psi.ArgumentList.Add(outFile);
        psi.ArgumentList.Add("-TimeoutSeconds");
        psi.ArgumentList.Add("30");

        var proc = Process.Start(psi) ?? throw new InvalidOperationException("the replica would not start");

        // 🪤 IT HAS TO BE READING BEFORE ANYTHING IS SENT. Records written into a
        // console whose reader has not started yet still queue up, but the
        // PowerShell host takes a moment to exist at all - and a send to a pid
        // that has no console yet fails outright. Wait for the window.
        var sw = Stopwatch.StartNew();
        while (sw.Elapsed.TotalSeconds < 20)
        {
            proc.Refresh();
            if (proc.HasExited)
            {
                throw new InvalidOperationException("the replica exited before it could be typed into");
            }

            if (proc.MainWindowHandle != IntPtr.Zero)
            {
                break;
            }

            Thread.Sleep(50);
        }

        // And a beat more for the script itself to reach its read loop.
        Thread.Sleep(900);
        return (ConsoleTarget.ForOwnedConsole((uint)proc.Id), proc, outFile);
    }

    private static void Cleanup(Process proc, string outFile)
    {
        try
        {
            if (!proc.HasExited)
            {
                proc.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException) { }

        proc.Dispose();
        try { File.Delete(outFile); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}

/// <summary>
/// 🔴 THESE MUST NOT RUN AT THE SAME TIME AS EACH OTHER. Each one frees this
/// process's console, attaches to another, and gives it back; two doing that
/// concurrently would attach to each other's replica and the failures would look
/// like the send path being wrong.
/// </summary>
[CollectionDefinition("console", DisableParallelization = true)]
public sealed class ConsoleSerialGroup
{
}
