using System.Globalization;
using SessionRestore.Core.Registry;

namespace SessionRestore.Core.Rows;

/// <summary>One conversation, as the rail groups it.</summary>
/// <param name="Path">Its project's path - the grouping key.</param>
/// <param name="At">Its last activity, local ticks; 0 when unknown.</param>
/// <param name="Band">Its sessions-column band - the tile counts NEEDS YOU and WORKING off this.</param>
/// <param name="Live">Whether it has a live agent - only-live and "busiest" read this.</param>
/// <param name="Hay">The header box's haystack (<see cref="SearchMatch.Haystack"/>).</param>
/// <param name="HayProj">The rail box's haystack: label and path, lower-cased.</param>
public sealed record RailRow(string Path, long At, string Band, bool Live, RegistrySession Session, RegistryDirectory Dir, string Hay, string HayProj);

/// <summary>What the rail's own controls are set to.</summary>
/// <param name="Sort">recent, name, waiting or busiest.</param>
/// <param name="Shut">Band keys folded shut, lower-case.</param>
/// <param name="Pick">The project the sessions column is filtered to, or null.</param>
public sealed record RailView(string Query, string ProjectQuery, string Sort, bool OnlyLive, bool ShowShelved, IReadOnlySet<string> Shut, string? Pick);

/// <summary>An age band's heading.</summary>
public sealed record RailHead(string Key, string Label, int Count, bool Shut)
{
    /// <summary>▸ shut, ▾ open.</summary>
    public string Caret => Shut ? "▸" : "▾";
}

/// <summary>One project's tile.</summary>
public sealed record RailTile(
    string Path, string Label, int Count, string State, string Tip,
    (byte R, byte G, byte B) Accent, double AccentOpacity, bool NeedsVisible, bool Picked);

/// <summary>The rail, built.</summary>
/// <param name="Items">Headings and tiles, in the order drawn.</param>
/// <param name="Shelved">How many projects are shelved, counted whether or not they are shown.</param>
public sealed record RailBuild(IReadOnlyList<object> Items, int Shelved);

/// <summary>
/// The projects rail. Ported from <c>Build-Rail</c>, <c>Get-RailGrouping</c>,
/// <c>New-RailTile</c> and the rail's band helpers.
/// </summary>
/// <remarks>
/// 🔴 THE RAIL CARRIES EVERY PROJECT - it does NOT ask the surface rule, or three
/// of its four age bands could never fill and a project quiet long enough to shelve
/// could never be a tile to right-click.
///
/// 🔴 GROUPING IS OUTSIDE THE SORT, as in the sessions column: the age band is the
/// order that matters, and the chosen sort only orders projects within one.
/// </remarks>
public static class Rail
{
    /// <summary><c>$script:RailBands</c>.</summary>
    public static readonly (string Key, string Label)[] BandsInOrder =
        [("today", "TODAY"), ("week", "THIS WEEK"), ("month", "THIS MONTH"), ("older", "OLDER")];

    /// <summary><c>$script:RailSorts</c>, in the order the control cycles them.</summary>
    public static readonly string[] Sorts = ["recent", "name", "waiting", "busiest"];

    private static readonly string Dot = " · ";

    /// <summary>Builds the rail, or returns null when a search box holds an invalid pattern.</summary>
    /// <remarks>
    /// 🪤 NULL IS "LEAVE THE RAIL AS IT IS": in the shipped window an invalid
    /// <c>-like</c> pattern throws inside the rebuild, which is abandoned.
    /// </remarks>
    /// <param name="autoTickOff">Whether a project's auto-tick budget is zero - a config lookup by path.</param>
    /// <param name="suggest">Shelve suggestions by project path.</param>
    public static RailBuild? Build(
        IEnumerable<RailRow> rows, RailView view, ProjectLabels labels, IReadOnlyList<string> accentOrder,
        RailCuts cuts, Func<string, bool> autoTickOff, IReadOnlyDictionary<string, string> suggest)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentNullException.ThrowIfNull(view);
        ArgumentNullException.ThrowIfNull(labels);
        ArgumentNullException.ThrowIfNull(autoTickOff);
        ArgumentNullException.ThrowIfNull(suggest);

        var q = view.Query.Trim().ToLowerInvariant();
        var qr = view.ProjectQuery.Trim().ToLowerInvariant();
        var qx = q.Length > 0 ? SearchMatch.Pattern(q) : null;
        var qrx = qr.Length > 0 ? SearchMatch.Pattern(qr) : null;
        if ((q.Length > 0 && qx is null) || (qr.Length > 0 && qrx is null))
        {
            return null;
        }

        // Grouped by path, ignoring case as a PowerShell hashtable does - and
        // keeping the FIRST spelling as the key.
        var byProj = new Dictionary<string, List<RailRow>>(StringComparer.OrdinalIgnoreCase);
        var newest = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        foreach (var r in rows)
        {
            if ((qx is not null && !qx.IsMatch(r.Hay)) || (qrx is not null && !qrx.IsMatch(r.HayProj)))
            {
                continue;
            }

            if (!byProj.TryGetValue(r.Path, out var list))
            {
                byProj[r.Path] = list = [];
            }

            list.Add(r);
            if (!newest.TryGetValue(r.Path, out var n) || r.At > n)
            {
                newest[r.Path] = r.At;
            }
        }

