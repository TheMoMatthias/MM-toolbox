using System.Windows;
using System.Windows.Media;

namespace SessionRestore.App.Views;

/// <summary>
/// The names the reading pane paints by, and the resources behind them.
/// </summary>
/// <remarks>
/// 🔑 THE PANE NAMES A HUE, NOT A RESOURCE. Every value in
/// <see cref="Core.Reading.PaneMetrics.Marks"/>, and every span
/// <see cref="Core.Reading.Inline"/> produces, carries a palette KEY - "Tool",
/// "Out", "TextMax" - because that is what the shipped <c>$Pal</c> hashtable is
/// and because a domain value must not hold a brush.
///
/// 🪤 AND THREE OF THEM DO NOT MATCH THEIR RESOURCE NAME. <c>Raised</c> is
/// <c>PanelHi</c>, <c>HairlineHi</c> is <c>Hairline</c>, and <c>TextDim</c> is
/// <c>AccQuiet</c> - a name from the accent set, not the text set. A port that
/// assumed "Hue" + the key, or the key itself, would paint two of them wrong and
/// one of them not at all.
/// </remarks>
public static class Palette
{
    /// <summary>Each palette key, and the resource it reads.</summary>
    public static readonly IReadOnlyDictionary<string, string> Keys =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["Ink"] = "Ink",
            ["Raised"] = "PanelHi",
            ["HairlineHi"] = "Hairline",
            ["TextMax"] = "TextMax",
            ["TextHigh"] = "TextHigh",
            ["TextMid"] = "TextMid",
            ["TextLow"] = "TextLow",
            ["TextDim"] = "AccQuiet",
            ["In"] = "HueIn",
            ["Out"] = "HueOut",
            ["Tool"] = "HueTool",
            ["Bad"] = "HueBad",
            ["Ask"] = "HueAsk",
            ["Warn"] = "HueWarn",
            ["Ok"] = "HueOk",
            ["Link"] = "HueLink",
        };

    /// <summary>
    /// The brush a palette key names, or null when the key is not one.
    /// </summary>
    /// <remarks>
    /// 🪤 AN UNKNOWN KEY PAINTS NOTHING RATHER THAN PAINTING BLACK. A brush of
    /// null leaves the element inheriting whatever it was going to inherit,
    /// which is visible as "this looks like the text around it"; a default black
    /// on a near-black ground is invisible, and an invisible line of a
    /// transcript is worse than a mis-hued one.
    /// </remarks>
    public static Brush? Brush(FrameworkElement? host, string? hue)
    {
        if (host is null || hue is null || !Keys.TryGetValue(hue, out var key))
        {
            return null;
        }

        return host.TryFindResource(key) as Brush;
    }
}
