using System.Runtime.InteropServices;
using System.Text;

namespace SessionRestore.Core.Console;

/// <summary>
/// Reading another process's console buffer.
/// </summary>
/// <remarks>
/// 🔴 THERE IS NOTHING IN HERE THAT WRITES. <c>WriteConsoleInputW</c> - the call
/// that types into a live conversation - is deliberately absent from this class
/// and from this phase. Twenty-odd conversations the operator cannot relaunch
/// are one bad call away from an interrupted turn, so the code that could do it
/// does not exist yet: it arrives at plan item 2.4b, with a replica console of
/// its own to be proven against.
///
/// 🔴 A PROCESS CAN BE ATTACHED TO ONLY ONE CONSOLE AT A TIME - which is not the
/// same as only one console EVER. Freeing before each attach is what lets one
/// process walk a list of them, and that is measured: spawning a child per
/// session put process creation in front of every read, at a 129 ms median
/// where the reading itself is about 30.
///
/// 🪤 AND THE PROCESS THAT ATTACHES MUST NEVER BE THE WINDOW. Attaching hands
/// this process somebody else's console; a UI process that did that would have
/// its own standard handles and Ctrl+C behaviour redefined underneath it. The
/// window talks to a helper (sr-screen) and this class only ever runs there.
/// </remarks>
public static class ConsoleApi
{
    private const uint GenericRead = 0x80000000u;
    private const uint GenericWrite = 0x40000000u;
    private const uint ShareRead = 1u;
    private const uint ShareWrite = 2u;
    private const uint OpenExisting = 3u;

