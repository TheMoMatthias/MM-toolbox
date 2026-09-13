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
/// 🔴 READ-ONLY: the registry, nothing else. No probe, no transcripts, no
/// handler - every row is non-live, which is why they all band as NOT RUNNING.
/// </remarks>
public static class Snapshot
{
    public static void SessionColumn(string pngPath)
    {
        var vm = new SessionsVm();
        vm.Sync(KeystrokeBench.Model());

        var w = new SessionsWindow
        {
            WindowStartupLocation = WindowStartupLocation.Manual,
            Left = -32000,
            Top = -32000,
            ShowInTaskbar = false,
            ShowActivated = false,
            IsHitTestVisible = false,
        };
        w.SessionList.ItemsSource = vm.View;

        w.Show();
        try
        {
            w.Dispatcher.Invoke(static () => { }, DispatcherPriority.ContextIdle);
            var list = w.SessionList;
            var dpi = VisualTreeHelper.GetDpi(list);
            var width = Math.Max(1, (int)Math.Ceiling(list.ActualWidth * dpi.DpiScaleX));
            var height = Math.Max(1, (int)Math.Ceiling(list.ActualHeight * dpi.DpiScaleY));
            var bmp = new RenderTargetBitmap(width, height, dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);

            // 🪤 THE LIST HAS A TRANSPARENT BACKGROUND, so rendering it alone gives
            // text on nothing. Paint the window's own ground under it first.
            // 🪤 AND THROUGH A VisualBrush, not Render(list): rendering a visual
            // that sits inside a tree carries its offset in the parent, and the
            // picture comes out shifted by wherever the column happens to be.
            var ground = new DrawingVisual();
            using (var dc = ground.RenderOpen())
            {
                var r = new Rect(0, 0, list.ActualWidth, list.ActualHeight);
                dc.DrawRectangle(w.Background, null, r);
                dc.DrawRectangle(new VisualBrush(list), null, r);
            }

            bmp.Render(ground);

            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(bmp));
            using var fs = File.Create(pngPath);
            enc.Save(fs);
        }
        finally
        {
            w.Close();
        }
    }
}
