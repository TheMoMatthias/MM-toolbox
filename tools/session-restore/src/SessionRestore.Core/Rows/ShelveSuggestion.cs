using System.Globalization;
using SessionRestore.Core.Registry;

namespace SessionRestore.Core.Rows;

/// <summary>
/// Whether a quiet project is worth suggesting for the shelf, as a sentence.
/// Ported from <c>Get-SRShelveSuggestion</c>.
/// </summary>
/// <remarks>
/// 🔴 A SUGGESTION, NEVER AN ACT. Nothing is ever shelved on its own; this only
/// words the line on the tile. Empty when there is nothing to say.
///
/// 🪤 A PROJECT OF NOTHING BUT WORKTREE LANES GOES QUIET TWICE AS FAST - half the
/// days, rounded up, never under one - because a finished worktree lane is the
/// most disposable thing on the rail.
/// </remarks>
public static class ShelveSuggestion
{
    /// <summary>The default for <c>shelveSuggestDays</c>, and what a value under one falls back to.</summary>
    public const int DefaultDays = 14;

    /// <param name="days">The configured <c>shelveSuggestDays</c>, or null when unset.</param>
    /// <param name="anythingRunning">Whether any conversation in it has a live agent.</param>
    public static string For(RegistryDirectory? dir, int? days, bool anythingRunning, DateTime now)
    {
        if (dir is null || dir.Missing || dir.Shelved || anythingRunning)
        {
            return string.Empty;
        }

        var d = days ?? DefaultDays;
        if (d < 1)
        {
            d = DefaultDays;
        }

        var live = dir.Sessions.Where(s => !s.Gone).ToList();
        if (live.Count == 0)
        {
            return string.Empty;
        }

        var newest = DateTime.MinValue;
        var allWorktree = true;
        foreach (var s in live)
        {
            if (!string.Equals(s.Lane, "worktree", StringComparison.OrdinalIgnoreCase))
            {
                allWorktree = false;
            }

            if (s.LastActive is { } t && t.LocalDateTime > newest)
            {
                newest = t.LocalDateTime;
            }
        }

        if (newest == DateTime.MinValue)
        {
            return string.Empty;
        }

        var cut = allWorktree ? Math.Max(1, (int)Math.Ceiling(d / 2.0)) : d;
        var quiet = (int)Math.Floor((now - newest).TotalDays);
        if (quiet < cut)
        {
            return string.Empty;
        }

        return allWorktree
            ? string.Format(CultureInfo.InvariantCulture, "nothing but finished worktree lanes here, quiet {0} days", quiet)
            : string.Format(CultureInfo.InvariantCulture, "nothing running, quiet {0} days", quiet);
    }
}
