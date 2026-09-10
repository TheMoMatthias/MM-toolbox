using SessionRestore.Core.Registry;
using SessionRestore.Core.Sessions;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.Core.Launch;

/// <summary>One conversation, as the two logon buttons see it.</summary>
public sealed record PlanRow(
    string Id,
    RegistrySession Session,
    RegistryDirectory Directory,
    AgentStatus? Agent)
{
    /// <summary>Running, as claude itself reports it - not as the registry remembers.</summary>
    public bool IsRunning => Agent is not null && Agent.Pid != 0;

    /// <summary>
    /// Mid-turn. 🔴 'busy' is claude's OWN word for a turn in progress; anything
    /// else that is running - idle, waiting, sitting at a login prompt - is safe
    /// to take. A conversation mid-turn is never taken, because the whole promise
    /// of relaunch is that it does not interrupt work.
    /// </summary>
    public bool IsBusy => Agent is not null && Agent.IsBusy;
}

/// <summary>What the ticked set would do, bucketed. Plan item 2.5c.</summary>
/// <remarks>
/// 🔴 THE TWO LOGON BUTTONS DO DIFFERENT THINGS TO THE SAME SET.
/// <c>Open not running</c> starts the ticked conversations nothing is holding.
/// <c>Relaunch sessions</c> CLOSES the ticked ones that ARE running and opens
/// them again - which is what you do after signing in, because a session reads
/// your login and its remote name at startup and neither can be picked up
/// without a restart.
/// </remarks>
public sealed record TickedPlan(
    IReadOnlyList<PlanRow> Fresh,
    IReadOnlyList<PlanRow> Restart,
    IReadOnlyList<PlanRow> Busy,
    IReadOnlyList<BlockedRow> Blocked);

/// <summary>A ticked conversation that would not open, and the reason.</summary>
public sealed record BlockedRow(PlanRow Row, string Why);

/// <summary>A live name that outranks the registry's, and would be adopted.</summary>
public sealed record NameAdoption(string Id, string Live, string Recorded);

/// <summary>The cap, applied and SAID OUT LOUD - a truncated list reads exactly like a complete one.</summary>
public sealed record Capped(IReadOnlyList<PlanRow> Go, int Over, int Cap);

/// <summary>
/// What a launch WOULD do. Plan item 2.5c, and every method here returns a
/// value.
/// </summary>
/// <remarks>
/// 🔴 THERE IS NO METHOD IN THIS ASSEMBLY THAT LAUNCHES OR ENDS A CONVERSATION,
/// AND THAT IS THE POINT OF THE SHAPE. The operator runs sessions he cannot
/// relaunch; a rebuild proving its launch path by launching something is the one
/// experiment that is never worth running. The PowerShell answers the same
/// questions the same way - <c>Get-LaunchBlock</c> and <c>Get-TickedPlan</c>
/// return a plan rather than performing one - so the two can be compared as
/// values, and only Phase 4 adds the single call that turns a plan into
/// processes.
/// </remarks>
public static class LaunchPlan
{
    /// <summary>
    /// A session opened seconds ago has no claude.exe yet - the boot shell is
    /// still starting one. Without this window, pressing the button twice opens
    /// everything twice.
    /// </summary>
    public static readonly TimeSpan JustLaunchedWindow = TimeSpan.FromSeconds(90);

    /// <summary>
    /// Why this conversation would NOT be opened, or null if it would go.
    /// </summary>
    /// <remarks>
    /// 🔑 EVERY CHECK HERE IS ONE THE LOGON RESTORE ALREADY APPLIES, so this
    /// button and restore-sessions.ps1 can never disagree about what is
    /// launchable. Two sets of launch rules is two chances to be right in only
    /// one of them.
    /// </remarks>
    /// <param name="launchedAt">When this conversation was last launched by this
    /// window, if it was.</param>
    /// <param name="now">Injected so the 90-second window is testable without
    /// waiting 90 seconds.</param>
    public static string? Blocked(PlanRow row, DateTime? launchedAt = null, DateTime? now = null)
    {
        ArgumentNullException.ThrowIfNull(row);
        var s = row.Session;
        if (s.Gone)
        {
            return "its transcript is gone from disk";
        }

        var cwd = s.Cwd.Length > 0 ? s.Cwd : row.Directory.Path;
        if (!Directory.Exists(cwd))
        {
            return "its directory no longer exists: " + cwd;
        }

        var jsonl = TranscriptPath.For(cwd, s.SessionId, s.Jsonl);
        if (jsonl.Length == 0 || !TranscriptPath.Exists(jsonl))
        {
            return "its transcript is missing - press Rescan";
        }

        if (launchedAt is not null
            && ((now ?? DateTime.Now) - launchedAt.Value) < JustLaunchedWindow)
        {
            return "it was launched a moment ago";
        }

        return null;
    }

