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
//   1. A SECOND PROCESS. wscript.exe started powershell.exe, which built a
//      console host, parsed a command line and only then loaded a runspace.
//      Hosting the runspace here removes that whole layer.
//   2. THE IDENTITY. Alt-Tab, the taskbar and the desktop button all showed the
//      PowerShell logo, because the shortcut literally said IconLocation =
//      'powershell.exe,0'. An icon is embedded here, so the app looks like
//      itself everywhere Windows shows it.
//   3. A SECOND WINDOW ON EVERY DOUBLE-CLICK. Nothing held a single-instance
//      lock, so a second launch built a second view of one registry file.
//      See the mutex below.
//   4. SILENT FAILURE. A throw before the window appeared went to
//      .state\restore.log and nowhere else. Here it is also a dialog.
//
// HONEST ABOUT WHAT IT DOES NOT DO: the window is not faster once it is up. The
// WPF and the PowerShell inside it are byte for byte what they were. What is
// saved is a process launch and the console host's startup; what is gained is
// that it stops looking and behaving like a script.
//
// APARTMENT. WPF requires STA, and sessions-gui.ps1 defends itself by
// re-launching through powershell.exe when it does not get one -- which here
// would silently reintroduce the very process this file removes. Main is
// [STAThread] and the runspace is pinned to this thread (UseCurrentThread), so
// the script's guard sees STA, does nothing, and the window's message loop is
// this process's own.
//
// DPI, deliberately not handled here. sessions-gui.ps1 calls
// SetProcessDpiAwarenessContext before it creates its first window, and that
// call only works while nothing has pinned awareness in the executable's
// manifest. csc.exe embeds a default manifest that says nothing about DPI, so
// the script's runtime call still wins. Adding a dpiAware entry to a manifest
// here would break it.
// ---------------------------------------------------------------------------

using System;
using System.Globalization;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace MMToolbox.SessionRestore
{
    internal static class SessionsApp
    {
        // Local\ scopes the mutex to this logon session, which is the right
        // scope: two users signed into one machine each get their own window
        // over their own registry, and neither blocks the other.
        private const string MutexName = @"Local\MMToolbox.SessionRestore.Gui";

        // Must match Title= in gui-window.xaml. Used ONLY to raise the window of
        // an instance that is already running. If the title ever drifts the
        // worst case is that a second launch exits quietly without bringing the
        // first one forward -- never a second window, which the mutex prevents
        // regardless of this string.
        private const string WindowTitle = "Claude sessions";

        private const string ScriptName = "sessions-gui.ps1";

        [STAThread]
        private static int Main(string[] argv)
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            string script = Path.Combine(baseDir, ScriptName);

            // SR_GUI_SHOW is the existing contract for "put the startup error on
            // screen rather than in the log"; Sessions.bat honours the same
            // variable. A winexe has no console at all, so make one.
            if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("SR_GUI_SHOW")))
            {
                AllocConsole();
            }

            if (!File.Exists(script))
            {
                Fail(baseDir,
                     ScriptName + " is not next to this application." +
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

                try
                {
                    return Run(script, argv);
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
                    single.ReleaseMutex();
                }
            }
        }

        // -------------------------------------------------------------------
        private static int Run(string script, string[] argv)
        {
            InitialSessionState iss = InitialSessionState.CreateDefault2();

            // The scripts are unsigned and live in a user folder, so a machine
            // whose policy is RemoteSigned or stricter would refuse to load
            // them. This is process-local -- it changes nothing for any other
            // PowerShell on the machine -- and is exactly what -ExecutionPolicy
            // Bypass on the old powershell.exe command line did.
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;

            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                // UseCurrentThread is the load-bearing line. Without it the
                // runspace spins up its own pipeline thread, the WPF window is
                // created there, and this thread sits with nothing to pump --
                // so ShowDialog blocks on a thread Windows is not delivering
                // messages to. On this thread, [STAThread] Main IS the UI thread.
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();

                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;

                    // Invoked through & rather than dot-sourced, for two
                    // reasons: the script's param() block binds properly (so
                    // -NoScan arrives as a switch and not as a string), and its
                    // closing `exit 0` ends the script instead of tearing down
                    // the pipeline underneath us.
                    ps.AddScript("param($path, $argv) & $path @argv", false)
                      .AddArgument(script)
                      .AddArgument(argv ?? new string[0]);

                    ps.Invoke();

                    if (ps.Streams.Error.Count > 0)
                    {
                        StringBuilder sb = new StringBuilder();
                        foreach (ErrorRecord e in ps.Streams.Error)
                        {
                            sb.AppendLine(e.ToString());
                            if (e.InvocationInfo != null)
                            {
                                sb.AppendLine("    at " + e.InvocationInfo.PositionMessage);
                            }
                        }
                        Fail(Path.GetDirectoryName(script), sb.ToString(), null);
                        return 1;
                    }
                }
            }
            return 0;
        }

        // -------------------------------------------------------------------
        // Both halves on purpose: the log is where a failure at logon has always
        // been written and other things read it, and the dialog is the point of
        // being an application -- a startup failure that leaves nothing on the
        // screen is indistinguishable from a machine that ignored the
        // double-click.
        private static void Fail(string baseDir, string message, Exception ex)
        {
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
                    "Claude sessions",
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

        private const int SW_RESTORE = 9;

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        private static extern bool IsIconic(IntPtr hWnd);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AllocConsole();
    }
}
