using SessionRestore.Core.Sessions;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>Plan item 2.5a - the agent map.</summary>
public sealed class AgentTests
{
    [Fact]
    public void A_background_agent_reports_state_and_an_interactive_one_reports_status()
    {
        // 🪤 READING ONLY ONE OF THEM leaves half the sessions with no status at
        // all - and a session with no status is a row the board cannot place.
        var map = AgentMap.Parse("""
        [
          {"sessionId":"AAA","kind":"interactive","status":"busy","pid":123},
          {"sessionId":"BBB","kind":"agent","state":"running"}
        ]
        """);

        Assert.Equal("busy", map["aaa"].Status);
        Assert.Equal("running", map["bbb"].Status);
    }

    [Fact]
    public void Blocked_counts_as_needing_you_even_though_it_names_no_question()
    {
        // A background agent that cannot proceed without you is the same demand
        // on your attention as one that is asking.
        var map = AgentMap.Parse("""[{"sessionId":"AAA","kind":"agent","state":"blocked"}]""");
        Assert.True(map["aaa"].Needs);
    }

    [Fact]
    public void Something_it_is_waiting_for_counts_too()
    {
        var map = AgentMap.Parse("""[{"sessionId":"AAA","status":"idle","waitingFor":"an answer"}]""");
        Assert.True(map["aaa"].Needs);
        Assert.Equal("an answer", map["aaa"].WaitingFor);
    }

    [Fact]
    public void An_ordinary_idle_session_needs_nothing()
    {
        var map = AgentMap.Parse("""[{"sessionId":"AAA","status":"idle"}]""");
        Assert.False(map["aaa"].Needs);
    }

    [Fact]
    public void The_key_is_lower_cased_so_a_lookup_cannot_miss_on_case()
    {
        var map = AgentMap.Parse("""[{"sessionId":"AbC-123","status":"idle"}]""");
        Assert.True(map.ContainsKey("abc-123"));
        Assert.Equal("AbC-123", map["abc-123"].SessionId);
    }

    [Fact]
    public void A_record_with_no_session_id_is_dropped_rather_than_keyed_on_nothing()
    {
        var map = AgentMap.Parse("""[{"status":"idle"},{"sessionId":"AAA","status":"idle"}]""");
        Assert.Single(map);
    }

    [Fact]
    public void The_start_time_comes_back_as_a_time_not_a_number()
    {
        var map = AgentMap.Parse("""[{"sessionId":"AAA","status":"idle","startedAt":1757000000000}]""");
        Assert.NotNull(map["aaa"].StartedAt);
        Assert.Equal(1757000000000, map["aaa"].StartedAt!.Value.ToUnixTimeMilliseconds());
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("not json")]
    [InlineData("{\"not\":\"an array\"}")]
    public void Anything_it_cannot_read_is_an_empty_map_and_not_a_throw(string json)
    {
        // 🔴 AN EMPTY MAP IS AN HONEST ANSWER: it means "claude could not be
        // asked", and every caller falls back to the transcript. A throw would
        // take a window down over a subprocess that failed.
        Assert.Empty(AgentMap.Parse(json));
    }
}
