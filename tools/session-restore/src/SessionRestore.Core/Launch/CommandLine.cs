using System.Text.RegularExpressions;

namespace SessionRestore.Core.Launch;

/// <summary>
/// Plan item 2.5c - the command line a launch WOULD use. It is a value; nothing
/// here starts a process.
/// </summary>
/// <remarks>
/// 🔴 THIS IS THE PIECE WHOSE DEFECTS ARE INVISIBLE UNTIL A TAB DIES. Measured
/// on 2026-08-18 by dumping the receiver's argv: PowerShell's
/// <c>Start-Process -ArgumentList @(...)</c> joins the array with spaces and
/// quotes NOTHING, so a directory under "Trading Bot" arrived as
/// <c>-d [C:\Users\mauri\Documents\Trading]</c> plus a stray
/// <c>[Bot\Python\...\D2]</c>. wt.exe took the fragment as the command to RUN and
/// every AlgoTrader tab died with 0x80070002 while space-free repos launched
/// fine. 🔑 The tell in that error is that the failing command line starts
/// MID-PATH.
///
/// 🪤 AND IT CANNOT BE PROVEN BY LAUNCHING. The operator runs sessions he cannot
/// relaunch; opening a conversation to check the tool's own quoting is exactly
/// the thing that is never allowed. So the PowerShell was split the same way -
/// <c>Get-SRLaunchCommandLine</c> returns the string and <c>Start-SRSession</c>
/// is the only caller that hands it to a process - and the oracle compares the
/// two strings over real paths.
/// </remarks>
public static class CommandLine
{
    // CommandLineToArgvW rules, which is how wt.exe and powershell.exe both
    // build their argv: a backslash is literal EXCEPT in the run immediately
    // preceding a quote (the closing one included), where each must be doubled;
    // an embedded quote becomes \".
    private static readonly Regex BeforeQuote = new(@"(\\*)""", RegexOptions.Compiled);
    private static readonly Regex AtEnd = new(@"(\\+)$", RegexOptions.Compiled);

    /// <summary>One argument, quoted so the receiver's argv splits where we meant.</summary>
    public static string Quote(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        var e = BeforeQuote.Replace(value, @"$1$1\""");
        e = AtEnd.Replace(e, "$1$1");
        return "\"" + e + "\"";
    }

    /// <summary>
    /// What <c>wt.exe</c> would be given to open one conversation in a new tab.
    /// </summary>
    /// <remarks>
    /// 🔴 A SEMICOLON IN A PATH IS A REFUSAL, NOT AN ESCAPE. wt splits its OWN
    /// argv on a bare ';' to begin a second command and quoting does not take
    /// that away, so a path containing one would run something nobody asked for.
    /// It is legal in a Windows path and effectively never present - refusing is
    /// cheap and launching is not. A title is cosmetic, so that one is sanitised
    /// to a comma instead of thrown on.
    /// </remarks>
    /// <exception cref="ArgumentException">A path contains ';'.</exception>
    public static string ForNewTab(string dir, string bootScript, string title)
    {
        ArgumentNullException.ThrowIfNull(dir);
        ArgumentNullException.ThrowIfNull(bootScript);
        ArgumentNullException.ThrowIfNull(title);

        foreach (var p in new[] { dir, bootScript })
        {
            if (p.Contains(';', StringComparison.Ordinal))
            {
                throw new ArgumentException(
                    "Refusing to launch: ';' in a path is a command separator to wt.exe -- " + p);
            }
        }

        return string.Join(' ',
            "-w", "0", "new-tab",
            "--title", Quote(title.Replace(';', ',')),
            "-d", Quote(dir),
            "powershell.exe", "-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", Quote(bootScript));
    }
}
