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
        yield return (Live(), true, "the same rail over the operator's own projects, with real bands and real live flags");
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

    /// <summary>
    /// The PowerShell half: compose the real model, run the real Build-Rail.
    /// </summary>
    /// <remarks>
    /// 🪤 THE SAME SPLICE LIST AS <c>rail/build</c> PLUS THE BAND FUNCTIONS,
    /// because this one derives the band rather than being handed it.
    /// </remarks>
    private const string LiveScript = """
        Add-Type -AssemblyName PresentationCore
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        foreach ($fn in @('Build-Rail', 'Get-RailGrouping', 'New-RailTile', 'Get-RailBandCuts', 'Get-RailBandKey',
                          'Get-ProjectAccent', 'Convert-HslToColor', 'Update-ProjectLabels', 'Get-ProjectLabel',
                          'Test-SRProjectRestoreOff', 'Test-SRProjectAutoTickOff', 'Get-SRPathLeaf',
                          'Update-RailShelved', 'Update-RailSuggest', 'Update-ShelveSuggestions',
                          'Sync-SRSessionItems', 'Get-SRItemSig',
                          'Test-SROpenDismissed', 'Get-SRRestingBand', 'Get-Band', 'Get-Title')) {
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
        $V_Show = 'Visible'; $V_Hide = 'Collapsed'
        function New-SRCtl { [PSCustomObject]@{ Text = ''; Visibility = 'Collapsed'; ToolTip = $null; Foreground = $null; ItemsSource = $null } }

        $script:HandbackMinChars = 40
        $script:askSeen = @{}
        $script:openDismissed = @{}

        # ---- the real model -------------------------------------------------
        $agentMap = Get-SRAgentStatus -Refresh
        $reg = Get-SRRegistry
        $script:dirs = @(@($reg.directories) | Where-Object { -not $_.missing })
        $script:model = @()
        $rowsOut = @()
        foreach ($d in $script:dirs) {
            foreach ($s in @($d.sessions)) {
                if ($s.gone) { continue }
                $id = "$($s.sessionId)".ToLower()
                $a = $agentMap[$id]
                # 🪤 -Conv $null IS WHAT UPDATE-MODEL PASSES: the transcript
                # reader is not on the band path at all.
                $cv = Resolve-SRSessionState -Agent $a -Conv $null
                $at = 0
                try { $at = ([datetime]$s.lastActive).Ticks } catch { }
                $r = [PSCustomObject]@{ Id = $id; S = $s; D = $d; A = $a; Conv = $cv; Said = $null
                                        At = [long]$at; Band = ''; Live = [bool]($a -and $a.pid); Hay = ''; HayProj = '' }
                $r.Band = "$(Get-Band $r)"
                $script:model += $r
                $rowsOut += [ordered]@{ id = $id; band = $r.Band; live = $r.Live }
            }
        }

        $script:accentOrder = @(); $script:accentCache = @{}
        Update-ProjectLabels
        foreach ($r in $script:model) {
            $t = Get-Title $r.S $r.D
            $r.Hay = ('{0} {1} {2} {3} {4}' -f $t.Text, $r.S.autoTitle, $r.D.path, $r.Id, (Get-ProjectLabel "$($r.D.path)")).ToLower()
            $r.HayProj = ('{0} {1}' -f (Get-ProjectLabel "$($r.D.path)"), $r.D.path).ToLower()
        }

        # 🔴 NEITHER SIDE GETS THE OPERATOR'S CONFIG. The lane budgets and the
        # shelve suggestions are read off it, and a comparison that depended on
        # a file he edits would move under both of us. rail/build's shaped views
        # are what exercise those two branches.
        $script:cfg = [PSCustomObject]@{}
        Update-ShelveSuggestions

        # 🔴 TWO VIEWS, NOT ONE, AND THE FIRST VERSION HAD ONE. Over `recent`
        # alone the rail never reads the LIVE flag at all - so dropping it on
        # this side stayed green, along with the label and the accent order.
        # One view reaches one set of branches; this is the same lesson the
        # captured screens taught, in a different shape.
        $gen = 0
        $out = @()
        foreach ($v in @(
            @{ n = 'recent';    sort = 'recent';  live = $false },
            @{ n = 'only-live'; sort = 'recent';  live = $true  })) {
            $gen++
            $ui = @{ Search = (New-SRCtl); RailSearch = (New-SRCtl); RailList = (New-SRCtl); RailClear = (New-SRCtl); RailShelved = (New-SRCtl); RailSuggest = (New-SRCtl) }
            $script:railSort = $v.sort; $script:railOnlyLive = $v.live; $script:railShowShelved = $false; $script:railPick = $null
            $script:railBandShut = @{}
            $script:modelGen = $gen
            $script:railBound = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
            Build-Rail

            $vi = @()
            foreach ($it in @($script:railBound)) {
                if ("$($it.Kind)" -eq 'band') {
                    $vi += [ordered]@{ kind = 'band'; key = "$($it.BandKey)"; label = "$($it.BandLabel)"; count = [int]$it.BandCount; caret = "$($it.BandCaret)" }
                } else {
                    $c = $it.Accent.Color
                    $vi += [ordered]@{ kind = 'tile'; path = "$($it.Path)"; label = "$($it.Label)"; count = [int]$it.Count
                                       state = "$($it.State)"; accent = ('{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B) }
                }
            }
            $out += [ordered]@{ view = $v.n; items = $vi }
        }
        $items = $out

        # 🔑 THE QUESTION TRAVELS AS A COUNT, NOT AS ITSELF. The directories
        # and the per-row bands are handed over so both sides build the rail
        # from ONE registry read - but echoing a megabyte of registry back would
        # make a one-tile difference arrive inside a diff nobody can read. Both
        # sides state how many rows and how many projects they worked from, so a
        # side that quietly dropped some is caught, and the ANSWER is the rail.
        (@{ views = $items; rowCount = @($rowsOut).Count; dirCount = @($script:dirs).Count
            rows = $rowsOut; dirs = $script:dirs } | ConvertTo-Json -Compress -Depth 8)
        """;

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


    // ------------------------------------------------- the rail over real data

    /// <summary>
    /// The rail built from the registry that is actually on this machine.
    /// </summary>
    /// <remarks>
    /// 🔴 THIS WAS DEFERRED FROM 4.2b WITH A NAMED TRIGGER - *"the rail needs
    /// bands and live agents per row, which the oracle has no model pass to
    /// build"*. The background pass built exactly that composition, so the
    /// trigger has fired.
    ///
    /// 🔑 THE POWERSHELL COMPOSES THE ROWS AND HANDS THEM OVER AS THE QUESTION,
    /// which is what makes this comparable at all. The band of a live
    /// conversation moves, the agent map is a subprocess taken at one moment,
    /// and two sides reading those independently would differ for reasons that
    /// are about the machine rather than about either rail. Here the INPUT is
    /// fixed by one side and the ANSWER - the headings, the tiles, their counts,
    /// their accents and their order - is computed twice. Nothing moves, so
    /// nothing needs forgiving, and a difference is real.
    ///
    /// 🪤 AND IT DELIBERATELY DOES NOT EXERCISE THE LANE BUDGETS OR THE SHELVE
    /// SUGGESTIONS. Both are read off the operator's own config, which this must
    /// not depend on; both sides are given the same empty ones. Those two
    /// branches are what `rail/build`'s eleven shaped views are for - this case
    /// answers a different question: does the rail agree over FOURTEEN REAL
    /// PROJECTS and four hundred real conversations.
    /// </remarks>
    private static OracleCase Live() => new(
        "rail/live",
        "headings, tiles, counts and accents over the registry on this machine",
        LiveScript,
        psOut =>
        {
            var doc = System.Text.Json.Nodes.JsonNode.Parse(psOut);

            // The directories, exactly as the other side read them.
            var dirs = new List<RegistryDirectory>();
            foreach (var d in doc?["dirs"]?.AsArray() ?? [])
            {
                if (d is not null
                    && JsonSerializer.Deserialize<RegistryDirectory>(d.ToJsonString()) is { } model)
                {
                    dirs.Add(model);
                }
            }

            // The band and the live flag per conversation - the question, not
            // the answer. Neither is recomputed here.
            var bands = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var live = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var r in doc?["rows"]?.AsArray() ?? [])
            {
                var id = r?["id"]?.GetValue<string>() ?? string.Empty;
                bands[id] = r?["band"]?.GetValue<string>() ?? string.Empty;
                if (r?["live"]?.GetValue<bool>() == true)
                {
                    live.Add(id);
                }
            }

            var labels = ProjectLabels.For(dirs.Select(x => x.Path));
            var accents = ProjectAccent.Order(dirs.Select(x => x.Path));

            var rows = new List<RailRow>();
            foreach (var dir in dirs)
            {
                foreach (var session in dir.Sessions)
                {
                    var id = session.SessionId.ToLowerInvariant();
                    if (session.Gone || !bands.TryGetValue(id, out var band))
                    {
                        continue;
                    }

                    var at = session.LastActive?.LocalDateTime.Ticks ?? 0;
                    var hay = SearchMatch.Haystack(
                        Titles.Of(session, dir).Text, session.AutoTitle, dir.Path, id, labels.Of(dir.Path));
                    var hayProj = (labels.Of(dir.Path) + " " + dir.Path).ToLowerInvariant();
                    rows.Add(new RailRow(dir.Path, at, band, live.Contains(id), session, dir, hay, hayProj));
                }
            }

            LiveRows = rows.Count;
            LiveDirs = dirs.Count;

            // 🪤 THE SHELVE SUGGESTION IS NOT READ OFF THE CONFIG - IT IS
            // DERIVED. Handing both sides an empty one made the first run red
            // on a single tile: "4 idle - could be shelved" against "4 idle".
            // Only the DAY COUNT comes from the config; the suggestion itself
            // comes from how long the project has been quiet and whether
            // anything in it is running, so this side has to work it out too.
            var suggest = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var dir in dirs)
            {
                var running = dir.Sessions.Any(x => live.Contains(x.SessionId.ToLowerInvariant()));
                var why = ShelveSuggestion.For(dir, null, running, DateTime.Now);
                if (why.Length > 0)
                {
                    suggest[dir.Path] = why;
                }
            }

            // The same four views the other side built, in the same order.
            var views = new JsonArray();
            foreach (var (name, sort, onlyLive) in LiveViews)
            {
                var built = Rail.Build(
                    rows,
                    new RailView(string.Empty, string.Empty, sort, onlyLive, false,
                                 new HashSet<string>(StringComparer.Ordinal), null),
                    labels, accents, RailCuts.At(),
                    _ => false,
                    suggest);

                views.Add(new JsonObject { ["view"] = name, ["items"] = Items(built) });
            }

            // 🪤 THE QUESTION IS HANDED BACK UNCHANGED, and that is not a
            // cheat - it is what lets the two documents be compared at all.
            // What must never be echoed is the ANSWER; the views and the two
            // counts are computed here from the rows this side built.
            return new JsonObject
            {
                ["views"] = views,
                ["rowCount"] = LiveRows,
                ["dirCount"] = LiveDirs,
                ["rows"] = doc?["rows"]?.DeepClone(),
                ["dirs"] = doc?["dirs"]?.DeepClone(),
            }.ToJsonString();
        });

    /// <summary>
    /// 🔴 TWO VIEWS, NOT ONE. Over `recent` alone the rail never reads the LIVE
    /// flag at all, so dropping it on this side stayed GREEN. One view reaches
    /// one set of branches - the same lesson the captured screens taught, in a
    /// different shape.
    ///
    /// 🪤 AND `busiest` AND `waiting` ARE DELIBERATELY NOT HERE. They order
    /// tiles by a count, and over 412 real conversations that count TIES
    /// constantly - both sorts are unstable, so the two sides disagreed on the
    /// order of tied tiles and on nothing else. `rail/build` already compares
    /// those two orders across eleven shaped views, with a tie normaliser
    /// written for exactly this; repeating it here would add a second copy of
    /// that machinery to catch nothing new.
    /// </summary>
    private static readonly (string Name, string Sort, bool OnlyLive)[] LiveViews =
    [
        ("recent", "recent", false),
        ("only-live", "recent", true),
    ];

    /// <summary>The rail's items, as the two sides compare them.</summary>
    private static JsonArray Items(RailBuild? built)
    {
        var items = new JsonArray();
        if (built is not null)
        {
            foreach (var h in built.Items)
            {
                items.Add(h switch
                {
                    RailHead head => new JsonObject
                    {
                        ["kind"] = "band", ["key"] = head.Key, ["label"] = head.Label,
                        ["count"] = head.Count, ["caret"] = head.Caret,
                    },
                    RailTile tile => new JsonObject
                    {
                        ["kind"] = "tile", ["path"] = tile.Path, ["label"] = tile.Label,
                        ["count"] = tile.Count, ["state"] = tile.State,
                        ["accent"] = string.Format(CultureInfo.InvariantCulture, "{0:X2}{1:X2}{2:X2}",
                            tile.Accent.R, tile.Accent.G, tile.Accent.B),
                    },
                    _ => new JsonObject { ["kind"] = "?" },
                });
            }
        }

        return items;
    }

    /// <summary>How many real conversations and projects the live case held.</summary>
    public static int LiveRows { get; private set; }

    public static int LiveDirs { get; private set; }

    public static string LiveCoverage() => string.Format(CultureInfo.InvariantCulture,
        "{0} real conversation(s) across {1} real project(s), bands and live flags handed over as the question",
        LiveRows, LiveDirs);

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
