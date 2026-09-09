using System.Globalization;
using SessionRestore.Oracle;
using SessionRestore.Oracle.Cases;

// ---------------------------------------------------------------------------
// sr-oracle - run the PowerShell domain and its C# replacement side by side.
//
//     dotnet run --project src/SessionRestore.Oracle
//     dotnet run --project src/SessionRestore.Oracle -- <name-fragment>
//
// 🔴 IT NEVER CHANGES ANYTHING. Every function that launches a session, types
// into one, drives its menus, focuses a window, or writes the registry or the
// config is replaced by a throwing stub BEFORE the comparison runs - see the
// fence in PowerShellRunner. One of the cases below exists purely to prove that
// fence is actually in place, because a safety net nobody has seen catch
// anything is not known to be there at all.
// ---------------------------------------------------------------------------

var filter = args.Length > 0 ? args[0] : string.Empty;

var cases = new List<(OracleCase Case, bool ExpectAgree, string Meaning)>
{
    // ---- the harness itself ------------------------------------------------
    (new OracleCase(
        "selftest/agree",
        "two sides that say the same thing must read as agreement",
        "'{ \"n\": 3, \"who\": \"session-restore\" }'",
        () => """{"who":"session-restore","n":3}"""),
     true,
     "key order and whitespace are not differences"),

    // 🔑 THE ONE THAT MATTERS. A comparison harness is worth nothing until it
    // has been seen to go RED - a green run only means something once you know
    // it can fail. This case is wrong on purpose, for ever.
    (new OracleCase(
        "selftest/differ",
        "a real difference must be found and NAMED, with a path",
        "'{ \"n\": 3, \"who\": \"session-restore\" }'",
        () => """{"who":"session-restore","n":4}"""),
     false,
     "a wrong value is reported as $.n"),

    (new OracleCase(
        "selftest/nested-differ",
        "a difference buried in an array must be found too",
        "'{ \"rows\": [ {\"id\":\"a\"}, {\"id\":\"b\"} ] }'",
        () => """{"rows":[{"id":"a"},{"id":"zzz"}]}"""),
     false,
     "a wrong value is reported as $.rows[1].id"),

    // ---- the fence ---------------------------------------------------------
    (new OracleCase(
        "selftest/fence-refuses-a-registry-write",
        "the fence must stop the one call that cost 210 conversations",
        "Save-SRRegistry @{}; '{\"reached\":true}'",
        () => """{"reached":false}"""),
     false,
     "Save-SRRegistry throws instead of running"),

    // ---- the domain is really loaded --------------------------------------
    (new OracleCase(
        "domain/loads",
        "the comparison must reach the REAL lib/_common.ps1, not an empty session",
        """
        $want = @('Get-SRRegistry','Get-SRConfig','Get-SRScreenText','Get-SRLastSaid')
        $have = @($want | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue })
        (@{ found = $have.Count; of = $want.Count } | ConvertTo-Json -Compress)
        """,
        () => """{"found":4,"of":4}"""),
     true,
     "the domain's own functions are present"),
};

// ---- phase 2: the domain, one item at a time ------------------------------
cases.AddRange(ConfigCases.All());
cases.AddRange(RegistryCases.All());

Console.WriteLine();
Console.WriteLine("  sr-oracle - the old implementation and the new, on the same input");
Note("tool root: " + PowerShellRunner.ToolRoot);
Console.WriteLine();

var ran = 0;
var bad = 0;
foreach (var (c, expectAgree, meaning) in cases)
{
    if (filter.Length > 0 && !c.Name.Contains(filter, StringComparison.OrdinalIgnoreCase))
    {
        continue;
    }

    ran++;
    var r = Oracle.Compare(c);

    // 🪤 THE FENCE CASE IS THE ONE PLACE A "could not run" IS THE PASS. Anywhere
    // else it means the comparison never happened and must not read as either
    // answer - so it is called out rather than counted.
    var fenceCase = c.Name.Contains("fence", StringComparison.Ordinal);
    if (r.Inconclusive && !fenceCase)
    {
        Huh(c.Name + " - " + r.Difference);
        bad++;
        continue;
    }

    if (r.Agree == expectAgree)
    {
        Ok(string.Format(CultureInfo.InvariantCulture, "{0,-42} {1}  [ps {2} ms, c# {3} ms]",
            c.Name, meaning, r.PsMs, r.CsMs));
        if (!expectAgree && r.Difference is not null)
        {
            Note("      " + r.Difference);
        }
    }
    else
    {
        bad++;
        Bad(c.Name + " - " + c.Why);
        Note("      expected them to " + (expectAgree ? "AGREE" : "DIFFER")
             + ", and they did not: " + (r.Difference ?? "no difference was found"));
    }
}

Console.WriteLine();
if (ran == 0)
{
    Huh("no case matched '" + filter + "'");
    return 2;
}

if (bad > 0)
{
    Bad(bad.ToString(CultureInfo.InvariantCulture) + " of " + ran.ToString(CultureInfo.InvariantCulture) + " did not behave as expected");
    return 1;
}

Ok("the oracle agrees where it should and disagrees where it should ("
   + ran.ToString(CultureInfo.InvariantCulture) + " case(s))");
return 0;

static void Ok(string m) => Write(ConsoleColor.Green, "  ok    " + m);
static void Bad(string m) => Write(ConsoleColor.Red, "  FAIL  " + m);
static void Huh(string m) => Write(ConsoleColor.Magenta, "  ????  " + m);
static void Note(string m) => Write(ConsoleColor.DarkGray, "        " + m);

static void Write(ConsoleColor c, string m)
{
    var was = Console.ForegroundColor;
    Console.ForegroundColor = c;
    Console.WriteLine(m);
    Console.ForegroundColor = was;
}
