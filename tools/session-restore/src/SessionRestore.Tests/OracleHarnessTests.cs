using System.Diagnostics;
using SessionRestore.Oracle;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>
/// The harness itself. 🔴 A HARNESS NOBODY CHECKS IS A CLAIM, NOT A CHECK.
/// </summary>
public sealed class OracleHarnessTests
{
    [Fact]
    public void A_powershell_that_stops_answering_times_out_instead_of_hanging()
    {
        // 🔴 THE DEADLINE USED TO BE CHECKED BETWEEN READS, and ReadLine blocks
        // for ever - so a side that stopped answering hung the whole run with
        // the timeout unable to fire. Observed for real: sr-oracle sat at two
        // seconds of CPU for twenty minutes, its output file empty, holding the
        // build's DLL locked, and nothing said why.
        //
        // 🪤 A HANG IS THE WORST OUTCOME A HARNESS HAS. A red is a fact and a
        // green is a claim; a hang is neither, and it takes the next build with
        // it.
        //
        // Its own session, not the shared one: proving this KILLS the session,
        // and the other tests need theirs.
        using var session = new PsSession();

        var sw = Stopwatch.StartNew();
        var r = session.Run("Start-Sleep -Seconds 30", TimeSpan.FromSeconds(3));
        sw.Stop();

        Assert.True(r.Failed);
        Assert.Contains("stopped answering", r.StdErr, StringComparison.Ordinal);
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(20),
            $"it took {sw.Elapsed.TotalSeconds:N0} s to give up on a 3 s deadline");
    }

    [Fact]
    public void A_session_that_answers_is_not_disturbed_by_the_deadline()
    {
        // The other half: the timeout must not fire on work that is simply
        // taking a moment.
        var r = PowerShellRunner.Run("Start-Sleep -Milliseconds 400; 'done'", TimeSpan.FromSeconds(30));

        Assert.False(r.Failed, r.StdErr);
        Assert.Contains("done", r.StdOut, StringComparison.Ordinal);
    }
}
