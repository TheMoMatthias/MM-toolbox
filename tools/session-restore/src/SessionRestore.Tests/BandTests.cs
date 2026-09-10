using SessionRestore.Core.Registry;
using SessionRestore.Core.Rows;
using SessionRestore.Core.Sessions;
using SessionRestore.Core.Transcripts;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>Plan item 2.6 - bands and titles.</summary>
public sealed class BandTests
{
    // -----------------------------------------------------------------
    // The name on the row.
    // -----------------------------------------------------------------

    [Fact]
    public void The_recorded_title_wins_and_the_placeholder_does_not_count_as_one()
    {
        // 🪤 '(untitled)' IS A VALUE THE REGISTRY HOLDS, not the absence of one.
        // Accepting it would draw a conversation claude never named as though it
        // had been named that - and hide the autoTitle that does describe it.
        Assert.Equal(new RowTitle("mine", false), Titles.Of(S(title: "mine", auto: "guessed"), D(@"C:\p\repo")));
        Assert.Equal(new RowTitle("guessed", true), Titles.Of(S(title: "(untitled)", auto: "guessed"), D(@"C:\p\repo")));
        Assert.Equal(new RowTitle("guessed", true), Titles.Of(S(title: "   ", auto: "guessed"), D(@"C:\p\repo")));
        Assert.Equal(new RowTitle("repo", true), Titles.Of(S(), D(@"C:\p\repo")));
        Assert.Equal(new RowTitle("(untitled)", true), Titles.Of(S(), D(string.Empty)));
        Assert.Equal(new RowTitle("(untitled)", true), Titles.Of(null, null));
    }

    [Fact]
    public void A_worktree_named_after_its_own_conversation_is_not_said_twice()
    {
        Assert.Equal("main", Titles.LaneLabel(S(), "anything"));
        Assert.Equal("main", Titles.LaneLabel(S(lane: "main"), "anything"));
        Assert.Equal("worktree", Titles.LaneLabel(S(lane: "wt"), "anything"));
        Assert.Equal("D2", Titles.LaneLabel(S(lane: "wt", worktree: "D2"), "some title"));
        Assert.Equal("worktree", Titles.LaneLabel(S(lane: "wt", worktree: "D2"), "D2"));
    }

    [Theory]
    [InlineData(0, "")]
    [InlineData(-5, "")]
    [InlineData(1, "now")]
    [InlineData(89, "now")]
    // 🔴 THE ROUNDING IS THE SHIPPED BEHAVIOUR, NOT A CHOICE. PowerShell's [int]
    // and [long] casts round half to EVEN rather than truncating, so 90 seconds
    // becomes 1,5 minutes and reads "2m" - and 3m30s reads "4m". A port that
    // truncated disagreed at every half-unit boundary, and the label also feeds
    // the fingerprint that decides whether to repaint a row.
    [InlineData(90, "2m")]
    [InlineData(120, "2m")]
    [InlineData(150, "2m")]
    [InlineData(210, "4m")]
    [InlineData(3599, "60m")]
    [InlineData(3600, "1h")]
    [InlineData(5400, "2h")]
    [InlineData(86399, "24h")]
    [InlineData(86400, "1d")]
    [InlineData(129600, "2d")]
    public void An_age_reads_the_way_the_window_reads_it(int seconds, string label)
        => Assert.Equal(label, Titles.AgeLabel((long)seconds * TimeSpan.TicksPerSecond));

    [Fact]
    public void Ninety_seconds_less_one_tick_still_rounds_up_to_a_whole_ninety()
    {
        // The exact input that found the difference: 89,9999999 s. PowerShell
        // rounds the seconds to 90, which is no longer "now".
        Assert.Equal("2m", Titles.AgeLabel(90 * TimeSpan.TicksPerSecond - 1));
        Assert.Equal("now", Titles.AgeLabel(89 * TimeSpan.TicksPerSecond));
    }

    // -----------------------------------------------------------------
    // Did it leave anything open?
    // -----------------------------------------------------------------

    [Theory]
    [InlineData("Everything is finished and nothing is left.", "")]
    [InlineData("I rebuilt it. Did that cover what you wanted?", "ends on a question")]
    // 🪤 A QUESTION MARK IN THE MIDDLE IS NOT A HAND-BACK. The rule is anchored
    // at the end for exactly this: prose full of rhetorical questions would put
    // every finished conversation in the open band.
    [InlineData("A question? Then more text after it.", "")]
    [InlineData("Remaining:\n- [ ] wire the reader", "an unticked box")]
    [InlineData("- [x] every box ticked", "")]
    [InlineData("The writer is still outstanding.", "names something open")]
    [InlineData("Let me know which you prefer.", "hands a decision back")]
    [InlineData("## OPEN: the cutover date", "a heading for it")]
    [InlineData("", "")]
    [InlineData("   ", "")]
    public void An_open_item_is_named_by_the_rule_that_found_it(string text, string reason)
    {
        Assert.Equal(reason, OpenItems.Reason(text));
        Assert.Equal(reason.Length > 0, OpenItems.Any(text));
    }

