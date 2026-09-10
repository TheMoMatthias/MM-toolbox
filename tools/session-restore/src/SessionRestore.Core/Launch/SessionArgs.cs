using System.Text.Json;
using SessionRestore.Core.Registry;

namespace SessionRestore.Core.Launch;

/// <summary>
/// A conversation's own settings - "the control plane" - as claude's argv.
/// </summary>
/// <remarks>
/// 🔴 EVERY ONE OF THESE IS A LAUNCH FLAG. claude reads them once, at startup;
/// there is no way to change the model, the permission mode or the tool limits
/// of a session that is already running. So changing one does nothing until the
/// conversation is relaunched, and the window has to say so rather than let the
/// operator believe a dropdown took effect.
///
/// 🪤 THE VALUES ARE VALIDATED HERE, NOT AT THE DROPDOWN. A value claude will
/// not accept does not fail politely - it fails the LAUNCH, and the conversation
/// simply never opens. An unrecognised effort or permission mode is therefore
/// dropped from the argv, while the label still shows it, so the operator can
/// see what is set and see that it is not being passed.
/// </remarks>
public static class SessionArgs
{
    /// <summary>What claude accepts, from <c>claude --help</c> on 2026-08-29.</summary>
    public static readonly string[] PermissionModes =
        ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"];

    /// <summary>What claude accepts, from <c>claude --help</c> on 2026-08-29.</summary>
    public static readonly string[] EffortLevels = ["low", "medium", "high", "xhigh", "max"];

    // 🪤 THE MEMBERSHIP TEST IS CASE-INSENSITIVE AND THE VALUE IS PASSED THROUGH
    // AS TYPED, because PowerShell's `-contains` is case-insensitive and that is
    // what ships. So "High" clears the guard and reaches claude as "High", which
    // makes the guard narrower than it reads - the accepted values are lowercase.
    // It is not reachable from the settings sheet, which only ever writes an
    // exact value, so matching it is parity rather than a defect left in place:
    // an Ordinal test here would have been a behaviour change smuggled into a
    // port. Found by the shapes case, which exists because not one conversation
    // in the live registry sets a pref at all.

    /// <summary>
    /// One setting off a session's <c>prefs</c>, or null.
    /// </summary>
    /// <remarks>
    /// 🪤 <c>prefs</c> IS ADDITIVE AND OFTEN ABSENT. A session written before the
    /// control plane existed simply has none, and an older build ignores a key it
    /// does not know - so every read here has to survive a missing object as
    /// "unset" rather than as an error.
    /// </remarks>
    public static JsonElement? Pref(RegistrySession? session, string name)
    {
        if (session?.Extra is null || !session.Extra.TryGetValue("prefs", out var prefs))
        {
            return null;
        }

        if (prefs.ValueKind != JsonValueKind.Object || !prefs.TryGetProperty(name, out var v))
        {
            return null;
        }

        return v.ValueKind == JsonValueKind.Null ? null : v;
    }

    /// <summary>
    /// Remote Control is ON unless a conversation says otherwise - that is what
    /// every session on this machine has done since the tool shipped, and a
    /// settings feature must not quietly switch it off for all of them.
    /// </summary>
    public static bool RemoteWanted(RegistrySession? session)
    {
        var v = Pref(session, "remoteControl");
        return v is null || Truthy(v.Value);
    }

    public static bool HiddenWanted(RegistrySession? session)
    {
        var v = Pref(session, "hidden");
        return v is not null && Truthy(v.Value);
    }

