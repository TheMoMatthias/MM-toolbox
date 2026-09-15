using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;

namespace SessionRestore.App.Views;

/// <summary>
/// Whether THIS band's heading is the pressed one - as the words beside it.
/// </summary>
/// <remarks>
/// 🔴 A GROUP HEADER'S DATA CONTEXT IS A <c>CollectionViewGroup</c>, which knows
/// its own name and its count and nothing about the window. So the pick has to
/// arrive beside it, which is what makes these MULTI-value converters: the
/// heading's name, and the column's current pick, read off the ListBox's own
/// DataContext.
///
/// 🪤 THE SECOND BINDING IS WHAT MAKES IT UPDATE. A converter over the name
/// alone would run once when the header was realised and never again, so the
/// heading would look unpressed for ever - the pick has to be a binding, so
/// that its PropertyChanged re-runs this.
/// </remarks>
public sealed class BandPickedHint : IMultiValueConverter
{
    /// <summary>What the heading says when it is the one being shown.</summary>
    public const string Hint = "only this";

    public object Convert(object[] values, Type targetType, object? parameter, CultureInfo culture) =>
        Pressed(values) ? Hint : string.Empty;

    public object[] ConvertBack(object? value, Type[] targetTypes, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException("a heading is pressed, never typed into");

    /// <summary>The heading's own name against the column's pick, ordinally.</summary>
    internal static bool Pressed(object[]? values) =>
        values is [string name, string pick, ..]
        && string.Equals(name, pick, StringComparison.Ordinal);
}

/// <summary>
/// The ground behind a pressed heading.
/// </summary>
/// <remarks>
/// 🪤 A HEADING YOU CAN PRESS HAS TO LOOK PRESSABLE, AND LOOK PRESSED. The
/// shipped one sets <c>BandBg</c> to <c>SelBg</c> and leaves every other heading
/// transparent; without it the only sign that the column is narrowed is that
/// rows are missing, which reads as a bug rather than as a choice.
/// </remarks>
public sealed class BandPickedBrush : IMultiValueConverter
{
    /// <summary>
    /// The window's own selected-row ground. Set once from the shell, so the
    /// resource is resolved there rather than looked up per heading - the same
    /// reasoning the shipped rebuild uses for its two brushes.
    /// </summary>
    public Brush? Picked { get; set; }

    public object Convert(object[] values, Type targetType, object? parameter, CultureInfo culture) =>
        BandPickedHint.Pressed(values) && Picked is not null ? Picked : Brushes.Transparent;

    public object[] ConvertBack(object? value, Type[] targetTypes, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException("a heading is pressed, never typed into");
}
