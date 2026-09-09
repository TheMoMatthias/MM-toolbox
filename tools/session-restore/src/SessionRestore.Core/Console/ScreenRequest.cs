using System.Globalization;

namespace SessionRestore.Core.Console;

/// <summary>
/// One line of the screen-server protocol, taken apart.
/// </summary>
/// <remarks>
/// 🔑 THREE SHAPES, AND THEY EXTEND THE ORIGINAL RATHER THAN REPLACING IT:
/// <c>&lt;pid&gt;</c>, <c>&lt;pid&gt;:&lt;back&gt;</c>, and <c>a&lt;pid&gt;</c>
/// for the colour plane. Neither an 'a' prefix nor a colon can occur in a bare
/// pid, which is what let the PowerShell add both in place - an older caller and
/// a newer server still understand each other.
///
/// 🪤 IT LIVES IN Core, NOT IN THE HELPER, so the client that BUILDS a request
/// and the server that READS one share a definition. Two copies of a wire format
/// is two things to keep in step, and the one that drifts is the one nobody is
/// looking at.
/// </remarks>
public readonly record struct ScreenRequest(uint Pid, int Back, bool Attributes)
{
    /// <summary>The wire form of this request.</summary>
    public override string ToString()
    {
        var body = Pid.ToString(CultureInfo.InvariantCulture);
        if (Back > 0)
        {
            body += ":" + Back.ToString(CultureInfo.InvariantCulture);
        }

        return Attributes ? "a" + body : body;
    }

    /// <summary>Reads one, or null if it is not a request at all.</summary>
    public static ScreenRequest? Parse(string? line)
    {
        if (string.IsNullOrEmpty(line))
        {
            return null;
        }

        var attrs = line.StartsWith('a');
        var body = attrs ? line[1..] : line;

        var back = 0;
        var colon = body.IndexOf(':', StringComparison.Ordinal);
        if (colon >= 0)
        {
            if (!int.TryParse(body[(colon + 1)..], NumberStyles.Integer, CultureInfo.InvariantCulture, out back)
                || back < 0)
            {
                return null;
            }

            body = body[..colon];
        }

        return uint.TryParse(body, NumberStyles.Integer, CultureInfo.InvariantCulture, out var pid)
            ? new ScreenRequest(pid, back, attrs)
            : null;
    }
}
