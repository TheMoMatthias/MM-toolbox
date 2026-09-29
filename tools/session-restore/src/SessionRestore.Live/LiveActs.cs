using System.Globalization;
using SessionRestore.Core.Acting;
using SessionRestore.Core.Console;
using SessionRestore.Core.Registry;

namespace SessionRestore.Live;

/// <summary>What the acting half needs to know about one conversation, at the moment it acts.</summary>
/// <param name="Pid">The process holding its console, or 0 when it is not running.</param>
/// <param name="Kind">What `claude agents` calls it - <c>interactive</c>, or a background kind.</param>
/// <param name="WaitingFor">The window's own record of what it is waiting on.</param>
public sealed record SessionFacts(int Pid, string Kind, string WaitingFor);

/// <summary>Where the acting half learns about conversations.</summary>
/// <remarks>
/// 🔑 AN INTERFACE SO A TEST CAN POINT EVERY ACT AT A REPLICA. The production
/// implementation reads the registry and the agents probe; the tests answer with
/// the pid of a console the test itself started.
/// </remarks>
public interface ISessions
{
    /// <summary>The facts about one conversation, or null when it is not known.</summary>
    SessionFacts? Find(string sessionId);

    /// <summary>
    /// A screen read taken NOW, or null when the screen could not be read.
    /// </summary>
    /// <remarks>
    /// 🔴 A FAILED READ IS NOT A MISSING MENU - but it is not a menu either. The
    /// reader sometimes comes back empty about a menu that is plainly still
    /// there, and the shipped ladder refuses nothing on an unreadable screen
    /// rather than refusing everything; <see cref="SendRefusal"/> carries that.
    /// </remarks>
    string? Screen(int pid);
}

/// <summary>
/// How a pid becomes something that may be typed into.
/// </summary>
/// <remarks>
/// 🔒 PRODUCTION IS <see cref="ConsoleTarget.ForSession"/>, and nothing else is
/// reachable from outside Core's own test assembly. A delegate rather than a
/// hard call so that the tests can hand over a console they own - through
/// <c>ConsoleTarget.ForOwnedConsole</c>, which is internal to Core.
/// </remarks>
public delegate ConsoleTarget? TargetFor(uint pid, out string refusal);

/// <summary>
/// The implementation of <see cref="IActs"/> that really acts.
/// </summary>
/// <remarks>
/// 🔴 THE OPERATOR RUNS ABOUT THIRTY LIVE CONVERSATIONS HE CANNOT RELAUNCH, and
/// every method here can reach one. The rules:
///
/// - It lives in its own assembly, which the window does not reference - a
///   check reads <c>Sessions2.dll</c>'s references and goes red if it ever does.
/// - Every write goes through a <see cref="ConsoleTarget"/>, whose only public
///   constructor refuses anything that is not a live <c>claude</c> process.
/// - It is proven ONLY against <c>tests/term-replica.ps1</c>, a real console
///   this repo starts and owns. Never against a conversation - not to test, not
///   once, not against one somebody believes is a spare.
///
/// 🪤 ACTS THAT ARE NOT BUILT YET REFUSE BY NAME. The contract lists ten acts;
/// this tranche builds the three that go through a console. The rest answer with
/// what they are and which tranche they belong to, so a window wired to this
/// early would say so on its status line instead of doing nothing silently.
/// </remarks>
public sealed class LiveActs : IActs
{
    /// <summary>
    /// The pause between typing a message and pressing Enter.
    /// </summary>
    /// <remarks>
    /// 🔴 TWO WRITES, NOT ONE, AND THE GAP IS LOAD-BEARING. The shipped
    /// <c>Send-SRSessionInput</c> types the text, sleeps 400 ms, and only then
    /// sends Enter as a key of its own. A paste that arrives with its Enter in the
    /// same burst is read by claude as a paste - the newline becomes part of the
    /// text and nothing is submitted.
    /// </remarks>
    public static readonly TimeSpan EnterAfter = TimeSpan.FromMilliseconds(400);

    private readonly ISessions _sessions;
    private readonly TargetFor _target;
    private readonly Action<TimeSpan> _pause;

