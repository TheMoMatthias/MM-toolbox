using System.Windows;
using System.Windows.Media;

namespace SessionRestore.App.Views;

/// <summary>
/// The faces and the size scale the shipped window installs after parse.
/// </summary>
/// <remarks>
/// 🔴 THE XAML DOES NOT SAY WHAT IS ON SCREEN. <c>window2.xaml</c> names Segoe
/// for its three text keys and Cascadia for the pane, and the PowerShell REPLACES
/// all of them before the window is shown - <c>Install-SRTypeface</c>,
/// <c>Install-SRPaneFace</c> and <c>Set-SRTypeScale</c>. A port that took the
/// markup at its word would open in a face the operator has never seen.
/// </remarks>
public static class Typefaces
{
    private static readonly string[] TextKeys = ["FontText", "FontDisplay", "FontSmall"];

    // 🔑 FontMono is the key for text that genuinely wants the grid, so it takes
    // the shipped mono face too. The chrome does NOT - reversed 2026-09 on the
    // operator's word, "too terminal-like".
    private static readonly string[] PaneKeys = ["FontPane", "FontMono"];

    private static readonly string[] SizeKeys = ["Micro", "Caption", "Body", "Mono", "Strong", "Display", "Pane"];

    private const double PaneFallback = 13.0;

    /// <summary>What was installed, for the surface check to report.</summary>
    public sealed record Installed(bool Manrope, bool Plex, double Size);

    /// <summary>Installs both faces and the size scale at <paramref name="zoomPercent"/>.</summary>
    public static Installed Install(FrameworkElement window, int zoomPercent = 100)
    {
        ArgumentNullException.ThrowIfNull(window);
        var manrope = Put(window, Family("Manrope"), TextKeys);
        var plex = Put(window, Family("IBM Plex Mono"), PaneKeys);
        var size = Scale(window, zoomPercent);
        return new Installed(manrope, plex, size);
    }

    /// <summary>
    /// One family from the embedded fonts, or null when it would be synthesised.
    /// </summary>
    /// <remarks>
    /// 🪤 FEWER THAN TWO FACES MEANS EVERY WEIGHT IS FAKED - a smeared oblique and
    /// a double-struck bold, which is precisely the "fat" the operator reported.
    /// The shipped tool keeps the declared face instead, and so does this.
    /// </remarks>
    private static FontFamily? Family(string name)
    {
        var fams = Fonts.GetFontFamilies(new Uri("pack://application:,,,/fonts/"));
        foreach (var f in fams)
        {
            if (f.Source.EndsWith("#" + name, StringComparison.Ordinal) && f.GetTypefaces().Count >= 2)
            {
                return f;
            }
        }

        return null;
    }

    /// <summary>
    /// Assigns <paramref name="fam"/> to every key, and puts every one back if any is refused.
    /// </summary>
    /// <remarks>
    /// 🔴 A REFUSED FONT MUST LEAVE THE WINDOW AS IT FOUND IT. The shipped tool
    /// once assigned a composite family WPF refused, AFTER the first key had taken
    /// it - so a handled failure left a broken value in the dictionary the pane
    /// renders from, and the window would not start. Reading the value back is
    /// the check, because assignment is where the refusal happens.
    /// </remarks>
    private static bool Put(FrameworkElement window, FontFamily? fam, string[] keys)
    {
        if (fam is null)
        {
            return false;
        }

        var was = new List<(string Key, object? Value)>();
        try
        {
            foreach (var k in keys)
            {
                was.Add((k, window.Resources.Contains(k) ? window.Resources[k] : null));
                window.Resources[k] = fam;
                if (!ReferenceEquals(window.Resources[k], fam))
                {
                    throw new InvalidOperationException("the resource did not take the value");
                }
            }

            return true;
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException)
        {
            foreach (var (k, v) in was)
            {
                if (v is not null)
                {
                    window.Resources[k] = v;
                }
            }

            return false;
        }
    }

    /// <summary>
    /// Every <c>Sz*</c> resource to the pane's size at this zoom, to the half pixel.
    /// </summary>
    /// <remarks>
    /// 🔴 ONE SIZE ACROSS THE WHOLE WINDOW, and that is a recorded decision, not a
    /// shortcut: 2026-09-03 collapsed the six-step scale so nothing on screen is a
    /// different size from anything else, and weight, hue and position carry the
    /// hierarchy. The six base values stay in the XAML as the record of what the
    /// scale was.
    /// </remarks>
    private static double Scale(FrameworkElement window, int zoomPercent)
    {
        var zoom = Math.Max(70, Math.Min(200, zoomPercent)) / 100.0;
        var pane = window.Resources["SzPane"] is double d && d > 0 ? d : PaneFallback;
        var v = Math.Round(pane * zoom * 2.0, MidpointRounding.ToEven) / 2.0;
        foreach (var k in SizeKeys)
        {
            window.Resources["Sz" + k] = v;
        }

        return v;
    }
}
