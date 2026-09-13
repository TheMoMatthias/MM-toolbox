using System.Text.Json.Nodes;

namespace SessionRestore.Oracle;

/// <summary>
/// The marker a comparison uses for a row that moved between the two reads, and
/// the allowance that forgives exactly that marker.
/// </summary>
/// <remarks>
/// 🔴 THE MARKER IS BUILT FROM THE POWERSHELL'S OWN ROW, so it covers every field
/// the other side emitted by construction rather than by a hand-kept list. Three
/// cases kept that list by hand, and each went intermittently red the day the
/// PowerShell emitted a field the list had missed.
///
/// 🪤 A NULL STAYS NULL. A block with no timestamp emits `when: null`; a marker
/// there is reported as "one side is empty (nothing vs JsonValue)", which carries
/// no marker text and matched no allowance. Nullness is the shape of the
/// question, not an answer: it says which field exists, never what it holds.
///
/// 🔴 AND THE ALLOWANCE ASKS WHETHER *THIS* DIFFERENCE'S C# VALUE IS THE MARKER,
/// never whether each LINE contains it. <see cref="Oracle"/> already hands a case
/// one difference at a time. Splitting that difference on newlines cut a
/// transcript body in half: the second half carried the marker, the first did
/// not, and a conversation that genuinely grew was reported as a real
/// difference. Measured 2026-09-13 on `transcript/blocks-detail`.
/// </remarks>
public static class Moving
{
    /// <summary>A copy of the PowerShell's row with every answer replaced by <paramref name="why"/>.</summary>
    /// <param name="psRow">The row the PowerShell emitted.</param>
    /// <param name="key">The field naming WHICH row this is; it is kept, not marked.</param>
    /// <param name="why">The marker.</param>
    public static JsonObject Mark(JsonNode? psRow, string key, string why)
    {
        var o = new JsonObject();
        if (psRow is not JsonObject row)
        {
            o[key] = why;
            return o;
        }

        foreach (var kv in row)
        {
            o[kv.Key] = string.Equals(kv.Key, key, StringComparison.Ordinal)
                ? kv.Value?.DeepClone()
                : kv.Value is null ? null : why;
        }

        return o;
    }

    /// <summary>True when the C# side of this one difference is exactly the marker.</summary>
    public static bool IsMarked(string difference, string why) =>
        (difference ?? string.Empty).EndsWith(", C# \"" + why + "\"", StringComparison.Ordinal);
}