    /// <param name="sessions">Where conversations are looked up.</param>
    /// <param name="target">How a pid becomes a console. Production leaves it null.</param>
    /// <param name="pause">How the send waits before its Enter. Tests leave it real.</param>
    public LiveActs(ISessions sessions, TargetFor? target = null, Action<TimeSpan>? pause = null)
    {
        _sessions = sessions ?? throw new ArgumentNullException(nameof(sessions));
        _target = target ?? ConsoleTarget.ForSession;
        _pause = pause ?? Thread.Sleep;
    }

    /// <summary>What was done, one line per act, for the log.</summary>
    public List<string> Log { get; } = [];

    public ActResult Carry(ActRequest request) => request.What switch
    {
        Act.Interrupt => Interrupt(request),
        Act.Send => Send(request),
        Act.Key => Key(request),
        _ => ActResult.Refused(NotBuilt(request.What)),
    };

    public ActResult Save(SessionRegistry registry) =>
        ActResult.Refused(NotBuilt(Act.SaveRegistry));

    /// <summary>What an act that is not built yet says.</summary>
    public static string NotBuilt(Act what) => what switch
    {
        Act.SaveRegistry or Act.WriteConfig =>
            "writing " + (what == Act.SaveRegistry ? "the registry" : "the configuration") + " is not built yet (4.2e-2)",
        _ => what.ToString().ToLowerInvariant() + " is not built yet (4.2e-3)",
    };

    // =======================================================================
    // Interrupt - Send-SRInterrupt
    // =======================================================================

    /// <remarks>
    /// 🔑 NO CONFIRMATION, DELIBERATELY, AND THAT IS THE WINDOW'S DECISION NOT
    /// THIS ONE'S. Stopping a turn is the recoverable half of the pair beside it:
    /// the session stays open and the transcript keeps everything written so far.
    /// A sheet in front of "stop, now" would have the operator watch it keep going
    /// while they read.
    /// </remarks>
    private ActResult Interrupt(ActRequest request)
    {
        var facts = _sessions.Find(request.SessionId);
        var pid = facts?.Pid ?? 0;
        if (pid <= 0)
        {
            return ActResult.Refused("there is no console to interrupt");
        }

        var target = _target((uint)pid, out var refusal);
        if (target is null)
        {
            return ActResult.Refused(refusal);
        }

        var n = ConsoleWriter.SendKeys(target, ForwardedKey.Escape);
        if (n < 0)
        {
            return ActResult.Refused(Unreachable(n));
        }

        Log.Add(string.Format(CultureInfo.InvariantCulture,
            "interrupted {0} (pid {1}) with one Esc", request.SessionId, pid));
        return ActResult.Ok("interrupted");
    }

    // =======================================================================
    // Send - Send-SRSessionInput
    // =======================================================================

    /// <remarks>
    /// 🔴 THE LADDER RUNS IN THE SHIPPED ORDER, and the order is the protection.
    /// Nothing to send, no process, not interactive, a dialog open - then the
    /// process is checked to BE claude, and only then is the screen read for a
    /// menu, because a session on a menu reads keystrokes as MENU INPUT and a
    /// sentence typed at it picks an option instead of queueing behind the turn.
    ///
    /// 🪤 THE CLAUDE CHECK IS THE TARGET, NOT A SEPARATE CALL. The shipped
    /// function asks <c>Test-SRClaudeProcess</c> in the middle of the ladder;
    /// here the same answer comes from <see cref="ConsoleTarget.ForSession"/>,
    /// and it is asked at the same rung - after the dialog, before the menu.
    /// </remarks>
    private ActResult Send(ActRequest request)
    {
        var facts = _sessions.Find(request.SessionId);
        var pid = facts?.Pid ?? 0;
        var kind = facts?.Kind ?? string.Empty;
        var waiting = facts?.WaitingFor ?? string.Empty;

        // The rungs above the claude check, with no screen and no claude answer.
        var early = SendRefusal.Of(request.Detail, pid, kind, waiting, null, null);
        if (early.Length > 0)
        {
            return ActResult.Refused(early);
        }

        var target = _target((uint)pid, out var refusal);
        if (target is null)
        {
            return ActResult.Refused(refusal);
        }

        // Now the screen, taken at the moment of sending: the window's own record
        // is up to ~26 s behind, and a read through the held-open reader is ~9 ms.
        var menu = SendRefusal.Of(request.Detail, pid, kind, waiting, null, _sessions.Screen(pid));
        if (menu.Length > 0)
        {
            return ActResult.Refused(menu);
        }

        var body = SendRefusal.Body(request.Detail);
        var n = ConsoleWriter.Send(target, body);
        if (n >= 0)
        {
            _pause(EnterAfter);
            n = ConsoleWriter.SendKeys(target, ForwardedKey.Enter);
        }

        if (n < 0)
        {
            return ActResult.Refused(Unreachable(n));
        }

        Log.Add(string.Format(CultureInfo.InvariantCulture,
            "sent {0} char(s) to {1}", body.Length, request.SessionId));
        return ActResult.Ok("sent");
    }

