using System.Text;

namespace SessionRestore.Core.Transcripts;

/// <summary>
/// Reading the end of a <c>.jsonl</c> transcript - the only part anything here
/// ever needs, and the part a live session is still writing to.
/// </summary>
public static class TranscriptTail
{
    /// <summary>The default reading window: 256 KB.</summary>
    public const int DefaultTailBytes = 262_144;

    /// <summary>
    /// The last <paramref name="tailBytes"/> of the file, decoded as UTF-8.
    /// </summary>
    /// <remarks>
    /// 🔴 SHARED READWRITE, AND THAT IS THE POINT. A live session holds its own
    /// transcript open for writing, and those are exactly the ones worth
    /// reading. Opening without the share flag fails on every conversation that
    /// is actually doing something.
    ///
    /// 🪤 A TAIL STARTS MID-CHARACTER. Seeking a byte count into UTF-8 lands
    /// inside a multi-byte sequence about as often as the file has non-ASCII in
    /// it, which for these is constantly. The partial character decodes to a
    /// replacement char on the first line, and that line is dropped by the
    /// whole-record filter anyway - which is why this reads the same way the
    /// PowerShell does rather than trying to be cleverer than it.
    /// </remarks>
    public static string Read(string path, int tailBytes = DefaultTailBytes)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path))
        {
            return string.Empty;
        }

        try
        {
            var len = new FileInfo(path).Length;
            if (len == 0)
            {
                return string.Empty;
            }

            var take = (int)Math.Min(len, tailBytes);
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read,
                                          FileShare.ReadWrite, bufferSize: 4096);
            fs.Seek(-take, SeekOrigin.End);
            var buf = new byte[take];
            var read = fs.Read(buf, 0, take);
            return Encoding.UTF8.GetString(buf, 0, read);
        }
        catch (IOException)
        {
            return string.Empty;
        }
        catch (UnauthorizedAccessException)
        {
            return string.Empty;
        }
    }

    /// <summary>
    /// The whole JSON records in <paramref name="text"/>, in file order.
    /// </summary>
    /// <remarks>
    /// 🪤 THE BYTE-ORDER MARK IS TRIMMED BEFORE THE TEST, NOT AFTER. claude's
    /// own transcripts have no BOM, but PowerShell 5.1's `Set-Content -Encoding
    /// UTF8` writes one - so any fixture written that way loses its FIRST record
    /// to this filter, silently, because a dropped line just looks like a
    /// conversation that said nothing. The PowerShell carries the same note and
    /// it cost an hour of reading the wrong function.
    /// </remarks>
    public static List<string> WholeRecords(string text)
    {
        var lines = new List<string>();
        if (string.IsNullOrEmpty(text))
        {
            return lines;
        }

        foreach (var raw in text.Split('\n'))
        {
            var t = raw.TrimStart('﻿', ' ', '\t');
            if (t.StartsWith('{'))
            {
                lines.Add(t);
            }
        }

        return lines;
    }
}
