using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace SessionRestore.Core.Sessions;

/// <summary>What claude says about one conversation, asked of claude itself.</summary>
public sealed record AgentStatus(
    string SessionId,
    string Status,
    string WaitingFor,
    bool Needs,
    int Pid,
    string Kind,
    string Name,
    string Cwd,
    DateTimeOffset? StartedAt)
{
    /// <summary>An interactive session, as opposed to a background agent.</summary>
    public bool IsInteractive => string.Equals(Kind, "interactive", StringComparison.Ordinal);

    /// <summary>Mid-turn. The probe's own word, not an inference from a transcript.</summary>
    public bool IsBusy => string.Equals(Status, "busy", StringComparison.Ordinal);
}

/// <summary>
/// <c>claude agents --json</c> - the only thing that knows what a session is
/// actually doing right now.
/// </summary>
/// <remarks>
/// 🔴 IT IS A SUBPROCESS AND IT IS NOT FREE. Measured in the PowerShell at
/// 295 ms of a 508 ms model refresh - the single dominant cost of the background
/// pass. Which is why it is cached, and why anything reading it repeatedly
/// inside one pass must not ask for a refresh.
///
/// 🪤 AND AN EMPTY MAP IS AN HONEST ANSWER. It means "claude could not be
/// asked", and every caller falls back to the transcript rather than showing
/// nothing. A throw here would take a window down over a subprocess that failed.
/// </remarks>
public sealed class AgentMap
{
    private static readonly TimeSpan DefaultMaxAge = TimeSpan.FromSeconds(5);

    private static readonly object Gate = new();
    private static IReadOnlyDictionary<string, AgentStatus>? _cache;
    private static DateTimeOffset _cachedAt;

    /// <summary>
    /// Every conversation claude knows about, keyed by lower-case session id.
    /// </summary>
    public static IReadOnlyDictionary<string, AgentStatus> Read(bool refresh = false, TimeSpan? maxAge = null)
    {
        lock (Gate)
        {
            var age = maxAge ?? DefaultMaxAge;
            if (!refresh && _cache is not null && DateTimeOffset.UtcNow - _cachedAt < age)
            {
                return _cache;
            }

            var map = Ask();
            _cache = map;
            _cachedAt = DateTimeOffset.UtcNow;
            return map;
        }
    }

    /// <summary>Parses what the CLI printed. Public so it can be tested without spawning.</summary>
    /// <remarks>
    /// 🪤 A BACKGROUND AGENT REPORTS `state`, AN INTERACTIVE ONE `status`. Reading
    /// only one of them leaves half the sessions with no status at all.
    ///
    /// 🪤 AND 'blocked' IS A DEMAND ON YOUR ATTENTION even though it names no
    /// question: a background agent that cannot proceed without you is the same
    /// thing as one asking, from the point of view of a board that says what
    /// needs doing.
    /// </remarks>
    public static Dictionary<string, AgentStatus> Parse(string json)
    {
        var map = new Dictionary<string, AgentStatus>(StringComparer.Ordinal);
        if (string.IsNullOrWhiteSpace(json))
        {
            return map;
        }

        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(json);
        }
        catch (JsonException)
        {
            return map;
        }

        using (doc)
        {
            if (doc.RootElement.ValueKind != JsonValueKind.Array)
            {
                return map;
            }

            foreach (var e in doc.RootElement.EnumerateArray())
            {
                if (e.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                var id = Str(e, "sessionId");
                if (id.Length == 0)
                {
                    continue;
                }

                var status = Str(e, "status");
                if (status.Length == 0)
                {
                    status = Str(e, "state");
                }

                var waitingFor = Str(e, "waitingFor");
                var needs = waitingFor.Length > 0
                            || string.Equals(status, "blocked", StringComparison.Ordinal);

                map[id.ToLowerInvariant()] = new AgentStatus(
                    SessionId: id,
                    Status: status,
                    WaitingFor: waitingFor,
                    Needs: needs,
                    Pid: e.TryGetProperty("pid", out var p) && p.ValueKind == JsonValueKind.Number ? p.GetInt32() : 0,
                    Kind: Str(e, "kind"),
                    Name: Str(e, "name"),
                    Cwd: Str(e, "cwd"),
                    StartedAt: StartedAt(e));
            }
        }

        return map;
    }

    /// <summary>
    /// Runs the CLI and hands back stdout.
    /// </summary>
    /// <remarks>
    /// 🔴 STDOUT AND STDERR ARE KEPT APART, NOT MERGED. A stderr line inside the
    /// document breaks the parse, and the failure then looks like "claude reports
    /// no sessions" rather than like an error - which is the worst shape a
    /// failure can take on a board whose job is saying what is running.
    ///
    /// 🪤 AND IT MUST NOT HAND THIS PROCESS A CONSOLE. A plain redirected start
    /// does not; PowerShell's native pipeline does, which is why the PowerShell
    /// grew its own CreateProcess wrapper to avoid it.
    /// </remarks>
    private static Dictionary<string, AgentStatus> Ask()
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "claude",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            psi.ArgumentList.Add("agents");
            psi.ArgumentList.Add("--json");

            using var proc = Process.Start(psi);
            if (proc is null)
            {
                return [];
            }

            var stdout = proc.StandardOutput.ReadToEnd();
            _ = proc.StandardError.ReadToEnd();
            if (!proc.WaitForExit(20_000))
            {
                try { proc.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                return [];
            }

            return proc.ExitCode == 0 ? Parse(stdout) : [];
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // claude is not on PATH. An empty map, and the caller falls back.
            return [];
        }
        catch (InvalidOperationException)
        {
            return [];
        }
    }

    private static DateTimeOffset? StartedAt(JsonElement e)
    {
        if (!e.TryGetProperty("startedAt", out var v) || v.ValueKind != JsonValueKind.Number)
        {
            return null;
        }

        return DateTimeOffset.FromUnixTimeMilliseconds(v.GetInt64()).ToLocalTime();
    }

    private static string Str(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? string.Empty
            : string.Empty;
}
