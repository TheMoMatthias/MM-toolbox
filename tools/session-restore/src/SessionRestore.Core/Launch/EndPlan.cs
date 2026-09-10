namespace SessionRestore.Core.Launch;

/// <summary>What closing one conversation would come to.</summary>
public enum EndVerdict
{
    /// <summary>Nothing is holding it; there is nothing to close.</summary>
    NotRunning,

    /// <summary>
    /// Mid-turn. 🔴 Closing it now would lose the reply it is writing, and the
    /// whole promise of relaunch is that it does not interrupt work.
    /// </summary>
    MidTurn,

    /// <summary>
    /// The recorded pid is not a claude any more.
    /// 🪤 A PID IS REUSABLE, so this is NOT "it exists" - it is "the process at
    /// that number is still the claude that owned this conversation". Without
    /// the name check a relaunch would kill whatever inherited the number.
    /// </summary>
    AlreadyEnded,

    /// <summary>It is running, it is not mid-turn, and this is what would be ended.</summary>
    Close,
}

/// <summary>
/// The end half of plan item 2.5c: what would be closed, and what would be left
/// alone. A value - nothing here ends a process.
/// </summary>
/// <remarks>
/// 🔴 ONLY WHAT ACTUALLY DIES MAY BE REOPENED, and that is why the plan and the
/// act are separate values rather than one loop. In the PowerShell a
/// <c>continue</c> once skipped the rest of an iteration while leaving the row in
/// the launch set, so a process that refused to die left the OLD conversation
/// running while a NEW one started on the same transcript. Two claude processes
/// holding one file is the state this tool exists to avoid, and it arrived
/// silently. <see cref="Reopenable"/> takes the outcome of the close, not the
/// intention.
///
/// 🪤 KILLING THE PROCESSES DOES NOT CLOSE THE TAB. Measured 2026-08-28: 40 tabs
/// for 18 live sessions after one relaunch. The tab name is part of the plan so
/// it can be closed between the end and the relaunch - a title only identifies a
/// dead tab while the session that owned it is dead.
/// </remarks>
public sealed record EndPlan(
    EndVerdict Verdict,
    uint ClaudePid,
    uint? BootShellPid,
    string TabName,
    string Why)
{
    /// <summary>Only <see cref="EndVerdict.Close"/> ends anything.</summary>
    public bool EndsAnything => Verdict == EndVerdict.Close;
}

/// <summary>Builds <see cref="EndPlan"/>s. Read only.</summary>
public static class EndPlans
{
    /// <summary>The name a boot shell would be running under.</summary>
    private const string BootShellName = "powershell.exe";

    private const string ClaudeName = "claude.exe";

    /// <summary>
    /// Does this command line belong to a boot shell this tool wrote?
    /// </summary>
    /// <remarks>
    /// 🔴 THE BOOT SHELL IS ONLY ENDED WHEN IT IS RECOGNISABLY OURS. The parent
    /// of a claude is usually the little powershell.exe that ran its boot script,
    /// but it can also be a terminal the operator started by hand - and ending
    /// THAT closes a window full of unrelated work. The command line naming a
    /// script under <c>.state\boot-</c> is the evidence.
    /// </remarks>
    public static bool LooksLikeBootShell(string? commandLine)
    {
        if (string.IsNullOrEmpty(commandLine))
        {
            return false;
        }

        // PowerShell's `-like '*.state*boot-*'`: case-insensitive, and the pieces
        // must appear in order.
        var i = commandLine.IndexOf(".state", StringComparison.OrdinalIgnoreCase);
        return i >= 0 && commandLine.IndexOf("boot-", i, StringComparison.OrdinalIgnoreCase) >= 0;
    }

    /// <summary>
    /// What closing <paramref name="row"/> would do.
    /// </summary>
    /// <param name="snapshot">One process snapshot shared across a whole plan;
    /// taking one per row would ask the OS the same question a hundred times and
    /// let the answer change halfway down the list.</param>
    /// <param name="tabTitle">What the tab is called when claude has no live name
    /// for it - the row's own title.</param>
    public static EndPlan For(
        PlanRow row,
        Dictionary<uint, ProcessFacts> snapshot,
        string tabTitle,
        Func<uint, string?>? commandLineOf = null)
    {
        ArgumentNullException.ThrowIfNull(row);
        ArgumentNullException.ThrowIfNull(snapshot);

        var name = (row.Agent?.Name ?? string.Empty).Trim();
        var tab = name.Length > 0 ? name : tabTitle ?? string.Empty;

        if (!row.IsRunning)
        {
            return new EndPlan(EndVerdict.NotRunning, 0, null, tab, "nothing is holding it");
        }

        var pid = (uint)row.Agent!.Pid;
        if (row.IsBusy)
        {
            return new EndPlan(EndVerdict.MidTurn, pid, null, tab,
                "it is mid-turn - closing it now would lose the reply it is writing");
        }

        var proc = ProcessTree.Of(pid, snapshot);
        if (proc is null || !string.Equals(proc.Name, ClaudeName, StringComparison.OrdinalIgnoreCase))
        {
            return new EndPlan(EndVerdict.AlreadyEnded, pid, null, tab,
                proc is null
                    ? "nothing is running at that pid any more"
                    : "the process at that pid is " + proc.Name + ", not claude");
        }

        uint? boot = null;
        if (snapshot.TryGetValue(proc.ParentPid, out var parent)
            && string.Equals(parent.Name, BootShellName, StringComparison.OrdinalIgnoreCase)
            && LooksLikeBootShell((commandLineOf ?? ProcessTree.CommandLineOf)(parent.Pid)))
        {
            boot = parent.Pid;
        }

        return new EndPlan(EndVerdict.Close, pid, boot, tab, "running and not mid-turn");
    }

    /// <summary>
    /// Which rows a relaunch would reopen, given what actually closed.
    /// </summary>
    /// <remarks>
    /// 🔴 A ROW WHOSE CLOSE FAILED IS IN NEITHER SET. It is not reopened - that
    /// would duplicate it - and saying so beats silently corrupting a
    /// conversation. A row that was ALREADY not running is reopened, because
    /// there is nothing left to duplicate.
    /// </remarks>
    public static IReadOnlyList<PlanRow> Reopenable(
        IEnumerable<(PlanRow Row, EndPlan Plan, bool Closed)> outcomes)
    {
        ArgumentNullException.ThrowIfNull(outcomes);
        return [.. outcomes.Where(o => !o.Plan.EndsAnything || o.Closed).Select(o => o.Row)];
    }
}