    [Fact]
    public void The_rules_read_the_whole_message_not_the_headline()
    {
        // 🔑 MEASURED OVER 26 LIVE CONVERSATIONS: the one-line Said the column
        // draws matched NONE of these shapes and the full message matched four.
        // The text was always there - the record threw it away.
        var headline = "I have rebuilt the index and checked it over";
        var full = headline + "\n\nShall I also drop the old one?";

        Assert.False(OpenItems.Any(headline));
        Assert.True(OpenItems.Any(full));
    }

    // -----------------------------------------------------------------
    // The band.
    // -----------------------------------------------------------------

    [Fact]
    public void A_needs_claim_with_nothing_behind_it_is_stuck_and_goes_quiet()
    {
        // 🔴 THE ONE THAT PUT A DEAD AGENT IN 'ACT ON THIS'. Measured 2026-08-23:
        // a background agent in state 'blocked', startedAt 33 DAYS earlier, no
        // pid and no transcript - sitting in NEEDS YOU while the typing path
        // refused to touch it for the very reason that made it unactionable.
        var live = SessionState.Of(A("blocked", pid: 100, needs: true));
        var dead = SessionState.Of(A("blocked", pid: 0, needs: true));

        Assert.True(live.Needs);
        Assert.False(live.Stuck);
        Assert.Equal(Bands.Needs, Bands.Of(live, null));

        Assert.False(dead.Needs);
        Assert.True(dead.Stuck);
        Assert.True(dead.Stale);
        Assert.Equal(Bands.Quiet, Bands.Of(dead, null));
    }

    [Fact]
    public void A_transcript_that_was_read_corroborates_a_needs_claim_without_a_pid()
    {
        // 🪤 A RUNNING BACKGROUND AGENT REPORTS NO PID, so the pid alone would
        // condemn every one of them. The transcript is the second half of the
        // test, not an afterthought.
        var backed = SessionState.Of(A("waiting", pid: 0, needs: true), readable: true);
        Assert.True(backed.Needs);
        Assert.False(backed.Stuck);
    }

    [Fact]
    public void A_dialog_is_told_apart_from_a_question()
    {
        // 🔑 THE DISTINCTION A TRANSCRIPT CAN NEVER MAKE. A permission dialog
        // writes nothing to the transcript, so a session sitting on one looked
        // identical to one mid-tool-call - and that is exactly the case the
        // operator most wants to see.
        Assert.Equal("a dialog is open, it wants an answer",
            SessionState.Of(A("waiting", pid: 9, needs: true, waitingFor: "DIALOG OPEN")).Detail);
        Assert.Equal("input needed",
            SessionState.Of(A("waiting", pid: 9, needs: true, waitingFor: "input needed")).Detail);
        Assert.Equal("waiting for you",
            SessionState.Of(A("waiting", pid: 9, needs: true)).Detail);
    }

    [Fact]
    public void An_unrecognised_status_is_reported_and_never_guessed_at()
    {
        // claude is free to add one, and a guess here would be a lie.
        var s = SessionState.Of(A("reticulating", pid: 5));
        Assert.Equal("unknown", s.State);
        Assert.Equal("claude reports 'reticulating'", s.Detail);
        Assert.Equal(Bands.Quiet, Bands.Of(s, null));
    }

    [Fact]
    public void Nothing_running_and_nothing_read_is_quiet()
    {
        Assert.Equal(Bands.Quiet, Bands.Of(SessionState.Of(null), null));
        Assert.Equal(Bands.Quiet, Bands.Of(null, null));
        Assert.True(SessionState.Nothing.Stale);
    }

    [Fact]
    public void A_resting_conversation_is_done_open_or_neither()
    {
        var enough = new string('x', Bands.HandbackMinChars + 5);
        var idle = SessionState.Of(A("idle", pid: 7));

        // Nothing said yet: idle, not done. An unread conversation must not be
        // reported as having handed back.
        Assert.Equal(Bands.Idle, Bands.Of(idle, null));

        // 🪤 Too short to be a hand-back. A one-word reply is a pause.
        Assert.Equal(Bands.Idle, Bands.Of(idle, Said("ok", "ok")));

        // 🪤 A tool still pending is not resting, whatever the status says.
        Assert.Equal(Bands.Idle, Bands.Of(idle, Said(enough, enough, pending: "Bash")));

        Assert.Equal(Bands.Done, Bands.Of(idle, Said(enough, enough)));
        Assert.Equal(Bands.Open, Bands.Of(idle, Said(enough, "Done the first bit. Shall I do the rest?")));
    }

    [Fact]
    public void A_dismissal_is_per_message_and_comes_back_when_anything_new_is_said()
    {
        // 🔑 The stamp of the message that was waved off is what is stored, so
        // the flag returns the moment the conversation says something new. A
        // permanent dismissal would be a way to hide a session from yourself for
        // good, which is not recoverable from the board.
        var idle = SessionState.Of(A("idle", pid: 7));
        var at = new DateTimeOffset(2026, 9, 10, 12, 0, 0, TimeSpan.Zero);
        var said = Said(new string('x', 60), "Shall I carry on?", at: at);
        var stamp = at.LocalDateTime.Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture);

