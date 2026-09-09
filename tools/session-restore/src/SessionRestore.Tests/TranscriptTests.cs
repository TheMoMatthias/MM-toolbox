using System.Text;
using SessionRestore.Core.Registry;
using SessionRestore.Core.Transcripts;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>Plan item 2.3 - the transcript reader.</summary>
public sealed class TranscriptTests
{
    [Theory]
    [InlineData("plain sentence", "plain sentence")]
    [InlineData("\n\n   leading blanks then text", "leading blanks then text")]
    [InlineData("## a heading\nand a line", "a heading")]
    [InlineData("- a bullet\nand a line", "a bullet")]
    [InlineData("**bold** and `code` inline", "bold and code inline")]
    [InlineData("   spaced    out     words   ", "spaced out words")]
    [InlineData("", "")]
    [InlineData("\n\n\n", "")]
    public void The_headline_is_the_first_meaningful_line(string input, string expected)
        => Assert.Equal(expected, LastSaid.FirstLine(input));

    [Fact]
    public void A_code_fence_at_the_top_is_not_the_headline()
    {
        // A conversation that opens its reply with a code block has not said
        // "```" - the first line that carries meaning is what the column wants.
        Assert.Equal("fenced first", LastSaid.FirstLine("```\nfenced first\n```\nafter the fence"));
    }

    [Fact]
    public void An_over_long_headline_is_cut_with_an_ellipsis()
    {
        var s = LastSaid.FirstLine(new string('x', 400));
        Assert.Equal(160, s.Length);
        Assert.EndsWith("...", s, StringComparison.Ordinal);
    }

    [Fact]
    public void The_body_keeps_the_END_of_a_long_message()
    {
        // 🔴 THE CAP TAKES THE TAIL, NOT THE HEAD. What is still open is written
        // at the CLOSE of a message, so a cap that kept the first 4.000
        // characters would throw away the only part anything reads this for.
        var text = new string('a', 5000) + "STILL OPEN: the thing";
        var body = LastSaid.SaidBody(text);

        Assert.Equal(4000, body.Length);
        Assert.EndsWith("STILL OPEN: the thing", body, StringComparison.Ordinal);
    }

    [Fact]
    public void A_record_written_with_a_byte_order_mark_is_not_silently_dropped()
    {
        // 🪤 claude's own transcripts have no BOM, but PowerShell 5.1's
        // `Set-Content -Encoding UTF8` writes one - so a fixture written that way
        // loses its FIRST record, silently, because a dropped line just looks
        // like a conversation that said nothing.
        var lines = TranscriptTail.WholeRecords("\uFEFF{\"a\":1}\n{\"b\":2}\n");

        Assert.Equal(2, lines.Count);
        Assert.StartsWith("{\"a\"", lines[0], StringComparison.Ordinal);
    }

    [Fact]
    public void A_fragment_left_by_the_tail_boundary_is_dropped()
    {
        // A tail starts wherever the byte count landed, which is usually inside
        // a record. That partial first line is not JSON and must not be parsed.
        var lines = TranscriptTail.WholeRecords("ent\":\"half a record\"}\n{\"whole\":true}\n");

        Assert.Single(lines);
        Assert.Equal("{\"whole\":true}", lines[0]);
    }

    [Fact]
    public void The_last_words_come_from_the_newest_assistant_record()
    {
        var path = Temp(
            Rec("user", "\"hello\""),
            Rec("assistant", "[{\"type\":\"text\",\"text\":\"an older answer\"}]"),
            Rec("assistant", "[{\"type\":\"text\",\"text\":\"the newest answer\"}]"));
        try
        {
            Assert.Equal("the newest answer", LastSaid.Read(path).Said);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void A_tool_call_after_the_text_in_one_record_is_still_reported_as_pending()
    {
        // 🪤 THE BLOCKS OF ONE RECORD ARE WALKED IN REVERSE TOO. A text block
        // followed by a tool_use in the SAME record would otherwise return on
        // the text and lose the tool that is actually running.
        var path = Temp(Rec("assistant",
            "[{\"type\":\"text\",\"text\":\"looking now\"}," +
            "{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"git status\"}}]"));
        try
        {
            var v = LastSaid.Read(path);
            Assert.Equal("looking now", v.Said);
            Assert.Equal("Bash", v.PendingTool);
            Assert.Equal("Bash(git status)", v.Pending);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void A_user_record_is_never_mistaken_for_what_it_said()
    {
        // The column answers "what did IT say", not "what did I type".
        var path = Temp(
            Rec("assistant", "[{\"type\":\"text\",\"text\":\"my answer\"}]"),
            Rec("user", "\"my question\""));
        try
        {
            Assert.Equal("my answer", LastSaid.Read(path).Said);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void A_transcript_that_is_all_tools_says_nothing_rather_than_guessing()
    {
        var path = Temp(Rec("assistant",
            "[{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{\"file_path\":\"C:\\\\x\\\\y.txt\"}}]"));
        try
        {
            var v = LastSaid.Read(path);
            Assert.Equal(string.Empty, v.Said);
            Assert.Equal("Read(C:\\x\\y.txt)", v.Pending);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void A_missing_transcript_is_silence_and_not_a_throw()
    {
        var v = LastSaid.Read(Path.Combine(Path.GetTempPath(), "sr-gone-" + Guid.NewGuid().ToString("N") + ".jsonl"));
        Assert.Same(SaidResult.Empty.Said, v.Said);
        Assert.Null(v.At);
    }

    [Fact]
    public void Every_transcript_on_this_machine_reads_without_throwing()
    {
        // 🪤 AN INVARIANT, NOT A COUNT. How many conversations exist is a fact
        // about the operator's Tuesday; that none of them makes the reader throw
        // is a fact about the reader.
        var paths = SessionRegistry.Read().AllSessions
            .Select(s => s.Jsonl)
            .Where(p => !string.IsNullOrEmpty(p) && File.Exists(p))
            .ToList();

        Assert.NotEmpty(paths);
        foreach (var p in paths)
        {
            var v = LastSaid.Read(p!);
            Assert.NotNull(v.Said);
            Assert.True(v.Said.Length <= 160, $"headline over 160 chars in {p}");
        }
    }

    private static string Rec(string type, string content) =>
        "{\"type\":\"" + type + "\",\"timestamp\":\"2026-09-09T12:00:00.000Z\"," +
        "\"message\":{\"role\":\"" + type + "\",\"content\":" + content + "}}";

    private static string Temp(params string[] records)
    {
        var p = Path.Combine(Path.GetTempPath(), "sr-jsonl-" + Guid.NewGuid().ToString("N") + ".jsonl");
        File.WriteAllText(p, string.Join("\n", records) + "\n", new UTF8Encoding(false));
        return p;
    }
}
