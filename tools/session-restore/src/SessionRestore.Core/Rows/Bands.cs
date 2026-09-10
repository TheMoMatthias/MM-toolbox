using SessionRestore.Core.Transcripts;

namespace SessionRestore.Core.Rows;

/// <summary>The four bands a conversation can be in. Plan item 2.6.</summary>
/// <remarks>
/// 🔴 GREY CARRIES STATE AND HUE CARRIES IDENTITY, and they never trade places.
/// These four names are the whole of what the window says about what is
/// happening: the ladder from white (needs you) down to the dimmest grey
/// (quiet). Getting one wrong does not look like a bug - it looks like the
/// operator's own board being wrong about his work.
/// </remarks>
public static class Bands
{
    public const string Needs = "needs";
    public const string Working = "working";
    public const string Open = "open";
    public const string Done = "done";
    public const string Idle = "idle";
    public const string Quiet = "quiet";

    /// <summary>
    /// How much a conversation has to have said before its silence counts as a
    /// hand-back rather than as a pause.
    /// </summary>
    public const int HandbackMinChars = 40;

    /// <summary>
    /// A conversation that is running and at its prompt: has it finished, or has
    /// it left something open?
    /// </summary>
    /// <remarks>
    /// 🪤 <c>Pending</c> EMPTY IS PART OF THE TEST. A session with a tool still
    /// pending is not resting, whatever its status says - it has said something
    /// and then gone back to work.
    /// </remarks>
    /// <param name="dismissedStamp">The <c>At</c> ticks of the message the
    /// operator waved off, if any. 🔑 DISMISSAL IS PER MESSAGE, NOT PER SESSION:
    /// the flag comes BACK the moment the conversation says anything new. A
    /// permanent dismissal would be a way to hide a session from yourself for
    /// good, which is not recoverable from the board.</param>
    public static string Resting(SaidResult? said, string? dismissedStamp = null)
    {
        if (said is null)
        {
            return Idle;
        }

        if (said.Pending.Trim().Length > 0 || said.Said.Trim().Length < HandbackMinChars)
        {
            return Idle;
        }

        if (OpenItems.Any(said.Full) && !Dismissed(said, dismissedStamp))
        {
            return Open;
        }

        return Done;
    }

    /// <summary>
    /// 🪤 NO STAMP MEANS IT CANNOT BE MATCHED, SO IT IS NOT DISMISSED. An
    /// unreadable stamp must never mean "unchanged" - that is the cheap-identity
    /// trap, and here it would hide a conversation that is asking for something.
    /// </summary>
    private static bool Dismissed(SaidResult said, string? dismissedStamp)
    {
        if (string.IsNullOrEmpty(dismissedStamp) || said.At is null)
        {
            return false;
        }

        return string.Equals(
            dismissedStamp,
            said.At.Value.LocalDateTime.Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture),
            StringComparison.Ordinal);
    }

    /// <summary>
    /// Which band this conversation belongs in.
    /// </summary>
    /// <remarks>
    /// 🔴 ANY LIVE BAND PROMOTES ON A SEEN MENU, NOT JUST 'working'. The one-way
    /// rule that used to hold here was containing a parser that could not tell
    /// prose from a menu; once the test became structural that weakness was gone,
    /// and the containment was costing ~26 s of notice on exactly the rows most
    /// likely to be asking for something.
    ///
    /// 🪤 'quiet' IS STILL EXCLUDED, and that exclusion is about a FACT rather
    /// than a policy. A conversation reaches quiet by being stuck, stale, or
    /// having no process at all - none of which has a screen a menu could have
    /// been seen on. A flag surviving on such a row is stale by definition, so it
    /// must not decide anything.
    /// </remarks>
    /// <param name="askSeen">Whether a menu was actually seen on this
    /// conversation's screen.</param>
    public static string Of(
        ConvState? conv,
        SaidResult? said,
        bool askSeen = false,
        string? dismissedStamp = null)
    {
        if (conv is null)
        {
            return Quiet;
        }

        if (conv.Stuck)
        {
            return Quiet;
        }

        if (conv.Needs)
        {
            return Needs;
        }

        if (conv.Stale)
        {
            return Quiet;
        }

        var band = conv.State switch
        {
            "working" => Working,
            "summarising" => Working,
            "waiting" => Needs,
            "idle" => Resting(said, dismissedStamp),
            _ => Quiet,
        };

        return !string.Equals(band, Quiet, StringComparison.Ordinal) && askSeen ? Needs : band;
    }
}

/// <summary>
/// The rail's age bands. A filter, never the grouping.
/// </summary>
/// <remarks>
/// 🔑 THE CUTS ARE TAKEN ONCE PER BUILD, NOT PER PROJECT. A pass that re-reads
/// the clock for every row compares each one against a slightly different "now",
/// which is not what any of these four words mean.
/// </remarks>
public sealed record RailCuts(long Today, long Week, long Month)
{
    public static RailCuts At(DateTime? now = null)
    {
        var midnight = (now ?? DateTime.Now).Date;
        return new RailCuts(midnight.Ticks, midnight.AddDays(-7).Ticks, midnight.AddDays(-30).Ticks);
    }

    public string KeyFor(long atTicks)
    {
        if (atTicks >= Today)
        {
            return "today";
        }

        if (atTicks >= Week)
        {
            return "week";
        }

        return atTicks >= Month ? "month" : "older";
    }
}
