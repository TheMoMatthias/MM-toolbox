using System.Globalization;
using System.Windows.Data;
using System.Windows.Media;
using SessionRestore.Core.Rows;

namespace SessionRestore.App.Views;

/// <summary>
/// A band key to its accent brush.
/// </summary>
/// <remarks>
/// 🔑 THE BRUSHES ARE SET IN THE MARKUP, from the window's own <c>Acc*</c>
/// resources, so the palette stays in one place - the XAML - and this knows only
/// which band is which. The PowerShell resolved <c>FindResource($b.Acc)</c> once
/// per band per rebuild and put the brush on every row object; with rows that
/// are never rebuilt there is no rebuild to resolve it in.
///
/// 🪤 AN UNKNOWN KEY GETS THE QUIET BRUSH, not null. A null Background is an
/// invisible bar, which is indistinguishable from a row that has no band.
/// </remarks>
public sealed class BandAccent : IValueConverter
{
    public Brush? Needs { get; set; }

    public Brush? Open { get; set; }

    public Brush? Working { get; set; }

    public Brush? Done { get; set; }

    public Brush? Idle { get; set; }

    public Brush? Quiet { get; set; }

    /// <summary>A band KEY, or a band LABEL - the group header only has the label.</summary>
    public object? Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        KeyOf(value as string) switch
        {
            Bands.Needs => Needs,
            Bands.Open => Open,
            Bands.Working => Working,
            Bands.Done => Done,
            Bands.Idle => Idle,
            _ => Quiet,
        };

    private static string? KeyOf(string? keyOrLabel)
    {
        foreach (var b in Bands.Ordered)
        {
            if (string.Equals(b.Label, keyOrLabel, StringComparison.Ordinal))
            {
                return b.Key;
            }
        }

        return keyOrLabel;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException("a band accent is drawn, never edited");
}
