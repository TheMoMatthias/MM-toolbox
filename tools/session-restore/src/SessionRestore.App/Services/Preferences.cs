namespace SessionRestore.App.Services;

/// <summary>Where a gesture's remembered setting goes - a fold, a zoom.</summary>
/// <remarks>
/// 🔴 THE SHIPPED WINDOW WRITES THE OPERATOR'S LIVE CONFIG FOR THESE. Folding a
/// column and stepping the zoom each call <c>Save-SRConfigLater</c>, which ends in
/// <c>session-restore.config.json</c> - the file this rebuild must never touch
/// before cutover. So remembering is a seam, and the only implementation in the
/// build is one that writes NOTHING and records what it was asked.
/// </remarks>
public interface IPreferences
{
    void Remember(string key, object value);
}

/// <summary>Remembers nothing; says what it was asked. The only preferences the rebuild has before cutover.</summary>
public sealed class NoPreferences : IPreferences
{
    public List<(string Key, object Value)> Asked { get; } = [];

    public void Remember(string key, object value) => Asked.Add((key, value));
}
