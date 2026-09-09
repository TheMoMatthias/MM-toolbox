using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace SessionRestore.Oracle;

/// <summary>
/// Compares two answers STRUCTURALLY and names the first place they differ.
/// </summary>
/// <remarks>
/// 🔑 A STRING COMPARE WOULD BE USELESS HERE. PowerShell's ConvertTo-Json and
/// System.Text.Json disagree about key order, whitespace, how a single-element
/// array is written and how a decimal is formatted - none of which is a defect,
/// and all of which would make every comparison red on the first run and
/// therefore ignored by the second.
///
/// What the oracle has to answer is "does the C# say the same thing", and the
/// useful form of a NO is a path and two values, not two walls of text.
/// </remarks>
public static class JsonDiff
{
    /// <summary>
    /// The first structural difference, or null when the two agree.
    /// </summary>
    public static string? FirstDifference(string leftJson, string rightJson)
    {
        JsonNode? a, b;
        try
        {
            a = Parse(leftJson);
        }
        catch (JsonException ex)
        {
            return "the PowerShell side did not produce JSON: " + ex.Message;
        }

        try
        {
            b = Parse(rightJson);
        }
        catch (JsonException ex)
        {
            return "the C# side did not produce JSON: " + ex.Message;
        }

        return Walk("$", a, b);
    }

    private static JsonNode? Parse(string s)
    {
        var t = (s ?? string.Empty).Trim();
        // PowerShell writes nothing at all for $null, and an empty answer is a
        // legitimate one - so it is null rather than a parse failure.
        return t.Length == 0 ? null : JsonNode.Parse(t);
    }

    private static string? Walk(string path, JsonNode? a, JsonNode? b)
    {
        if (a is null && b is null)
        {
            return null;
        }

        if (a is null || b is null)
        {
            return path + ": one side is empty (" + Describe(a) + " vs " + Describe(b) + ")";
        }

        if (a is JsonObject oa && b is JsonObject ob)
        {
            // Key ORDER IS NOT A DIFFERENCE, but it IS the right order to look
            // in. Walking the left side's own order - which PowerShell's
            // [ordered]@{} preserves and System.Text.Json preserves too - means
            // the first difference reported is the first one the author thought
            // mattered. Sorting alphabetically instead put `bodyLen` ahead of
            // `kinds` and reported a body-length difference on a row whose
            // block SEQUENCE was the actual problem.
            foreach (var kv in oa)
            {
                if (!ob.TryGetPropertyValue(kv.Key, out var bv))
                {
                    return path + "." + kv.Key + ": present in PowerShell, missing in C#";
                }

                var d = Walk(path + "." + kv.Key, kv.Value, bv);
                if (d is not null)
                {
                    return d;
                }
            }

            foreach (var kv in ob)
            {
                if (!oa.ContainsKey(kv.Key))
                {
                    return path + "." + kv.Key + ": present in C#, missing in PowerShell";
                }
            }

            return null;
        }

        if (a is JsonArray aa && b is JsonArray ba)
        {
            if (aa.Count != ba.Count)
            {
                return path + ": " + aa.Count.ToString(CultureInfo.InvariantCulture) + " item(s) in PowerShell, "
                     + ba.Count.ToString(CultureInfo.InvariantCulture) + " in C#";
            }

            for (var i = 0; i < aa.Count; i++)
            {
                var d = Walk(path + "[" + i.ToString(CultureInfo.InvariantCulture) + "]", aa[i], ba[i]);
                if (d is not null)
                {
                    return d;
                }
            }

            return null;
        }

        var sa = Scalar(a);
        var sb = Scalar(b);
        // 🪤 ORDINAL. A culture-sensitive compare is what made ("· x")
        // .StartsWith("⏵") return True and cost a day - see the ledger.
        return string.Equals(sa, sb, StringComparison.Ordinal)
            ? null
            : path + ": PowerShell " + Quote(sa) + ", C# " + Quote(sb);
    }

    private static string Describe(JsonNode? n) => n is null ? "nothing" : n.GetType().Name;

    private static string Quote(string s) =>
        s.Length > 160 ? "\"" + s[..160] + "\"... (" + s.Length.ToString(CultureInfo.InvariantCulture) + " chars)" : "\"" + s + "\"";

    /// <summary>
    /// One scalar as a canonical string, so 1 and 1.0 and "1" do not read as
    /// three different answers when only the serialiser differs.
    /// </summary>
    private static string Scalar(JsonNode n)
    {
        if (n is not JsonValue v)
        {
            return n.ToJsonString();
        }

        if (v.TryGetValue<bool>(out var bo))
        {
            return bo ? "true" : "false";
        }

        if (v.TryGetValue<decimal>(out var de))
        {
            return de.ToString("0.##########", CultureInfo.InvariantCulture);
        }

        if (v.TryGetValue<double>(out var d))
        {
            return d.ToString("0.##########", CultureInfo.InvariantCulture);
        }

        return v.TryGetValue<string>(out var s) ? s : v.ToJsonString();
    }
}
