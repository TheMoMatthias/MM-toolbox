namespace SessionRestore.Core.Sessions;

/// <summary>
/// Which conversations have been SEEN with a menu on their screen.
/// </summary>
/// <remarks>
/// 🔴 A MENU SEEN ON SCREEN IS AN INPUT TO THE BAND, NOT A CORRECTION AFTER IT.
/// This is what made a conversation flip between NEEDS YOU and WORKING every few
/// seconds: the quiet check read a screen, saw a menu, and wrote the band
/// directly - but the band is DERIVED, and every recompute called the band rule
/// again and overwrote it with whatever the agent probe thought. The probe says
/// "working" for a session sitting on a menu, so the two took turns. Neither was
/// wrong; the screen's answer simply had nowhere durable to live.
///
/// 🔑 SO IT LIVES HERE, KEYED BY SESSION, AND THE BAND RULE CONSULTS IT. A
/// recompute is then idempotent - it reads the same evidence and reaches the
/// same band.
///
/// 🔴 AND IT IS CLEARED ONLY BY EVIDENCE, NEVER BY A RECOMPUTE: the transcript
/// growing (that session is working again) or a later screen read finding no
/// menu. A recompute that cleared it would be the original defect with an extra
/// step.
/// </remarks>
public sealed class AskSeenSet
{
    private readonly HashSet<string> _seen = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>How many conversations are flagged.</summary>
    public int Count => _seen.Count;

    /// <summary>Whether this conversation has a menu on its screen, as far as anything has seen.</summary>
    public bool this[string? id] => !string.IsNullOrEmpty(id) && _seen.Contains(id);

    /// <summary>
    /// Records what a screen read found.
    /// </summary>
    /// <remarks>
    /// 🔑 IT RETURNS WHETHER ANYTHING CHANGED, and that is the whole reason it
    /// is a function rather than two lines at the call site: the caller rebands
    /// only when the answer moved. A poll that rebanded on every tick would put
    /// the model pass on a 400 ms cadence by accident.
    ///
    /// 🪤 AN EMPTY ID CHANGES NOTHING AND IS NOT AN ERROR. The shipped line
    /// returns false for it rather than throwing, because the callers are polls
    /// over whatever the probe last reported.
    /// </remarks>
    /// <returns>True when the flag moved.</returns>
    public bool Set(string? id, bool asking)
    {
        if (string.IsNullOrEmpty(id))
        {
            return false;
        }

        var was = _seen.Contains(id);
        if (was == asking)
        {
            return false;
        }

        if (asking)
        {
            _seen.Add(id);
        }
        else
        {
            _seen.Remove(id);
        }

        return true;
    }

    /// <summary>The ids currently flagged, for a check to look at.</summary>
    public IReadOnlyCollection<string> Ids => _seen;
}
