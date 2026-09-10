using SessionRestore.Core.Registry;

namespace SessionRestore.Core.Rows;

/// <summary>Which conversations the work surface shows. Plan item 2.6.</summary>
public static class Surface
{
    /// <summary>
    /// Is this conversation on the work surface?
    /// </summary>
    /// <remarks>
    /// 🔴 WHAT YOU ARE READING STAYS ON SCREEN, and that clause is not a
    /// convenience. A conversation drops off this surface once it stops being
    /// live and its last activity passes 24 hours - and the refresh runs every
    /// six seconds, so it could vanish from under the reading pane mid-read and
    /// the rebuild would silently select a DIFFERENT conversation in its place.
    /// Whatever is selected is pinned until something else is.
    ///
    /// 🪤 <paramref name="warm"/> IS THE SAME 24-HOUR QUESTION DECIDED ONCE, when
    /// the model was built. Passing it in matters: answering it per row re-parses
    /// a date string AND re-reads the clock, and it made a pass over 292
    /// conversations compare each against a slightly different cut-off. Pass null
    /// only when all you hold is a bare session record.
    /// </remarks>
    public static bool Shows(
        bool live,
        bool? warm,
        string id,
        string? selectedId,
        RegistrySession? session,
        DateTime? now = null)
    {
        if (live)
        {
            return true;
        }

        var selected = !string.IsNullOrEmpty(selectedId)
            && string.Equals(id, selectedId, StringComparison.Ordinal);

        if (warm is not null)
        {
            return warm.Value || selected;
        }

        return selected || Titles.Warm(session, now);
    }
}
