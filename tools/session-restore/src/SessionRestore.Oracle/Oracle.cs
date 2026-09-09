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
}

/// <summary>What a comparison found.</summary>
public sealed record OracleResult(
    string Name,
    bool Agree,
    string? Difference,
    long PsMs,
    long CsMs)
{
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
        var diff = JsonDiff.FirstDifference(ps.StdOut, cs);
        return new OracleResult(c.Name, diff is null, diff, psMs, sw.ElapsedMilliseconds);
    }

    private static string Shorten(string s)
    {
        var line = s.Replace("\r", " ", StringComparison.Ordinal)
                    .Replace("\n", " ", StringComparison.Ordinal)
                    .Trim();
        return line.Length > 300 ? line[..300] + "..." : line;
    }
}
