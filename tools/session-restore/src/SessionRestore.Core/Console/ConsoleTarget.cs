using System.Diagnostics;
using System.Globalization;

namespace SessionRestore.Core.Console;

/// <summary>
/// A console this tool is permitted to type into.
/// </summary>
/// <remarks>
/// 🔴 THE GUARD IS THE TYPE, NOT A CALL SOMEBODY HAS TO REMEMBER. Every write in
/// <see cref="ConsoleWriter"/> takes one of these and there is no public
/// constructor, so a new call site cannot forget to check what it is typing
/// into - it cannot even be written.
///
/// 🔴 A PID IS REUSABLE, and that is the whole reason this exists. The number
/// belonging to a conversation five minutes ago may belong to anything at all
/// now; the PowerShell learned to re-check before every send and says so.
/// Confirming it is still a claude is the difference between interrupting a turn
/// and pressing Escape in whatever inherited the number.
/// </remarks>
public sealed class ConsoleTarget
{
    private ConsoleTarget(uint pid, string what)
    {
        Pid = pid;
        What = what;
    }

    /// <summary>The process whose console will receive the keys.</summary>
    public uint Pid { get; }

    /// <summary>What that process is - for saying so when something goes wrong.</summary>
    public string What { get; }

    /// <summary>
    /// A live conversation, or null with a reason nobody has to invent.
    /// </summary>
    /// <param name="pid">The candidate process.</param>
    /// <param name="refusal">Empty when a target was returned; why not otherwise.</param>
    /// <remarks>
    /// 🪤 A PROCESS CAN EXIT BETWEEN THE LOOKUP AND THE READ, and asking a dead
    /// one for its name throws too - which is the common case here, a session
    /// that closed while a card was still on screen. Both are caught, and both
    /// answer with the same sentence a person would say.
    /// </remarks>
    public static ConsoleTarget? ForSession(uint pid, out string refusal)
    {
        if (pid == 0)
        {
            refusal = "there is no console to type into";
            return null;
        }

        Process p;
        try
        {
            p = Process.GetProcessById((int)pid);
        }
        catch (ArgumentException)
        {
            refusal = "that session has exited";
            return null;
        }
        catch (InvalidOperationException)
        {
            refusal = "that session has exited";
            return null;
        }

        string name;
        try
        {
            name = p.ProcessName;
        }
        catch (InvalidOperationException)
        {
            refusal = "that session has exited";
            return null;
        }
        finally
        {
            p.Dispose();
        }

        if (!string.Equals(name, "claude", StringComparison.OrdinalIgnoreCase))
        {
            refusal = string.Format(CultureInfo.InvariantCulture,
                "pid {0} is {1}, not claude - refusing to type into it", pid, name);
            return null;
        }

        refusal = string.Empty;
        return new ConsoleTarget(pid, "claude");
    }

    /// <summary>
    /// A console the caller created and owns.
    /// </summary>
    /// <remarks>
    /// 🔒 INTERNAL, AND IT IS THE ONLY WAY PAST THE CLAUDE CHECK. It exists for
    /// one purpose: a test needs a real console with a real input queue to prove
    /// the send path against, and that console must never be one of the
    /// operator's conversations. The standing rule in this repo is that nothing
    /// may type into a session - not to test, not once, not against what
    /// somebody believes is a spare - and this keeps the escape hatch inside the
    /// assembly where the tests are, rather than on the public surface where a
    /// future call site could reach for it.
    /// </remarks>
    internal static ConsoleTarget ForOwnedConsole(uint pid) => new(pid, "a console this test owns");
}
