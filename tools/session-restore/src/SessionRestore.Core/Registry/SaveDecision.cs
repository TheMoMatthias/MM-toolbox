namespace SessionRestore.Core.Registry;

/// <summary>Whether a save may go ahead, and why not.</summary>
public enum SaveVerdict
{
    Allow,

    /// <summary>
    /// The file is on disk but could not be read to check whether it changed.
    /// 🔴 A CHECK THAT CANNOT TELL MUST NOT PERMIT.
    /// </summary>
    RefuseUnreadable,

    /// <summary>Something has the file open, so the comparison could not be made.</summary>
    RefuseHeld,

    /// <summary>Somebody else saved since this session read it.</summary>
    RefuseChanged,
}

/// <summary>
/// The registry save guard, as a value. Plan item 2.7.
/// </summary>
/// <remarks>
/// 🔴 A REGISTRY-OVERWRITE BUG IN THIS REPO'S HISTORY COST 210 CONVERSATIONS.
/// That is why this is a TYPE and not an <c>if</c> inside the writer: the
/// decision can be enumerated, compared against the PowerShell over every shape,
/// and proven to refuse - without a single byte being written anywhere. A guard
/// nobody has seen refuse is not known to be there at all.
///
/// 🪤 AND THE THREE REFUSALS ARE NOT ONE REFUSAL. They are told apart because
/// the operator can act on each differently: a held file means try again in a
/// moment, a changed file means press Rescan first, and an unreadable file means
/// something is wrong that retrying may not fix. Collapsing them into "could not
/// save" is what makes people force it.
/// </remarks>
public sealed record SaveDecision(SaveVerdict Verdict, string Why)
{
    public bool Allowed => Verdict == SaveVerdict.Allow;

    private static readonly SaveDecision Yes = new(SaveVerdict.Allow, string.Empty);

    /// <summary>
    /// May this save proceed?
    /// </summary>
    /// <param name="readStamp">What this session saw when it read the file. Null
    /// or empty means it never read one - so there is nothing to be stale
    /// against, and the save goes ahead.</param>
    /// <param name="nowStamp">What <see cref="RegistryStamp.Of"/> says right
    /// now, taken INSIDE the lock so nobody can slip a write between the check
    /// and the replace.</param>
    /// <param name="fileExists">Whether the file is on disk at all. 🔴 ASKED
    /// SEPARATELY rather than inferred from an empty stamp: empty is also what a
    /// failed read returns, and having a stamp at all means this session read a
    /// registry - so failing to stamp one now is not evidence that nothing
    /// changed, it is evidence that the question could not be answered.</param>
    /// <param name="force">The caller has already told the operator and been told
    /// to go ahead.</param>
    public static SaveDecision For(string? readStamp, string nowStamp, bool fileExists, bool force = false)
    {
        ArgumentNullException.ThrowIfNull(nowStamp);

        if (force || string.IsNullOrEmpty(readStamp))
        {
            return Yes;
        }

        if (nowStamp.Length == 0)
        {
            return fileExists
                ? new SaveDecision(SaveVerdict.RefuseUnreadable,
                    "the registry is on disk but could not be read to check whether it changed, " +
                    "so this save was refused rather than risk overwriting another window's ticks. " +
                    "Try again in a moment.")
                : Yes;
        }

        if (string.Equals(nowStamp, RegistryStamp.Unhashed, StringComparison.Ordinal))
        {
            return new SaveDecision(SaveVerdict.RefuseHeld,
                "the registry could not be read to check whether it changed - something else has it " +
                "open. This save was refused rather than risk overwriting another window's ticks. " +
                "Try again in a moment.");
        }

        if (!string.Equals(nowStamp, readStamp, StringComparison.Ordinal))
        {
            return new SaveDecision(SaveVerdict.RefuseChanged,
                "the registry changed on disk since this window read it - another Sessions window " +
                "(or a scan) has saved. Saving now would discard those changes. Close the other " +
                "window, or press Rescan to pick them up, then save again.");
        }

        return Yes;
    }
}
