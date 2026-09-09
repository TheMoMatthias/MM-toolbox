using SessionRestore.Core.Console;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>Plan item 2.4a - the console reader.</summary>
/// <remarks>
/// 🔴 NOTHING HERE READS A REAL SESSION, AND NOTHING ANYWHERE HERE WRITES TO
/// ONE. The live comparison is the oracle's job, where it is done once and
/// deliberately; these are the parts that can be checked without going near the
/// operator's conversations.
/// </remarks>
public sealed class ScreenTests
{
    [Fact]
    public void The_helper_is_built_and_findable()
    {
        // 🪤 A PATH SEARCH THAT FAILS BY FINDING NOTHING IS SILENT. Without this,
        // every screen read would come back "!nohelper" and read as "the session
        // had nothing on screen" rather than as "the tool is not assembled".
        Assert.NotNull(ScreenReader.HelperPath);
        Assert.True(File.Exists(ScreenReader.HelperPath));
        Assert.EndsWith("sr-screen.exe", ScreenReader.HelperPath!, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void A_process_that_is_not_there_says_so_rather_than_throwing()
    {
        // 🪤 A SESSION THAT EXITED BETWEEN BEING LISTED AND BEING READ IS AN
        // ORDINARY EVENT, several times an hour. It has to be told apart from a
        // session that said nothing, and it must not throw: this runs on a timer
        // behind a window that has to stay responsive.
        //
        // Pid 0 is the System Idle Process and can never be attached to.
        var text = ScreenReader.Read(0);

        Assert.StartsWith("!", text, StringComparison.Ordinal);
        Assert.Contains("attach", text, StringComparison.Ordinal);
    }

    [Fact]
    public void A_refusal_is_never_mistaken_for_a_screen()
    {
        // The '!' prefix is the whole protocol between the helper and its caller,
        // so it is worth one test that it survives the round trip through a file.
        var text = ScreenReader.Read(0, attributes: true);
        Assert.StartsWith("!", text, StringComparison.Ordinal);
    }

    [Fact]
    public void Reading_leaves_no_file_behind()
    {
        // A leaked temp degrades every later session on this machine, and this
        // path runs several times a second.
        var before = Directory.Exists(Core.ToolPaths.State)
            ? Directory.GetFiles(Core.ToolPaths.State, "screen-*.txt").Length
            : 0;

        _ = ScreenReader.Read(0);

        var after = Directory.GetFiles(Core.ToolPaths.State, "screen-*.txt").Length;
        Assert.Equal(before, after);
    }
}
