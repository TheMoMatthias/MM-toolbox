using System.Runtime.InteropServices;

namespace SessionRestore.Core.Console;

/// <summary>The keys this tool is allowed to forward, and nothing else.</summary>
/// <remarks>
/// 🔒 A CLOSED LIST, AS AN ENUM RATHER THAN A TABLE OF NUMBERS. Each of these is
/// a key some path in the tool already sends and has exercised against a real
/// console. Widening it is a decision, and making it a type means widening it
/// shows up in a diff rather than as one more entry in a dictionary.
/// </remarks>
public enum ForwardedKey : ushort
{
    Enter = 0x0D,
    Backspace = 0x08,
    Tab = 0x09,
    Escape = 0x1B,
    Left = 0x25,
    Up = 0x26,
    Right = 0x27,
    Down = 0x28,
    Space = 0x20,
}

/// <summary>The three control chords, and only those three.</summary>
/// <remarks>
/// 🔒 ADDED ON THE OPERATOR'S EXPLICIT INSTRUCTION, 2026-09-09, asked as "should
/// the terminal forward Ctrl+C, Ctrl+D and Ctrl+Z" and answered "yes, all
/// three". Recorded because the recommendation was NO and the reasoning for it
/// still stands on its own: these three can end a conversation that cannot be
/// relaunched. It was a decision taken with that in front of him, not an
/// oversight - and it is not one for a later session to reverse, or to widen,
/// without asking again.
/// </remarks>
public enum ForwardedChord
{
    /// <summary>Interrupt.</summary>
    C,

    /// <summary>End of input - can close a conversation outright.</summary>
    D,

    /// <summary>Suspend.</summary>
    Z,
}

/// <summary>
/// Writing keystrokes into a session's console input queue.
/// </summary>
/// <remarks>
/// 🔴 THIS IS THE MOST DANGEROUS CLASS IN THE TOOL. What it writes is
/// indistinguishable from what the keyboard writes - by the time claude reads a
/// forwarded keystroke there is no way to tell the two apart. The operator runs
/// two dozen conversations he cannot relaunch.
///
/// 🔒 Every method takes a <see cref="ConsoleTarget"/>, which cannot be
/// constructed for anything but a live claude process except from inside this
/// assembly's own tests. That is the guard, and it is a type rather than a call
/// somebody has to remember to make.
/// </remarks>
public static class ConsoleWriter
{
    private const ushort KeyEvent = 1;
    private const uint LeftCtrlPressed = 0x0008;
    private const uint AttachParentProcess = 0xFFFFFFFF;

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachConsole(uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FreeConsole();

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFileW(
        string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WriteConsoleInputW(
        IntPtr h, InputRecord[] buffer, uint length, out uint written);

    [StructLayout(LayoutKind.Sequential)]
    private struct InputRecord
    {
        public ushort EventType;
        public ushort Padding;
        [MarshalAs(UnmanagedType.Bool)] public bool KeyDown;
        public ushort RepeatCount;
        public ushort VirtualKeyCode;
        public ushort VirtualScanCode;
        public char UnicodeChar;
        public uint ControlKeyState;
    }

    /// <summary>Types <paramref name="text"/>, optionally followed by Enter.</summary>
    /// <returns>Records written, or the negative of a win32 error.</returns>
    public static int Send(ConsoleTarget target, string text, bool enter = false)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(text);

        var records = new List<InputRecord>((text.Length + 1) * 2);
        foreach (var c in text)
        {
            AddPair(records, vk: 0, ch: c, ctrl: 0);
        }

        if (enter)
        {
            AddPair(records, vk: (ushort)ForwardedKey.Enter, ch: '\r', ctrl: 0);
        }

        return Write(target, records);
    }

    /// <summary>
    /// Presses keys, as keys.
    /// </summary>
    /// <remarks>
    /// 🔑 KEYS, NOT CHARACTERS. <see cref="Send"/> writes character records,
    /// which is everything a prompt needs and nothing a MENU needs: claude's
    /// question card is driven with the arrow keys, and an arrow has no
    /// character to write.
    ///
    /// 🪤 DOWN AND UP FOR EACH, because a TUI watching for key-release sees
    /// nothing from half a pair.
    /// </remarks>
    public static int SendKeys(ConsoleTarget target, params ForwardedKey[] keys)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(keys);

        var records = new List<InputRecord>(keys.Length * 2);
        foreach (var k in keys)
        {
            // 🪤 ENTER IS THE ONE THAT ALSO NEEDS ITS CHARACTER, or a console
            // reading cooked input never sees the line end.
            var ch = k == ForwardedKey.Enter ? '\r' : '\0';
            AddPair(records, (ushort)k, ch, 0);
        }

        return Write(target, records);
    }