    // 🪤 DllImport RATHER THAN LibraryImport, AND THE REASON IS THE BUFFERS.
    // The generated marshalling LibraryImport produces cannot pass an [Out]
    // char[] without the whole assembly opting out of runtime marshalling - and
    // opting out is a far larger change, affecting every struct in the project,
    // to gain nothing here. These are the same signatures the PowerShell used,
    // which is also what makes them comparable line by line.
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachConsole(uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFileW(
        string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetConsoleScreenBufferInfo(IntPtr h, out ConsoleScreenBufferInfo info);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReadConsoleOutputCharacterW(
        IntPtr h, [Out] char[] buffer, uint length, uint coord, out uint got);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReadConsoleOutputAttribute(
        IntPtr h, [Out] ushort[] buffer, uint length, uint coord, out uint got);

    [StructLayout(LayoutKind.Sequential)]
    private struct Coord
    {
        public short X;
        public short Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SmallRect
    {
        public short Left;
        public short Top;
        public short Right;
        public short Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ConsoleScreenBufferInfo
    {
        public Coord Size;
        public Coord Cursor;
        public ushort Attributes;
        public SmallRect Window;
        public Coord Max;
    }

    /// <summary>
    /// The characters on a session's screen, one line per row.
    /// </summary>
    /// <param name="pid">The process whose console to read.</param>
    /// <param name="back">
    /// How many rows ABOVE the visible top to include. 0 is the visible screen,
    /// which is what every caller but the terminal watcher wants.
    /// </param>
    /// <remarks>
    /// 🔴 THE VIEWPORT IS NOT THE BUFFER. <c>Size.Y</c> is the buffer and
    /// <c>Window.T/B</c> is the window onto it; reading only the window is why
    /// "watch its terminal" once had nothing to scroll up to.
    ///
    /// 🪤 AND ASKING FOR MORE DOES NOT ALWAYS GET MORE. claude runs under
    /// ConPTY, whose pseudo-console buffer IS the size of the viewport - so on
    /// those, <paramref name="back"/> returns the same rows however large it is.
    /// Whatever scrolled past belongs to Windows Terminal, where no console API
    /// can follow it. Measured, and it invalidated a feature built on the
    /// assumption that scrollback was reachable.
    ///
    /// 🪤 BOUNDED BY THE CALLER, NOT BY THE BUFFER. A read is one call per row,
    /// and a Windows Terminal buffer is 9.001 rows; doing that on 26 consoles
    /// several times a second would be thousands of calls. The watcher asks for
    /// hundreds, for one console, and nothing else asks at all.
    /// </remarks>
    public static string Rows(uint pid, int back = 0) =>
        Read(pid, back, static (h, width, top, bottom) =>
        {
            var sb = new StringBuilder();
            var line = new char[width];
            for (var y = top; y <= bottom; y++)
            {
                var at = (uint)y << 16;
                if (!ReadConsoleOutputCharacterW(h, line, (uint)width, at, out var got))
                {
                    continue;
                }

                sb.Append(new string(line, 0, (int)got).TrimEnd());
                sb.Append('\n');
            }

            return sb.ToString();
        });

    /// <summary>
    /// The colour plane for the same rows, four hex digits per cell.
    /// </summary>
    /// <remarks>
    /// 🔴 IT IS AN APPROXIMATION AND MUST NEVER BE DESCRIBED AS THE COLOURS. The
    /// console keeps characters in one plane and colour in ANOTHER, and that
    /// other plane is four bits of foreground and four of background, while
    /// claude paints 24-bit through VT sequences. What comes back is conhost's
    /// own nearest-legacy rounding of what was drawn.
    ///
    /// 🔑 It was worth building anyway, and that was decided by measuring rather
    /// than by argument: 3.600 cells of a live screen carried FOUR distinct
    /// values - default, dim, bright, green. Not the palette, but the structure.
    /// </remarks>
    public static string Attributes(uint pid, int back = 0) =>
        Read(pid, back, static (h, width, top, bottom) =>
        {
            var sb = new StringBuilder();
            var line = new ushort[width];
            for (var y = top; y <= bottom; y++)
            {
                var at = (uint)y << 16;
                if (!ReadConsoleOutputAttribute(h, line, (uint)width, at, out var got))
                {
                    continue;
                }

                for (var x = 0; x < (int)got; x++)
                {
                    sb.Append(line[x].ToString("x4", System.Globalization.CultureInfo.InvariantCulture));
                }

                sb.Append('\n');
            }

            return sb.ToString();
        });

    /// <summary>
    /// The attach/read/detach dance both readers share.
    /// </summary>
    /// <remarks>
    /// 🪤 A FAILURE IS A STRING BEGINNING WITH '!', NOT AN EXCEPTION. This runs
    /// in a helper whose whole output is one blob of text; a session that exited
    /// between being listed and being read is an ordinary event, several times
    /// an hour, and it has to be told apart from a session that said nothing.
    /// </remarks>
    private static string Read(uint pid, int back, Func<IntPtr, int, int, int, string> body)
    {
        FreeConsole();
        if (!AttachConsole(pid))
        {
            return "!attach " + Marshal.GetLastWin32Error().ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        try
        {
            var h = CreateFileW("CONOUT$", GenericRead | GenericWrite,
                ShareRead | ShareWrite, IntPtr.Zero, OpenExisting, 0u, IntPtr.Zero);
            if (h == new IntPtr(-1))
            {
                return "!conout " + Marshal.GetLastWin32Error().ToString(System.Globalization.CultureInfo.InvariantCulture);
            }

            try
            {
                if (!GetConsoleScreenBufferInfo(h, out var info))
                {
                    return "!csbi " + Marshal.GetLastWin32Error().ToString(System.Globalization.CultureInfo.InvariantCulture);
                }

                int width = info.Size.X;
                int rows = info.Size.Y;
                if (width <= 0 || rows <= 0)
                {
                    return "!empty";
                }

                var top = info.Window.Top < 0 ? 0 : info.Window.Top;
                var bottom = info.Window.Bottom >= rows ? rows - 1 : info.Window.Bottom;
                if (bottom < top)
                {
                    top = 0;
                    bottom = rows - 1;
                }

                if (back > 0)
                {
                    top -= back;
                    if (top < 0)
                    {
                        top = 0;
                    }
                }

                return body(h, width, top, bottom);
            }
            finally
            {
                CloseHandle(h);
            }
        }
        finally
        {
            FreeConsole();
        }
    }
}
