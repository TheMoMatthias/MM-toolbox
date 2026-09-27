using System.Windows;

namespace SessionRestore.App.Services;

/// <summary>
/// Putting text on the clipboard.
/// </summary>
/// <remarks>
/// 🔴 A SEAM FOR A SMALL ACT, AND FOR A SHARP REASON: the clipboard is the
/// OPERATOR'S, not the program's. A check that drove a real selection and pressed
/// Ctrl+C would silently throw away whatever he had copied - on a machine running
/// thirty live conversations, while he is working. Behind an interface, the check
/// asserts the text that WOULD have been written and nothing leaves the process.
///
/// 🪤 AND THE REAL ONE CAN FAIL. Another process can hold the clipboard open, and
/// <c>Clipboard.SetText</c> throws <c>COMException</c> when it does. A copy that
/// took the window down would be a far worse bug than a copy that did not happen.
/// </remarks>
public interface IClip
{
    /// <summary>Put this on the clipboard. False means it did not go.</summary>
    bool Put(string text);
}

/// <summary>The real clipboard.</summary>
public sealed class RealClip : IClip
{
    public bool Put(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return false;
        }

        try
        {
            Clipboard.SetText(text);
            return true;
        }
#pragma warning disable CA1031 // a failed copy must not take the window with it
        catch (Exception)
#pragma warning restore CA1031
        {
            return false;
        }
    }
}

/// <summary>Writes nothing anywhere and remembers what it was handed. For checks.</summary>
public sealed class NoClip : IClip
{
    /// <summary>Everything that would have been copied, in order.</summary>
    public List<string> Wrote { get; } = [];

    /// <summary>The last thing that would have been copied.</summary>
    public string Last => Wrote.Count > 0 ? Wrote[^1] : string.Empty;

    public bool Put(string text)
    {
        Wrote.Add(text ?? string.Empty);
        return !string.IsNullOrEmpty(text);
    }
}
