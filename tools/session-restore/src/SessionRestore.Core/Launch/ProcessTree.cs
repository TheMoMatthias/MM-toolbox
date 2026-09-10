using System.Runtime.InteropServices;

namespace SessionRestore.Core.Launch;

/// <summary>One live process, as much of it as the end plan needs to decide.</summary>
public sealed record ProcessFacts(uint Pid, string Name, uint ParentPid)
{
    /// <summary>
    /// The full command line, or null when it could not be read.
    /// </summary>
    /// <remarks>
    /// 🔴 NULL IS "COULD NOT READ", NEVER "EMPTY". The boot-shell test is
    /// <c>command line looks like a boot script</c>, so a null that read as an
    /// empty string would answer "not a boot shell" for a process nobody could
    /// look at - a gate that abstains printing green.
    /// </remarks>
    public string? CommandLine { get; init; }
}

/// <summary>
/// Who is running and who started them. Read only - plan item 2.5c has no
/// method that ends a process.
/// </summary>
/// <remarks>
/// 🪤 NOT WMI, AND THE REASON IS MEASURED. The PowerShell asks
/// <c>Get-CimInstance Win32_Process -Filter "Name='claude.exe'"</c> and that cost
/// 824 to 1.367 ms in this repo's own notes - per call, on a path the window
/// takes while the operator is waiting. A single Toolhelp snapshot answers name
/// and parent for every process at once, and the command line is read only for
/// the one process a decision actually turns on.
///
/// 🔴 A PID IS REUSABLE, and that is why <see cref="Of"/> returns the NAME rather
/// than a boolean. Every caller here confirms the process at a recorded pid is
/// still the claude that owns the conversation before deciding anything about
/// it; a bare "does pid 12345 exist" would happily point at whatever inherited
/// the number.
/// </remarks>
public static class ProcessTree
{
    private const uint Th32csSnapProcess = 0x00000002;
    private const uint ProcessQueryInformation = 0x0400;
    private const uint ProcessVmRead = 0x0010;

    /// <summary>Every process, by pid. One snapshot.</summary>
    public static Dictionary<uint, ProcessFacts> All()
    {
        var map = new Dictionary<uint, ProcessFacts>();
        var snap = CreateToolhelp32Snapshot(Th32csSnapProcess, 0);
        if (snap == IntPtr.Zero || snap == new IntPtr(-1))
        {
            return map;
        }

        try
        {
            var e = default(ProcessEntry32W);
            e.Size = (uint)Marshal.SizeOf<ProcessEntry32W>();
            if (!Process32FirstW(snap, ref e))
            {
                return map;
            }

            do
            {
                // 🪤 THE SAME PID CAN APPEAR TWICE across a snapshot taken while
                // processes are starting and ending. First one wins rather than
                // throwing: this is a read of something that moves.
                map.TryAdd(e.ProcessId, new ProcessFacts(e.ProcessId, e.ExeFile ?? string.Empty, e.ParentProcessId));
                e.Size = (uint)Marshal.SizeOf<ProcessEntry32W>();
            }
            while (Process32NextW(snap, ref e));
        }
        finally
        {
            CloseHandle(snap);
        }

        return map;
    }

    /// <summary>One process, or null when nothing is running at that pid.</summary>
    public static ProcessFacts? Of(uint pid, Dictionary<uint, ProcessFacts>? snapshot = null)
    {
        var all = snapshot ?? All();
        return all.TryGetValue(pid, out var p) ? p : null;
    }

    /// <summary>
    /// The command line of a running process, or null if it cannot be read.
    /// </summary>
    /// <remarks>
    /// 🪤 IT NEEDS PROCESS_VM_READ, so a process running elevated or as another
    /// user answers null even though WMI would answer for it. That is a real
    /// difference from the PowerShell and it is reported as "could not read"
    /// rather than papered over - the sessions this tool owns are all the
    /// operator's own, and one that is not should be visible, not guessed at.
    /// </remarks>
    public static string? CommandLineOf(uint pid)
    {
        var h = OpenProcess(ProcessQueryInformation | ProcessVmRead, false, pid);
        if (h == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            var pbi = default(ProcessBasicInformation);
            if (NtQueryInformationProcess(h, 0, ref pbi, (uint)Marshal.SizeOf<ProcessBasicInformation>(), out _) != 0
                || pbi.PebBaseAddress == IntPtr.Zero)
            {
                return null;
            }

            // PEB -> ProcessParameters (offset 0x20 on x64) -> CommandLine
            // UNICODE_STRING (offset 0x70). Both offsets are for a 64-bit process
            // read by a 64-bit reader, which is the only combination this ships in.
            if (!ReadPtr(h, pbi.PebBaseAddress + 0x20, out var upp) || upp == IntPtr.Zero)
            {
                return null;
            }

            var us = new byte[16];
            if (!ReadProcessMemory(h, upp + 0x70, us, us.Length, out var got) || got != us.Length)
            {
                return null;
            }

            // 🪤 Length IS A ushort OF BYTES, so it cannot exceed 65.535 and a
            // sanity cap on it would be dead code. The bound that matters is the
            // read itself, which is checked below.
            var len = BitConverter.ToUInt16(us, 0);
            var buf = new IntPtr(BitConverter.ToInt64(us, 8));
            if (len == 0 || buf == IntPtr.Zero)
            {
                return null;
            }

            var raw = new byte[len];
            if (!ReadProcessMemory(h, buf, raw, raw.Length, out var n) || n != raw.Length)
            {
                return null;
            }

            return System.Text.Encoding.Unicode.GetString(raw);
        }
        finally
        {
            CloseHandle(h);
        }
    }

    private static bool ReadPtr(IntPtr h, IntPtr at, out IntPtr value)
    {
        var b = new byte[8];
        if (!ReadProcessMemory(h, at, b, b.Length, out var got) || got != b.Length)
        {
            value = IntPtr.Zero;
            return false;
        }

        value = new IntPtr(BitConverter.ToInt64(b, 0));
        return true;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry32W
    {
        public uint Size;
        public uint Usage;
        public uint ProcessId;
        public IntPtr DefaultHeapId;
        public uint ModuleId;
        public uint Threads;
        public uint ParentProcessId;
        public int PriClassBase;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string ExeFile;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessBasicInformation
    {
        public IntPtr ExitStatus;
        public IntPtr PebBaseAddress;
        public IntPtr AffinityMask;
        public IntPtr BasePriority;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    // 🪤 DllImport RATHER THAN LibraryImport, for the same reason ConsoleApi
    // gives: the generated marshalling cannot pass the fixed-size string buffer
    // inside PROCESSENTRY32W.
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry32W entry);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry32W entry);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReadProcessMemory(
        IntPtr h, IntPtr addr, [Out] byte[] buffer, int size, out int read);

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(
        IntPtr h, int cls, ref ProcessBasicInformation info, uint size, out uint returned);
}
