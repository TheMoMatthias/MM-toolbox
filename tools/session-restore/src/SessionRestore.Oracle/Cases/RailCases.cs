using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using SessionRestore.Core.Registry;
using SessionRestore.Core.Rows;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 4.2b - the projects rail, against <c>Build-Rail</c> itself.
/// </summary>
/// <remarks>
/// 🔴 THE WHOLE FUNCTION RUNS, NOT A COPY OF IT. <c>Build-Rail</c>, the tile, the
/// grouping, the bands, the accent wheel, the labels, the shelve suggestions and
/// the two header controls are spliced from the window; only what they draw ON is
/// stubbed - <c>$ui</c>'s controls, and <c>$window</c>'s brushes, which are real
/// brushes so the shipped casts survive, named back into words for the answer.
///
/// 🔴 A MODEL BUILT TO REACH EVERY RULE, because live data does not: nothing on
/// this machine is shelved, and nothing has an auto-tick budget of zero. Two paths
/// differ only by case, two projects share a folder name, a band is folded with the
/// picked project inside it, a worktree-only project goes quiet at half the days.
///
/// 🪤 WAITING AND BUSIEST SORT ON COUNTS THAT TIE, and PowerShell 5.1's
/// Sort-Object makes no promise about ties while the shipped keys are enumerated
/// in hashtable order - so for those two views each band's tiles are re-ordered by
/// (count, path) on BOTH sides before comparing. The count is in the row, so an
/// order that is wrong BETWEEN counts still fails.
/// </remarks>
public static class RailCases
{
    private static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Rails(), true, "headings and tiles for eleven rail settings, against Build-Rail itself");
    }

    private sealed record Sess(string Id, string Lane, bool Gone, double AgeHours, bool Ticked, string Band, bool Live);

    private sealed record Dir(string Path, bool? Enabled, bool Shelved, Sess[] Sessions);

    private static readonly Dir[] Dirs =
    [
        new(@"C:\p\alpha", true, false, [new("a1", "", false, 1, true, "needs", true), new("a2", "", false, 2, false, "working", true)]),
        new(@"C:\P\ALPHA", true, false, [new("f1", "", false, 0.2, true, "needs", false)]),
        new(@"C:\p\beta", false, false, [new("b1", "", false, 30, true, "idle", false)]),
        // A live conversation that is idle beside a working one: "working" counts the BAND, not .Live.
        new(@"C:\q\beta", null, false, [new("c1", "", false, 72, false, "working", true), new("c2", "", false, 73, false, "idle", true)]),
        new(@"C:\p\gamma", true, true, [new("d1", "", false, 24 * 40, false, "quiet", false)]),
        // Ten days quiet: past HALF the fourteen, which is what a worktree-only project gets, and not past all of it.
        new(@"C:\p\delta", true, false, [new("e1", "worktree", false, 24 * 10, false, "quiet", false), new("e2", "worktree", true, 24 * 400, false, "quiet", false)]),
        new(@"C:\p\eps", true, false, [new("g1", "", false, 24 * 15, false, "idle", false)]),
        // Working but not live, and live but idle: only-live must read .Live, not the band.
        // Both sit in TODAY beside alpha, so a band holds tiles with different waiting counts.
        new(@"C:\p\zeta", true, false, [new("z1", "", false, 5, false, "working", false)]),
        new(@"C:\p\eta", true, false, [new("n1", "", false, 6, false, "idle", true)]),
    ];

    private sealed record View(string Name, string Q, string Qr, string Sort, bool OnlyLive, bool ShowShelved, string Shut, string? Pick);

    private static readonly View[] Views =
    [
        new("recent", "", "", "recent", false, false, "", null),
        new("by-name", "", "", "name", false, false, "", null),
        new("waiting", "", "", "waiting", false, false, "", null),
        new("busiest", "", "", "busiest", false, false, "", null),
        new("only-live", "", "", "recent", true, false, "", null),
        new("shelved-shown", "", "", "recent", false, true, "", null),
        new("week-shut-with-pick-inside", "", "", "recent", false, false, "week,month", @"C:\p\beta"),
        new("header-search", "a1", "", "recent", false, false, "", null),
        new("rail-search", "", "q / beta", "recent", false, false, "", null),
        new("rail-search-wildcard", "", "*eta", "name", false, false, "", null),
        new("invalid-pattern", "", "[be", "recent", false, false, "", null),
    ];

    private static string Hay(Dir d, Sess s) => ("title-" + s.Id + " " + d.Path + " " + s.Id).ToLowerInvariant();

    private static string PsModel(DateTime now)
    {
        var inv = CultureInfo.InvariantCulture;
        var sb = new StringBuilder("$dirSpecs = @(\n");
        foreach (var d in Dirs)
        {
            sb.Append("[PSCustomObject]@{ path = ").Append(PsText.Literal(d.Path))
              .Append(d.Enabled is { } e ? "; enabled = $" + e.ToString().ToLowerInvariant() : string.Empty)
              .Append(d.Shelved ? "; shelved = $true" : string.Empty)
              .Append("; missing = $false; sessions = @(");
            foreach (var s in d.Sessions)
            {
                var at = now.AddHours(-s.AgeHours);
                sb.Append(inv, $"[PSCustomObject]@{{ sessionId = '{s.Id}'; lane = '{s.Lane}'; gone = ${s.Gone.ToString().ToLowerInvariant()}; ")
                  .Append(inv, $"lastActive = '{at.ToString("o", inv)}'; enabled = ${s.Ticked.ToString().ToLowerInvariant()}; ")
                  .Append(inv, $"_band = '{s.Band}'; _live = ${s.Live.ToString().ToLowerInvariant()}; _at = {at.Ticks}; _hay = ")
                  .Append(PsText.Literal(Hay(d, s))).Append(" },");
            }

            sb.Append("$null) },\n");
        }

        return sb.Append("$null)\n").ToString();
    }

    private static OracleCase Rails() => new(
        "rail/build",
        "headings and tiles for eleven rail settings, against Build-Rail itself",
        """
        Add-Type -AssemblyName PresentationCore
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        foreach ($fn in @('Build-Rail', 'Get-RailGrouping', 'New-RailTile', 'Get-RailBandCuts', 'Get-RailBandKey',
                          'Get-ProjectAccent', 'Convert-HslToColor', 'Update-ProjectLabels', 'Get-ProjectLabel',
                          'Test-SRProjectRestoreOff', 'Test-SRProjectAutoTickOff', 'Get-SRPathLeaf',
                          'Update-RailShelved', 'Update-RailSuggest', 'Update-ShelveSuggestions',
                          'Sync-SRSessionItems', 'Get-SRItemSig')) {
            $a = $winSrc.IndexOf("function $fn")
            if ($a -lt 0) { throw "could not find $fn in sessions-window.ps1" }
            $b = $winSrc.IndexOf("`n}", $a)
            Invoke-Expression $winSrc.Substring($a, $b - $a + 2)
        }
        foreach ($var in @('$script:RailBands = @(', '$script:SR_PathSeps = ')) {
            $a = $winSrc.IndexOf($var)
            $b = $winSrc.IndexOf("`n)", $a)
            $e = $winSrc.IndexOf("`n", $a)
            $stmt = $(if ($var.EndsWith('(')) { $winSrc.Substring($a, $b - $a + 2) } else { $winSrc.Substring($a, $e - $a) })
            Invoke-Expression $stmt
        }

        function New-SRNamedBrush($r) { $x = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb($r, 1, 2)); $x.Freeze(); $x }
        $brushes = [ordered]@{ SelBg = (New-SRNamedBrush 11); EdgeLit = (New-SRNamedBrush 12); TextMax = (New-SRNamedBrush 13); TextHigh = (New-SRNamedBrush 14); TextLow = (New-SRNamedBrush 15) }
        $window = New-Object PSObject
        $window | Add-Member -MemberType ScriptMethod -Name FindResource -Value { param($k) $brushes[$k] }
        function Get-SRBrushName($b) {
            if ($null -eq $b) { return 'null' }
            if ([object]::ReferenceEquals($b, [System.Windows.Media.Brushes]::Transparent)) { return 'Blank' }
            foreach ($k in $brushes.Keys) { if ([object]::ReferenceEquals($b, $brushes[$k])) { return $k } }
            return 'unknown'
        }
        $V_Show = 'Visible'; $V_Hide = 'Collapsed'
        function New-SRCtl { [PSCustomObject]@{ Text = ''; Visibility = 'Collapsed'; ToolTip = $null; Foreground = $null; ItemsSource = $null } }

        """ + PsModel(Now) + """
        $script:dirs = @($dirSpecs | Where-Object { $_ })
        foreach ($d in $script:dirs) { $d.sessions = @($d.sessions | Where-Object { $_ }) }
        $script:agents = @{}
        $script:model = @()
        foreach ($d in $script:dirs) {
            foreach ($s in $d.sessions) {
                if ($s.gone) { continue }
                if ($s._live) { $script:agents[$s.sessionId] = $true }
                $script:model += [PSCustomObject]@{ Id = $s.sessionId; S = $s; D = $d; At = [long]$s._at; Band = $s._band; Live = [bool]$s._live; Hay = $s._hay; HayProj = '' }
            }
        }
        $script:accentOrder = @(); $script:accentCache = @{}
        Update-ProjectLabels
        foreach ($r in $script:model) { $r.HayProj = ('{0} {1}' -f (Get-ProjectLabel "$($r.D.path)"), $r.D.path).ToLower() }
        $script:cfg = [PSCustomObject]@{ autoTickLaneBudgets = [PSCustomObject]@{ 'eps/*' = 0; 'alpha/*' = 3 } }
        Update-ShelveSuggestions

        $views = @(
        """ + string.Join(",\n", Views.Select(v =>
            "@{ n = '" + v.Name + "'; q = " + PsText.Literal(v.Q) + "; qr = " + PsText.Literal(v.Qr) + "; sort = '" + v.Sort
            + "'; live = $" + v.OnlyLive.ToString().ToLowerInvariant() + "; shelved = $" + v.ShowShelved.ToString().ToLowerInvariant()
            + "; shut = '" + v.Shut + "'; pick = " + (v.Pick is null ? "$null" : PsText.Literal(v.Pick)) + " }")) + """

        )
        $out = @()
        $gen = 0
        foreach ($v in $views) {
            $gen++; $script:modelGen = $gen
            $ui = @{ Search = (New-SRCtl); RailSearch = (New-SRCtl); RailList = (New-SRCtl); RailClear = (New-SRCtl); RailShelved = (New-SRCtl); RailSuggest = (New-SRCtl) }
            $ui.Search.Text = $v.q; $ui.RailSearch.Text = $v.qr
            $script:railSort = $v.sort; $script:railOnlyLive = $v.live; $script:railShowShelved = $v.shelved; $script:railPick = $v.pick
            $script:railBandShut = @{}; foreach ($k in ("$($v.shut)" -split ',')) { if ($k) { $script:railBandShut[$k] = $true } }
            $script:railBound = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
            $threw = $false
            try { Build-Rail } catch { $threw = $true }
            $items = @()
            foreach ($it in @($script:railBound)) {
                if ("$($it.Kind)" -eq 'band') {
                    $items += [ordered]@{ kind = 'band'; key = "$($it.BandKey)"; label = "$($it.BandLabel)"; count = [int]$it.BandCount; caret = "$($it.BandCaret)" }
                } else {
                    $c = $it.Accent.Color
                    $items += [ordered]@{ kind = 'tile'; path = "$($it.Path)"; label = "$($it.Label)"; count = [int]$it.Count
                        state = "$($it.State)"; tip = "$($it.Tip)"; accent = ('{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B)
                        opacity = [string]$it.AccentOpacity; needs = "$($it.NeedsVis)"
                        pickBg = (Get-SRBrushName $it.PickBg); pickEdge = (Get-SRBrushName $it.PickEdge); fg = (Get-SRBrushName $it.Fg) }
                }
            }
            # Ties: within each band, is the order non-increasing in the count, and
            # then the tiles that share a count ordered by path.
            $orderOk = $true
            if ($v.sort -eq 'waiting' -or $v.sort -eq 'busiest') {
                $fixed = @(); $run = @(); $last = [int]::MaxValue
                foreach ($it in ($items + @([ordered]@{ kind = 'end' }))) {
                    if ($it.kind -ne 'tile') {
                        $fixed += @($run | Sort-Object @{ E = { -$_.key } }, @{ E = { $_.path } }); $run = @(); $last = [int]::MaxValue
                        if ($it.kind -eq 'band') { $fixed += $it }
                        continue
                    }
                    $p = $it.path
                    $kids = @($script:model | Where-Object { "$($_.D.path)" -eq $p })
                    $n = $(if ($v.sort -eq 'waiting') { @($kids | Where-Object { $_.Band -eq 'needs' }).Count } else { @($kids | Where-Object { $_.Live }).Count })
                    if ($n -gt $last) { $orderOk = $false }
                    $last = $n
                    $it['key'] = $n
                    $run += $it
                }
                $items = $fixed
            }
            $out += [ordered]@{
                view = $v.n; threw = $threw; orderOk = $orderOk; items = $items
                clear = "$($ui.RailClear.Visibility)"
                shelvedText = "$($ui.RailShelved.Text)"; shelvedVis = "$($ui.RailShelved.Visibility)"; shelvedTip = "$($ui.RailShelved.ToolTip)"
                suggestText = "$($ui.RailSuggest.Text)"; suggestVis = "$($ui.RailSuggest.Visibility)"; suggestTip = "$($ui.RailSuggest.ToolTip)"
            }
        }
        (@{ views = $out } | ConvertTo-Json -Compress -Depth 6)
        """,
        psOut => CSharpSide(psOut));

    /// <summary>One clock for the case, shared by both sides through the spliced model.</summary>
    private static readonly DateTime Now = DateTime.Now.AddMinutes(-1);

    /// <summary>The same tie handling the PowerShell half does, on this side's own items.</summary>
    private static (bool Ok, JsonArray Items) Ties(JsonArray items, string sort, List<RailRow> rows)
    {
        var ok = true;
        var fixedItems = new JsonArray();
        var run = new List<JsonObject>();
        var last = int.MaxValue;
        void Flush()
        {
            foreach (var t in run.OrderBy(t => -t["key"]!.GetValue<int>())
                                 .ThenBy(t => t["path"]!.GetValue<string>(), StringComparer.CurrentCultureIgnoreCase))
            {
                fixedItems.Add(t.DeepClone());
            }

            run.Clear();
            last = int.MaxValue;
        }

        foreach (var node in items)
        {
            var it = (JsonObject)node!;
            if (it["kind"]!.GetValue<string>() == "band")
            {
                Flush();
                fixedItems.Add(it.DeepClone());
                continue;
            }

            var path = it["path"]!.GetValue<string>();
            var kids = rows.Where(r => string.Equals(r.Path, path, StringComparison.OrdinalIgnoreCase)).ToList();
            var n = sort == "waiting" ? kids.Count(r => r.Band == Bands.Needs) : kids.Count(r => r.Live);
            if (n > last)
            {
                ok = false;
            }

            last = n;
            var copy = (JsonObject)it.DeepClone();
            copy["key"] = n;
            run.Add(copy);
        }

        Flush();
        return (ok, fixedItems);
    }

    private static string CSharpSide(string psOut)
    {
        var dirs = Dirs.Select(d =>
        {
            var json = new JsonObject { ["path"] = d.Path, ["missing"] = false };
            if (d.Enabled is { } e)
            {
                json["enabled"] = e;
            }

            if (d.Shelved)
            {
                json["shelved"] = true;
            }

            var ss = new JsonArray();
            foreach (var s in d.Sessions)
            {
                ss.Add(new JsonObject
                {
                    ["sessionId"] = s.Id, ["lane"] = s.Lane, ["gone"] = s.Gone,
                    ["lastActive"] = Now.AddHours(-s.AgeHours).ToString("o", CultureInfo.InvariantCulture),
                    ["enabled"] = s.Ticked,
                });
            }

            json["sessions"] = ss;
            return (Spec: d, Model: JsonSerializer.Deserialize<RegistryDirectory>(json.ToJsonString())!);
        }).ToList();

        var labels = ProjectLabels.For(dirs.Select(x => x.Model.Path));
        var accentOrder = ProjectAccent.Order(dirs.Select(x => x.Model.Path));
        var liveIds = Dirs.SelectMany(d => d.Sessions).Where(s => s.Live).Select(s => s.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);

        var rows = new List<RailRow>();
        foreach (var (spec, model) in dirs)
        {
            for (var i = 0; i < spec.Sessions.Length; i++)
            {
                var s = spec.Sessions[i];
                if (s.Gone)
                {
                    continue;
                }

                rows.Add(new RailRow(model.Path, Now.AddHours(-s.AgeHours).Ticks, s.Band, s.Live, model.Sessions[i], model,
                    Hay(spec, s), (labels.Of(model.Path) + " " + model.Path).ToLowerInvariant()));
            }
        }

        var suggest = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var names = new List<string>();
        foreach (var (spec, model) in dirs)
        {
            var running = spec.Sessions.Any(s => liveIds.Contains(s.Id));
            var why = ShelveSuggestion.For(model, null, running, DateTime.Now);
            if (why.Length > 0)
            {
                suggest[model.Path] = why;
                names.Add(labels.Of(model.Path));
            }
        }

        var budgets = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase) { ["eps/*"] = 0, ["alpha/*"] = 3 };
        bool AutoOff(string path) =>
            budgets.TryGetValue(Titles.PathLeaf(path) + "/*", out var n) && n == 0;

        var views = new JsonArray();
        foreach (var v in Views)
        {
            var shut = v.Shut.Split(',', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal);
            var built = Rail.Build(rows, new RailView(v.Q, v.Qr, v.Sort, v.OnlyLive, v.ShowShelved, shut, v.Pick),
                labels, accentOrder, RailCuts.At(), AutoOff, suggest);
            var items = new JsonArray();
            foreach (var it in built?.Items ?? [])
            {
                if (it is RailHead h)
                {
                    items.Add(new JsonObject { ["kind"] = "band", ["key"] = h.Key, ["label"] = h.Label, ["count"] = h.Count, ["caret"] = h.Caret });
                }
                else if (it is RailTile t)
                {
                    items.Add(new JsonObject
                    {
                        ["kind"] = "tile", ["path"] = t.Path, ["label"] = t.Label, ["count"] = t.Count,
                        ["state"] = t.State, ["tip"] = t.Tip,
                        ["accent"] = string.Format(CultureInfo.InvariantCulture, "{0:X2}{1:X2}{2:X2}", t.Accent.R, t.Accent.G, t.Accent.B),
                        ["opacity"] = t.AccentOpacity.ToString(CultureInfo.InvariantCulture),
                        ["needs"] = t.NeedsVisible ? "Visible" : "Collapsed",
                        ["pickBg"] = t.Picked ? "SelBg" : "Blank",
                        ["pickEdge"] = t.Picked ? "EdgeLit" : "Blank",
                        ["fg"] = t.Picked ? "TextMax" : "TextHigh",
                    });
                }
            }

            var orderOk = true;
            if (v.Sort is "waiting" or "busiest")
            {
                (orderOk, items) = Ties(items, v.Sort, rows);
            }

            var shelvedCtl = built is null ? null : Rail.ShelvedControl(built.Shelved, v.ShowShelved);
            var suggestCtl = built is null ? null : Rail.SuggestControl(names);
            views.Add(new JsonObject
            {
                ["view"] = v.Name, ["threw"] = built is null, ["orderOk"] = orderOk, ["items"] = items,
                ["clear"] = built is not null && v.Pick is not null ? "Visible" : "Collapsed",
                ["shelvedText"] = shelvedCtl?.Text ?? string.Empty,
                ["shelvedVis"] = shelvedCtl is null ? "Collapsed" : "Visible",
                ["shelvedTip"] = shelvedCtl?.Tip ?? string.Empty,
                ["suggestText"] = suggestCtl?.Text ?? string.Empty,
                ["suggestVis"] = suggestCtl is null ? "Collapsed" : "Visible",
                ["suggestTip"] = suggestCtl?.Tip ?? string.Empty,
            });
        }

        return new JsonObject { ["views"] = views }.ToJsonString(Compact);
    }
}
