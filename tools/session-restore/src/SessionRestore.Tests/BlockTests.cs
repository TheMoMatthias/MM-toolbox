using System.Text;
using SessionRestore.Core.Transcripts;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>Plan item 2.3b - the block parser.</summary>
public sealed class BlockTests
{
    // 🔴 THE DEFECT THE ORACLE FOUND IN THE POWERSHELL, PINNED HERE SO THE C#
    // CANNOT ACQUIRE IT. `$recWhen` was assigned only in the user/assistant
    // branch, and New-Block closed over it - so every system, compact, hook,
    // file and queued block carried the PREVIOUS record's timestamp. It showed
    // up as two sides agreeing on every field of a block except `when`, 36 ms
    // apart, which is a record boundary rather than a rounding.
    [Fact]
    public void A_system_block_carries_its_own_timestamp_not_the_previous_records()
    {
        var path = Temp(
            """{"type":"assistant","timestamp":"2026-09-09T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"before"}]}}""",
            """{"type":"system","subtype":"informational","timestamp":"2026-09-09T10:00:05.000Z","content":"a notice"}""");
        try
        {
            var b = TranscriptBlocks.Read(path);
            var sys = Assert.Single(b, x => x.Kind == BlockKind.System);
            var said = Assert.Single(b, x => x.Kind == BlockKind.Said);

            Assert.NotNull(sys.When);
            Assert.NotNull(said.When);
            Assert.Equal(5, (sys.When!.Value - said.When!.Value).TotalSeconds);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void Turn_duration_records_are_dropped()
    {
        // 68 of them in a busy tail. They would be the loudest thing in the pane
        // and say the least.
        var path = Temp("""{"type":"system","subtype":"turn_duration","timestamp":"2026-09-09T10:00:00Z","content":"1234ms"}""");
        try
        {
            Assert.Empty(TranscriptBlocks.Read(path));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void An_answered_question_is_one_asked_block_and_never_a_tool_call()
    {
        // 🔴 A QUESTION YOU ANSWERED IS NOT A TOOL CALL. Drawing it as one gave
        // the argument slot a stringified object and the answer came back as a
        // run-on line of quoted pairs. The call is dropped; the RESULT carries
        // the questions and answers structurally.
        var path = Temp(
            """{"type":"assistant","timestamp":"2026-09-09T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"question":"which?"}]}}]}}""",
            """{"type":"user","timestamp":"2026-09-09T10:00:01Z","toolUseResult":{"answers":{"which?":"this one"}},"message":{"role":"user","content":[{"type":"tool_result","content":"ignored"}]}}""");
        try
        {
            var b = TranscriptBlocks.Read(path);

            Assert.DoesNotContain(b, x => x.Kind == BlockKind.Tool);
            var asked = Assert.Single(b, x => x.Kind == BlockKind.Asked);
            Assert.Equal("you answered", asked.Head);
            Assert.Equal("1", asked.Meta);
            // The halves are separated by U+0001 so neither can contain it.
            Assert.Equal("which?\u0001this one", asked.Body);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void A_backgrounded_bash_is_named_as_one()
    {
        // 🪤 run_in_background IS ON THE INPUT AND NOWHERE ELSE. The transcript
        // answers a backgrounded Bash immediately and records no shell id, so
        // this flag on the CALL is the only evidence a shell was left running.
        var path = Temp("""{"type":"assistant","timestamp":"2026-09-09T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"npm run watch","run_in_background":true,"description":"watch the build"}}]}}""");
        try
        {
            var t = Assert.Single(TranscriptBlocks.Read(path), x => x.Kind == BlockKind.Tool);
            Assert.Equal("Bash (background)", t.Head);
            Assert.Equal("watch the build", t.Meta);
            Assert.Equal("npm run watch", t.Body);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void A_message_to_a_named_pipe_is_addressed_in_words()
    {
        // 🪤 `to` IS OFTEN A NAMED PIPE, NOT A NAME. Printing that as the
        // recipient is the same defect as printing the envelope as prose.
        var path = Temp("""{"type":"assistant","timestamp":"2026-09-09T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"SendMessage","input":{"to":"uds:\\\\.\\pipe\\LOCAL\\cc-msg-e1d5","message":"the actual words"}}]}}""");
        try
        {
            var t = Assert.Single(TranscriptBlocks.Read(path), x => x.Kind == BlockKind.Tool);
            Assert.Equal("another session", t.Meta);
            Assert.Equal("the actual words", t.Body);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void A_read_file_attachment_is_its_name_and_its_size_never_its_contents()
    {
        // The attachment carries the ENTIRE FILE. Putting that in the pane would
        // bury the conversation it belongs to.
        var big = string.Join("\\n", Enumerable.Repeat("a line", 500));
        var path = Temp(
            "{\"type\":\"user\",\"timestamp\":\"2026-09-09T10:00:00Z\",\"attachment\":{\"type\":\"file\"," +
            "\"content\":{\"file\":{\"filePath\":\"C:\\\\x\\\\y\\\\big.txt\",\"content\":\"" + big + "\"}}}}");
        try
        {
            var f = Assert.Single(TranscriptBlocks.Read(path), x => x.Kind == BlockKind.File);
            Assert.Equal("read", f.Head);
            Assert.Equal("big.txt", f.Body);
            Assert.Equal("500 lines", f.Meta);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void A_plain_enqueued_prompt_is_not_drawn_twice()
    {
        // It arrives again as a user record when the session takes it, so
        // drawing it here as well would show everything typed twice. Only an
        // actual cross-session message becomes a block.
        var path = Temp("""{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-09T10:00:00Z","content":"just something I typed"}""");
        try
        {
            Assert.Empty(TranscriptBlocks.Read(path));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void A_slash_command_is_its_name_and_arguments_not_its_expansion()
    {
        // 🔴 Claude Code EXPANDS a slash command into the whole prompt body, so
        // invoking a skill of two hundred lines put two hundred lines on screen
        // in the operator's own voice.
        var text = "<command-name>/loop</command-name><command-args>every 20 minutes</command-args>" +
                   "and then two hundred lines of skill body";
        Assert.Equal("/loop every 20 minutes", UserBlocks.SlashCommandText(text));
    }

    [Theory]
    [InlineData("<system-reminder>context</system-reminder>", true)]
    [InlineData("[Cross-session idle notice] something", true)]
    [InlineData("what I actually typed", false)]
    [InlineData("what I typed <system-reminder>plus context</system-reminder>", false)]
    public void Machinery_is_told_apart_from_the_operator(string text, bool isMachine)
    {
        // 🪤 STRIPPED FOR THE TEST, KEPT FOR THE BLOCK. A real message with a
        // system-reminder appended is still a real message.
        Assert.Equal(isMachine, UserBlocks.IsMachineRecord(text));
    }

    [Fact]
    public void A_tool_argument_that_is_a_list_reads_as_a_list_not_as_json()
    {
        // The oracle found this at $.rows[495].meta: a call whose only argument
        // was an array of file paths. "a.png b.png" belongs on a reading
        // surface; ["a.png","b.png"] does not.
        var path = Temp("""{"type":"assistant","timestamp":"2026-09-09T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Whatever","input":{"files":["a.png","b.png"]}}]}}""");
        try
        {
            var t = Assert.Single(TranscriptBlocks.Read(path), x => x.Kind == BlockKind.Tool);
            Assert.Equal("a.png b.png", t.Body);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void A_long_path_keeps_the_end_that_says_which_worktree()
    {
        var s = TranscriptText.ShortenPath(@"C:\Users\mauri\Documents\Trading Bot\Python\AlgoTrader\src\thing.py");
        Assert.StartsWith("C:", s, StringComparison.Ordinal);
        Assert.EndsWith(@"AlgoTrader\src\thing.py", s, StringComparison.Ordinal);
    }

    [Fact]
    public void Terminal_escapes_go_but_layout_stays()
    {
        // 🪤 TAB AND NEWLINE ARE KEPT: they are layout in a tool result, and
        // stripping them runs a table into one line.
        var raw = "\u001B[31mred\u001B[0m\tcolumn\nnext";
        Assert.Equal("red\tcolumn\nnext", TranscriptText.RemoveAnsi(raw));
    }

    [Fact]
    public void A_record_bigger_than_the_reading_window_still_produces_blocks()
    {
        // 🔴 A TAIL CAN LAND ENTIRELY INSIDE ONE RECORD, AND THEN IT READS AS AN
        // EMPTY CONVERSATION. Measured on a 180 MB transcript: records run to
        // 916 KB against a median of 629 bytes, so whenever the newest record is
        // bigger than the window, every line in it is a fragment, the
        // whole-record filter keeps none of them, and the pane draws nothing.
        // Intermittent by construction, which is why it was reported as
        // "sometimes the tool does not show the conversation".
        //
        // 🔑 THIS IS A FIXTURE ON PURPOSE. It is the path the giant transcripts
        // exercise, and proving it here - deterministically, in milliseconds -
        // is what lets the live comparison drop them and stay fast.
        var huge = new string('x', 40_000);
        var path = Temp(
            """{"type":"assistant","timestamp":"2026-09-10T10:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"the older answer"}]}}""",
            "{\"type\":\"assistant\",\"timestamp\":\"2026-09-10T10:00:01Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"" + huge + "\"}]}}");
        try
        {
            // A window far smaller than that last record: every line in it is a
            // fragment until the read widens.
            var b = TranscriptBlocks.Read(path, maxRecords: 60, maxTailBytes: 4_096);

            Assert.NotEmpty(b);
            Assert.Contains(b, x => x.Kind == BlockKind.Said && x.Body.Length == huge.Length);
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static string Temp(params string[] records)
    {
        var p = Path.Combine(Path.GetTempPath(), "sr-blk-" + Guid.NewGuid().ToString("N") + ".jsonl");
        File.WriteAllText(p, string.Join("\n", records) + "\n", new UTF8Encoding(false));
        return p;
    }
}
