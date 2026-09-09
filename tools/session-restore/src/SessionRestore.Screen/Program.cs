using System.Globalization;
using System.Text;
using SessionRestore.Core.Console;

// ---------------------------------------------------------------------------
// sr-screen <pid> <outfile>            the visible screen
// sr-screen -attrs <pid> <outfile>     its colour plane
// sr-screen -back <n> <pid> <outfile>  n rows above the visible top as well
// sr-screen -serve <pipe> [idleSeconds]  stay alive and answer reads on a pipe
//
// 🔴 THE ANSWER GOES TO A FILE, NEVER TO STDOUT, and that is a measured lesson
// rather than a preference: this process frees its own console, attaches to
// somebody else's, and frees again. A child that has just done that is not
// something to trust a redirected stream to. The PowerShell it replaces writes
// to a file for exactly this reason and says so.
//
// 🪤 THE FILE LIVES WHERE THE CALLER SAYS, and the caller puts it beside the
// tool's own state rather than in the OS temp directory - a leaked temp there
// degrades every later session on this machine.
// ---------------------------------------------------------------------------

// The held-open form. See Server for why it exists and what it measured at.
if (args.Length >= 2 && string.Equals(args[0], "-serve", StringComparison.Ordinal))
{
    var idle = args.Length >= 3 &&
               int.TryParse(args[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out var s)
        ? s
        : 120;
    return SessionRestore.Screen.Server.Run(args[1], idle);
}

if (args.Length < 2)
{
    Console.Error.WriteLine("usage: sr-screen [-attrs] [-back <n>] <pid> <outfile>");
    Console.Error.WriteLine("       sr-screen -serve <pipe> [idleSeconds]");
    return 2;
}

var attrs = false;
var back = 0;
var rest = new List<string>();

for (var i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "-attrs":
            attrs = true;
            break;
        case "-back" when i + 1 < args.Length:
            _ = int.TryParse(args[++i], NumberStyles.Integer, CultureInfo.InvariantCulture, out back);
            break;
        default:
            rest.Add(args[i]);
            break;
    }
}

if (rest.Count < 2 ||
    !uint.TryParse(rest[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var pid))
{
    Console.Error.WriteLine("usage: sr-screen [-attrs] [-back <n>] <pid> <outfile>");
    return 2;
}

var text = attrs ? ConsoleApi.Attributes(pid, back) : ConsoleApi.Rows(pid, back);

// 🪤 UTF-8 WITHOUT A BOM. The caller splits this on newlines and tests whether
// a line starts with a given character; a BOM makes the first line of every
// read fail that test, silently.
File.WriteAllText(rest[1], text, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));

// A refusal is still an answer, and the caller reads it out of the file. The
// exit code says only whether the helper itself ran.
return 0;
