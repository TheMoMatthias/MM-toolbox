namespace SessionRestore.Core.Rows;

/// <summary>
/// What each project is called on screen. Ported from <c>Update-ProjectLabels</c>
/// and <c>Get-ProjectLabel</c>.
/// </summary>
/// <remarks>
/// 🔑 THE FOLDER NAME, UNTIL TWO PROJECTS SHARE ONE. Then both take one more path
/// segment - <c>api / src</c> against <c>web / src</c> - and again, up to four
/// levels, until they differ. Search and the project sort both read this label,
/// so a port that used the bare leaf would sort two <c>src</c> folders together
/// and let "web" find neither.
///
/// 🪤 CASE-INSENSITIVE TWICE, as the PowerShell is without saying so: a hashtable
/// keys paths ignoring case, so two spellings of one path are one project that
/// keeps the FIRST spelling; and Group-Object groups labels ignoring case, so
/// <c>Src</c> and <c>src</c> count as a clash.
/// </remarks>
public sealed class ProjectLabels
{
    private readonly Dictionary<string, string> _label;

    private ProjectLabels(Dictionary<string, string> label) => _label = label;

    /// <summary>Labels for every project path, disambiguated against each other.</summary>
    public static ProjectLabels For(IEnumerable<string?> paths)
    {
        ArgumentNullException.ThrowIfNull(paths);
        var label = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var p in paths)
        {
            if (!string.IsNullOrEmpty(p))
            {
                // An existing key keeps its first spelling; the value is the last one's leaf.
                label[p] = Titles.Leaf(p);
            }
        }

        for (var depth = 1; depth <= 4; depth++)
        {
            var dupes = label
                .GroupBy(kv => kv.Value, StringComparer.OrdinalIgnoreCase)
                .Where(g => g.Count() > 1)
                .ToList();
            if (dupes.Count == 0)
            {
                break;
            }

            foreach (var g in dupes)
            {
                foreach (var e in g.ToList())
                {
                    var parts = e.Key.Split('\\', '/').Where(x => x.Length > 0).ToArray();
                    var take = Math.Min(depth + 1, parts.Length);
                    label[e.Key] = string.Join(" / ", parts[^take..]);
                }
            }
        }

        return new ProjectLabels(label);
    }

    /// <summary>The label for <paramref name="path"/>; the bare folder name for a path it was not built with.</summary>
    public string Of(string? path)
    {
        if (string.IsNullOrEmpty(path))
        {
            return string.Empty;
        }

        return _label.TryGetValue(path, out var l) ? l : Titles.Leaf(path);
    }
}
