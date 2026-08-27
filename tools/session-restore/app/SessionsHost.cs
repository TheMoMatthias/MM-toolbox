// ---------------------------------------------------------------------------
// Sessions.exe -- the session console as an application rather than a script.
//
// WHAT THIS IS NOT: a rewrite. Not one line of the ~10,000 lines of PowerShell
// behind the window moved. This process opens a Windows PowerShell 5.1 runspace
// IN ITSELF and runs sessions-gui.ps1 inside it, on this thread. The script sees
// the same $PSScriptRoot, dot-sources the same _common.ps1, and reads the same
// gui-window.xaml as it always did. Every test driver still drives the .ps1
// files directly and is unaffected by this file existing.
//
// WHY IT EXISTS: launching through powershell.exe cost four things that the .vbs
// wrapper hides but cannot fix.
//
//   1. THE IDENTITY. Alt-Tab, the taskbar and the desktop button all showed the
//      PowerShell logo, because the shortcut literally said IconLocation =
//      'powershell.exe,0'. An icon is embedded here, so the app looks like
//      itself everywhere Windows shows it.
//   2. A SECOND WINDOW ON EVERY DOUBLE-CLICK. Nothing held a single-instance
//      lock, so a second launch built a second view of one registry. See the
//      two guards below.
//   3. SILENT FAILURE. A throw before the window appeared went to
//      .state\restore.log and nowhere else. Here it is also a dialog.
//   4. NOTHING ON SCREEN FOR SECONDS. See "THE SPLASH".
//
// AND A SMALL AMOUNT OF TIME. Measured 2026-08-27, medians over seven runs:
//
//      wscript.exe (noop)                144.6 ms  }  the old prelude,
//      powershell.exe -Command exit      608.5 ms  }  753.1 ms
//      Sessions.exe start + file check   580.1 ms  }  the new one,
//      runspace CreateDefault2 + Open      7.7 ms  }  587.8 ms
//
// So ~165 ms, and that figure is an UPPER BOUND: the path measured for the exe
// returns before System.Management.Automation is loaded, which a real launch
// pays for. Note the exe's own start (580 ms) is within noise of
// powershell.exe's (608 ms) -- the CLR is the cost, not the console host, and
// nearly all of the saving is the removed wscript.exe hop. Against 5.8 s from
// double-click to window it is about 3 per cent. SPEED IS NOT WHAT THIS BOUGHT,
// and the docs say so.
//
// APARTMENT. WPF requires STA, and sessions-gui.ps1 defends itself by
// re-launching through powershell.exe when it does not get one -- which here
// would silently reintroduce the process this file removes. Main is [STAThread]
// and the runspace is pinned to this thread (UseCurrentThread), so the script's
// guard sees STA, does nothing, and the window's message loop is this process's
// own.
//
// 🔴 DPI, AND WHY IT IS HANDLED HERE NOW. sessions-gui.ps1 calls
// SetProcessDpiAwarenessContext before it creates its first window, and its own
// comment says why that position matters: process DPI awareness is fixed when
// the first HWND is created and cannot be changed afterwards. THE SPLASH IS AN
// HWND, and it exists first -- so without the call below, adding a splash would
// have silently pinned this process as DPI-unaware and gone soft on every
// non-96-DPI screen, with nothing failing and nothing to read. The host makes
// the call itself, before any window; the script's own call then returns false
// harmlessly, which it already tolerates. If the call FAILS, there is no splash
// at all: a few seconds of blank desktop is a far smaller price than a blurry
// window nobody can explain.
// ---------------------------------------------------------------------------

