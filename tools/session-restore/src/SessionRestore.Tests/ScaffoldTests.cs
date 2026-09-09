using SessionRestore.Core;
using SessionRestore.Oracle;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>
/// Phase 1's own tests. They assert that the scaffold is actually wired to the
/// real tool and that the oracle can go red - nothing about the domain, because
/// there is no domain yet.
/// </summary>
public sealed class ScaffoldTests
{
    [Fact]
    public void The_tool_root_is_the_real_one()
    {
        // 🪤 A PATH SEARCH THAT FAILS BY FINDING THE WRONG FOLDER IS SILENT.
        // It resolves to something plausible with no data in it, which reads as
        // "no conversations" rather than as an error - so the check is that the
        // marker files are actually there, not that a string looks right.
        Assert.True(File.Exists(Path.Combine(ToolPaths.Lib, "_common.ps1")));
        Assert.True(File.Exists(Path.Combine(ToolPaths.Lib, "window2.xaml")));
        Assert.True(File.Exists(ToolPaths.Registry));
    }

    [Fact]
    public void Json_key_order_and_spacing_are_not_differences()
    {
        Assert.Null(JsonDiff.FirstDifference(
            """{ "b": 2,  "a": 1 }""",
            """{"a":1,"b":2}"""));
    }

    [Fact]
    public void A_number_written_two_ways_is_not_a_difference()
    {
        // PowerShell's ConvertTo-Json and System.Text.Json disagree about how a
        // whole number is spelled. That is a serialiser difference, not a defect,
        // and if it read as one every comparison would be red on day one and
        // ignored by day two.
        Assert.Null(JsonDiff.FirstDifference("""{"n": 3.0}""", """{"n":3}"""));
    }

    [Theory]
    [InlineData("""{"n":3}""", """{"n":4}""", "$.n")]
    [InlineData("""{"rows":[{"id":"a"}]}""", """{"rows":[{"id":"z"}]}""", "$.rows[0].id")]
    [InlineData("""{"a":1}""", """{"a":1,"b":2}""", "$.b")]
    [InlineData("""{"rows":[1,2]}""", """{"rows":[1]}""", "$.rows")]
    public void A_real_difference_is_found_and_named(string ps, string cs, string path)
    {
        var d = JsonDiff.FirstDifference(ps, cs);
        Assert.NotNull(d);
        Assert.StartsWith(path, d, StringComparison.Ordinal);
    }

    [Fact]
    public void An_answer_that_is_not_json_says_which_side()
    {
        var d = JsonDiff.FirstDifference("that is not json", """{"a":1}""");
        Assert.NotNull(d);
        Assert.Contains("PowerShell side", d, StringComparison.Ordinal);
    }

    [Fact]
    [Trait("Category", "Oracle")]
    public void The_oracle_reaches_the_real_powershell_domain()
    {
        var r = Oracle.Oracle.Compare(new OracleCase(
            "domain/loads",
            "the comparison must reach lib/_common.ps1, not an empty session",
            """
            $want = @('Get-SRRegistry','Get-SRConfig','Get-SRScreenText','Get-SRLastSaid')
            $have = @($want | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue })
            (@{ found = $have.Count; of = $want.Count } | ConvertTo-Json -Compress)
            """,
            () => """{"found":4,"of":4}"""));

        Assert.True(r.Agree, r.Difference ?? "no difference reported");
    }

    [Fact]
    [Trait("Category", "Oracle")]
    public void The_fence_refuses_the_call_that_cost_210_conversations()
    {
        // 🔴 A SAFETY NET NOBODY HAS SEEN CATCH ANYTHING IS NOT KNOWN TO BE
        // THERE. The oracle runs the old implementation thousands of times over
        // real data; this asserts that the one call which could destroy that
        // data throws instead of running.
        var run = PowerShellRunner.Run("Save-SRRegistry @{}; 'reached'");

        Assert.True(run.Failed);
        Assert.DoesNotContain("reached", run.StdOut, StringComparison.Ordinal);
        Assert.Contains("oracle fence refused Save-SRRegistry", run.StdErr, StringComparison.Ordinal);
    }

    [Fact]
    [Trait("Category", "Oracle")]
    public void The_fence_leaves_the_read_path_alone()
    {
        // 🪤 AND IT MUST NOT BE OVER-BUILT EITHER. Fencing the screen server
        // would make every console comparison measure a spawn-per-read fallback
        // that nobody ships - a fence that breaks what it protects is not a
        // fence, it is a different bug.
        var run = PowerShellRunner.Run(
            "if (Get-Command Start-SRScreenServer -ErrorAction SilentlyContinue) { 'present' } else { 'gone' }");

        Assert.False(run.Failed, run.StdErr);
        Assert.Contains("present", run.StdOut, StringComparison.Ordinal);
    }
}
