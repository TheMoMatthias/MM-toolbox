using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace SessionRestore.Core.Transcripts;

/// <summary>How full a conversation's context is, as its transcript records it.</summary>
/// <param name="Ok">The transcript was read and had at least one record.</param>
/// <param name="Model">The last model that answered, never <c>&lt;synthetic&gt;</c>.</param>
/// <param name="Tokens">Input plus both cache figures of the newest usage record that had any.</param>
/// <param name="Window">200k, or 1M when the model says so or the count is already past 200k.</param>
public sealed record ContextUse(bool Ok, string Model, long Tokens, int Window)
{
    public static ContextUse None { get; } = new(false, string.Empty, 0, 200000);

    /// <summary>
    /// The model, token count and window from a transcript's tail. Ported from the
    /// part of <c>Get-SRSessionVitals</c> the row's context bar reads.
    /// </summary>
    /// <remarks>
    /// 🔴 THE WINDOW IS A GUESS AND THE ROW KNOWS IT. The model id does not record
    /// which window was chosen, so a 1M conversation under 200k reads as 200k -
    /// which is why a window the session PRINTED outranks this wherever one has
    /// ever been seen. This is the fallback, not the answer.
    ///
    /// 🪤 THE SUM IS A LONG. PowerShell widens an overflowing sum to a double
    /// rather than wrapping, so an int here would disagree on exactly the input
    /// that matters least and look like a parser defect.
    /// </remarks>
    public static ContextUse Read(string? jsonlPath, int maxTailBytes = 600000)
    {
        if (string.IsNullOrEmpty(jsonlPath) || !File.Exists(jsonlPath))
        {
            return None;
        }

        string text;
        try
        {
            var len = new FileInfo(jsonlPath).Length;
            using var fs = new FileStream(jsonlPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var take = (int)Math.Min(len, maxTailBytes);
            fs.Seek(-take, SeekOrigin.End);
            var buf = new byte[take];
            var read = fs.Read(buf, 0, take);
            text = Encoding.UTF8.GetString(buf, 0, read);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return None;
        }

        var lines = text.Split('\n').Where(l => l.Trim().StartsWith('{')).ToList();
        if (lines.Count == 0)
        {
            return None;
        }

        var model = string.Empty;
        long tokens = 0;
        foreach (var ln in lines)
        {
            JsonDocument doc;
            try
            {
                doc = JsonDocument.Parse(ln);
            }
            catch (JsonException)
            {
                continue;
            }

            using (doc)
            {
                if (doc.RootElement.ValueKind != JsonValueKind.Object
                    || !Member(doc.RootElement, "message", out var m)
                    || !Truthy(m)
                    || m.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                if (Member(m, "model", out var mv))
                {
                    var s = Str(mv);
                    if (s.Length > 0 && !string.Equals(s, "<synthetic>", StringComparison.OrdinalIgnoreCase))
                    {
                        model = s;
                    }
                }

                if (Member(m, "usage", out var u) && Truthy(u) && u.ValueKind == JsonValueKind.Object)
                {
                    long tot = 0;
                    foreach (var f in new[] { "input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens" })
                    {
                        if (Member(u, f, out var fv))
                        {
                            tot += PsInt(fv);
                        }
                    }

                    if (tot > 0)
                    {
                        tokens = tot;
                    }
                }
            }
        }

        var window = Regex.IsMatch(model, "1m", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant) || tokens > 200000
            ? 1000000
            : 200000;
        return new ContextUse(true, model, tokens, window);
    }

    /// <summary>A member looked up the way PowerShell reads one: case-insensitively.</summary>
    private static bool Member(JsonElement o, string name, out JsonElement value)
    {
        foreach (var p in o.EnumerateObject())
        {
            if (string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                value = p.Value;
                return true;
            }
        }

        value = default;
        return false;
    }

    /// <summary>PowerShell's truthiness for a JSON value.</summary>
    private static bool Truthy(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.Null or JsonValueKind.Undefined or JsonValueKind.False => false,
        JsonValueKind.String => (e.GetString() ?? string.Empty).Length > 0,
        JsonValueKind.Number => e.GetDecimal() != 0,
        JsonValueKind.Array => e.GetArrayLength() > 0,
        _ => true,
    };

    private static string Str(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.String => e.GetString() ?? string.Empty,
        JsonValueKind.Null or JsonValueKind.Undefined => string.Empty,
        _ => e.GetRawText(),
    };

    /// <summary>
    /// PowerShell's <c>[int]</c> on a JSON value: numbers round half to even, a
    /// numeric string parses, null is nought - and anything else throws, as it does there.
    /// </summary>
    private static int PsInt(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.Null or JsonValueKind.Undefined => 0,
        JsonValueKind.True => 1,
        JsonValueKind.False => 0,
        JsonValueKind.Number => checked((int)Math.Round(e.GetDecimal(), MidpointRounding.ToEven)),
        JsonValueKind.String => checked((int)Math.Round(
            decimal.Parse(e.GetString() ?? "0", NumberStyles.Float, CultureInfo.InvariantCulture), MidpointRounding.ToEven)),
        _ => throw new FormatException("a usage figure that is not a number"),
    };
}
