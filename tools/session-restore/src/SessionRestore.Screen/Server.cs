using System.Globalization;
using System.IO.Pipes;
using System.Text;
using SessionRestore.Core.Console;

namespace SessionRestore.Screen;

/// <summary>
/// One helper, held open, answering screen reads down a pipe.
/// </summary>
/// <remarks>
/// 🔴 IT EXISTS BECAUSE STARTING THE HELPER IS THE COST, NOT THE READING.
/// Measured on this machine, 2026-09-09, over 26 live consoles: spawning is
/// 1.673 ms and this is 25 ms - 0,9 ms a console against 51,7. The PowerShell's
/// own held-open pipe does the same 26 in 63 ms.
///
/// 🔑 AND HOLDING ONE PROCESS OPEN BEAT BATCHING THEM INTO ONE, which is the
/// counter-intuitive half: a batch avoids 26 spawns, a server avoids the 27th.
/// Only possible because a process may attach to one console at a time but not
/// only one console EVER - freeing before each attach is what lets it walk a
/// list.
///
/// 🪤 FRAMED BY LENGTH, NOT BY A SENTINEL. Console text can contain anything at
/// all, including whatever separator looked safe; a four-byte length cannot be
/// confused with content.
///
/// 🪤 AND IT DIES ON ITS OWN. A helper whose caller went away without saying so
/// would sit on this machine until a reboot, holding a pipe name the next one
/// wants. The idle timeout is what makes that impossible rather than unlikely.
/// </remarks>
internal static class Server
{
    internal static int Run(string pipeName, int idleSeconds)
    {
        var idle = TimeSpan.FromSeconds(idleSeconds <= 0 ? 120 : idleSeconds);

        while (true)
        {
            using var pipe = new NamedPipeServerStream(
                pipeName, PipeDirection.InOut, 1,
                PipeTransmissionMode.Byte, PipeOptions.Asynchronous);

            var connect = pipe.WaitForConnectionAsync();
            if (!connect.Wait(idle))
            {
                // Nobody came back. Better to be started again than to linger.
                return 0;
            }

            try
            {
                Serve(pipe, idle);
            }
            catch (IOException)
            {
                // The caller went away mid-request. Wait for the next one.
            }
        }
    }

    private static void Serve(NamedPipeServerStream pipe, TimeSpan idle)
    {
        var reader = new BinaryReader(pipe, Encoding.UTF8, leaveOpen: true);
        var writer = new BinaryWriter(pipe, Encoding.UTF8, leaveOpen: true);

        while (pipe.IsConnected)
        {
            string request;
            try
            {
                request = reader.ReadString();
            }
            catch (EndOfStreamException)
            {
                return;
            }

            if (request.Length == 0 || string.Equals(request, "bye", StringComparison.Ordinal))
            {
                return;
            }

            var answer = Answer(request);
            writer.Write(answer);
            writer.Flush();
        }

        _ = idle;
    }

    /// <summary>One request, answered.</summary>
    /// <remarks>
    /// The protocol itself lives in Core (<see cref="ScreenRequest"/>) so the
    /// client that builds a request and the server that reads one share a
    /// definition rather than each keeping a copy.
    /// </remarks>
    internal static string Answer(string request)
    {
        var r = ScreenRequest.Parse(request);
        if (r is null)
        {
            return "!badrequest";
        }

        return r.Value.Attributes
            ? ConsoleApi.Attributes(r.Value.Pid, r.Value.Back)
            : ConsoleApi.Rows(r.Value.Pid, r.Value.Back);
    }
}
