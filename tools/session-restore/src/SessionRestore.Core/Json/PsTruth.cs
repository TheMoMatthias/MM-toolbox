using System.Text.Json;

namespace SessionRestore.Core.Json;

/// <summary>
/// Whether PowerShell would treat a JSON value as true.
/// </summary>
/// <remarks>
/// 🔴 THIS IS NOT "IS IT THE BOOLEAN TRUE", AND THE DIFFERENCE IS A REAL
/// DEFECT THIS PORT SHIPPED. The shipped tool asks
/// <c>if ($b.input.run_in_background)</c>, and PowerShell's rule for a value
/// that came out of <c>ConvertFrom-Json</c> is its own: a NON-EMPTY STRING is
/// true, whatever it says. The transcript writes the flag both ways -
/// <c>"run_in_background": true</c> for a Bash and <c>"run_in_background":
/// "true"</c> for an Agent - so a C# test of <c>ValueKind == True</c> silently
/// dropped every background AGENT and kept every background shell.
///
/// 🪤 FOUND BY THE ORACLE, NOT BY READING. `subagents/live-tasks` reported
/// PowerShell 2, C# 1 on a conversation with one background shell and one
/// background agent, with the file's length pinned on both sides so growth
/// could not explain it (2026-09-14).
///
/// 🪤 AND "false" IS TRUE HERE. That reads like a bug and is not: it is what
/// the shipped tool does, every caller below is comparing against the shipped
/// tool, and a port that "fixed" it would differ from the window the operator
/// is actually looking at. If it is ever to change, it changes in the
/// PowerShell first.
/// </remarks>
public static class PsTruth
{
    /// <summary>Would <c>if ($value)</c> take the branch?</summary>
    public static bool Of(JsonElement v) => v.ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        JsonValueKind.Null => false,
        JsonValueKind.Undefined => false,

        // A non-empty string, whatever it says.
        JsonValueKind.String => (v.GetString() ?? string.Empty).Length > 0,

        // 🪤 TryGetDouble, not GetDouble: a number too large for a double is
        // still a number PowerShell would call true, and an exception here
        // would take out the whole transcript read.
        JsonValueKind.Number => !v.TryGetDouble(out var d) || d != 0,

        // 🔑 AN ARRAY IS ITS COUNT, AND ONE ELEMENT IS THAT ELEMENT. PowerShell
        // unrolls a single-element array before testing it, so @($false) is
        // FALSE while @($false, $false) is true. Nothing in the transcripts
        // relies on this; it is here so the rule has no gap to fall into.
        JsonValueKind.Array => v.GetArrayLength() switch
        {
            0 => false,
            1 => Of(v[0]),
            _ => true,
        },

        // Any object at all.
        _ => true,
    };

    /// <summary>Would <c>if ($o.name)</c> take the branch, when the property may be absent?</summary>
    public static bool Of(JsonElement owner, string name) =>
        owner.ValueKind == JsonValueKind.Object
        && owner.TryGetProperty(name, out var v)
        && Of(v);
}
