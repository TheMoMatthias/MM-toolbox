namespace SessionRestore.Core.Rows;

/// <summary>
/// Each project's identity colour on the rail. Ported from <c>Get-ProjectAccent</c>
/// and <c>Convert-HslToColor</c>, with the order <c>Update-ProjectLabels</c> deals.
/// </summary>
/// <remarks>
/// 🔴 DEALT, NOT DRAWN. A hash per project clustered - eight projects came out
/// "mostly green and blue" - and hash-mod-wheel gave four colours across seven.
/// So the projects are SORTED and dealt consecutive slots off a fixed wheel of
/// twelve hues already far apart. Adding a project can re-deal the others; at a
/// few dozen projects a set you can tell apart beats a colour that never moves.
/// </remarks>
public static class ProjectAccent
{
    /// <summary>The wheel: hue, saturation, lightness. The olive band is simply not on it.</summary>
    public static readonly (double H, double S, double L)[] Wheel =
    [
        (206, 0.88, 0.68), (8, 0.86, 0.70), (150, 0.72, 0.62), (276, 0.80, 0.74),
        (34, 0.92, 0.64), (188, 0.78, 0.62), (330, 0.82, 0.72), (102, 0.66, 0.62),
        (248, 0.82, 0.76), (18, 0.84, 0.64), (168, 0.72, 0.66), (300, 0.70, 0.72),
    ];

    /// <summary>
    /// The dealing order: every project path lower-cased, sorted, de-duplicated.
    /// </summary>
    /// <remarks>🪤 SORTED AS POWERSHELL SORTS STRINGS: by the current culture, not ordinally.</remarks>
    public static IReadOnlyList<string> Order(IEnumerable<string?> paths) =>
        (paths ?? throw new ArgumentNullException(nameof(paths)))
            .Select(p => (p ?? string.Empty).ToLowerInvariant())
            .Where(p => p.Length > 0)
            .Distinct(StringComparer.CurrentCultureIgnoreCase)
            .OrderBy(p => p, StringComparer.CurrentCultureIgnoreCase)
            .ToList();

    /// <summary>The colour for <paramref name="path"/>: its slot in the order, slot 0 when it is not in it.</summary>
    public static (byte R, byte G, byte B) Of(string? path, IReadOnlyList<string> order)
    {
        ArgumentNullException.ThrowIfNull(order);
        var k = (path ?? string.Empty).ToLowerInvariant();
        var idx = 0;
        for (var i = 0; i < order.Count; i++)
        {
            if (string.Equals(order[i], k, StringComparison.Ordinal))
            {
                idx = i;
                break;
            }
        }

        var slot = Wheel[idx % Wheel.Length];
        return Hsl(slot.H, slot.S, slot.L);
    }

    /// <summary><c>Convert-HslToColor</c>, rounding half to even as <c>[math]::Round</c> does.</summary>
    public static (byte R, byte G, byte B) Hsl(double h, double s, double l)
    {
        var c = (1 - Math.Abs((2 * l) - 1)) * s;
        var x = c * (1 - Math.Abs(((h / 60) % 2) - 1));
        var m = l - (c / 2);
        double r = 0, g = 0, b = 0;
        switch ((int)Math.Floor(h / 60))
        {
            case 0: r = c; g = x; break;
            case 1: r = x; g = c; break;
            case 2: g = c; b = x; break;
            case 3: g = x; b = c; break;
            case 4: r = x; b = c; break;
            default: r = c; b = x; break;
        }

        return (Byte(r + m), Byte(g + m), Byte(b + m));
    }

    private static byte Byte(double v) => checked((byte)Math.Round(v * 255, MidpointRounding.ToEven));
}
