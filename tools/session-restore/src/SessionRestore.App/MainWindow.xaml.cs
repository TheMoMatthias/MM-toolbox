using System.Globalization;
using System.IO;
using SessionRestore.Core;

namespace SessionRestore.App;

public partial class MainWindow : System.Windows.Window
{
    public MainWindow()
    {
        InitializeComponent();

        // Not decoration: it is the whole of what phase 1 claims to have built -
        // a window that starts, and a Core reference that resolves the real tool
        // beneath it. Nothing here reads a conversation yet.
        RootLine.Text = "tool root: " + ToolPaths.Root;

        var reg = new FileInfo(ToolPaths.Registry);
        StateLine.Text = reg.Exists
            ? string.Format(CultureInfo.InvariantCulture,
                "registry: {0:N0} KB, last written {1:yyyy-MM-dd HH:mm}  (read only - nothing here writes it)",
                reg.Length / 1024, reg.LastWriteTime)
            : "registry: not found at " + ToolPaths.Registry;
    }
}
