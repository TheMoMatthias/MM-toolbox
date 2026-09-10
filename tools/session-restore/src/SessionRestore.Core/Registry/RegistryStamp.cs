using System.Globalization;
using System.Security.Cryptography;

namespace SessionRestore.Core.Registry;

/// <summary>
/// What the registry looked like when this session read it. Plan item 2.7.
/// </summary>
/// <remarks>
/// 🔑 THE STAMP CARRIES THE CONTENT ITSELF - sha256 of the bytes, measured at
/// 1,98 ms on top of a 0,67 ms stat, which is nothing on a save and a save is a
/// gesture rather than a hot path.
///
/// 🔑 AND IT IS ONE OPAQUE STRING ON PURPOSE. The alternative - keeping the raw
/// text read at load time as a baseline - has to cross a runspace boundary: the
/// background probe reads the registry in its own runspace and hands back both
/// the object and the stamp. A second parallel baseline would mean marshalling
/// 549.146 characters every 15 s, and would be a second thing to remember on
/// every path that adopts one.
///
/// 🪤 IT ALSO MAKES THE BOM TRAP STRUCTURALLY IMPOSSIBLE. A baseline derived
/// from the string we serialised would never match the file - PowerShell's
/// <c>Set-Content -Encoding utf8</c> adds a BOM and a trailing newline (measured:
/// 7 characters in, 12 bytes out, 9 characters back). This always reads what is
/// actually on disk.
/// </remarks>
public static class RegistryStamp
{
    /// <summary>The file could not be hashed - something has it open exclusively.</summary>
    public const string Unhashed = "unhashed";

    /// <summary>
    /// The stamp for a file.
    /// </summary>
    /// <remarks>
    /// 🔴 THE EMPTY STRING MEANS "THERE IS NO FILE", AND THAT IS NOT THE SAME AS
    /// "COULD NOT TELL". The two are separate values because the save guard has
    /// to treat them oppositely: no file means there is nothing to clobber, and
    /// could-not-tell means refuse. Collapsing them is what let a save go
    /// through against a registry it had failed to read.
    /// </remarks>
    public static string Of(string path)
    {
        ArgumentNullException.ThrowIfNull(path);

        FileInfo fi;
        try
        {
            fi = new FileInfo(path);
            if (!fi.Exists)
            {
                return string.Empty;
            }
        }
        catch (IOException)
        {
            return string.Empty;
        }
        catch (UnauthorizedAccessException)
        {
            return string.Empty;
        }

        string hex;
        try
        {
            // 🪤 FileShare.ReadWrite. Another window mid-save must not turn this
            // into an exception - and a torn read cannot produce a FALSE MATCH,
            // only a mismatch, which fails safe by refusing.
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            hex = Convert.ToHexString(SHA256.HashData(fs));
        }
        catch (IOException)
        {
            return Unhashed;
        }
        catch (UnauthorizedAccessException)
        {
            return Unhashed;
        }

        return string.Create(CultureInfo.InvariantCulture,
            $"{fi.Length}|{fi.LastWriteTimeUtc.Ticks}|{hex}");
    }
}
