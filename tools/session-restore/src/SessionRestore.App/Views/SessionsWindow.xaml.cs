using System.Windows;

namespace SessionRestore.App.Views;

/// <summary>
/// The window, ported from <c>lib/window2.xaml</c>. Plan item 4.1.
/// </summary>
/// <remarks>
/// 🔴 THE MARKUP IS THE SHIPPED FILE WITH ONE ATTRIBUTE ADDED - <c>x:Class</c> -
/// and nothing else, at the first commit of 4.1. Every style in it was tuned
/// against rendered pixels, so the port starts byte-for-byte and diverges only
/// where a binding replaces an imperative update, one named change at a time.
///
/// 🪤 NO HANDLERS YET, ON PURPOSE. Plan item 4.2 wires the 77 of them; until
/// then this window cannot launch, type into, end or save anything, because the
/// code that would is not attached to any control.
/// </remarks>
public partial class SessionsWindow : Window
{
    public SessionsWindow()
    {
        InitializeComponent();
        Faces = Typefaces.Install(this);
    }

    /// <summary>What the typeface install managed, for the surface check to report.</summary>
    public Typefaces.Installed Faces { get; }
}
