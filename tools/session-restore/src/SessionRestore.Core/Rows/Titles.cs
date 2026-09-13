using System.Globalization;
using SessionRestore.Core.Registry;

namespace SessionRestore.Core.Rows;

/// <summary>What a conversation is called, and how old it is. Plan item 2.6.</summary>
public sealed record RowTitle(string Text, bool Derived);

/// <summary>
/// The name on the row, its lane, and the age beside it.
/// </summary>
/// <remarks>
/// 🔑 <c>Derived</c> IS PART OF THE ANSWER, not decoration. A title the operator
/// set and a title the tool guessed are drawn differently, because a guessed one
/// is a claim the window is making rather than a name the conversation has - and
/// three of the four sources here are guesses.
/// </remarks>
public static class Titles
{
    /// <summary>
    /// The four sources, in order: the recorded title, the generated one, the
    /// project's folder, then a placeholder.
    /// </summary>
    /// <remarks>
    /// 🪤 <c>(untitled)</c> IS A VALUE THE REGISTRY ACTUALLY HOLDS, not the
    /// absence of one - so it has to be rejected as explicitly as an empty
    /// string, or a conversation claude never named would be drawn as though it
    /// had been named that.
    /// </remarks>
    public static RowTitle Of(RegistrySession? session, RegistryDirectory? directory)
    {
        var t = (session?.Title ?? string.Empty).Trim();
        if (t.Length > 0 && !string.Equals(t, "(untitled)", StringComparison.Ordinal))
        {
            return new RowTitle(t, false);
        }

        var a = (session?.AutoTitle ?? string.Empty).Trim();
        if (a.Length > 0)
        {
            return new RowTitle(a, true);
        }

        var dp = directory?.Path ?? string.Empty;
        var leaf = dp.Length > 0 ? Leaf(dp) : string.Empty;
        return leaf.Length > 0 ? new RowTitle(leaf, true) : new RowTitle("(untitled)", true);
    }

    /// <summary>
    /// Which lane a conversation is on.
    /// </summary>
    /// <remarks>
    /// 🪤 A WORKTREE NAMED AFTER THE CONVERSATION INSIDE IT SAYS NOTHING TWICE.
    /// When the worktree's name already IS the title, repeating it beside the
    /// title spends a column on a word the eye has just read - so it collapses to
    /// the generic label instead.
    /// </remarks>
    public static string LaneLabel(RegistrySession? session, string title)
    {
        var lane = session?.Lane ?? string.Empty;
        if (lane.Length == 0 || string.Equals(lane, "main", StringComparison.Ordinal))
        {
            return "main";
        }

        var wt = (session?.Worktree ?? string.Empty).Trim();
        if (wt.Length == 0 || string.Equals(wt, (title ?? string.Empty).Trim(), StringComparison.Ordinal))
        {
            return "worktree";
        }

        return wt;
    }

    /// <summary>
    /// What an age READS AS, from a tick delta.
    /// </summary>
    /// <remarks>
    /// 🔑 ONE DEFINITION, DRIVEN BY A DELTA RATHER THAN A CLOCK, so it can be
    /// called in a tight loop without a system call or a date parse. Both the
    /// painted row and the change-detection fingerprint go through it, so they
    /// can never disagree about whether an age moved - which is what decides
    /// whether a row is repainted at all.
    /// </remarks>
    public static string AgeLabel(long deltaTicks)
    {
        if (deltaTicks <= 0)
        {
            return string.Empty;
        }

        // 🔴 EVERY DIVISION HERE ROUNDS TO NEAREST, AND THAT IS NOT A CHOICE -
        // it is what the shipped tool does. PowerShell's [long] and [int] casts
        // are Convert.ToInt64/ToInt32, which round half to EVEN rather than
        // truncating - so a delta of 3m31s reads "4m" and 90 seconds minus one
        // tick becomes 90 whole seconds, then 1,5 minutes, then "2m".
        //
        // 🪤 THAT LAST ONE IS WHY THIS IS WRITTEN OUT RATHER THAN LEFT AS
        // INTEGER DIVISION. C# integer division truncates, which is the
        // conventional reading of an age and disagreed with the window at every
        // half-unit boundary - found at 89,9999999 s, where the two sides said
        // "2m" and "now". The label also feeds the change-detection fingerprint,
        // so a port that truncated would have made the row and its own repaint
        // test disagree about whether an age had moved.
        var s = (long)Math.Round(deltaTicks / (double)TimeSpan.TicksPerSecond, MidpointRounding.ToEven);
        if (s < 90)
        {
            return "now";
        }

        if (s < 3600)
        {
            return Round(s / 60.0) + "m";
        }

        if (s < 86400)
        {
            return Round(s / 3600.0) + "h";
        }

        return Round(s / 86400.0) + "d";
    }

    /// <summary>
    /// The age of a moment.
    /// </summary>
    /// <remarks>
    /// 🔑 <paramref name="nowTicks"/> IS PASSED BY THE CALLERS IN A LOOP.
    /// Reading the clock is a system call, and doing it once per row cost
    /// 22,3 ms of a 193 ms build - 11,5% - so that every row could ask what time
    /// it is during a pass too short for the answer to change. The list builders
    /// hoist one reading and hand it down.
    /// </remarks>
    public static string AgeOf(long atTicks, long nowTicks = 0)
    {
        if (atTicks <= 0)
        {
            return string.Empty;
        }

        if (nowTicks <= 0)
        {
            nowTicks = DateTime.Now.Ticks;
        }

        return AgeLabel(nowTicks - atTicks);
    }

    /// <summary>Was this conversation active in the last 24 hours?</summary>
    public static bool Warm(RegistrySession? session, DateTime? now = null)
    {
        var at = session?.LastActive;
        return at is not null && at.Value.LocalDateTime > (now ?? DateTime.Now).AddHours(-24);
    }

    /// <summary>PowerShell's <c>[int]</c> cast: half to even, never truncation.</summary>
    private static string Round(double v) =>
        ((int)Math.Round(v, MidpointRounding.ToEven)).ToString(CultureInfo.InvariantCulture);

    /// <summary>PowerShell's <c>Split-Path -Leaf</c>.</summary>
    /// <remarks>
    /// 🪤 SPLIT-PATH IS PROVIDER-RELATIVE, and two of its answers are not string
    /// work at all - measured 2026-09-13: <c>C:\</c> leafs to <c>C:\</c>, and a bare
    /// <c>\</c> or <c>/</c> to the CURRENT drive's root. The port trimmed separators
    /// and answered <c>C:</c> and <c>\</c>; live data never has a drive root as a
    /// project, so only a shape built for it found the difference. A bare <c>C:</c>
    /// resolves against the current directory and is deliberately not ported: no
    /// absolute project path can be one.
    /// </remarks>
    internal static string Leaf(string dir)
    {
        var t = dir.TrimEnd('\\', '/');
        if (t.Length == 0)
        {
            return dir.Length == 0 ? dir : Path.GetPathRoot(Environment.CurrentDirectory) ?? dir;
        }

        if (t.Length == 2 && t[1] == ':' && char.IsAsciiLetter(t[0]) && dir.Length > 2)
        {
            return t + "\\";
        }

        var i = t.LastIndexOfAny(['\\', '/']);
        return i < 0 ? t : t[(i + 1)..];
    }
}
