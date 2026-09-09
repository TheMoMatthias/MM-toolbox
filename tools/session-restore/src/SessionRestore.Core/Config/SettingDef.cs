namespace SessionRestore.Core.Config;

/// <summary>What shape a setting's value has.</summary>
/// <remarks>
/// 🔑 THE CATALOGUE DECIDES THIS, NOT THE VALUE'S TYPE. The PowerShell's
/// Get-SRCfgKind carries the same rule and says why: transcriptTools is a string
/// and a string is a text box - but it takes one of three words, and a text box
/// over a fixed set is how "grayscal" gets into a config file.
/// </remarks>
public enum SettingKind
{
    /// <summary>Free text.</summary>
    Text,

    /// <summary>On or off.</summary>
    Toggle,

    /// <summary>A whole number, usually bounded by <see cref="SettingDef.Min"/>/<see cref="SettingDef.Max"/>.</summary>
    Number,

    /// <summary>Exactly one of <see cref="SettingDef.Options"/>.</summary>
    Choice,

    /// <summary>Any number of <see cref="SettingDef.Options"/>, stored comma-joined.</summary>
    Flags,

    /// <summary>An ordered list of strings.</summary>
    List,

    /// <summary>A pattern-keyed map of numbers (autoTickLaneBudgets).</summary>
    Map,
}

/// <summary>
/// One setting: its key in the file, how it is offered, and the single default
/// the tool uses when the operator has not set it.
/// </summary>
/// <remarks>
/// 🔴 THE KEY IS A CONTRACT WITH A FILE THAT ALREADY EXISTS. The operator's
/// session-restore.config.json is live and hand-edited; renaming a key here
/// silently reverts whatever he had set to its default.
/// </remarks>
public sealed record SettingDef(
    string Key,
    string Group,
    string Label,
    string Help,
    SettingKind Kind,
    object? Default,
    int? Min,
    int? Max,
    IReadOnlyList<string>? Options)
{
    /// <summary>Is <paramref name="value"/> something this setting will accept?</summary>
    /// <remarks>
    /// 🪤 A REJECTED VALUE IS NOT AN ERROR, IT IS THE DEFAULT. The config is
    /// hand-edited, so an out-of-range number or a misspelled choice is an
    /// ordinary Tuesday - and a tool that refuses to start because one setting
    /// is wrong is worse than one that ignores it and says so.
    /// </remarks>
    public bool Accepts(object? value)
    {
        switch (Kind)
        {
            case SettingKind.Toggle:
                return value is bool;

            case SettingKind.Number:
                if (value is not int n)
                {
                    return false;
                }

                return (Min is null || n >= Min) && (Max is null || n <= Max);

            // 🔴 NO DECLARED OPTIONS MEANS "NOTHING TO CHECK AGAINST", NEVER
            // "NOTHING IS ALLOWED". This read the other way first and it turned
            // a gap in the catalogue into a silent reset of a real setting: the
            // generator was reading choice lists from `Options` only, so
            // railBandsShut arrived with none, every value was rejected, and the
            // operator's own "month,older" came back as the default. The oracle
            // caught it on its first real comparison against his file.
            //
            // An empty catalogue entry is a defect in THIS code, and the safe
            // behaviour when this code is wrong is to keep what the operator
            // wrote. The strictness lives in a test instead - every Choice and
            // Flags setting must declare its options - so the gap is loud at
            // build time rather than silent at his desk.
            case SettingKind.Choice:
                return value is string s
                    && (Options is null || Options.Contains(s, StringComparer.Ordinal));

            case SettingKind.Flags:
                if (value is not string f)
                {
                    return false;
                }

                if (f.Length == 0 || Options is null)
                {
                    return true;
                }

                // Comma-joined rather than an array, and the PowerShell records
                // why: a one-element JSON array comes back UNROLLED to its
                // element, so one flag would read as a bare string while two
                // read as an array. Splitting a string has one shape.
                foreach (var part in f.Split(','))
                {
                    var t = part.Trim();
                    if (t.Length > 0 && !Options.Contains(t, StringComparer.Ordinal))
                    {
                        return false;
                    }
                }

                return true;

            case SettingKind.Text:
                return value is string;

            case SettingKind.List:
            case SettingKind.Map:
                return value is not null;

            default:
                return false;
        }
    }
}