    /// <summary>
    /// A control chord.
    /// </summary>
    /// <remarks>
    /// 🔴 Ctrl+C IS NOT THE LETTER C AND IT IS NOT THE C KEY. A console reader
    /// decides what it received from THREE fields together: the virtual key, the
    /// character, and the control-key state. Send the key alone and a TUI sees a
    /// plain "c"; send the character alone and a reader watching for the key
    /// sees nothing. All three, with the control bit, is what a keyboard
    /// produces and the only form that works for readers of either kind.
    /// </remarks>
    public static int SendChord(ConsoleTarget target, ForwardedChord chord)
    {
        ArgumentNullException.ThrowIfNull(target);

        var (vk, ch) = chord switch
        {
            ForwardedChord.C => ((ushort)0x43, (char)3),
            ForwardedChord.D => ((ushort)0x44, (char)4),
            ForwardedChord.Z => ((ushort)0x5A, (char)26),
            _ => ((ushort)0, '\0'),
        };

        if (vk == 0)
        {
            return 0;
        }

        var records = new List<InputRecord>(2);

        // The release record carries the control bit too, because a reader that
        // tracks modifier state sees the control key go up WITH the letter
        // rather than stay down after it.
        AddPair(records, vk, ch, LeftCtrlPressed);
        return Write(target, records);
    }

    private static void AddPair(List<InputRecord> into, ushort vk, char ch, uint ctrl)
    {
        into.Add(new InputRecord
        {
            EventType = KeyEvent, KeyDown = true, RepeatCount = 1,
            VirtualKeyCode = vk, UnicodeChar = ch, ControlKeyState = ctrl,
        });
        into.Add(new InputRecord
        {
            EventType = KeyEvent, KeyDown = false, RepeatCount = 1,
            VirtualKeyCode = vk, UnicodeChar = ch, ControlKeyState = ctrl,
        });
    }

    /// <summary>
    /// Attach, write, detach - and give the caller its console back.
    /// </summary>
    /// <remarks>
    /// 🔴 GIVE THE CALLER ITS OWN CONSOLE BACK. Attaching to another process's
    /// console means first freeing ours, and a process may hold exactly one. The
    /// PowerShell did not restore it at first, so a console-hosted caller was
    /// left with no console at all and died on the NEXT write with "the handle
    /// is invalid" - from a line that had nothing to do with any of this. The
    /// window never noticed, because a WPF process has no console to lose.
    ///
    /// 🪤 ONLY FOR CALLERS THAT HAD ONE. Attaching the window to whatever
    /// console its launcher happens to own would be a new behaviour, not a
    /// restoration.
    /// </remarks>
    private static int Write(ConsoleTarget target, List<InputRecord> records)
    {
        if (records.Count == 0)
        {
            return 0;
        }

        var had = GetConsoleWindow() != IntPtr.Zero;
        FreeConsole();
        if (!AttachConsole(target.Pid))
        {
            var err = Marshal.GetLastWin32Error();
            GiveBack(had);
            return -err;
        }

        try
        {
            var h = CreateFileW("CONIN$", 0x80000000u | 0x40000000u,
                1u | 2u, IntPtr.Zero, 3u, 0u, IntPtr.Zero);
            if (h == new IntPtr(-1))
            {
                return -Marshal.GetLastWin32Error();
            }

            try
            {
                var buf = records.ToArray();
                return WriteConsoleInputW(h, buf, (uint)buf.Length, out var written)
                    ? (int)written
                    : -Marshal.GetLastWin32Error();
            }
            finally
            {
                CloseHandle(h);
            }
        }
        finally
        {
            GiveBack(had);
        }
    }

    private static void GiveBack(bool had)
    {
        FreeConsole();
        if (had)
        {
            AttachConsole(AttachParentProcess);
        }
    }
}
