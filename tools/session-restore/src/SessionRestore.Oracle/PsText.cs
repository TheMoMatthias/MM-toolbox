using System.Globalization;
using System.Text;

namespace SessionRestore.Oracle;

/// <summary>Spelling a C# string as a PowerShell expression.</summary>
public static class PsText
{
    /// <summary>
    /// A PowerShell expression that evaluates to exactly <paramref name="text"/>.
    /// </summary>
    /// <remarks>
    /// 🔴 EVERY CHARACTER OUTSIDE PRINTABLE ASCII IS SPELLED AS [char]0xNNNN, and
    /// nothing is encoded. Two reasons, both measured: the oracle's session reads
    /// its script through a pipe where a stray codepage turns a U+23F5 into three
    /// Latin-1 characters; and the one alternative that avoids that - base64,
    /// decoded in the script - is a dropper's shape, which the antivirus refused
    /// outright on 2026-09-13.
    /// </remarks>
    public static string Literal(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var sb = new StringBuilder("('");
        foreach (var ch in text)
        {
            if (ch == '\'')
            {
                sb.Append("''");
            }
            else if (ch >= ' ' && ch <= '~')
            {
                sb.Append(ch);
            }
            else
            {
                sb.Append(CultureInfo.InvariantCulture, $"' + [string][char]0x{(int)ch:X4} + '");
            }
        }

        return sb.Append("')").ToString();
    }
}
