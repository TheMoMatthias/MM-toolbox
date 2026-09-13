using System.Globalization;
using System.Windows.Data;
using System.Windows.Media;
using SessionRestore.Core.Rows;

namespace SessionRestore.App.Views;

/// <summary>The context bar's hue to its brush - the palette stays in the markup.</summary>
public sealed class ContextHueBrush : IValueConverter
{
    public Brush? Ok { get; set; }

    public Brush? Warn { get; set; }

    public Brush? Bad { get; set; }

    /// <summary>A compact is running: the bar is its progress, in the question hue.</summary>
    public Brush? Compacting { get; set; }

    public object? Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value switch
        {
            ContextHue.Warn => Warn,
            ContextHue.Bad => Bad,
            ContextHue.Compacting => Compacting,
            _ => Ok,
        };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException("a hue is drawn, never edited");
}