    // =======================================================================
    // Key - Send-SRTermKey / Send-SRTermChord
    // =======================================================================

    /// <summary>
    /// What a key request's Detail names: a key, a chord, or nothing we send.
    /// </summary>
    /// <remarks>
    /// 🪤 A CHORD IS THREE FIELDS, NOT A LETTER. Written as a bare key, Ctrl+C
    /// arrives as the character "c" - measured in 2.4b, where dropping the
    /// control bit made the chord vanish entirely. So "Ctrl+C" parses to a chord
    /// and "C" parses to nothing at all.
    /// </remarks>
    public static (ForwardedKey? Key, ForwardedChord? Chord) ParseKey(string? detail)
    {
        var d = (detail ?? string.Empty).Trim();
        if (d.StartsWith("Ctrl+", StringComparison.OrdinalIgnoreCase))
        {
            // 🔴 ONE ASCII LETTER, AND THE LETTER TEST IS NOT DECORATION.
            // Enum.TryParse accepts the enum's NUMBERS as well as its names, so
            // "Ctrl+1" parsed as ForwardedChord value 1 - which is Ctrl+D, the
            // chord that can close a conversation outright. Found by a break that
            // stayed green: the length check alone let a digit through.
            var letter = d[5..];
            return letter.Length == 1 && char.IsAsciiLetter(letter[0]) &&
                   Enum.TryParse<ForwardedChord>(letter, ignoreCase: true, out var c)
                ? (null, c)
                : (null, null);
        }

        return Enum.TryParse<ForwardedKey>(d, ignoreCase: true, out var k) &&
               Enum.IsDefined(k) && !int.TryParse(d, NumberStyles.Integer, CultureInfo.InvariantCulture, out _)
            ? (k, null)
            : (null, null);
    }

    private ActResult Key(ActRequest request)
    {
        var (key, chord) = ParseKey(request.Detail);
        if (key is null && chord is null)
        {
            return ActResult.Refused("no such key: " + request.Detail);
        }

        var facts = _sessions.Find(request.SessionId);
        var pid = facts?.Pid ?? 0;
        if (pid <= 0)
        {
            return ActResult.Refused("there is no console to send a key to");
        }

        var target = _target((uint)pid, out var refusal);
        if (target is null)
        {
            return ActResult.Refused(refusal);
        }

        var n = chord is { } c
            ? ConsoleWriter.SendChord(target, c)
            : ConsoleWriter.SendKeys(target, key!.Value);
        if (n < 0)
        {
            return ActResult.Refused(Unreachable(n));
        }

        Log.Add(string.Format(CultureInfo.InvariantCulture,
            "sent {0} to {1}", request.Detail, request.SessionId));
        return ActResult.Ok("sent " + request.Detail);
    }

    /// <summary>What a failed console write says - the shipped sentence, with the Win32 code.</summary>
    public static string Unreachable(int n) => string.Format(CultureInfo.InvariantCulture,
        "could not reach that session's console (win32 error {0})", -n);
}
