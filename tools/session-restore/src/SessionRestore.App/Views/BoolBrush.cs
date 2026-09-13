using System.Globalization;
using System.Windows.Data;
using System.Windows.Media;

namespace SessionRestore.App.Views;

/// <summary>
/// One of two brushes, by a bool on the row.
/// </summary>
/// <remarks>
/// 🔑 THE BRUSHES STAY IN THE MARKUP, as with <see cref="BandAccent"/>: the row
/// says WHICH, the XAML says what colour that is. The queue mark is the first
/// user - amber when your own words are waiting, grey when it is only the machine.
/// </remarks>
public sealed class BoolBrush : IValueConverter
{
    public Brush? WhenTrue { get; set; }

    public Brush? WhenFalse { get; set; }

    public object? Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? WhenTrue : WhenFalse;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException("a hue is drawn, never edited");
}