        IEnumerable<string> keys = byProj.Keys;
        var culture = StringComparer.CurrentCultureIgnoreCase;
        var order = view.Sort switch
        {
            "name" => keys.OrderBy(k => labels.Of(k).ToLowerInvariant(), culture).ToList(),
            "waiting" => keys.OrderBy(k => -byProj[k].Count(x => x.Band == Bands.Needs)).ToList(),
            "busiest" => keys.OrderBy(k => -byProj[k].Count(x => x.Live)).ToList(),
            _ => keys.OrderBy(k => -newest[k]).ToList(),
        };

        if (view.OnlyLive)
        {
            order = order.Where(k => byProj[k].Any(x => x.Live)).ToList();
        }

        // 🔴 COUNTED WHETHER OR NOT SHOWN: a list that silently omits things is a
        // list whose length you cannot trust.
        var shelved = order.Where(k => byProj[k][0].Dir.Shelved).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!view.ShowShelved && shelved.Count > 0)
        {
            order = order.Where(k => !shelved.Contains(k)).ToList();
        }

        var inBand = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var k in order)
        {
            var bk = cuts.KeyFor(newest[k]);
            if (!inBand.TryGetValue(bk, out var l))
            {
                inBand[bk] = l = [];
            }

            l.Add(k);
        }

        var items = new List<object>();
        foreach (var (key, label) in BandsInOrder)
        {
            if (!inBand.TryGetValue(key, out var paths))
            {
                continue;
            }

            var shut = view.Shut.Contains(key);
            items.Add(new RailHead(key, label, paths.Count, shut));
            foreach (var k in paths)
            {
                // 🔴 A FOLDED BAND NEVER HIDES THE PROJECT YOU ARE FILTERED TO.
                var picked = view.Pick is not null && string.Equals(view.Pick, k, StringComparison.OrdinalIgnoreCase);
                if (shut && !picked)
                {
                    continue;
                }

                suggest.TryGetValue(k, out var why);
                items.Add(Tile(k, byProj[k], picked, labels, accentOrder, autoTickOff(k), why ?? string.Empty));
            }
        }

        return new RailBuild(items, shelved.Count);
    }

    /// <summary><c>New-RailTile</c>.</summary>
    private static RailTile Tile(
        string path, List<RailRow> kids, bool picked, ProjectLabels labels, IReadOnlyList<string> accentOrder,
        bool autoOff, string suggest)
    {
        // 🔴 THE BAND, NOT .Live: the tile once counted everything with a live
        // agent and called it "working", sweeping in every idle prompt.
        var needs = kids.Count(r => r.Band == Bands.Needs);
        var working = kids.Count(r => r.Band != Bands.Needs && r.Band == Bands.Working);
        var inv = CultureInfo.InvariantCulture;

        var bits = new List<string>();
        if (needs > 0)
        {
            bits.Add(needs.ToString(inv) + " waiting");
        }

        if (working > 0)
        {
            bits.Add(working.ToString(inv) + " working");
        }

        if (bits.Count == 0)
        {
            bits.Add(kids.Count.ToString(inv) + " idle");
        }

        var ticked = kids.Count(k => k.Session.Enabled);
        var d = kids[0].Dir;
        var restoreOff = d.EnabledPresent && !d.Enabled;
        if (restoreOff)
        {
            bits.Add("no logon");
        }

        if (autoOff)
        {
            bits.Add("no auto-tick");
        }

        var state = string.Join(Dot, bits);
        if (suggest.Length > 0)
        {
            state += Dot + "could be shelved";
        }

        var tip = string.Format(inv, "{0} ticked conversation(s) here.", ticked)
                  + (restoreOff ? " This project reopens NOTHING at your next logon - every tick is kept as it is." : " They reopen at your next logon.")
                  + (autoOff ? " New conversations started here are not auto-ticked." : string.Empty)
                  + (suggest.Length > 0 ? " " + suggest : string.Empty)
                  + Environment.NewLine + "Right-click for this project's settings.";

        return new RailTile(
            path, labels.Of(path), kids.Count, state, tip,
            ProjectAccent.Of(path, accentOrder),
            needs > 0 ? 1.0 : working > 0 ? 0.85 : 0.35,
            needs > 0,
            picked);
    }

    /// <summary>The shelved control's text and tooltip; null when nothing is shelved and it is hidden.</summary>
    public static (string Text, string Tip)? ShelvedControl(int shelved, bool shown) =>
        shelved <= 0
            ? null
            : shown
                ? (string.Format(CultureInfo.InvariantCulture, "{0} shelved, shown", shelved),
                   "Shelved projects are on the rail. Click to put them away again.")
                : (string.Format(CultureInfo.InvariantCulture, "{0} shelved", shelved),
                   string.Format(CultureInfo.InvariantCulture,
                       "{0} project(s) are shelved: off this rail, and not restored at logon. Click to see them.", shelved));

    /// <summary>The "could be shelved" line and tooltip; null when there is nothing to suggest.</summary>
    public static (string Text, string Tip)? SuggestControl(IReadOnlyList<string> names)
    {
        ArgumentNullException.ThrowIfNull(names);
        if (names.Count == 0)
        {
            return null;
        }

        var some = names.OrderBy(n => n, StringComparer.CurrentCultureIgnoreCase).Take(12).ToList();
        var tip = string.Join("\n", some)
                  + (names.Count > some.Count ? "\n...and " + (names.Count - some.Count).ToString(CultureInfo.InvariantCulture) + " more" : string.Empty)
                  + "\n\nNothing is shelved for you. Right-click a project to shelve it.";
        return (string.Format(CultureInfo.InvariantCulture, "{0} quiet project(s) could be shelved", names.Count), tip);
    }
}
