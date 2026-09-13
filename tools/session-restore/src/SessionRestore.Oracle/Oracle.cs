using System.Diagnostics;

namespace SessionRestore.Oracle;

/// <summary>One side-by-side comparison of the old implementation and the new.</summary>
/// <remarks>
/// 🔑 THE C# SIDE IS HANDED THE POWERSHELL'S ANSWER, and that is not cheating -
/// it is what lets a comparison ASK ABOUT THE SAME THINGS. Many of these
/// questions are of the form "for these 434 conversations, do you agree?", and
/// the list of 434 is the QUESTION, not the answer. A C# side that had to
/// enumerate them itself would be testing two things at once and would report a
/// difference in the enumeration as a difference in the answer.
///
/// 🪤 What it must never do is read the VALUES out of that string and hand them
/// back. Every case here computes its own answers; the input is used to decide
/// what to compute them about.
/// </remarks>
public sealed record OracleCase(
    string Name,
    string Why,
    string PowerShell,
    Func<string, string> CSharp)
{
    /// <summary>For a comparison that needs no input from the other side.</summary>
    public OracleCase(string name, string why, string powerShell, Func<string> csharp)
        : this(name, why, powerShell, _ => csharp())
    {
    }

    /// <summary>
    /// A difference this case is allowed to have, and why.
    /// </summary>
    /// <remarks>
    /// 🔴 A NAMED ALLOWANCE, NEVER A SILENT ONE. Some comparisons are against
    /// something that MOVES - a live session's screen changes while it is being
    /// read - and a harness with no way to say so has only two options, both
    /// bad: report a working implementation as broken on any busy afternoon, or
    /// quietly copy one side's answer to the other. The first gets the harness
    /// switched off; the second is the one thing its contract forbids.
    ///
    /// 🪤 IT TAKES THE DIFFERENCE TEXT, so an allowance can only ever match a
    /// SHAPE somebody wrote down. It cannot be "ignore failures in this case",
    /// and every use of it prints what it forgave.
    /// </remarks>
    public Func<string, bool>? Tolerate { get; init; }

    /// <summary>What the allowance is for, printed whenever it is used.</summary>
    public string ToleranceReason { get; init; } = string.Empty;
}

/// <summary>What a comparison found.</summary>
public sealed record OracleResult(
    string Name,
    bool Agree,
    string? Difference,
    long PsMs,
    long CsMs)
{
    /// <summary>A difference this case's named allowance let through, if any.</summary>
    public string? Forgave { get; init; }

    public bool Inconclusive => Difference is not null && Difference.StartsWith("could not run", StringComparison.Ordinal);
}

/// <summary>
/// Runs a PowerShell function and its C# replacement on the SAME input and
/// reports whether they said the same thing.
/// </summary>
/// <remarks>
/// 🔑 THIS IS WHAT MAKES A ONE-PASS REBUILD SAFE, and it is only available
/// because the rewrite is happening BESIDE a working implementation instead of
/// instead of one. "The C# looks right" is not a check. "The same 434
/// conversations, the same 1 MB registry, the same live console, and the same
/// answer" is.
///
/// 🪤 A COMPARISON THAT CANNOT RUN MUST NOT READ AS AGREEMENT. If the
/// PowerShell side throws, there is no answer to compare against - that is a
/// third state, not a pass and not a fail. A harness that cannot tell must not
/// print green; see the gate-that-abstains note in the ledger.
/// </remarks>
public static class Oracle
{
    public static OracleResult Compare(OracleCase c)
    {
        ArgumentNullException.ThrowIfNull(c);

        var sw = Stopwatch.StartNew();
        var ps = PowerShellRunner.Run(c.PowerShell);
        sw.Stop();
        var psMs = sw.ElapsedMilliseconds;

        if (ps.Failed)
        {
            var why = ps.StdErr.Trim();
            if (why.Length == 0)
            {
                why = "exit code " + ps.ExitCode.ToString(System.Globalization.CultureInfo.InvariantCulture);
            }

            return new OracleResult(c.Name, false, "could not run the PowerShell side: " + Shorten(why), psMs, 0);
        }

        sw.Restart();
        string cs;
        try
        {
            cs = c.CSharp(ps.StdOut) ?? string.Empty;
        }
#pragma warning disable CA1031 // the whole job here is to REPORT a failure, not to propagate it
        catch (Exception ex)
#pragma warning restore CA1031
        {
            sw.Stop();
            return new OracleResult(c.Name, false, "the C# side threw: " + ex.GetType().Name + ": " + ex.Message, psMs, sw.ElapsedMilliseconds);
        }

        sw.Stop();

        // 🔴 EVERY DIFFERENCE, NOT THE FIRST, because a case with a named
        // allowance passes only when ALL of them are ones it named. Applying a
        // tolerance to the first difference alone would let a forgiven row hide
        // every real difference behind it.
        //
        // 🔴 AND UNCAPPED WHEN THERE IS AN ALLOWANCE. The walk stopped at fifty,
        // so a conversation that grew - eight marked fields a block, a few
        // hundred blocks - filled all fifty with forgivable differences, and a
        // corrupted field further down was never reached. The case printed
        // green over a deliberate break. Measured 2026-09-13 on
        // transcript/blocks-detail; the cap stays only where nothing is forgiven
        // and the first difference is all that is reported anyway.
        var diffs = JsonDiff.Differences(ps.StdOut, cs, c.Tolerate is null ? 50 : int.MaxValue);
        if (diffs.Count == 0)
        {
            return new OracleResult(c.Name, true, null, psMs, sw.ElapsedMilliseconds);
        }

        if (c.Tolerate is not null && diffs.TrueForAll(d => c.Tolerate(d)))
        {
            return new OracleResult(c.Name, true, null, psMs, sw.ElapsedMilliseconds)
            {
                Forgave = diffs.Count.ToString(System.Globalization.CultureInfo.InvariantCulture)
                          + " difference(s), first: " + diffs[0],
            };
        }

        // Report the first one this case did NOT name, which is the one worth
        // reading - not the first one overall.
        var real = diffs.Find(d => c.Tolerate is null || !c.Tolerate(d)) ?? diffs[0];
        return new OracleResult(c.Name, false, real, psMs, sw.ElapsedMilliseconds);
    }

    private static string Shorten(string s)
    {
        var line = s.Replace("\r", " ", StringComparison.Ordinal)
                    .Replace("\n", " ", StringComparison.Ordinal)
                    .Trim();
        return line.Length > 300 ? line[..300] + "..." : line;
    }
}
