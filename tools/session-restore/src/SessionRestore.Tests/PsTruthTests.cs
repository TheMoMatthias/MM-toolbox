using System.Text.Json;
using SessionRestore.Core.Json;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>
/// PowerShell's own answer to <c>if ($value)</c>, for a value that came out of
/// <c>ConvertFrom-Json</c>.
/// </summary>
/// <remarks>
/// 🔴 THE ORACLE COVERS THE TWO SPELLINGS THAT ACTUALLY OCCUR - a boolean and
/// the string "true" - because those are what a transcript contains. These are
/// the rest of the rule, which no transcript on this machine reaches and which a
/// later caller could.
/// </remarks>
public class PsTruthTests
{
    private static JsonElement V(string json) => JsonDocument.Parse(json).RootElement.Clone();

    [Theory]
    [InlineData("true", true)]
    [InlineData("false", false)]
    [InlineData("null", false)]
    [InlineData("0", false)]
    [InlineData("1", true)]
    [InlineData("-1", true)]
    [InlineData("0.0", false)]
    [InlineData("\"\"", false)]
    [InlineData("\"true\"", true)]

    // 🪤 AND THIS ONE IS NOT A BUG. A non-empty string is true in PowerShell
    // whatever it says, so the shipped tool treats "false" as a yes - and every
    // caller of this is being compared against the shipped tool.
    [InlineData("\"false\"", true)]
    [InlineData("\"0\"", true)]
    [InlineData("\" \"", true)]
    [InlineData("{}", true)]
    [InlineData("{\"a\":1}", true)]
    [InlineData("[]", false)]
    [InlineData("[false]", false)]
    [InlineData("[true]", true)]
    [InlineData("[false,false]", true)]
    [InlineData("[0]", false)]
    [InlineData("[[]]", false)]
    public void Reads_the_way_PowerShell_does(string json, bool expected) =>
        Assert.Equal(expected, PsTruth.Of(V(json)));

    [Fact]
    public void An_absent_property_is_false() =>
        Assert.False(PsTruth.Of(V("""{"other":true}"""), "run_in_background"));

    [Fact]
    public void A_property_that_is_there_is_its_own_answer()
    {
        Assert.True(PsTruth.Of(V("""{"run_in_background":"true"}"""), "run_in_background"));
        Assert.False(PsTruth.Of(V("""{"run_in_background":false}"""), "run_in_background"));
    }

    [Fact]
    public void Anything_that_is_not_an_object_has_no_properties() =>
        Assert.False(PsTruth.Of(V("[1,2]"), "run_in_background"));
}