        Assert.Equal(Bands.Open, Bands.Of(idle, said));
        Assert.Equal(Bands.Done, Bands.Of(idle, said, dismissedStamp: stamp));

        // Something new was said: the stamp no longer matches, so it is open again.
        var newer = Said(new string('x', 60), "Shall I carry on?", at: at.AddMinutes(1));
        Assert.Equal(Bands.Open, Bands.Of(idle, newer, dismissedStamp: stamp));
    }

    [Fact]
    public void An_unreadable_stamp_never_means_dismissed()
    {
        // 🔴 A cheap identity proxy that cannot be read must not answer
        // "unchanged" - here that would hide a conversation which is asking for
        // something.
        var idle = SessionState.Of(A("idle", pid: 7));
        var said = Said(new string('x', 60), "Shall I carry on?", at: null);
        Assert.Equal(Bands.Open, Bands.Of(idle, said, dismissedStamp: "12345"));
    }

    [Fact]
    public void A_seen_menu_promotes_any_live_band_and_never_a_quiet_one()
    {
        // 🪤 'quiet' IS EXCLUDED BECAUSE OF A FACT, NOT A POLICY. A conversation
        // reaches quiet by being stuck, stale, or having no process - none of
        // which has a screen a menu could have been seen on, so a flag surviving
        // on such a row is stale by definition.
        var enough = new string('x', 60);
        Assert.Equal(Bands.Needs, Bands.Of(SessionState.Of(A("busy", pid: 7)), null, askSeen: true));
        Assert.Equal(Bands.Needs, Bands.Of(SessionState.Of(A("idle", pid: 7)), Said(enough, enough), askSeen: true));
        Assert.Equal(Bands.Quiet, Bands.Of(SessionState.Of(A("reticulating", pid: 7)), null, askSeen: true));
        Assert.Equal(Bands.Quiet, Bands.Of(SessionState.Of(A("blocked", pid: 0, needs: true)), null, askSeen: true));
    }

    // -----------------------------------------------------------------
    // The rail, and what is on screen.
    // -----------------------------------------------------------------

    [Fact]
    public void The_rail_bands_are_midnight_relative_and_taken_once()
    {
        var now = new DateTime(2026, 9, 10, 14, 30, 0, DateTimeKind.Local);
        var cuts = RailCuts.At(now);

        Assert.Equal("today", cuts.KeyFor(now.Ticks));
        Assert.Equal("today", cuts.KeyFor(now.Date.Ticks));
        Assert.Equal("week", cuts.KeyFor(now.Date.Ticks - 1));
        Assert.Equal("week", cuts.KeyFor(now.Date.AddDays(-7).Ticks));
        Assert.Equal("month", cuts.KeyFor(now.Date.AddDays(-7).Ticks - 1));
        Assert.Equal("month", cuts.KeyFor(now.Date.AddDays(-30).Ticks));
        Assert.Equal("older", cuts.KeyFor(now.Date.AddDays(-30).Ticks - 1));
        Assert.Equal("older", cuts.KeyFor(0));
    }

    [Fact]
    public void What_you_are_reading_stays_on_screen()
    {
        // 🔴 The refresh runs every six seconds. Without this a conversation
        // could drop off the surface mid-read and the rebuild would silently
        // select a DIFFERENT one in its place.
        var cold = S();
        cold.LastActive = DateTimeOffset.UtcNow.AddDays(-9);

        Assert.False(Surface.Shows(false, false, "a", null, cold));
        Assert.True(Surface.Shows(false, false, "a", "a", cold));
        Assert.False(Surface.Shows(false, false, "a", "b", cold));

        // Live and warm each carry it on their own.
        Assert.True(Surface.Shows(true, false, "a", null, cold));
        Assert.True(Surface.Shows(false, true, "a", null, cold));
    }

    [Fact]
    public void With_no_warm_verdict_it_falls_back_to_reading_the_date()
    {
        var warm = S();
        warm.LastActive = DateTimeOffset.UtcNow.AddHours(-1);
        var cold = S();
        cold.LastActive = DateTimeOffset.UtcNow.AddHours(-25);

        Assert.True(Surface.Shows(false, null, "a", null, warm));
        Assert.False(Surface.Shows(false, null, "a", null, cold));
        Assert.True(Surface.Shows(false, null, "a", "a", cold));
        Assert.False(Surface.Shows(false, null, "a", null, null));
    }

    // -----------------------------------------------------------------

    private static AgentStatus A(string status, int pid = 0, bool needs = false, string waitingFor = "")
        => new("id", status, waitingFor, needs, pid, "interactive", string.Empty, string.Empty, null);

    private static SaidResult Said(string said, string full, string pending = "", DateTimeOffset? at = null)
        => new(said, pending, string.Empty, at, full);

    private static RegistrySession S(string title = "", string auto = "", string lane = "", string worktree = "")
        => new()
        {
            SessionId = "id",
            Title = title,
            AutoTitle = auto,
            Lane = lane,
            Worktree = worktree,
        };

    private static RegistryDirectory D(string path) => new() { Path = path };
}