    /// <summary>The flags this conversation adds to <c>claude</c>.</summary>
    /// <remarks>
    /// 🪤 AN EMPTY RESULT IS AN EMPTY LIST, NOT A LIST HOLDING NOTHING. The
    /// PowerShell hit the ",@()" trap backwards here: <c>return ,$arr</c> exists
    /// to stop a multi-element array being unrolled, but on an EMPTY one it emits
    /// a one-element array holding the empty array - so a conversation with no
    /// settings reported a count of 1 and the first real flag landed at index 1.
    /// </remarks>
    public static string[] For(RegistrySession? session)
    {
        var a = new List<string>();

        var m = Text(Pref(session, "model"));
        if (m.Length > 0)
        {
            a.Add("--model");
            a.Add(m);
        }

        var e = Text(Pref(session, "effort"));
        if (e.Length > 0 && EffortLevels.Contains(e, StringComparer.OrdinalIgnoreCase))
        {
            a.Add("--effort");
            a.Add(e);
        }

        var pm = Text(Pref(session, "permissionMode"));
        if (pm.Length > 0 && PermissionModes.Contains(pm, StringComparer.OrdinalIgnoreCase))
        {
            a.Add("--permission-mode");
            a.Add(pm);
        }

        foreach (var t in Many(Pref(session, "allowedTools")))
        {
            a.Add("--allowedTools");
            a.Add(t);
        }

        foreach (var t in Many(Pref(session, "disallowedTools")))
        {
            a.Add("--disallowedTools");
            a.Add(t);
        }

        return [.. a];
    }

    /// <summary>
    /// A one-line summary for the row, so the settings are visible without
    /// opening anything. Empty when a conversation is on all the defaults.
    /// </summary>
    /// <remarks>
    /// 🪤 THE LABEL SHOWS WHAT IS SET; <see cref="For"/> SHOWS WHAT IS PASSED, and
    /// they deliberately differ. An effort claude would reject appears here and
    /// not in the argv - which is the only way the operator can tell a setting is
    /// present but inert.
    /// </remarks>
    public static string Label(RegistrySession? session)
    {
        var bits = new List<string>();

        var m = Text(Pref(session, "model"));
        if (m.Length > 0)
        {
            bits.Add(m);
        }

        var e = Text(Pref(session, "effort"));
        if (e.Length > 0)
        {
            bits.Add(e);
        }

        var pm = Text(Pref(session, "permissionMode"));
        if (pm.Length > 0)
        {
            bits.Add(pm);
        }

        if (!RemoteWanted(session))
        {
            bits.Add("no remote");
        }

        if (HiddenWanted(session))
        {
            bits.Add("hidden");
        }

        var n = Many(Pref(session, "allowedTools")).Count + Many(Pref(session, "disallowedTools")).Count;
        if (n > 0)
        {
            bits.Add(n.ToString(System.Globalization.CultureInfo.InvariantCulture) + " tool rule(s)");
        }

        return string.Join("  ·  ", bits);
    }

    /// <summary>
    /// PowerShell's <c>"$x".Trim()</c>: a number or a bool stringifies, and a
    /// missing value becomes the empty string rather than throwing.
    /// </summary>
    private static string Text(JsonElement? v) => v is null
        ? string.Empty
        : (v.Value.ValueKind switch
        {
            JsonValueKind.String => v.Value.GetString() ?? string.Empty,
            JsonValueKind.True => "True",
            JsonValueKind.False => "False",
            _ => v.Value.ToString(),
        }).Trim();

    /// <summary>
    /// A tool-rule list. 🪤 It is a LIST OR A SINGLE VALUE: PowerShell's
    /// <c>@(...)</c> wraps a bare string into one element, so a pref saved as a
    /// single rule has to read as a one-item list here too - not as six
    /// characters.
    /// </summary>
    private static List<string> Many(JsonElement? v)
    {
        var outp = new List<string>();
        if (v is null)
        {
            return outp;
        }

        if (v.Value.ValueKind == JsonValueKind.Array)
        {
            foreach (var x in v.Value.EnumerateArray())
            {
                var s = Text(x);
                if (s.Length > 0)
                {
                    outp.Add(s);
                }
            }

            return outp;
        }

        var one = Text(v.Value);
        if (one.Length > 0)
        {
            outp.Add(one);
        }

        return outp;
    }

    private static bool Truthy(JsonElement v) => v.ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        JsonValueKind.Null => false,
        JsonValueKind.Number => v.TryGetDouble(out var d) && d != 0,
        JsonValueKind.String => (v.GetString() ?? string.Empty).Length > 0,
        _ => true,
    };
}
