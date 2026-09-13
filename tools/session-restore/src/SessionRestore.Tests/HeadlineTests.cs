using SessionRestore.Core.Rows;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>Plan item 4.1 - the second line of a session row.</summary>
/// <remarks>
/// The PowerShell is an inline expression in <c>Build-Sessions</c>, not a
/// function the oracle can call:
/// <c>if ($r.Said -and "$($r.Said.Said)".Trim()) { ("$($r.Said.Said)".Trim() -replace '\s+', ' ') }
/// elseif ($r.Conv -and "$($r.Conv.Detail)") { "$($r.Conv.Detail)" }</c>.
/// Both sides run the same .NET regex engine, so the shapes below are the ones
/// where a hand port usually slips: a whitespace-only line, a non-breaking space,
/// and a line that is nothing but newlines.
///
/// 🔑 THE EXPECTED VALUES ARE THE POWERSHELL'S, not predictions: that exact
/// expression was run under PowerShell 5.1 on these shapes on 2026-09-13 and
/// printed `a b c`, `a b`, `working on it`, `idle`, `nothing known` and ``.
/// </remarks>
public sealed class HeadlineTests
{
    [Theory]
    [InlineData("done.", "x", "done.")]
    [InlineData("  a\t\tb \r\n c  ", "x", "a b c")]
    [InlineData("a\u00A0\u00A0b", "x", "a b")] // \s matches NBSP in .NET, on both sides
    [InlineData("   ", "working on it", "working on it")] // whitespace is nothing said
    [InlineData("\r\n\r\n", "idle", "idle")]
    [InlineData(null, "nothing known", "nothing known")]
    [InlineData(null, null, "")]
    [InlineData("", "", "")]
    public void The_second_line_is_what_it_said_else_what_state_it_is_in(string? said, string? detail, string expected) =>
        Assert.Equal(expected, Headline.Of(said, detail));
}
