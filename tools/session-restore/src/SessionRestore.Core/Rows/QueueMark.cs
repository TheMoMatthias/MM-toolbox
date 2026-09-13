using System.Globalization;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.Core.Rows;

/// <summary>The » mark on a session row: what is waiting behind its turn.</summary>
/// <param name="Visible">Whether the row draws it at all.</param>
/// <param name="Text">The count beside the glyph.</param>
/// <param name="Tip">The tooltip.</param>
/// <param name="Mine">Amber when true - your own words are waiting; grey when it is only machine traffic.</param>
public sealed record QueueMark(bool Visible, string Text, string Tip, bool Mine)
{
    public static QueueMark Off { get; } = new(false, string.Empty, string.Empty, false);

    /// <summary>
    /// The mark for one conversation's queue. Ported from the inline block in
    /// <c>Build-Sessions</c> that runs per row.
    /// </summary>
    /// <remarks>
    /// 🔴 THE COUNT IS YOURS WHEN YOU HAVE ANY, and only falls back to the total
    /// when you have none. Measured: of everything queued across 432 transcripts,
    /// 1,356 were cross-session messages and 1,107 task notifications against 144
    /// lines a person typed - a mark lit for all of it would mean nothing.
    ///
    /// 🪤 THE OLDEST OF YOURS IS NAMED IN THE TIP, and how long it has waited is
    /// the whole question - so it is the FIRST item that is yours, in queue order.
    /// </remarks>
    /// <param name="now">One clock for the pass, in local time.</param>
    public static QueueMark Of(QueueState? rec, DateTime now)
    {
        if (rec is null || rec.Count <= 0
            || !Waiting.Fresh(rec, now, Waiting.StaleHours, Waiting.MachineStaleMinutes))
        {
            return Off;
        }

        var inv = CultureInfo.InvariantCulture;
        if (rec.Mine <= 0)
        {
            return new QueueMark(
                true,
                rec.Count.ToString(inv),
                string.Format(inv, "{0} queued, none of them yours - cross-session messages and task notifications", rec.Count),
                false);
        }

        var tip = string.Format(inv, "{0} message(s) of yours waiting to be read", rec.Mine);
        if (rec.Machine > 0)
        {
            tip += string.Format(inv, ", behind {0} from the machine", rec.Machine);
        }

        foreach (var qi in rec.Items)
        {
            if (!qi.Mine)
            {
                continue;
            }

            tip += qi.At is { } at
                ? "\nwaiting " + Titles.AgeOf(at.Ticks, now.Ticks) + ": " + qi.First
                : "\n" + qi.First;
            break;
        }

        return new QueueMark(true, rec.Mine.ToString(inv), tip, true);
    }
}
