using System.Globalization;
using System.Text.Json.Nodes;
using SessionRestore.Core.Rows;

namespace SessionRestore.Oracle.Cases;

/// <summary>
/// Plan item 4.5 - the one animation this window has, compared as numbers.
/// </summary>
/// <remarks>
/// 🔴 THIS CASE EXISTS BECAUSE THE PORT WAS WRONG AND NOTHING SAID SO. 4.2c
/// wrote the breathing dot straight into the shell - 1.0 to 0.35, no easing -
/// against a shipped animation that goes to 0.25 on a sine in and out. Every
/// check passed: the dot animated when a conversation was mid-turn and stopped
/// when it was not, which is what they asked. None of them asked what it
/// LOOKED like, and the shipped source says exactly why that matters: *"a
/// linear fade reads as a fault light, a sine one reads as breathing."*
///
/// 🔑 SO THE ANIMATION IS EVALUATED AND READ FIELD BY FIELD. <c>New-SRPulse</c>
/// builds a real <c>DoubleAnimation</c> and returns it; there is nothing to
/// stub, because building one draws nothing.
///
/// 🪤 AND THE EASING IS COMPARED BY TYPE NAME AND MODE, not by sampling the
/// curve. A port that used a different easing family with the same endpoints
/// would sample identically at 0 and 1 and differently everywhere a person
/// looks.
/// </remarks>
public static class AnimCases
{
    public static IEnumerable<(OracleCase Case, bool ExpectAgree, string Meaning)> All()
    {
        yield return (Breath(), true, "the breathing dot's endpoints, duration, repeat and easing");
    }

    private static OracleCase Breath() => new(
        "anim/pulse",
        "New-SRPulse, field by field",
        """
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName PresentationFramework
        $winSrc = [System.IO.File]::ReadAllText((Join-Path $SR_Root 'lib\sessions-window.ps1'))
        $a = $winSrc.IndexOf('function New-SRPulse')
        if ($a -lt 0) { throw 'could not find New-SRPulse' }
        Invoke-Expression $winSrc.Substring($a, $winSrc.IndexOf("`n}", $a) - $a + 2)

        # 🔴 THE REAL OBJECT, READ BACK. Building a DoubleAnimation draws
        # nothing and starts nothing - it is a description until something
        # hands it to a property.
        $p = New-SRPulse
        $ease = $p.EasingFunction
        (@{
            from        = [double]$p.From
            to          = [double]$p.To
            ms          = [double]$p.Duration.TimeSpan.TotalMilliseconds
            autoReverse = [bool]$p.AutoReverse
            forever     = [bool]($p.RepeatBehavior -eq [System.Windows.Media.Animation.RepeatBehavior]::Forever)
            easing      = $(if ($ease) { $ease.GetType().Name } else { '' })
            easingMode  = $(if ($ease) { "$($ease.EasingMode)" } else { '' })
        } | ConvertTo-Json -Compress)
        """,
        _ => new JsonObject
        {
            ["from"] = Pulse.From,
            ["to"] = Pulse.To,
            ["ms"] = Pulse.Duration.TotalMilliseconds,
            ["autoReverse"] = Pulse.AutoReverse,
            ["forever"] = Pulse.Forever,
            ["easing"] = Pulse.Easing,
            ["easingMode"] = Pulse.EasingMode,
        }.ToJsonString());

    public static string Coverage() => string.Format(CultureInfo.InvariantCulture,
        "the pulse: {0} to {1} over {2} ms, {3} {4}",
        Pulse.From, Pulse.To, Pulse.Duration.TotalMilliseconds, Pulse.Easing, Pulse.EasingMode);
}
