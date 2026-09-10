using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace SessionRestore.Core.Registry;

/// <summary>What a save did, or did not do.</summary>
public sealed record SaveResult(SaveDecision Decision, string Stamp, bool LockWasHeld, string? Error)
{
    /// <summary>The bytes reached the file.</summary>
    public bool Written => Decision.Allowed && Error is null;
}

/// <summary>
/// Writes the registry. Plan item 2.7, and last on purpose.
/// </summary>
/// <remarks>
/// 🔴 THIS IS THE ONLY CLASS IN THE REBUILD THAT CAN LOSE THE OPERATOR'S WORK.
/// A registry-overwrite bug in this repo's history cost 210 conversations. Three
/// things stand between this and a repeat, and all three are structural rather
/// than remembered:
///
/// 1. <see cref="RegistryTarget"/> - the live file cannot be NAMED. There is no
///    factory for it.
/// 2. <see cref="SaveDecision"/> - the stale check is a value, enumerable and
///    compared against the PowerShell over every shape, refusals included.
/// 3. Write-beside-then-replace, with the failure REPORTED. A half-written
///    registry would lose every selection.
///
/// 🪤 AND THE THIRD ONE HAS ALREADY GONE WRONG ONCE IN THE POWERSHELL.
/// <c>Set-Content</c> and <c>Move-Item</c> report a blocked file as a
/// NON-TERMINATING error, so a registry another process held open was never
/// written, the function returned normally, and the caller then re-stamped
/// against the OLD file - leaving its staleness check agreeing with a save that
/// never happened. The operator's ticks were gone with nothing said. In C# an
/// IOException is not ignorable, but the equivalent mistake is available:
/// swallowing it and returning the new stamp anyway. Hence
/// <see cref="SaveResult.Written"/>, which is false when an error was recorded,
/// and a stamp that is NOT refreshed on a failed write.
/// </remarks>
public static class RegistryWriter
{
    /// <summary>
    /// How the registry is serialised.
    /// </summary>
    /// <remarks>
    /// 🪤 NOT BYTE-IDENTICAL TO POWERSHELL'S <c>ConvertTo-Json</c>, AND CHASING
    /// THAT WOULD BE THE WRONG GOAL. Indentation, escaping and number formatting
    /// differ between the two serialisers and none of it is data - what has to
    /// survive a write is every FIELD of every conversation, including the ones
    /// this build does not model. That is what the round-trip comparison checks,
    /// and it is the property a data-loss bug would actually break.
    ///
    /// 🔴 UnsafeRelaxedJsonEscaping IS NOT COSMETIC HERE. The default encoder
    /// escapes non-ASCII to \uXXXX, so a project path or a conversation title
    /// with an umlaut in it would come back correct but change every byte of its
    /// row on the first write - turning one save into a whole-file rewrite and
    /// making any diff useless.
    ///
    /// 🪤 <c>Depth 8</c> IN THE POWERSHELL IS A CEILING THAT SILENTLY TRUNCATES.
    /// System.Text.Json throws instead, which is the better failure - but it
    /// means a registry the PowerShell would have quietly flattened is refused
    /// here rather than written wrong.
    /// </remarks>
    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.Never,
    };

    /// <summary>
    /// The bytes that would be written.
    /// </summary>
    /// <remarks>
    /// 🔑 A BOM AND A TRAILING NEWLINE, because that is what the file on disk
    /// has - measured, <c>sessions-registry.json</c> starts EF BB BF - and the
    /// stamp is a hash of the bytes. A writer that dropped the BOM would make
    /// every other reader's stamp disagree.
    /// </remarks>
    public static byte[] Bytes(SessionRegistry registry)
    {
        ArgumentNullException.ThrowIfNull(registry);
        var json = JsonSerializer.Serialize(registry, WriteOptions);
        return [.. Encoding.UTF8.GetPreamble(), .. new UTF8Encoding(false).GetBytes(json + "\r\n")];
    }

    /// <summary>
    /// Saves the registry, if the guard allows it.
    /// </summary>
    /// <param name="readStamp">What the caller saw when it read the file. Pass
    /// null only when it genuinely never read one.</param>
    /// <param name="stampNow">Injected for the tests that have to produce a
    /// "somebody else saved" without a second process. 🪤 It is taken INSIDE the
    /// lock either way, so nobody can slip a write between the check and the
    /// replace.</param>
    public static SaveResult Save(
        SessionRegistry registry,
        RegistryTarget target,
        string? readStamp,
        bool force = false,
        Func<string, string>? stampNow = null,
        DateTimeOffset? now = null)
    {
        ArgumentNullException.ThrowIfNull(registry);
        ArgumentNullException.ThrowIfNull(target);

        // 🪤 THE REAL `held` IS CARRIED OUT, NOT ASSUMED. The first version of
        // this returned `... with { LockWasHeld = true }`, which threw away the
        // out value and reported a lock that may never have been taken - the same
        // class of dishonesty as re-stamping after a failed write.
        var result = RegistryLock.Run(
            () =>
            {
                var current = (stampNow ?? RegistryStamp.Of)(target.Path);
                var decision = SaveDecision.For(readStamp, current, File.Exists(target.Path), force);
                if (!decision.Allowed)
                {
                    // 🔴 THE STAMP HANDED BACK IS THE ONE THAT WAS READ, not a
                    // fresh one. A refusal must leave the caller's staleness
                    // check exactly as it was, or the next save would think it
                    // was up to date with a file it never saw.
                    return new SaveResult(decision, readStamp ?? string.Empty, false, null);
                }

                registry.LastScan = now ?? DateTimeOffset.Now;

                // Write beside the target then replace: a half-written registry
                // would lose every selection.
                var tmp = target.Path + ".tmp";
                try
                {
                    File.WriteAllBytes(tmp, Bytes(registry));
                    File.Move(tmp, target.Path, overwrite: true);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
                {
                    Cleanup(tmp);
                    return new SaveResult(
                        decision,
                        readStamp ?? string.Empty,
                        false,
                        "the registry could not be saved (" + target.Path + "): " + ex.Message
                        + ". Nothing was written, so your ticks are still here - close whatever is "
                        + "holding the file and save again.");
                }

                // What we just wrote is now what this session has seen.
                return new SaveResult(decision, RegistryStamp.Of(target.Path), false, null);
            },
            out var held);

        return result with { LockWasHeld = held };

        static void Cleanup(string tmp)
        {
            // 🪤 A LEAKED .tmp BESIDE THE REGISTRY IS NOT HARMLESS - the next
            // write targets the same name, and a stale one that cannot be
            // overwritten fails every save from then on.
            try
            {
                if (File.Exists(tmp))
                {
                    File.Delete(tmp);
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
