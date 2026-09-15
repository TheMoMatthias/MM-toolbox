using SessionRestore.Core.Console;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>
/// The menu probe, on shapes the sixteen captured screens do not happen to
/// contain.
/// </summary>
/// <remarks>
/// 🔑 THE ORACLE ALREADY COMPARES THE CAPTURES LINE FOR LINE, so these do not
/// repeat it. What they hold are the shapes that decide the ANSWER and that the
/// captures reach only incidentally - a run of one, a run restarted by a second
/// '1.', a numbered list disqualified by a prompt line under it, and the
/// case-insensitivity PowerShell's <c>-match</c> has and .NET's default does
/// not.
/// </remarks>
public class LiveMenuTests
{
    private static string Screen(params string[] lines) => string.Join("\n", lines);

    [Fact]
    public void NothingOnTheScreenIsNotAMenu()
    {
        Assert.Equal(-1, LiveMenu.Start(string.Empty));
        Assert.Equal(-1, LiveMenu.Start(null));
        Assert.False(LiveMenu.IsOn(string.Empty));
    }

    /// <summary>One numbered line is a paragraph, not a menu.</summary>
    [Fact]
    public void ARunOfOneIsNotAMenu()
    {
        Assert.Equal(-1, LiveMenu.Start(Screen("some prose", "1. only one", "more prose")));
    }

    [Fact]
    public void TwoConsecutiveOptionsAreAMenu()
    {
        var at = LiveMenu.Start(Screen("prose", "  1. alpha", "  2. bravo"));
        Assert.Equal(1, at);
        Assert.True(LiveMenu.IsOn(Screen("prose", "  1. alpha", "  2. bravo")));
    }

    /// <summary>
    /// 🔴 THE DEFECT THE SHIPPED PARSER WAS FIXED FOR. A numbered list in
    /// scrollback above a live menu used to capture the parse.
    /// </summary>
    [Fact]
    public void TheLastRunWins()
    {
        var s = Screen(
            "1. scrollback one",
            "2. scrollback two",
            "3. scrollback three",
            "",
            "❯ 1. the real first option",
            "  2. the real second option");
        Assert.Equal(4, LiveMenu.Start(s));
    }

    /// <summary>
    /// A run is disqualified the moment the session's own status line appears
    /// below it - everything above the input box is scrollback by definition.
    /// </summary>
    [Theory]
    [InlineData("Model: Opus 5")]
    [InlineData("  shift+tab to cycle  ")]
    [InlineData("? for shortcuts")]
    public void APromptLineUnderARunKillsIt(string prompt)
    {
        Assert.True(LiveMenu.IsPromptLine(prompt));
        Assert.Equal(-1, LiveMenu.Start(Screen("1. alpha", "2. bravo", prompt)));
    }

    /// <summary>And a run STARTED after the prompt line still counts.</summary>
    [Fact]
    public void APromptLineAboveARunDoesNot()
    {
        Assert.Equal(1, LiveMenu.Start(Screen("Model: Opus 5", "1. alpha", "2. bravo")));
    }

    /// <summary>
    /// 🪤 POWERSHELL'S <c>-match</c> IS CASE-INSENSITIVE AND .NET'S DEFAULT IS
    /// NOT. A port that missed this would call a session at its own prompt a
    /// session on a menu, on any screen whose status line was not capitalised
    /// the way the pattern is.
    /// </summary>
    [Theory]
    [InlineData("model: opus 5")]
    [InlineData("MODEL: OPUS 5")]
    [InlineData("SHIFT+TAB TO CYCLE")]
    [InlineData("? FOR SHORTCUTS")]
    public void ThePromptPatternsIgnoreCase(string line) => Assert.True(LiveMenu.IsPromptLine(line));

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("the model: is named here")]
    [InlineData("press shift+tab to cycle modes")]
    public void AndAreAnchoredWhereTheShippedOnesAre(string line)
    {
        // The middle two are the point: 'Model:' only counts at the start of the
        // line, while the cycle hint counts anywhere - which is what the shipped
        // patterns say, one anchored and one a word boundary.
        var expected = line.Contains("shift+tab to cycle", StringComparison.Ordinal);
        Assert.Equal(expected, LiveMenu.IsPromptLine(line));
    }

    /// <summary>
    /// 🪤 A NUMBERED LINE THAT IS NEITHER A '1.' NOR THE NEXT IN THE RUN IS
    /// SKIPPED, NOT A RESET - only a prompt line resets. Ported exactly, because
    /// the difference decides what a screen with an interrupted count says.
    /// </summary>
    [Fact]
    public void AnOutOfOrderNumberDoesNotEndTheRun()
    {
        Assert.Equal(0, LiveMenu.Start(Screen("1. alpha", "7. wandered off", "2. bravo")));
    }

    /// <summary>The cursor glyph is allowed in front of an option, and ignored.</summary>
    [Fact]
    public void TheHighlightDoesNotChangeWhereTheMenuStarts()
    {
        Assert.Equal(0, LiveMenu.Start(Screen("1. alpha", "❯ 2. bravo")));
    }

    /// <summary>Two digits, because a menu can have ten options.</summary>
    [Fact]
    public void TenOptionsParse()
    {
        var lines = new List<string>();
        for (var i = 1; i <= 10; i++)
        {
            lines.Add($"  {i}. option {i}");
        }

        Assert.Equal(0, LiveMenu.Start(string.Join("\n", lines)));
    }

    /// <summary>A number with nothing after the dot is prose, not an option.</summary>
    [Fact]
    public void AnEmptyOptionIsNotAnOption()
    {
        Assert.Equal(-1, LiveMenu.Start(Screen("1. ", "2. ")));
    }
}
