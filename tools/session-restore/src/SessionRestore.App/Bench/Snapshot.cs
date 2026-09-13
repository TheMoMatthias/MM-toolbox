using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using SessionRestore.App.ViewModels;
using SessionRestore.App.Views;

namespace SessionRestore.App.Bench;

/// <summary>
/// Renders part of the ported window to a PNG, so a port can be looked at.
/// </summary>
/// <remarks>
/// 🔴 A GREEN IS NOT A PICTURE. The surface check proves a control exists and the
/// bench proves nothing failed to bind; neither says the row reads the way the
/// shipped one does. This is the cheapest honest way to find out, and it uses the
/// same off-screen showing as the bench: -32000, not activated, not hit-testable.
///
/// 🔴 READ-ONLY: the registry and the queue tails of warm transcripts, nothing
/// else. No probe, no console, no handler - every row is non-live, which is why
/// they all band as NOT RUNNING.
/// </remarks>
public static class Snapshot
{
    /// <param name="fakeQueue">Give the newest conversation a synthetic queue - two of
    /// yours, one from the machine - so the mark can be LOOKED at even when nothing
    /// on this machine is waiting. Nothing is written; the queue exists only in memory.</param>
    public static void SessionColumn(string pngPath, bool fakeQueue = false)
    {
        // The queues of the conversations the surface will show, so a mark that
        // exists on this machine is drawn. Read-only: a 4 MB tail per transcript.
        var model = KeystrokeBench.Model();
        var queues = new Dictionary<string, RowExtras>(StringComparer.OrdinalIgnoreCase);
        foreach (var (id, s, _) in model)
        {
            if (Core.Rows.Titles.Warm(s) && !string.IsNullOrEmpty(s.Jsonl))
            {
                var use = Core.Transcripts.ContextUse.Read(s.Jsonl);
                queues[id] = new RowExtras(
                    Core.Transcripts.Waiting.Read(s.Jsonl),
                    null,
                    0,
                    use.Ok ? new Core.Rows.CachedContext(use.Tokens, use.Window, s.Jsonl, DateTime.Now) : null,
                    null);
            }
        }

        if (fakeQueue && model.Count > 0)
        {
            var newest = model.OrderByDescending(m => m.S.LastActive).First();
            var now = DateTime.Now;
            // A queue, a shell, two sub-agents and a compact two-thirds through -
            // every mark the row can draw, on one row.
            queues[newest.Id] = new RowExtras(
                new Core.Transcripts.QueueState(
                [
                    new("<task-notification>x</task-notification>", "x", now.AddMinutes(-1), false),
                    new("please check the logs", "please check the logs", now.AddMinutes(-4), true),
                    new("and then the build", "and then the build", now.AddMinutes(-2), true),
                ], 2, 1, true, now),
                new Core.Rows.RowScreen(1, 2, -1, -1, true, 66, 97, now),
                0,
                null,
                null);
        }

        var vm = new SessionsVm();
        vm.Sync(model, extras: queues);

        var w = new SessionsWindow
        {
            WindowStartupLocation = WindowStartupLocation.Manual,
            Left = -32000,
            Top = -32000,
            ShowInTaskbar = false,
            ShowActivated = false,
            IsHitTestVisible = false,
        };
        // The rail through the real shell, preferences going nowhere - the same
        // wiring the handler check drives.
        new WindowShell(w, vm, new Services.NoPreferences()).Attach();

        w.Show();
        try
        {
            w.Dispatcher.Invoke(static () => { }, DispatcherPriority.ContextIdle);
            Save(w, w.SessionList, pngPath);
            Save(w, w.RailList, Path.ChangeExtension(pngPath, null) + "-rail.png");
        }
        finally
        {
            w.Close();
        }
    }

    /// <summary>One element of the window, on the window's own ground, to a PNG.</summary>
    /// <remarks>
    /// 🪤 THE LIST HAS A TRANSPARENT BACKGROUND, so it is painted over the window's
    /// ground - and through a VisualBrush, since rendering a visual inside a tree
    /// carries its offset in the parent and the picture comes out shifted.
    /// </remarks>
    private static void Save(Window w, FrameworkElement e, string pngPath)
    {
        var dpi = VisualTreeHelper.GetDpi(e);
        var width = Math.Max(1, (int)Math.Ceiling(e.ActualWidth * dpi.DpiScaleX));
        var height = Math.Max(1, (int)Math.Ceiling(e.ActualHeight * dpi.DpiScaleY));
        var bmp = new RenderTargetBitmap(width, height, dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        var ground = new DrawingVisual();
        using (var dc = ground.RenderOpen())
        {
            var r = new Rect(0, 0, e.ActualWidth, e.ActualHeight);
            dc.DrawRectangle(w.Background, null, r);
            dc.DrawRectangle(new VisualBrush(e), null, r);
        }

        bmp.Render(ground);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(bmp));
        using var fs = File.Create(pngPath);
        enc.Save(fs);
    }
}
