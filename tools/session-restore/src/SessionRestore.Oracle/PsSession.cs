using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace SessionRestore.Oracle;

/// <summary>
/// One long-lived powershell.exe with the domain loaded and the fence in place,
/// fed one comparison at a time down its stdin.
/// </summary>
/// <remarks>
/// 🔴 MEASURED, AND IT IS THE DIFFERENCE BETWEEN USABLE AND NOT. A fresh
/// powershell.exe that dot-sources lib/_common.ps1 (455 KB) costs 4,5 to 14,5
/// SECONDS - measured on the first oracle run, five cases in 41 s. Phase 2
/// compares hundreds of things against real data; at that price nobody would
/// run it, which means it would stop being the safety net it exists to be.
///
/// So the file is loaded ONCE and the session is kept. It is the same trick the
/// tool itself already uses for screen reads, where holding the pipe open beat
/// batching 26 consoles into one process (63 ms against 82).
///
/// 🪤 THE MARKERS CARRY AN ID, not a fixed string. Without one, a comparison
/// whose OUTPUT happens to contain the marker - and this reads conversations
/// about this very tool - would end the read early and hand back a truncated
/// answer that still parses.
///
/// 🪤 STDERR IS DRAINED ON ITS OWN THREAD. Reading stdout to a marker while the
/// child blocks writing a full stderr pipe is a deadlock, and it would present
/// as "the oracle hangs sometimes".
/// </remarks>
public sealed class PsSession : IDisposable
{
    private readonly Process _proc;
    private readonly StringBuilder _stderr = new();
    private readonly object _gate = new();

    // 🔴 ONE REQUEST AT A TIME DOWN ONE PIPE. xUnit runs test classes in
    // parallel by default, and two comparisons interleaving on the same stdin
    // would each read part of the other's answer - producing a difference that
    // is real, reproducible under load, and about nothing. A harness that
    // invents differences is worse than no harness: every one has to be chased.
    private readonly SemaphoreSlim _one = new(1, 1);
    private int _seq;
    private bool _disposed;

    private static readonly Lazy<PsSession> Shared = new(() =>
    {
        var s = new PsSession();
        AppDomain.CurrentDomain.ProcessExit += (_, _) => s.Dispose();
        return s;
    });

    /// <summary>The session every comparison shares.</summary>
    public static PsSession Instance => Shared.Value;

