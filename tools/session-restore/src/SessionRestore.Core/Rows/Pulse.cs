namespace SessionRestore.Core.Rows;

/// <summary>
/// The breathing dot, as numbers.
/// </summary>
/// <remarks>
/// 🔑 THE PULSE IS IN ONE PLACE, AND THE SHIPPED WINDOW LEARNED THAT THE HARD
/// WAY. Two callers want the identical animation - the pane's state dot and the
/// live line in the document - and <c>Set-WorkingPulse</c> built it inline, so
/// "two copies of a 900 ms sine is how they drift apart". <c>New-SRPulse</c>
/// exists for that reason; this is its value half, so the numbers can be
/// compared without a window.
///
/// 🔴 AND THE PORT HAD TWO OF THEM WRONG. 4.2c wrote the dot straight into the
/// shell: 1.0 to 0.35, no easing. The shipped one is 1.0 to 0.25 with a SINE
/// ease in and out - and the difference is not decoration, it is the whole
/// point of the mark: *"a linear fade reads as a fault light, a sine one reads
/// as breathing."* A dot that reads as a fault light on every mid-turn
/// conversation is the opposite of what it is for.
/// </remarks>
public static class Pulse
{
    /// <summary>Full opacity, at the top of the breath.</summary>
    public const double From = 1.0;

    /// <summary>How far down it goes.</summary>
    public const double To = 0.25;

    /// <summary>One half-breath.</summary>
    public static readonly TimeSpan Duration = TimeSpan.FromMilliseconds(900);

    /// <summary>It breathes back up rather than snapping.</summary>
    public const bool AutoReverse = true;

    /// <summary>It never stops on its own - stopping it is a decision somebody makes.</summary>
    public const bool Forever = true;

    /// <summary>
    /// Eased in and out, not linear.
    /// </summary>
    /// <remarks>
    /// 🪤 THE EASING IS THE DIFFERENCE BETWEEN A SIGNAL AND AN ALARM. A linear
    /// fade spends equal time at every opacity, which the eye reads as a fault
    /// light blinking; a sine spends most of its time near the ends and moves
    /// quickly through the middle, which reads as breathing.
    /// </remarks>
    public const string Easing = "SineEase";

    /// <summary>In and out, not just one end.</summary>
    public const string EasingMode = "EaseInOut";
}
