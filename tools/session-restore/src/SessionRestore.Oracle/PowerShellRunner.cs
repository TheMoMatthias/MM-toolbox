using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace SessionRestore.Oracle;

/// <summary>
/// Runs a snippet against the LIVE PowerShell domain (lib/_common.ps1), with
/// every function that could change something replaced first.
/// </summary>
public static class PowerShellRunner
{
    // 🔴 THE FENCE, AND IT IS A LIST OF REAL FUNCTION NAMES, NOT A CATEGORY.
    // Read out of lib/_common.ps1 rather than remembered: these are the ones
    // that launch a session, type into one, drive its menus, focus a window, or
    // write the registry or the config.
    //
    // The operator runs two dozen conversations he cannot relaunch, and a
    // registry-overwrite bug in this repo's history cost 210 of them. The oracle
    // exists to run the old code thousands of times on real data - which is
    // exactly the shape of thing that reaches one of these by accident.
    //
    // 🪤 STUBS GO AFTER THE DOT-SOURCE, NEVER BEFORE. A function defined before
    // the file is loaded is simply overwritten by it, and the fence would be
    // silently absent while looking present.
    //
    // 🪤 Start-SRScreenServer and Stop-SRScreenServer are deliberately NOT here.
    // They are the READ path - the held-open pipe that makes a screen read 3,6 ms
    // instead of a process spawn - and stubbing them would make every console
    // comparison measure a fallback nobody ships.
    internal static readonly string[] FencedNames =
    [
        "Start-SRSession", "Start-SRHiddenSession",
        "Send-SRSessionInput", "Send-SRQuestionAnswer", "Send-SRInterrupt",
        "Invoke-SRAnswerOnScreen", "Invoke-SRAnswerMultiOnScreen",
        "Invoke-SRAnswerTypedOnScreen", "Invoke-SRRoundMove",
        "Save-SRRegistry", "Set-SRRegistryStamp",
        "Set-SRConfigOnDisk", "Save-SRConfigValue", "Save-SRConfigLater", "Save-SRConfigWrites",
        "Invoke-SRRescan", "Invoke-SRJumpToSession",
    ];

    /// <summary>Where the PowerShell tool lives - the folder holding lib\.</summary>
    /// <remarks>Core already has to find this, so it owns it; two copies of a
    /// path search is two places for it to be right in only one of them.</remarks>
    public static string ToolRoot => Core.ToolPaths.Root;

    /// <summary>
    /// Runs <paramref name="script"/> with the domain loaded and the fence in
    /// place, in the SHARED session - see PsSession for why that matters.
    /// </summary>
    public static PsRun Run(string script, TimeSpan? timeout = null)
        => PsSession.Instance.Run(script, timeout);

    /// <summary>
    /// The same thing in a throwaway process. Kept because it is the only way
    /// to answer "is this a real difference, or has the shared session been
    /// left in a state by something earlier?" - a question the kept session
    /// cannot answer about itself.
    /// </summary>
    public static PsRun RunIsolated(string script, TimeSpan? timeout = null)
    {
        ArgumentNullException.ThrowIfNull(script);

        var sb = new StringBuilder();
        sb.AppendLine("$ErrorActionPreference = 'Stop'");
        sb.AppendLine("$ProgressPreference = 'SilentlyContinue'");
        sb.Append("$SR_Root = '").Append(ToolRoot.Replace("'", "''", StringComparison.Ordinal)).AppendLine("'");
        sb.AppendLine(". (Join-Path $SR_Root 'lib\\_common.ps1')");
        sb.AppendLine("# ---- the fence ----");
        foreach (var fn in FencedNames)
        {
            sb.Append("function ").Append(fn)
              .Append("{ throw 'the oracle fence refused ").Append(fn)
              .AppendLine(" - a comparison must never change anything' }");
        }

        sb.AppendLine("# ---- the comparison ----");
        sb.AppendLine(script);

        var tmp = Path.Combine(Path.GetTempPath(), "sr-oracle-" + Guid.NewGuid().ToString("N", CultureInfo.InvariantCulture) + ".ps1");
        try
        {
            // 🪤 UTF-8 WITHOUT A BOM, and Windows PowerShell 5.1 is why. It reads
            // a .ps1 as ANSI unless the BOM says otherwise - so a script written
            // as UTF-8 with a BOM parses, and one written as plain UTF-8 mojibakes
            // the moment a comparison contains a non-ASCII character. The
            // conversations this reads are full of them.
            File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                WorkingDirectory = ToolRoot,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            psi.ArgumentList.Add("-NoProfile");
            psi.ArgumentList.Add("-NonInteractive");
            psi.ArgumentList.Add("-ExecutionPolicy");
            psi.ArgumentList.Add("Bypass");
            psi.ArgumentList.Add("-File");
            psi.ArgumentList.Add(tmp);

            using var p = Process.Start(psi)
                ?? throw new InvalidOperationException("powershell.exe would not start");

            var stdout = p.StandardOutput.ReadToEnd();
            var stderr = p.StandardError.ReadToEnd();
            var ms = (int)(timeout ?? TimeSpan.FromMinutes(5)).TotalMilliseconds;
            if (!p.WaitForExit(ms))
            {
                try { p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                return new PsRun(string.Empty, "timed out after " + ms + " ms", -1);
            }

            return new PsRun(stdout, stderr, p.ExitCode);
        }
        finally
        {
            // A leaked temp degrades every later session on this machine; see
            // the environment note in CLAUDE.md.
            try { File.Delete(tmp); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}

/// <summary>What one PowerShell run produced.</summary>
public sealed record PsRun(string StdOut, string StdErr, int ExitCode)
{
    public bool Failed => ExitCode != 0 || StdErr.Trim().Length > 0;
}