    /// <summary>
    /// The ticked set, split into what would open, what would be restarted, what
    /// is mid-turn and what is blocked.
    /// </summary>
    /// <remarks>
    /// 🔴 THE LIVE NAME OUTRANKS THE REGISTRY, and getting this wrong UNDOES the
    /// operator's own work. A conversation renamed by hand reports the new name
    /// through claude while the registry still holds whatever discovery last
    /// read. Relaunching from the registry would pass the stale title to
    /// <c>-n</c> and rename it BACK - silently, inside an action pressed to FIX
    /// names. The adoptions are RETURNED rather than applied, because a function
    /// asked for a plan must not dirty the registry; only the button about to
    /// launch writes them.
    /// </remarks>
    public static TickedPlan Ticked(
        IEnumerable<PlanRow> rows,
        Func<PlanRow, DateTime?>? launchedAt = null,
        DateTime? now = null,
        ICollection<NameAdoption>? adoptions = null)
    {
        ArgumentNullException.ThrowIfNull(rows);

        var fresh = new List<PlanRow>();
        var restart = new List<PlanRow>();
        var busy = new List<PlanRow>();
        var blocked = new List<BlockedRow>();

        foreach (var r in rows)
        {
            if (r.Directory.Missing || !r.Directory.Enabled || !r.Session.Enabled)
            {
                continue;
            }

            if (r.IsRunning)
            {
                var live = (r.Agent!.Name ?? string.Empty).Trim();
                if (adoptions is not null
                    && live.Length > 0
                    && !string.Equals(live, "(untitled)", StringComparison.Ordinal)
                    && !string.Equals(live, r.Session.Title, StringComparison.Ordinal))
                {
                    adoptions.Add(new NameAdoption(r.Id, live, r.Session.Title));
                }

                (r.IsBusy ? busy : restart).Add(r);
                continue;
            }

            var why = Blocked(r, launchedAt?.Invoke(r), now);
            if (why is not null)
            {
                blocked.Add(new BlockedRow(r, why));
            }
            else
            {
                fresh.Add(r);
            }
        }

        return new TickedPlan(Newest(fresh), Newest(restart), busy, blocked);
    }

    /// <summary>
    /// The <c>maxSessions</c> cap.
    /// </summary>
    /// <remarks>
    /// 🔑 <paramref name="already"/> COUNTS WHAT THE SAME ACTION HAS ALREADY
    /// COMMITTED TO, so two calls can share one cap. Relaunch needs it: it
    /// restarts the running set and opens the not-running set in one press, and
    /// the cap is about how many sessions the machine ends up with - not how many
    /// each half started.
    /// </remarks>
    public static Capped Cap(IReadOnlyList<PlanRow> items, int cap, int already = 0)
    {
        ArgumentNullException.ThrowIfNull(items);
        if (cap <= 0)
        {
            return new Capped(items, 0, cap);
        }

        var room = Math.Max(0, cap - already);
        return items.Count > room
            ? new Capped([.. items.Take(room)], items.Count - room, cap)
            : new Capped(items, 0, cap);
    }

    /// <summary>Newest first. An unparseable timestamp sorts as the epoch, never throws.</summary>
    private static List<PlanRow> Newest(List<PlanRow> rows)
    {
        // 🪤 THIS SORT IS STABLE AND POWERSHELL 5.1's IS NOT - Sort-Object gained
        // -Stable only in PowerShell 6 - so two conversations sharing a
        // lastActive to the tick can come back in a different ORDER from the two
        // sides. It is a real difference, it is named in the oracle case rather
        // than normalised away, and stable is the better behaviour to keep: a
        // launch order that changes run to run for no visible reason is worse
        // than one that does not.
        return [.. rows.OrderByDescending(r => r.Session.LastActive ?? DateTimeOffset.MinValue)];
    }
}
