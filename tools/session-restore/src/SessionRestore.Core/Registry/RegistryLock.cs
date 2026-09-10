namespace SessionRestore.Core.Registry;

/// <summary>
/// The cross-process lock around a read-modify-write of the registry.
/// </summary>
/// <remarks>
/// 🪤 THE REGISTRY IS READ-MODIFY-WRITTEN BY MORE THAN ONE PROCESS, and they
/// overlap routinely: the hourly scan task, a logon restore, and the panel -
/// which scans every time it opens. Without a lock the classic lost update
/// applies: the scan reads, the operator ticks something and saves, the scan
/// writes its copy back, and the tick is gone with nothing reported. 🔑 An atomic
/// replace does NOT help - it makes the last writer win cleanly rather than
/// making both survive.
///
/// 🔑 A NAMED MUTEX IS RE-ENTRANT FOR THE SAME THREAD, which is what lets a
/// whole read-modify-write hold it while the save takes it again inside.
/// <c>Local\</c> rather than <c>Global\</c>: this is per-user state, and Global
/// needs privileges.
/// </remarks>
public static class RegistryLock
{
    /// <summary>The same name the PowerShell uses, so the two lock each other out.</summary>
    /// <remarks>
    /// 🔴 IT MUST STAY IDENTICAL WHILE BOTH TOOLS EXIST. Two different names is
    /// two locks and no mutual exclusion at all - and during the cutover both
    /// will be running against one file.
    /// </remarks>
    public const string Name = @"Local\MMToolbox.SessionRestore.Registry";

    public const int DefaultTimeoutMs = 15000;

    /// <summary>
    /// Runs <paramref name="body"/> holding the lock.
    /// </summary>
    /// <remarks>
    /// 🔴 IT FAILS OPEN, DELIBERATELY. Fifteen seconds is far longer than any
    /// scan takes, so a timeout means something is wedged - and refusing at that
    /// point would lose the operator's work rather than protect it. The save's
    /// own stale check is what stops a genuine clobber; the lock is there to stop
    /// the ordinary overlap.
    /// </remarks>
    /// <param name="lockWasHeld">False when the lock could not be taken and the
    /// body ran unlocked - the caller says so rather than staying quiet.</param>
    public static T Run<T>(Func<T> body, out bool lockWasHeld, int timeoutMs = DefaultTimeoutMs)
    {
        ArgumentNullException.ThrowIfNull(body);

        using var mutex = new Mutex(false, Name);
        var held = false;
        try
        {
            try
            {
                held = mutex.WaitOne(timeoutMs);
            }
            catch (AbandonedMutexException)
            {
                // A previous holder died without releasing. We own it now, and
                // the file itself is fine because every write is an atomic
                // replace.
                held = true;
            }

            lockWasHeld = held;
            return body();
        }
        finally
        {
            if (held)
            {
                mutex.ReleaseMutex();
            }
        }
    }
}