    public PsSession()
    {
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = PowerShellRunner.ToolRoot,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-NonInteractive");
        psi.ArgumentList.Add("-ExecutionPolicy");
        psi.ArgumentList.Add("Bypass");
        psi.ArgumentList.Add("-Command");
        psi.ArgumentList.Add("-");

        _proc = Process.Start(psi) ?? throw new InvalidOperationException("powershell.exe would not start");

        _proc.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is not null)
            {
                lock (_gate)
                {
                    _stderr.AppendLine(e.Data);
                }
            }
        };
        _proc.BeginErrorReadLine();

        // 🪤 THE INPUT ENCODING HAS TO BE SET TOO. Without it the pipe is written
        // in the console codepage and every non-ASCII character in a comparison -
        // and these read conversations full of them - arrives mangled.
        _proc.StandardInput.AutoFlush = false;

        Send(Preamble());
        // Prove the preamble landed before anything trusts this session.
        var ready = Run("'ready'", TimeSpan.FromMinutes(2));
        if (ready.Failed || !ready.StdOut.Contains("ready", StringComparison.Ordinal))
        {
            var why = ready.StdErr.Trim();
            Dispose();
            throw new InvalidOperationException(
                "the oracle's PowerShell session did not come up" + (why.Length > 0 ? ": " + why : "."));
        }
    }

    private static string Preamble()
    {
        var sb = new StringBuilder();
        sb.AppendLine("$ErrorActionPreference = 'Stop'");
        sb.AppendLine("$ProgressPreference = 'SilentlyContinue'");
        sb.AppendLine("[Console]::OutputEncoding = [Text.Encoding]::UTF8");
        sb.Append("$SR_Root = '")
          .Append(PowerShellRunner.ToolRoot.Replace("'", "''", StringComparison.Ordinal))
          .AppendLine("'");
        sb.AppendLine(". (Join-Path $SR_Root 'lib\\_common.ps1')");
        foreach (var fn in PowerShellRunner.FencedNames)
        {
            sb.Append("function ").Append(fn)
              .Append("{ throw 'the oracle fence refused ").Append(fn)
              .AppendLine(" - a comparison must never change anything' }");
        }

        return sb.ToString();
    }

    private void Send(string s)
    {
        _proc.StandardInput.Write(s);
        _proc.StandardInput.Write('\n');
        _proc.StandardInput.Flush();
    }

    /// <summary>Runs one comparison in the shared session.</summary>
    public PsRun Run(string script, TimeSpan? timeout = null)
    {
        ArgumentNullException.ThrowIfNull(script);
        ObjectDisposedException.ThrowIf(_disposed, this);

        _one.Wait();
        try
        {
            return RunLocked(script, timeout);
        }
        finally
        {
            _one.Release();
        }
    }

    private PsRun RunLocked(string script, TimeSpan? timeout)
    {
        lock (_gate)
        {
            _stderr.Clear();
        }

        var id = Interlocked.Increment(ref _seq).ToString(CultureInfo.InvariantCulture);
        var outMark = "<<<SR-OUT-" + id + ">>>";
        var errMark = "<<<SR-ERR-" + id + ">>>";
        var endMark = "<<<SR-END-" + id + ">>>";

        var sb = new StringBuilder();
        sb.AppendLine("$__e = ''");
        sb.AppendLine("$__o = ''");
        sb.AppendLine("try {");
        sb.AppendLine("  $__o = & {");
        sb.AppendLine(script);
        sb.AppendLine("  } | Out-String");
        sb.AppendLine("} catch { $__e = \"$($_.Exception.Message)\" }");
        sb.Append("Write-Output '").Append(outMark).AppendLine("'");
        sb.AppendLine("Write-Output $__o");
        sb.Append("Write-Output '").Append(errMark).AppendLine("'");
        sb.AppendLine("Write-Output $__e");
        sb.Append("Write-Output '").Append(endMark).AppendLine("'");
        Send(sb.ToString());

        var deadline = DateTime.UtcNow + (timeout ?? TimeSpan.FromMinutes(5));
        var body = new StringBuilder();
        var err = new StringBuilder();
        var where = 0; // 0 before OUT, 1 in OUT, 2 in ERR

        while (DateTime.UtcNow < deadline)
        {
            var line = _proc.StandardOutput.ReadLine();
            if (line is null)
            {
                return new PsRun(string.Empty, "the oracle's PowerShell session ended unexpectedly", -1);
            }

            if (line.Contains(endMark, StringComparison.Ordinal))
            {
                var e = err.ToString().Trim();
                lock (_gate)
                {
                    var stray = _stderr.ToString().Trim();
                    if (stray.Length > 0)
                    {
                        e = e.Length > 0 ? e + Environment.NewLine + stray : stray;
                    }
                }

                return new PsRun(body.ToString().Trim(), e, e.Length > 0 ? 1 : 0);
            }

            if (line.Contains(errMark, StringComparison.Ordinal))
            {
                where = 2;
                continue;
            }

            if (line.Contains(outMark, StringComparison.Ordinal))
            {
                where = 1;
                continue;
            }

            if (where == 1)
            {
                body.AppendLine(line);
            }
            else if (where == 2)
            {
                err.AppendLine(line);
            }
        }

        // A comparison that ran out of time has left the session mid-answer, so
        // it cannot be reused - and an inconclusive result must never be
        // mistaken for either answer.
        Dispose();
        return new PsRun(string.Empty, "timed out; the shared session was closed", -1);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        // 🪤 THE SEMAPHORE IS DELIBERATELY NOT DISPOSED HERE. The timeout path
        // calls Dispose() from INSIDE the guarded region, and Run's finally then
        // releases - on a disposed semaphore that throws, so a comparison that
        // merely timed out would come back as an ObjectDisposedException from
        // the harness and be read as a defect in the code under test.
        try
        {
            _proc.StandardInput.Write("exit\n");
            _proc.StandardInput.Flush();
            if (!_proc.WaitForExit(3000))
            {
                _proc.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException) { }
        catch (IOException) { }
        finally
        {
            _proc.Dispose();
        }
    }
}
