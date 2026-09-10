using SessionRestore.Core;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>Plan item 3.4 - the cadences.</summary>
public sealed class CadenceTests
{
    [Fact]
    public void Every_timer_the_window_has_is_named_here()
    {
        // 🔑 THE DRIFT CHECK'S OTHER HALF. The oracle proves the VALUES match the
        // shipped window; this proves the table is not missing a name, which is
        // what a comparison keyed on the PowerShell's rows cannot catch on its
        // own - a timer absent from both sides agrees perfectly.
        var expected = new[]
        {
            "ansTimer", "followTimer", "measureTimer", "showTimer", "searchTimer",
            "launchTimer", "writeTimer", "castTimer", "fastTimer", "liveTimer",
            "pollTimer", "askTimer",
        };

        Assert.Equal(expected.Length, Cadences.ByTimerName.Count);
        foreach (var name in expected)
        {
            Assert.True(Cadences.ByTimerName.ContainsKey(name), name + " has no cadence");
        }
    }

    [Fact]
    public void The_two_that_decide_how_live_it_feels_are_what_was_measured()
    {
        // 🔴 Six and fifteen seconds are not round numbers picked for tidiness.
        // Six is what makes working->done reachable in under a sweep; fifteen is
        // what `claude agents --json` costs at 295 ms a call.
        Assert.Equal(TimeSpan.FromSeconds(6), Cadences.Fast);
        Assert.Equal(TimeSpan.FromSeconds(15), Cadences.Live);
    }

    [Fact]
    public void No_cadence_is_zero_or_negative()
    {
        // A zero interval is a busy loop wearing a timer's name.
        foreach (var (name, every) in Cadences.ByTimerName)
        {
            Assert.True(every > TimeSpan.Zero, name + " is " + every);
        }
    }
}