using System;
using System.Globalization;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// ---------------------------------------------------------------------------
// VERSION METADATA. Without this the exe reports FileVersion 0.0.0.0 and a blank
// product, description and company -- which is what it did until 2026-08-27,
// measured. That is not cosmetic:
//
//   * Task Manager and Details show a nameless entry, so the one process the
//     operator most needs to recognise is the one they cannot.
//   * right-click -> Properties -> Details is empty, which is the first place
//     anyone looks when asking "what IS this thing on my desktop".
//   * an unsigned binary with NO metadata at all scores worse with SmartScreen
//     and with behavioural antivirus than an unsigned binary that says what it
//     is -- and this repo has been quarantined once already (CONTEXT.md).
//
// AssemblyTitle becomes FileDescription, which is the column Task Manager and
// the taskbar actually show. It is deliberately the same string as the window
// title, so the process, the window and the taskbar all say one thing.
// ---------------------------------------------------------------------------
[assembly: AssemblyTitle("Claude sessions")]
[assembly: AssemblyDescription("The session console: every Claude Code conversation on this machine, what each last said, and which of them reopen at logon.")]
[assembly: AssemblyProduct("session-restore")]
[assembly: AssemblyCompany("MM-toolbox")]
[assembly: AssemblyCopyright("Local tool. No warranty, no telemetry, no network.")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace MMToolbox.SessionRestore
{
    internal static class SessionsApp
    {
        // Local\ scopes the mutex to this logon session, which is the right
        // scope: two users signed into one machine each get their own window
        // over their own registry, and neither blocks the other.
        private const string MutexName = @"Local\MMToolbox.SessionRestore.Gui";

        // Must match Title= in gui-window.xaml. Used to raise an instance that is
        // already running, and by the splash to know when to get out of the way.
        internal const string WindowTitle = "Claude sessions";

        private const string GuiScript = "sessions-gui.ps1";
        private const string RestoreScript = "restore-sessions.ps1";

        [STAThread]
        private static int Main(string[] argv)
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');

            // SR_GUI_SHOW is the existing contract for "put the startup error on
            // screen rather than in the log"; Sessions.bat honours the same
            // variable. A winexe has no console at all, so make one.
            if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("SR_GUI_SHOW")) &&
                GetConsoleWindow() == IntPtr.Zero)
            {
                AllocConsole();
                AttachStdIo();
            }

            // -Restore runs the OTHER script, so one binary is both desktop
            // buttons and both carry the app's icon. It is a different action,
            // not a second window: no mutex, no splash, and a console because
            // restoring prints what it launched and you are meant to read it.
            string[] rest;
            if (TakeSwitch(argv, "-Restore", out rest))
            {
                return RunRestore(baseDir, rest);
            }

            string script = Path.Combine(baseDir, GuiScript);
            if (!File.Exists(script))
            {
                Fail(baseDir,
                     GuiScript + " is not next to this application." +
                     Environment.NewLine + Environment.NewLine +
                     "Looked in:" + Environment.NewLine + baseDir,
                     null);
                return 2;
            }

            bool createdNew;
            using (Mutex single = new Mutex(true, MutexName, out createdNew))
            {
                // TWO GUARDS, because there are two ways in. The mutex catches a
                // second Sessions.exe. The window search catches an instance
                // started the OLD way -- Sessions.bat and Sessions GUI.vbs run
                // the same script under powershell.exe, which never touches this
                // mutex, and a machine mid-migration has both routes on the
                // desktop. Measured 2026-08-27: with only the mutex, launching
                // the exe alongside a .vbs-started window opened a second view
                // of one sessions-registry.json.
                //
                // Raising the existing window is what every other desktop app
                // does; two views of one registry file is how you end up with
                // two screens that disagree about what is ticked.
                if (!createdNew || FindWindow(null, WindowTitle) != IntPtr.Zero)
                {
                    RaiseExistingWindow();
                    return 0;
                }

                // So the script's last-resort $here fallback -- (Get-Location) --
                // lands on the tool folder rather than on whatever directory
                // Explorer happened to hand us.
                try { Directory.SetCurrentDirectory(baseDir); }
                catch (Exception) { /* not fatal: $PSScriptRoot resolves first anyway */ }

                // Read the comment at the top of this file before moving either
                // of these two lines, or reordering them.
                bool dpiOk = TrySetPerMonitorDpi();
                if (dpiOk && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("SR_NO_SPLASH")))
                {
                    Splash.Start();
                }

                try
                {
                    return Run(script, rest);
                }
                catch (Exception ex)
                {
                    Fail(baseDir,
                         "The session console could not start." +
                         Environment.NewLine + Environment.NewLine + ex.Message,
                         ex);
                    return 1;
                }
                finally
                {
                    Splash.Stop();
                    single.ReleaseMutex();
                }
            }
        }

        // -------------------------------------------------------------------
        private static int Run(string script, string[] argv)
        {
            using (Runspace rs = NewRunspace())
            using (PowerShell ps = PowerShell.Create())
            {
                ps.Runspace = rs;

                // Invoked through & rather than dot-sourced so the script's
                // closing `exit 0` ends the script instead of tearing down the
                // pipeline underneath us. See BuildInvocation for why the
                // arguments are text rather than AddArgument calls.
                ps.AddScript(BuildInvocation(script, argv), false);

                ps.Invoke();

                if (ps.Streams.Error.Count > 0)
                {
                    Fail(Path.GetDirectoryName(script), Describe(ps.Streams.Error), null);
                    return 1;
                }
            }
            return 0;
        }

        // -------------------------------------------------------------------
        // -Restore. The same runspace, the other script, and a console -- because
        // "Restore Sessions.bat" has always printed what it launched and paused
        // so you could read it, and folding it into the app must not quietly
        // take that away.
        private static int RunRestore(string baseDir, string[] argv)
        {
            string script = Path.Combine(baseDir, RestoreScript);
            if (!File.Exists(script))
            {
                Fail(baseDir, RestoreScript + " is not next to this application.", null);
                return 2;
            }

            // No console of our own means Explorer or a shortcut started us, so
            // we make one AND pause at the end. Started from a terminal we
            // inherit its console, print into it, and must not pause -- which is
            // the same rule the .bat implemented by grepping %cmdcmdline%, done
            // by asking the OS instead of by pattern-matching a command line.
            bool ownConsole = GetConsoleWindow() == IntPtr.Zero;
            if (ownConsole) { AllocConsole(); AttachStdIo(); }

            try { Directory.SetCurrentDirectory(baseDir); }
            catch (Exception) { }

            int code = 0;
            try
            {
                using (Runspace rs = NewRunspace())
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;

                    // Write-Host in a hosted runspace goes to the INFORMATION
                    // stream, not to a console -- so without this the restore
                    // would run correctly and print absolutely nothing. Colours
                    // are carried on the record and are reapplied, or the output
                    // arrives as a wall of grey where it used to be readable.
                    ps.Streams.Information.DataAdded += (s, e) =>
                    {
                        InformationRecord r = ps.Streams.Information[e.Index];
                        HostInformationMessage hm = r.MessageData as HostInformationMessage;
                        if (hm == null) { Console.WriteLine(r.MessageData); return; }
                        ConsoleColor fg = Console.ForegroundColor;
                        try
                        {
                            if (hm.ForegroundColor.HasValue) { Console.ForegroundColor = hm.ForegroundColor.Value; }
                            if (hm.NoNewLine.HasValue && hm.NoNewLine.Value) { Console.Write(hm.Message); }
                            else { Console.WriteLine(hm.Message); }
                        }
                        finally { Console.ForegroundColor = fg; }
                    };
                    ps.Streams.Warning.DataAdded += (s, e) =>
                        WriteColoured(ConsoleColor.Yellow, "WARNING: " + ps.Streams.Warning[e.Index].Message);
                    ps.Streams.Error.DataAdded += (s, e) =>
                        WriteColoured(ConsoleColor.Red, ps.Streams.Error[e.Index].ToString());

                    ps.AddScript(BuildInvocation(script, argv), false);

                    ps.Invoke();

                    // The script ends in `exit <n>`; under & that sets
                    // $LASTEXITCODE rather than ending the process, so the exit
                    // code has to be read back out of the runspace.
                    object last = rs.SessionStateProxy.GetVariable("LASTEXITCODE");
                    if (last != null) { int.TryParse(last.ToString(), out code); }
                    if (ps.Streams.Error.Count > 0 && code == 0) { code = 1; }
                }
            }
            catch (Exception ex)
            {
                WriteColoured(ConsoleColor.Red, "FATAL: " + ex.Message);
                Fail(baseDir, "The restore could not run." + Environment.NewLine + ex.Message, ex);
                code = 1;
            }

            if (ownConsole && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("SR_NOPAUSE")))
            {
                Console.WriteLine();
                Console.Write("Press any key to close this window...");
                try { Console.ReadKey(true); } catch (Exception) { /* no real input handle */ }
            }
            return code;
        }

        // -------------------------------------------------------------------
        private static Runspace NewRunspace()
        {
            InitialSessionState iss = InitialSessionState.CreateDefault2();

            // The scripts are unsigned and live in a user folder, so a machine
            // whose policy is RemoteSigned or stricter would refuse to load
            // them. This is process-local -- it changes nothing for any other
            // PowerShell on the machine -- and is exactly what -ExecutionPolicy
            // Bypass on the old powershell.exe command line did.
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;

            Runspace rs = RunspaceFactory.CreateRunspace(iss);

            // UseCurrentThread is the load-bearing line for the GUI. Without it
            // the runspace spins up its own pipeline thread, the WPF window is
            // created there, and this thread sits with nothing to pump -- so
            // ShowDialog blocks on a thread Windows is not delivering messages
            // to. On this thread, [STAThread] Main IS the UI thread.
            rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
            rs.Open();
            return rs;
        }

        // -------------------------------------------------------------------
        // 🔴 HOW ARGUMENTS REACH THE SCRIPT, and why it is done the long way.
        //
        // The obvious way is a wrapper -- AddScript("param($p,$a) & $p @a")
        // with AddArgument for each. IT SILENTLY MIS-BINDS, and this was shipped
        // before it was measured. Probed 2026-08-27 against a stub with the same
        // param shape as restore-sessions.ps1, passing -DryRun -Place -3440,0:
        //
        //   AddScript + AddArgument   DryRun=False  Place=[-DryRun]
        //   AddScript + AddParameter  DryRun=False  Place=[-DryRun]
        //   built command text        DryRun=True   Place=[-3440,0]
        //
        // Both API routes pass every token POSITIONALLY: a parameter NAME is
        // never recognised, so "-DryRun" arrived as a string VALUE bound to the
        // next positional parameter. No error, no warning. The measured cost of
        // that was a restore asked for as a dry run launching two real Claude
        // sessions, and -NoScan never reaching the GUI at all.
        //
        // So the invocation is built as TEXT, exactly as a command line would
        // be. A token is left unquoted only when it is unmistakably a parameter
        // name -- a leading dash, then letters, digits, hyphens and nothing else
        // -- and everything else is single-quoted with its quotes doubled. That
        // keeps -Place '-3440,0' working (a VALUE that starts with a dash, which
        // must stay quoted) and leaves nothing shaped like an argument able to
        // become code.
        private static string BuildInvocation(string script, string[] argv)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("& '").Append(script.Replace("'", "''")).Append("'");
            foreach (string a in (argv ?? new string[0]))
            {
                if (string.IsNullOrEmpty(a)) { continue; }
                if (LooksLikeParameterName(a)) { sb.Append(' ').Append(a); }
                else { sb.Append(" '").Append(a.Replace("'", "''")).Append("'"); }
            }
            return sb.ToString();
        }

        private static bool LooksLikeParameterName(string a)
        {
            if (a.Length < 2 || a[0] != '-' || !char.IsLetter(a[1])) { return false; }
            for (int i = 1; i < a.Length; i++)
            {
                char c = a[i];
                if (!char.IsLetterOrDigit(c) && c != '-') { return false; }
            }
            return true;
        }

        private static string Describe(PSDataCollection<ErrorRecord> errors)
        {
            StringBuilder sb = new StringBuilder();
            foreach (ErrorRecord e in errors)
            {
                sb.AppendLine(e.ToString());
                if (e.InvocationInfo != null) { sb.AppendLine("    at " + e.InvocationInfo.PositionMessage); }
            }
            return sb.ToString();
        }

        private static void WriteColoured(ConsoleColor c, string s)
        {
            ConsoleColor fg = Console.ForegroundColor;
            try { Console.ForegroundColor = c; Console.WriteLine(s); }
            finally { Console.ForegroundColor = fg; }
        }

        // Pulls the named switch out of the argument list, case-insensitively,
        // and hands back everything else to forward to the script.
        private static bool TakeSwitch(string[] argv, string name, out string[] rest)
        {
            bool found = false;
            System.Collections.Generic.List<string> keep = new System.Collections.Generic.List<string>();
            foreach (string a in (argv ?? new string[0]))
            {
                if (string.Equals(a, name, StringComparison.OrdinalIgnoreCase)) { found = true; }
                else { keep.Add(a); }
            }
            rest = keep.ToArray();
            return found;
        }

        // -------------------------------------------------------------------
        // Both halves on purpose: the log is where a failure at logon has always
        // been written and other things read it, and the dialog is the point of
        // being an application -- a startup failure that leaves nothing on the
        // screen is indistinguishable from a machine that ignored the
        // double-click.
        private static void Fail(string baseDir, string message, Exception ex)
        {
            Splash.Stop();
            try
            {
                string stateDir = Path.Combine(
                    string.IsNullOrEmpty(baseDir) ? "." : baseDir, ".state");
                Directory.CreateDirectory(stateDir);
                string line = string.Format(CultureInfo.InvariantCulture,
                    "[{0:yyyy-MM-dd HH:mm:ss}] Sessions.exe: {1}{2}",
                    DateTime.Now,
                    message.Replace(Environment.NewLine, " | "),
                    Environment.NewLine);
                File.AppendAllText(Path.Combine(stateDir, "restore.log"), line,
                                   new UTF8Encoding(false));
            }
            catch (Exception) { /* a broken log must not swallow the dialog */ }

            // A TEST SEAM, and the only one in this file. MessageBox.Show blocks
            // until somebody clicks it, so the app-driver's negative case --
            // "start with sessions-gui.ps1 missing and prove it refuses" --
            // would hang forever instead of failing. With this set the failure
            // still goes to the log, which is what that test then reads.
            if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("SR_GUI_NODIALOG")))
            {
                return;
            }

            try
            {
                System.Windows.Forms.MessageBox.Show(
                    message,
                    WindowTitle,
                    System.Windows.Forms.MessageBoxButtons.OK,
                    System.Windows.Forms.MessageBoxIcon.Error);
            }
            catch (Exception) { /* no desktop to draw on: a service, a locked session */ }
        }

        // -------------------------------------------------------------------
        private static void RaiseExistingWindow()
        {
            IntPtr hwnd = FindWindow(null, WindowTitle);
            if (hwnd == IntPtr.Zero) { return; }
            if (IsIconic(hwnd)) { ShowWindow(hwnd, SW_RESTORE); }
            SetForegroundWindow(hwnd);
        }

        // PER_MONITOR_AWARE_V2. Wrapped because the entry point does not exist
        // before Windows 10 1703, and because a process whose manifest already
        // pinned awareness is refused -- in both cases the answer is false and
        // the caller does without the splash.
        private static bool TrySetPerMonitorDpi()
        {
            try { return SetProcessDpiAwarenessContext(new IntPtr(-4)); }
            catch (Exception) { return false; }
        }

        // Console handles cached by the CLR before AllocConsole point at nothing,
        // so stdout and stdin are reopened onto the console we just made.
        private static void AttachStdIo()
        {
            try
            {
                StreamWriter w = new StreamWriter(Console.OpenStandardOutput());
                w.AutoFlush = true;
                Console.SetOut(w);
                Console.SetIn(new StreamReader(Console.OpenStandardInput()));
            }
            catch (Exception) { }
        }

        private const int SW_RESTORE = 9;

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        private static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AllocConsole();

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetConsoleWindow();
    }

    // -----------------------------------------------------------------------
    // THE SPLASH.
    //
    // Measured 2026-08-27: 5.8 seconds from double-click to window, of which the
    // host is ~0.6. The rest is the GUI script -- WPF loading, 115 KB of XAML
    // parsing, and a 208-conversation registry being read. During all of it the
    // desktop showed NOTHING, which is the single loudest way this still read as
    // a script: an application acknowledges the click.
    //
    // Deliberately NOT on the main thread. That thread is about to be handed to
    // the runspace and will be executing PowerShell solidly until the real
    // window appears, so anything drawn on it would be a frozen rectangle --
    // worse than blank. This runs its own STA thread with its own message pump.
    //
    // It closes by WATCHING FOR THE REAL WINDOW rather than by being told, so it
    // needs no cooperation from the PowerShell and there is nothing to keep in
    // sync when that script changes. Belt and braces: a hard deadline closes it
    // regardless, because a splash that outlives its cause is the worst outcome
    // available here.
    // -----------------------------------------------------------------------
    internal static class Splash
    {
        private static Thread _thread;
        private static System.Windows.Forms.Form _form;
        private static volatile bool _stop;

        private const int PollMs = 120;
        private const int DeadlineMs = 180000;

        internal static void Start()
        {
            _stop = false;
            _thread = new Thread(Pump);
            _thread.IsBackground = true;   // can never hold the process open
            _thread.SetApartmentState(ApartmentState.STA);
            _thread.Start();
        }

        internal static void Stop()
        {
            _stop = true;
            try
            {
                System.Windows.Forms.Form f = _form;
                if (f != null && f.IsHandleCreated && !f.IsDisposed)
                {
                    f.BeginInvoke((System.Windows.Forms.MethodInvoker)delegate
                    {
                        try { f.Close(); } catch (Exception) { }
                    });
                }
            }
            catch (Exception) { }
        }

        private static void Pump()
        {
            try
            {
                using (System.Windows.Forms.Form f = Build())
                {
                    _form = f;
                    System.Windows.Forms.Application.Run(f);
                }
            }
            catch (Exception) { /* a splash must never be able to fail the launch */ }
            finally { _form = null; }
        }

        private static System.Windows.Forms.Form Build()
        {
            System.Drawing.Color plate = System.Drawing.Color.FromArgb(21, 22, 26);
            System.Drawing.Color ink = System.Drawing.Color.FromArgb(233, 234, 236);
            System.Drawing.Color dim = System.Drawing.Color.FromArgb(138, 143, 150);

            System.Windows.Forms.Form f = new System.Windows.Forms.Form();
            f.FormBorderStyle = System.Windows.Forms.FormBorderStyle.None;
            f.StartPosition = System.Windows.Forms.FormStartPosition.CenterScreen;
            f.Size = new System.Drawing.Size(440, 132);
            f.BackColor = plate;
            f.TopMost = true;

            // NO TASKBAR BUTTON AND NO TITLE, both on purpose. A titled window
            // would become this process's MainWindowTitle, and the app-driver
            // waits for exactly that string to decide the real window is up --
            // a splash that answers for it would make the test pass early and
            // measure nothing.
            f.ShowInTaskbar = false;
            f.Text = "";

            f.Paint += delegate(object s, System.Windows.Forms.PaintEventArgs e)
            {
                using (System.Drawing.Pen p = new System.Drawing.Pen(System.Drawing.Color.FromArgb(60, 64, 70)))
                {
                    e.Graphics.DrawRectangle(p, 0, 0, f.Width - 1, f.Height - 1);
                }
            };

            try
            {
                System.Drawing.Icon ico = System.Drawing.Icon.ExtractAssociatedIcon(
                    System.Windows.Forms.Application.ExecutablePath);
                if (ico != null)
                {
                    System.Windows.Forms.PictureBox pb = new System.Windows.Forms.PictureBox();
                    pb.Image = ico.ToBitmap();
                    pb.SizeMode = System.Windows.Forms.PictureBoxSizeMode.Zoom;
                    pb.Bounds = new System.Drawing.Rectangle(30, 34, 48, 48);
                    pb.BackColor = System.Drawing.Color.Transparent;
                    f.Controls.Add(pb);
                }
            }
            catch (Exception) { }

            System.Windows.Forms.Label title = new System.Windows.Forms.Label();
            title.Text = SessionsApp.WindowTitle;
            title.ForeColor = ink;
            title.Font = new System.Drawing.Font("Segoe UI", 15F, System.Drawing.FontStyle.Regular);
            title.AutoSize = true;
            title.Location = new System.Drawing.Point(100, 36);
            title.BackColor = System.Drawing.Color.Transparent;
            f.Controls.Add(title);

            System.Windows.Forms.Label sub = new System.Windows.Forms.Label();
            sub.Text = "starting";
            sub.ForeColor = dim;
            sub.Font = new System.Drawing.Font("Segoe UI", 9F, System.Drawing.FontStyle.Regular);
            sub.AutoSize = true;
            sub.Location = new System.Drawing.Point(103, 70);
            sub.BackColor = System.Drawing.Color.Transparent;
            f.Controls.Add(sub);

            int elapsed = 0;
            int dots = 0;
            System.Windows.Forms.Timer t = new System.Windows.Forms.Timer();
            t.Interval = PollMs;
            t.Tick += delegate
            {
                elapsed += PollMs;

                // The dots are not decoration: a static panel for six seconds
                // reads as hung, which is the thing this exists to prevent.
                if (elapsed % 480 < PollMs)
                {
                    dots = (dots + 1) % 4;
                    sub.Text = "starting" + new string('.', dots);
                }

                if (_stop || elapsed >= DeadlineMs || RealWindowIsUp(f.Handle))
                {
                    t.Stop();
                    try { f.Close(); } catch (Exception) { }
                }
            };
            f.Shown += delegate { t.Start(); };
            return f;
        }

        // A top-level window of THIS process, titled like the real one, that is
        // not the splash itself.
        private static bool RealWindowIsUp(IntPtr splash)
        {
            IntPtr found = IntPtr.Zero;
            uint me = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                if (h == splash) { return true; }
                uint owner;
                GetWindowThreadProcessId(h, out owner);
                if (owner != me) { return true; }
                if (!IsWindowVisible(h)) { return true; }
                StringBuilder sb = new StringBuilder(256);
                GetWindowTextW(h, sb, sb.Capacity);
                if (sb.ToString() == SessionsApp.WindowTitle) { found = h; return false; }
                return true;
            }, IntPtr.Zero);
            return found != IntPtr.Zero;
        }

        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetWindowTextW")]
        private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);
    }
}
