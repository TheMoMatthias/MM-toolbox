using System.Text;
using SessionRestore.Core.Sessions;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>Plan item 2.5b - the sub-agent readers and what is running now.</summary>
public sealed class SubAgentTests : IDisposable
{
    private readonly string _root =
        Path.Combine(Path.GetTempPath(), "sr-sub-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(_root, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    [Fact]
    public void Sub_agents_live_beside_the_parent_not_inside_it()
    {
        // <project>\<session-id>\subagents\ - the path this whole reader hangs on.
        var dir = SubAgents.Directory(@"C:\p\abc-123.jsonl");
        Assert.Equal(Path.Combine(@"C:\p", "abc-123", "subagents"), dir);
    }

    [Theory]
    [InlineData("")]
    [InlineData(null)]
    public void A_conversation_with_no_path_has_no_sub_agent_directory(string? path)
        => Assert.Equal(string.Empty, SubAgents.Directory(path));

    [Fact]
    public void A_meta_that_will_not_parse_is_still_a_sub_agent_that_ran()
    {
        // 🪤 DROPPING IT WOULD UNDER-REPORT THE VERY THING THIS EXISTS TO
        // SURFACE. Name it from the file and carry on.
        var parent = Sub("agent-Explore-dead", meta: "{ this is not json", transcript: null);

        var one = Assert.Single(SubAgents.List(parent));
        Assert.Equal("agent-Explore-dead", one.Id);
        Assert.Equal("Explore-dead", one.Label);   // the stem, minus its prefix
        Assert.False(one.HasTranscript);
    }

    [Fact]
    public void A_task_agent_is_labelled_by_its_type_and_a_teammate_by_its_name()
    {
        // A Task sub-agent has an agentType and NO name; a teammate has both.
        var parent = Sub("agent-Explore-aaa",
            meta: """{"agentType":"Explore","description":"Map the review UI","toolUseId":"toolu_9"}""",
            transcript: "");
        Sub("agent-gui-builder-2-bbb",
            meta: """{"agentType":"gui-builder-2","name":"gui-builder-2","taskKind":"in_process_teammate","teamName":"session-d7","model":"claude-opus-5"}""",
            transcript: "", parent: parent);

        var all = SubAgents.List(parent);
        var task = Assert.Single(all, x => x.Id.StartsWith("agent-Explore", StringComparison.Ordinal));
        var mate = Assert.Single(all, x => x.IsTeammate);

        Assert.Equal("Explore", task.Label);
        Assert.Equal("Map the review UI", task.Description);
        Assert.Equal("toolu_9", task.ToolUseId);
        Assert.False(task.IsTeammate);

        Assert.Equal("gui-builder-2", mate.Label);
        Assert.Equal("session-d7", mate.Team);
        Assert.Equal("claude-opus-5", mate.Model);
    }

    [Fact]
    public void An_agent_with_no_transcript_can_never_be_live()
    {
        // 🪤 45 of the 374 on this machine are exactly that - metadata and no
        // transcript. A real state, and it must not look like a file that failed
        // to load. There is nothing writing, so it cannot be running.
        var parent = Sub("agent-Explore-nofile", meta: """{"agentType":"Explore"}""", transcript: null);

        var one = Assert.Single(SubAgents.List(parent));
        Assert.False(one.HasTranscript);
        Assert.False(one.IsLive());
    }

    [Fact]
    public void Whether_it_is_live_is_read_off_the_transcripts_own_clock()
    {
        var parent = Sub("agent-Explore-live", meta: """{"agentType":"Explore"}""", transcript: "{}");
        var one = Assert.Single(SubAgents.List(parent));

        Assert.True(one.IsLive(), "just written and not live");
        // 🔴 Three minutes, deliberately generous: an agent thinking for a minute
        // writes nothing, and a tighter threshold would flicker.
        Assert.False(one.IsLive(DateTimeOffset.Now.AddSeconds(SubAgents.LiveSeconds + 5)));
    }

    [Fact]
    public void The_list_is_ordered_by_the_transcripts_mtime_not_the_metas()
    {
        // 🪤 THE META IS WRITTEN ONCE AT SPAWN and never touched again, so
        // ordering by it would put a finished agent above one still writing.
        var parent = Sub("agent-old", meta: """{"agentType":"Old"}""", transcript: "{}");
        Sub("agent-new", meta: """{"agentType":"New"}""", transcript: "{}", parent: parent);

        var dir = SubAgents.Directory(parent);
        File.SetLastWriteTime(Path.Combine(dir, "agent-old.jsonl"), DateTime.Now.AddHours(-2));
        File.SetLastWriteTime(Path.Combine(dir, "agent-new.meta.json"), DateTime.Now.AddHours(-3));

        var all = SubAgents.List(parent);
        Assert.Equal("agent-new", all[0].Id);
    }

    [Fact]
    public void The_last_line_is_the_newest_thing_it_SAID()
    {
        // An agent's tail is mostly tool traffic; what answers "what is it doing"
        // is the last thing it said.
        var parent = Sub("agent-x", meta: """{"agentType":"Explore"}""", transcript: string.Join("\n",
            Assistant("""[{"type":"text","text":"an older thought"}]"""),
            Assistant("""[{"type":"text","text":"the newest thought\nand a second line"}]""")));

        Assert.Equal("the newest thought", SubAgents.LastLine(parent, "x"));
    }

    [Fact]
    public void Failing_that_it_is_the_last_tool_it_reached_for()
    {
        var parent = Sub("agent-y", meta: """{"agentType":"Explore"}""", transcript:
            Assistant("""[{"type":"tool_use","name":"Grep","input":{"pattern":"x"}}]"""));

        Assert.Equal("- Grep", SubAgents.LastLine(parent, "y"));
    }

    [Theory]
    [InlineData(@"..\..\something")]
    [InlineData("has a space")]
    [InlineData("")]
    [InlineData("waaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaay-too-long-to-be-an-id")]
    public void An_agent_id_that_is_not_an_id_never_reaches_a_path(string id)
    {
        // 🔒 IT ARRIVES FROM A TRANSCRIPT - data this tool does not write - and it
        // is about to become a filename.
        var parent = Sub("agent-z", meta: """{"agentType":"Explore"}""", transcript: "{}");
        Assert.Equal(string.Empty, SubAgents.LastLine(parent, id));
    }

    // ---- what is running -----------------------------------------------

    [Fact]
    public void A_shell_is_running_until_a_task_notification_names_it()
    {
        // 🔑 THE RULE IS EXACT AND NEEDS NO HEURISTIC: running = launched, and no
        // task-notification for that id since.
        var path = Transcript(
            Assistant("""[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"npm test","run_in_background":true,"description":"the suite"}}]"""),
            User("""[{"type":"tool_result","tool_use_id":"tu1","content":"Command running in background with ID: beq1. Output is being written to: C:\\x"}]"""));

        var one = Assert.Single(LiveTasks.Read(path));
        Assert.Equal("beq1", one.Id);
        Assert.True(one.IsShell);
        Assert.Equal("npm test", one.Command);
        Assert.Equal("the suite", one.Description);
    }

    [Fact]
    public void And_it_stops_running_when_one_does()
    {
        var path = Transcript(
            Assistant("""[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"npm test","run_in_background":true}}]"""),
            User("""[{"type":"tool_result","tool_use_id":"tu1","content":"Command running in background with ID: beq1."}]"""),
            User("""[{"type":"text","text":"<task-notification><task-id>beq1</task-id><status>completed</status></task-notification>"}]"""));

        Assert.Empty(LiveTasks.Read(path));
    }

    [Fact]
    public void An_agent_launch_is_told_from_a_shell_by_its_NAME_not_by_the_flag()
    {
        // 🪤 BOTH KINDS CARRY run_in_background. An Agent that fell into the shell
        // branch would be listed as a background command with no command line.
        var path = Transcript(
            Assistant("""[{"type":"tool_use","id":"tu1","name":"Agent","input":{"subagent_type":"Explore","run_in_background":true,"description":"map it"}}]"""),
            User("""[{"type":"tool_result","tool_use_id":"tu1","content":"Started with agentId: ag7"}]"""));

        var one = Assert.Single(LiveTasks.Read(path));
        Assert.Equal("ag7", one.Id);
        Assert.False(one.IsShell);
        Assert.Equal("Explore", one.Command);
    }

    [Fact]
    public void A_foreground_bash_is_not_a_running_shell()
    {
        var path = Transcript(
            Assistant("""[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"git status"}}]"""),
            User("""[{"type":"tool_result","tool_use_id":"tu1","content":"On branch main"}]"""));

        Assert.Empty(LiveTasks.Read(path));
    }

    [Fact]
    public void A_launch_whose_answer_names_no_id_is_dropped_rather_than_invented()
    {
        var path = Transcript(
            Assistant("""[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"x","run_in_background":true}}]"""),
            User("""[{"type":"tool_result","tool_use_id":"tu1","content":"it failed to start"}]"""));

        Assert.Empty(LiveTasks.Read(path));
    }

    [Fact]
    public void A_byte_order_mark_on_the_first_record_does_not_hide_a_launch()
    {
        // 🪤 THE BOM IS NOT WHITESPACE, so a StartsWith('{') test is FALSE on the
        // first line of any file written with one and the record is skipped in
        // silence. Caught before by a fixture rewritten through a StreamWriter
        // whose first line happened to be a LAUNCH: one running shell was
        // reported instead of two. A dropped record looks like a correct answer.
        var path = Path.Combine(_root, "bom.jsonl");
        Directory.CreateDirectory(_root);
        File.WriteAllText(path, string.Join("\n",
            Assistant("""[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"a","run_in_background":true}}]"""),
            User("""[{"type":"tool_result","tool_use_id":"tu1","content":"Command running in background with ID: one."}]""")) + "\n",
            new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));

        Assert.Single(LiveTasks.Read(path));
    }

    // ---- fixtures --------------------------------------------------------

    private string Sub(string stem, string meta, string? transcript, string? parent = null)
    {
        parent ??= Path.Combine(_root, "conv-1.jsonl");
        Directory.CreateDirectory(_root);
        if (!File.Exists(parent))
        {
            File.WriteAllText(parent, "{}\n");
        }

        var dir = SubAgents.Directory(parent);
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, stem + ".meta.json"), meta);
        if (transcript is not null)
        {
            File.WriteAllText(Path.Combine(dir, stem + ".jsonl"), transcript);
        }

        return parent;
    }

    private string Transcript(params string[] records)
    {
        Directory.CreateDirectory(_root);
        var p = Path.Combine(_root, "t-" + Guid.NewGuid().ToString("N") + ".jsonl");
        File.WriteAllText(p, string.Join("\n", records) + "\n", new UTF8Encoding(false));
        return p;
    }

    private static string Assistant(string content) =>
        """{"type":"assistant","timestamp":"2026-09-10T09:00:00.000Z","message":{"role":"assistant","content":"""
        + content + "}}";

    private static string User(string content) =>
        """{"type":"user","timestamp":"2026-09-10T09:00:01.000Z","message":{"role":"user","content":"""
        + content + "}}";
}
