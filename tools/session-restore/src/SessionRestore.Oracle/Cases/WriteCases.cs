using System.Globalization;
using System.Text.Json.Nodes;
using SessionRestore.Core;
using SessionRestore.Core.Registry;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 2.7 - the registry WRITE, and it is last on purpose.
/// </summary>
/// <remarks>
/// 🔴 A REGISTRY-OVERWRITE BUG IN THIS REPO'S HISTORY COST 210 CONVERSATIONS.
/// Nothing here writes the operator's registry, and nothing here CAN: the C#
/// writer takes a <see cref="RegistryTarget"/>, the only factory for one refuses
/// that file by full path, and there is no factory for the live file at all.
///
/// 🔴 AND <c>Save-SRRegistry</c> IS ON THE ORACLE'S FENCE, WHICH DOES NOT MOVE.
/// That is the whole difficulty of this item: the thing to verify is a function
/// the harness is forbidden to call, and un-fencing it to make a comparison
/// possible is precisely the "loosening a write guard to make a test pass" this
/// repo has a standing rule against. So the PowerShell was split instead - the
/// stale check is now <c>Get-SRSaveRefusal</c>, which returns a sentence and
/// writes nothing - exactly the move that made the launch path comparable in
/// 2.5c. The guard is compared; the act stays fenced.
///
/// 🔑 AND THE WRITE ITSELF IS VERIFIED THE ONE WAY THAT MATTERS: the C# writes a
/// COPY, and the SHIPPED POWERSHELL READER opens it and reports what it found.
/// "The old tool can read what the new one writes, and nothing was lost" is the
/// property a cutover actually needs - stronger than a round-trip inside one
/// implementation, which would agree with itself about a field both halves drop.
/// </remarks>
public static class WriteCases
{
    /// <summary>How many conversations were carried through a real write.</summary>
    public static int Carried { get; private set; }

    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Stamp(), true, "the stamp that decides whether a save is safe");
        yield return (Guard(), true, "every allow and every refusal of the stale check");
        yield return (ReadBack(), true, "the old tool reads what the new one wrote, field by field");
        yield return (Refuses(), true, "the live registry cannot be named by the C# writer at all");
    }

    public static string Coverage() =>
        Carried.ToString(CultureInfo.InvariantCulture)
        + " conversation(s) written by the C# and read back by the shipped PowerShell - "
        + "the live registry was never opened for writing";

    private static string Scratch => Path.Combine(Path.GetTempPath(), "sr-write-oracle");

    // ---------------------------------------------------------------------

    /// <summary>
    /// 🪤 ONE ROW, AND IT IS THE HONEST ONE. <c>Get-SRRegistryStamp</c> reads
    /// <c>$SR_RegistryPath</c> and nothing else, so the only file both sides can
    /// independently stamp is the live registry - read only, never written. The
    /// two "could not tell" answers cannot be produced from it and are proved in
    /// <c>RegistryWriteTests</c> instead, where files can be made and held open
    /// freely. Saying that here is better than a case that swaps a global to
    /// fake them and then has to decide what agreement even means.
    /// </summary>
    private static OracleCase Stamp() => new(
        "write/stamp",
        "length, mtime and sha256 of the live registry - the whole staleness check",
        """
        $a = Get-SRRegistryStamp
        $b = Get-SRRegistryStamp
        (@{ before = "$a"; after = "$b"; parts = @("$a" -split '\|').Count
            hexLen = @("$a" -split '\|')[-1].Length } | ConvertTo-Json -Compress)
        """,
        psOut =>
        {
            // 🔴 THE FILE IS ASKED TWICE, AND THAT IS WHAT MAKES THE ALLOWANCE
            // NARROW ENOUGH TO BE WORTH HAVING. The first version forgave any
            // difference in the one field it had, so it could not go red at all -
            // a deliberate break from LastWriteTimeUtc to LastWriteTime sailed
            // through it. Now the PowerShell stamps the file twice: if those two
            // agree the file held still, and this side's answer is compared
            // EXACTLY. Only when they differ - the operator saved mid-run - is
            // anything forgiven, and the shape is never forgiven either way.
            var doc = JsonNode.Parse(psOut);
            var before = doc?["before"]?.GetValue<string>() ?? string.Empty;
            var after = doc?["after"]?.GetValue<string>() ?? string.Empty;
            var moved = !string.Equals(before, after, StringComparison.Ordinal);

            var mine = RegistryStamp.Of(ToolPaths.Registry);
            var parts = mine.Split('|');

            return new JsonObject
            {
                ["before"] = moved ? Moved : mine,
                ["after"] = moved ? Moved : mine,
                ["parts"] = parts.Length,
                ["hexLen"] = parts[^1].Length,
            }.ToJsonString();
        })
    {
        // 🪤 THE OPERATOR IS WORKING WHILE THIS RUNS - a tick, a rename, a
        // scan - and then the two sides hash different bytes, which is exactly
        // what the stamp exists to notice. Forgiven only on the rows the
        // PowerShell itself reported as moving.
        Tolerate = d => Diffs(d).All(x => x.Contains(Moved, StringComparison.Ordinal)),
        ToleranceReason = "the live registry was saved while the PowerShell was looking at it - it stamped two different files",
    };

    private const string Moved = "(the file moved while the PowerShell looked)";

    /// <summary>
    /// Every allow and every refusal.
    /// </summary>
    /// <remarks>
    /// 🔴 THIS IS THE CASE THE 210 CONVERSATIONS PAID FOR. The guard has four
    /// outcomes and three of them are refusals told apart on purpose, because the
    /// operator can act on each differently: a held file means try again, a
    /// changed file means Rescan first, an unreadable one means something is
    /// wrong that retrying may not fix. A comparison that only asked "did it
    /// save" would agree with a guard that never refused anything.
    ///
    /// 🔑 AND NOT ONE OF THESE SHAPES TOUCHES A FILE. Both sides are given the
    /// four inputs directly, which is what splitting the check out of the writer
    /// bought.
    ///
    /// 🔴 ONE SHAPE IS DELIBERATELY ABSENT, AND IT IS THE ONE THE TWO SIDES
    /// DISAGREE ABOUT. Two stamps differing only in CASE: PowerShell's <c>-ne</c>
    /// on strings is case-insensitive, so it calls them equal and ALLOWS the
    /// save; this side compares ordinally and refuses. It cannot occur - a stamp
    /// is <c>length|ticks|SHA256HEX</c> and the hex is always upper case from the
    /// same function - so neither behaviour is reachable from the tool. It is not
    /// in the shared list because a tolerance for it would be an allowance
    /// covering a whole row of the 210-conversation guard, and the difference is
    /// worth stating outright instead: **this side is deliberately the stricter
    /// of the two**, and being laxer to match a quirk that cannot fire would be
    /// the wrong trade on this particular check. Pinned in
    /// <c>RegistryWriteTests</c>.
    /// </remarks>
    private static OracleCase Guard() => new(
        "write/guard",
        "allow, changed, held and unreadable - the stale check over every shape",
        """
        $shapes = @(
            @{ k='never-read';      read='';           now='a-stamp';  file=$true;  force=$false }
            @{ k='never-read-force';read='';           now='a-stamp';  file=$true;  force=$true  }
            @{ k='matches';         read='a-stamp';    now='a-stamp';  file=$true;  force=$false }
            @{ k='changed';         read='old-stamp';  now='a-stamp';  file=$true;  force=$false }
            @{ k='changed-forced';  read='old-stamp';  now='a-stamp';  file=$true;  force=$true  }
            @{ k='held';            read='a-stamp';    now='unhashed'; file=$true;  force=$false }
            @{ k='held-forced';     read='a-stamp';    now='unhashed'; file=$true;  force=$true  }
            @{ k='unreadable';      read='a-stamp';    now='';         file=$true;  force=$false }
            @{ k='gone';            read='a-stamp';    now='';         file=$false; force=$false }
            @{ k='gone-never-read'; read='';           now='';         file=$false; force=$false }
            @{ k='held-never-read'; read='';           now='unhashed'; file=$true;  force=$false }
        )
        $rows = @()
        foreach ($sh in $shapes) {
            $why = Get-SRSaveRefusal -ReadStamp "$($sh.read)" -NowStamp "$($sh.now)" `
                       -FileExists ([bool]$sh.file) -Force:([bool]$sh.force)
            $rows += [ordered]@{
                k    = "$($sh.k)"
                kind = $(
                    if (-not $why) { 'allow' }
                    elseif ($why -like '*on disk but could not be read*') { 'unreadable' }
                    elseif ($why -like '*something else has it open*')    { 'held' }
                    elseif ($why -like '*changed on disk since this window read it*') { 'changed' }
                    else { 'other' }
                )
                why  = "$why"
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 4)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var k = a?["k"]?.GetValue<string>() ?? string.Empty;
                var sh = Shapes.FirstOrDefault(x => string.Equals(x.K, k, StringComparison.Ordinal));
                if (sh.K is null)
                {
                    rows.Add(new JsonObject { ["k"] = k, ["kind"] = "(no such shape here)", ["why"] = "(no such shape here)" });
                    continue;
                }

                var d = SaveDecision.For(sh.Read.Length == 0 ? null : sh.Read, sh.Now, sh.File, sh.Force);
                rows.Add(new JsonObject
                {
                    ["k"] = k,
                    ["kind"] = d.Verdict switch
                    {
                        SaveVerdict.Allow => "allow",
                        SaveVerdict.RefuseUnreadable => "unreadable",
                        SaveVerdict.RefuseHeld => "held",
                        SaveVerdict.RefuseChanged => "changed",
                        _ => "other",
                    },
                    // 🔑 THE SENTENCE IS COMPARED TOO, not just the verdict. It is
                    // what the operator reads and what tells them which of the
                    // three refusals they are looking at; two implementations
                    // agreeing on a code while disagreeing on the words is not
                    // agreement.
                    ["why"] = d.Why,
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString();
        });

    private static readonly (string K, string Read, string Now, bool File, bool Force)[] Shapes =
    [
        ("never-read", "", "a-stamp", true, false),
        ("never-read-force", "", "a-stamp", true, true),
        ("matches", "a-stamp", "a-stamp", true, false),
        ("changed", "old-stamp", "a-stamp", true, false),
        ("changed-forced", "old-stamp", "a-stamp", true, true),
        ("held", "a-stamp", "unhashed", true, false),
        ("held-forced", "a-stamp", "unhashed", true, true),
        ("unreadable", "a-stamp", "", true, false),
        ("gone", "a-stamp", "", false, false),
        ("gone-never-read", "", "", false, false),
        ("held-never-read", "", "unhashed", true, false),
    ];

    /// <summary>
    /// The C# writes; the shipped PowerShell reads.
    /// </summary>
    /// <remarks>
    /// 🔴 THIS IS THE PROPERTY A CUTOVER NEEDS AND A DATA-LOSS BUG BREAKS. A
    /// round-trip inside one implementation proves nothing about a field both
    /// halves drop; this hands the file to the OTHER tool's reader. A field this
    /// build does not model - <c>prefs</c> is exactly one - has to survive
    /// anyway, which is what <c>JsonExtensionData</c> is for and what nobody
    /// notices is missing until a tick disappears.
    ///
    /// 🪤 AND THE BYTES ARE DELIBERATELY NOT COMPARED. The two serialisers
    /// indent, escape and format numbers differently and none of that is data.
    /// Chasing byte-identical JSON would be a great deal of work proving
    /// something that does not matter while leaving this unproven.
    /// </remarks>
    private static OracleCase ReadBack() => new(
        "write/read-back",
        "every conversation and every field, out of a file the C# wrote",
        """
        $t = Join-Path $env:TEMP 'sr-write-oracle\rt-cs.json'
        if (-not (Test-Path -LiteralPath $t)) { throw "the C# side has not written its copy yet: $t" }
        $was = $SR_RegistryPath
        try {
            Set-Variable -Name SR_RegistryPath -Scope Script  -Value $t
            Set-Variable -Name SR_RegistryPath -Scope Global  -Value $t
            $back = Get-SRRegistry
        } finally {
            Set-Variable -Name SR_RegistryPath -Scope Script -Value $was
            Set-Variable -Name SR_RegistryPath -Scope Global -Value $was
        }
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($d in @($back.directories)) {
            foreach ($s in @($d.sessions)) {
                $rows.Add([ordered]@{
                    of      = "$($d.path)"
                    id      = "$($s.sessionId)"
                    title   = "$($s.title)"
                    enabled = [bool]$s.enabled
                    pinned  = [bool]$s.pinned
                    gone    = [bool]$s.gone
                    cwd     = "$($s.cwd)"
                    lane    = "$($s.lane)"
                    wt      = "$($s.worktree)"
                    jsonl   = "$($s.jsonl)"
                    auto    = "$($s.autoTitle)"
                    stamp   = "$($s.stamp)"
                    last    = $(if ($s.lastActive) { [string]([datetime]$s.lastActive).ToUniversalTime().Ticks } else { '' })
                    first   = $(if ($s.firstSeen)  { [string]([datetime]$s.firstSeen).ToUniversalTime().Ticks } else { '' })
                    # 🔑 CANONICAL, NOT SERIALISED. Two JSON writers format the
                    # same object differently and none of that is data; sorted
                    # name=value pairs are the same on both sides, or the data
                    # really did change. 🪤 An array stringifies with $OFS,
                    # which is a space - matched deliberately on the other side.
                    prefs   = $(if ($s.prefs) {
                        ((@($s.prefs.PSObject.Properties) | Sort-Object Name |
                          ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ';')
                    } else { '' })
                    # 🔴 THE FIELD LIST ITSELF, so a key the writer dropped shows
                    # up as a missing NAME rather than as a value that happens to
                    # match its default. That is how `prefs` would disappear.
                    keys    = ((@($s.PSObject.Properties.Name) | Sort-Object) -join ',')
                })
            }
        }
        (@{ version = [int]$back.version; dirs = @($back.directories).Count; rows = $rows.ToArray() } |
            ConvertTo-Json -Compress -Depth 6)
        """,
        psOut =>
        {
            // 🪤 THE COPY IS WRITTEN BEFORE THE POWERSHELL RUNS, NOT AFTER. The
            // oracle runs the PowerShell side first, so the file has to exist by
            // then - see PrepareCopy, which is called when the case is built.
            var doc = JsonNode.Parse(psOut);
            try
            {
                // 🔴 THIS SIDE REPORTS WHAT IT MEANT TO WRITE, NOT WHAT IT CAN
                // READ BACK. Re-reading the file it just wrote made this case
                // unable to detect a LOSSY WRITE at all: both sides would then be
                // reading the same lossy file and agreeing about the loss.
                // Proven - dropping [JsonExtensionData] from RegistrySession, the
                // exact bug that would destroy `prefs`, left the case green.
                // Comparing intent against what the OLD TOOL found is the only
                // arrangement where a dropped field has nowhere to hide.
                var back = Written ?? throw new InvalidOperationException(
                    "write/read-back ran before the copy was written");
                var rows = new JsonArray();
                foreach (var d in back.Directories)
                {
                    foreach (var s in d.Sessions)
                    {
                        rows.Add(new JsonObject
                        {
                            ["of"] = d.Path,
                            ["id"] = s.SessionId,
                            ["title"] = s.Title,
                            ["enabled"] = s.Enabled,
                            ["pinned"] = s.Pinned,
                            ["gone"] = s.Gone,
                            ["cwd"] = s.Cwd,
                            ["lane"] = s.Lane,
                            ["wt"] = s.Worktree ?? string.Empty,
                            ["jsonl"] = s.Jsonl ?? string.Empty,
                            ["auto"] = s.AutoTitle ?? string.Empty,
                            ["stamp"] = s.Stamp,
                            ["last"] = Ticks(s.LastActive),
                            ["first"] = Ticks(s.FirstSeen),
                            ["prefs"] = Prefs(s),
                            ["keys"] = Keys(s),
                        });
                        Carried++;
                    }
                }

                // 🔴 AND FAIL IF NOTHING WAS CARRIED. An empty file would
                // otherwise agree about nothing at all and print green.
                if (rows.Count == 0)
                {
                    rows.Add(new JsonObject { ["id"] = "(nothing survived the write)" });
                }

                return new JsonObject
                {
                    ["version"] = back.Version,
                    ["dirs"] = back.Directories.Count,
                    ["rows"] = rows,
                }.ToJsonString();
            }
            finally
            {
                Wipe();
            }
        });

    /// <summary>
    /// 🔴 THE STRUCTURAL GUARD, ASSERTED RATHER THAN TRUSTED. The PowerShell can
    /// be pointed at any path - it is a variable - so this comparison is not
    /// symmetric and does not pretend to be: the PowerShell supplies the two live
    /// paths, and this side answers whether it can name them. A guard nobody has
    /// seen refuse is not known to be there at all.
    /// </summary>
    private static OracleCase Refuses() => new(
        "write/refuses-the-live-file",
        "the C# writer has no way to name the operator's own registry",
        """
        # 🔴 THE POWERSHELL ANSWERS THE SAME QUESTION A DIFFERENT WAY. For each
        # spelling it resolves the path and says whether it IS one of the two
        # live files; the C# says whether its writer REFUSES to name it. Those
        # two answers have to be identical for every row, and a guard that
        # compared the string it was handed rather than the resolved path fails
        # on the second row onwards.
        $reg = $SR_RegistryPath
        $dir = Split-Path -Parent $reg
        $leaf = Split-Path -Leaf $reg
        $spellings = @(
            $reg
            $reg.ToUpperInvariant()
            $reg.ToLowerInvariant()
            (Join-Path (Join-Path $dir '.') $leaf)
            (Join-Path (Join-Path (Join-Path $dir 'lib') '..') $leaf)
            $SR_ConfigPath
            (Join-Path $env:TEMP 'sr-a-copy.json')
        )
        $rows = @()
        foreach ($sp in $spellings) {
            $full = [System.IO.Path]::GetFullPath($sp)
            $rows += [ordered]@{
                p    = "$sp"
                live = [bool](($full -ieq [System.IO.Path]::GetFullPath($reg)) -or
                              ($full -ieq [System.IO.Path]::GetFullPath($SR_ConfigPath)))
            }
        }
        (@{ rows = $rows } | ConvertTo-Json -Compress -Depth 4)
        """,
        psOut =>
        {
            var asked = JsonNode.Parse(psOut)?["rows"]?.AsArray() ?? [];
            var rows = new JsonArray();
            foreach (var a in asked)
            {
                var sp = a?["p"]?.GetValue<string>() ?? string.Empty;
                rows.Add(new JsonObject
                {
                    ["p"] = sp,
                    // 🔑 "REFUSED" IS THIS SIDE'S WHOLE ANSWER, and it has to
                    // line up with "is this a live file" row for row. There is no
                    // allowance on this case: an assertion nothing can fail is
                    // not an assertion, which is what the first version of it was.
                    ["live"] = RegistryTarget.ForCopy(sp, out _) is null,
                });
            }

            return new JsonObject { ["rows"] = rows }.ToJsonString();
        });

    // ---------------------------------------------------------------------

    private static string CopyPath => Path.Combine(Scratch, "rt-cs.json");

    /// <summary>
    /// Writes the copy the read-back case compares.
    /// </summary>
    /// <remarks>
    /// 🔴 THE ONLY WRITE IN THIS FILE, AND IT GOES TO THE SESSION'S SCRATCH. It
    /// is built through <see cref="RegistryTarget.ForCopy"/> like every other
    /// caller - there is no bypass - and the directory is removed in the
    /// read-back case's finally.
    /// </remarks>
    public static void PrepareCopy()
    {
        Directory.CreateDirectory(Scratch);
        var target = RegistryTarget.ForCopy(CopyPath, out var refusal)
            ?? throw new InvalidOperationException("the writer refused its own scratch copy: " + refusal);

        var reg = SessionRegistry.Read();

        // 🔴 SHAPES THE LIVE REGISTRY DOES NOT CONTAIN, or `prefs` would be
        // empty on all 560 rows and the column that proves an unmodelled field
        // survives a write would be proving nothing - the same blindness that
        // made launch/settings unable to fail. These exist ONLY in the scratch
        // copy; the operator's file is never opened for writing.
        reg.Directories.Add(new RegistryDirectory
        {
            Path = ShapeDir,
            Enabled = true,
            Sessions =
            {
                Shape(
                    "00000000-0000-0000-0000-00000000cafe",
                    "{\"model\":\"claude-opus-5\",\"effort\":\"max\","
                    + "\"allowedTools\":[\"Bash\",\"Read\"],\"remoteControl\":false,\"hidden\":true}"),
                Shape(
                    "00000000-0000-0000-0000-00000000beef",
                    "{\"model\":\"a name with \u00e4n umlaut, a ; and an apostrophe\"}"),
            },
        });

        var saved = RegistryWriter.Save(reg, target, readStamp: null);
        if (!saved.Written)
        {
            throw new InvalidOperationException(
                "2.7 could not write its own scratch copy: " + (saved.Error ?? saved.Decision.Why));
        }

        Written = reg;
    }

    /// <summary>
    /// The registry as it was handed to the writer - what the file is SUPPOSED
    /// to contain.
    /// </summary>
    private static SessionRegistry? Written { get; set; }

    private const string ShapeDir = @"C:\(sr-oracle-shapes)";

    /// <summary>
    /// A synthetic conversation carrying a <c>prefs</c> object and one field this
    /// build does not model at all.
    /// </summary>
    private static RegistrySession Shape(string id, string prefsJson) => new()
    {
        SessionId = id,
        Title = "(sr-oracle) " + id[^4..],
        Enabled = true,
        Cwd = ShapeDir,
        Lane = "main",
        LastActive = DateTimeOffset.UnixEpoch,
        Extra = new Dictionary<string, System.Text.Json.JsonElement>(StringComparer.Ordinal)
        {
            ["prefs"] = System.Text.Json.JsonDocument.Parse(prefsJson).RootElement.Clone(),

            // 🪤 A KEY NO VERSION OF THIS BUILD KNOWS. If the writer emitted
            // only what it models, this would vanish - and that is precisely how
            // an older build opening a newer file destroys a field nobody misses
            // until it is needed.
            ["somethingFromTheFuture"] =
                System.Text.Json.JsonDocument.Parse("\"keep me\"").RootElement.Clone(),
        },
    };

    private static string Ticks(DateTimeOffset? at) =>
        at is null ? string.Empty : at.Value.UtcDateTime.Ticks.ToString(CultureInfo.InvariantCulture);

    /// <summary>
    /// Sorted <c>name=value</c> pairs - the same canonical form the PowerShell
    /// side builds, so two serialisers cannot look like a data change.
    /// </summary>
    private static string Prefs(RegistrySession s)
    {
        if (s.Extra is null || !s.Extra.TryGetValue("prefs", out var p)
            || p.ValueKind != System.Text.Json.JsonValueKind.Object)
        {
            return string.Empty;
        }

        return string.Join(";", p.EnumerateObject()
            .OrderBy(x => x.Name, StringComparer.Ordinal)
            .Select(x => x.Name + "=" + Flat(x.Value)));
    }

    /// <summary>PowerShell's string conversion: an array joins on $OFS, a space.</summary>
    private static string Flat(System.Text.Json.JsonElement v) => v.ValueKind switch
    {
        System.Text.Json.JsonValueKind.Array => string.Join(" ", v.EnumerateArray().Select(Flat)),
        System.Text.Json.JsonValueKind.String => v.GetString() ?? string.Empty,
        System.Text.Json.JsonValueKind.True => "True",
        System.Text.Json.JsonValueKind.False => "False",
        System.Text.Json.JsonValueKind.Null => string.Empty,
        _ => v.ToString(),
    };

    /// <summary>
    /// Every field name this side sees on the session, sorted.
    /// </summary>
    /// <remarks>
    /// 🔴 THIS IS THE COLUMN THAT CATCHES A DROPPED FIELD. A value comparison
    /// cannot: a key the writer lost reads back as its default, and <c>false</c>
    /// for a tick that was never there is indistinguishable from <c>false</c> for
    /// a tick that was thrown away.
    /// </remarks>
    private static string Keys(RegistrySession s)
    {
        var names = new List<string>
        {
            "sessionId", "title", "enabled", "pinned", "gone", "lastActive",
            "firstSeen", "stamp", "cwd", "lane", "worktree", "jsonl", "autoTitle",
        };
        if (s.Extra is not null)
        {
            names.AddRange(s.Extra.Keys);
        }

        names.Sort(StringComparer.Ordinal);
        return string.Join(",", names);
    }

    private static void Wipe()
    {
        try
        {
            if (Directory.Exists(Scratch))
            {
                Directory.Delete(Scratch, recursive: true);
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static IEnumerable<string> Diffs(string d) =>
        (d ?? string.Empty).Split('\n').Select(x => x.Trim()).Where(x => x.Length > 0);
}
