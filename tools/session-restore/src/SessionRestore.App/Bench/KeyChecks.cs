using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using SessionRestore.App.Views;

namespace SessionRestore.App.Bench;

/// <summary>
/// Plan item 4.3 - real keys, into a real window, through the real tunnel.
/// </summary>
/// <remarks>
/// 🔴 THE SHIPPED SUITE COULD NOT DO THIS, which is why the decision was split
/// into functions over there: a window that has never been SHOWN has no
/// PresentationSource, and a <see cref="KeyEventArgs"/> cannot even be
/// constructed against one. The rebuild's checking window is shown at -32000,
/// so the tunnelling event itself can be raised - and the defect that cost the
/// operator rewind was a TUNNEL ORDER defect, which is exactly what a value
/// comparison alone cannot see.
///
/// 🔑 SO BOTH HALVES ARE CHECKED, DIFFERENTLY. `keys/route` compares the
/// ORDER against the shipped handler over twenty-seven states; these press the
/// keys and look at what the window did.
/// </remarks>
public static class KeyChecks
{
    public static IReadOnlyList<HandlerChecks.Check> Run(SessionsWindow w, WindowShell shell)
    {
        ArgumentNullException.ThrowIfNull(w);
        ArgumentNullException.ThrowIfNull(shell);
        var checks = new List<HandlerChecks.Check>();

        // ---- the bare slash takes the keyboard to the search box ------------
        w.SessionList.Focus();
        Pump(w);
        var slash = Press(w, Key.Oem2);
        Pump(w);
        checks.Add(new HandlerChecks.Check(
            "a bare slash puts the keyboard in the search box",
            slash && w.Search.IsKeyboardFocusWithin,
            string.Format(CultureInfo.InvariantCulture, "handled {0}, search focused {1}", slash, w.Search.IsKeyboardFocusWithin)));

        // ---- Escape in a search box with text empties it --------------------
        w.Search.Text = "algo";
        w.Search.Focus();
        Pump(w);
        var cleared = Press(w, Key.Escape);
        Pump(w);
        checks.Add(new HandlerChecks.Check(
            "Escape empties a search box that has something in it, and leaves the keyboard there",
            cleared && w.Search.Text.Length == 0,
            string.Format(CultureInfo.InvariantCulture, "handled {0}, text '{1}'", cleared, w.Search.Text)));

        // ---- and takes the keyboard out of an empty one ---------------------
        w.Search.Focus();
        Pump(w);
        var left = Press(w, Key.Escape);
        Pump(w);
        checks.Add(new HandlerChecks.Check(
            "and takes the keyboard out of an empty one, to the conversation list",
            left && w.SessionList.IsKeyboardFocusWithin,
            string.Format(CultureInfo.InvariantCulture, "handled {0}, list focused {1}", left, w.SessionList.IsKeyboardFocusWithin)));

        // ---- a bare letter typed into a box stays a letter -------------------
        //
        // 🪤 THE DEFECT THIS IS FOR: `hello` typed into the broadcast box
        // arrived as `heo`, because `l` was a bare shortcut and PreviewKeyDown
        // tunnels - the window's handler ran before the box ever saw the key.
        w.RailSearch.Text = string.Empty;
        w.RailSearch.Focus();
        Pump(w);
        var ell = Press(w, Key.L);
        var slashInBox = Press(w, Key.Oem2);
        Pump(w);
        checks.Add(new HandlerChecks.Check(
            "a bare l and a bare slash typed into a box are NOT taken as shortcuts",
            !ell && !slashInBox && w.RailSearch.IsKeyboardFocusWithin,
            string.Format(CultureInfo.InvariantCulture, "l handled {0}, slash handled {1}, still in the box {2}",
                ell, slashInBox, w.RailSearch.IsKeyboardFocusWithin)));

        // ---- Ctrl+1 and Ctrl+2 work FROM INSIDE a box ------------------------
        var railBefore = w.RailPane.Visibility;
        var ctrl1 = PressWithCtrl(w, Key.D1);
        Pump(w);
        checks.Add(new HandlerChecks.Check(
            "Ctrl+1 folds the rail even with the keyboard in a text box",
            ctrl1 && w.RailPane.Visibility != railBefore,
            string.Format(CultureInfo.InvariantCulture, "handled {0}, rail {1} -> {2}", ctrl1, railBefore, w.RailPane.Visibility)));

        PressWithCtrl(w, Key.D1);
        Pump(w);

        // ---- THE WATCHER ---------------------------------------------------
        //
        // 🔴 4.3'S DONE-WHEN. Escape, `/` and `l` must reach the terminal
        // watcher. The watcher itself is not ported, so what is set up here is
        // the STATE it puts the window in - it holds the keyboard and the
        // conversation it shows is streaming - and what is asserted is that the
        // window does not take the keys.
        w.SessionList.Focus();
        Pump(w);
        shell.TermShowing = "abc";
        shell.TermStreaming = new Dictionary<string, bool>(StringComparer.Ordinal) { ["abc"] = true };
        // 🪤 A COLLAPSED ELEMENT CANNOT TAKE THE KEYBOARD. LivePane starts
        // Collapsed - it is shown only while a terminal is being watched - and
        // Focus() on it simply returns false, so the first version of this check
        // pressed keys with the focus still on the list and reported the window
        // eating them. Which is what a real defect would look like too.
        var paneWas = w.LivePane.Visibility;
        w.LivePane.Visibility = Visibility.Visible;
        w.LivePane.Focusable = true;
        Pump(w);
        w.LivePane.Focus();
        Pump(w);

        var focused = w.LivePane.IsKeyboardFocusWithin;
        var esc = Press(w, Key.Escape);
        var sl = Press(w, Key.Oem2);
        var l2 = Press(w, Key.L);
        Pump(w);

        checks.Add(new HandlerChecks.Check(
            "Escape, slash and l all reach the terminal watcher instead of being eaten",
            focused && !esc && !sl && !l2,
            string.Format(CultureInfo.InvariantCulture,
                "watcher focused {0}; escape handled {1}, slash {2}, l {3}", focused, esc, sl, l2)));

        // 🪤 AND THE KEYBOARD MUST STILL BE THERE. The original defect was not
        // only that Escape was swallowed - it also threw the focus out of the
        // pane, which is why the SECOND Escape of the rewind gesture went to the
        // conversation list. A check that only counted "handled" would have
        // missed half of it.
        checks.Add(new HandlerChecks.Check(
            "and the watcher still has the keyboard afterwards - the second Escape of a rewind goes there too",
            w.LivePane.IsKeyboardFocusWithin,
            "watcher focused " + w.LivePane.IsKeyboardFocusWithin.ToString(CultureInfo.InvariantCulture)));

        // ---- but a sheet in front of it still gets Escape --------------------
        var sheetSaw = false;
        shell.SheetUp = () => true;
        var overSheet = Press(w, Key.Escape);
        shell.SheetUp = () => false;
        sheetSaw = !overSheet;
        Pump(w);
        checks.Add(new HandlerChecks.Check(
            "a sheet in front of the watcher takes Escape back",
            sheetSaw,
            "the window stood down: " + sheetSaw.ToString(CultureInfo.InvariantCulture)));

        shell.TermShowing = string.Empty;
        shell.TermStreaming = null;
        w.LivePane.Focusable = false;
        w.LivePane.Visibility = paneWas;
        w.SessionList.Focus();
        Pump(w);

        // ---- and with nothing streaming, the shortcuts come back -------------
        //
        // 🔒 IT IS DELIBERATELY NOT "the pane is visible". The pane shows the
        // transcript too, where `/` and `l` must still be shortcuts. What
        // suspends them is the conversation being STREAMED and the pane holding
        // the keyboard.
        var backAgain = Press(w, Key.Oem2);
        Pump(w);
        checks.Add(new HandlerChecks.Check(
            "with nothing streaming into it, the bare shortcuts work again",
            backAgain && w.Search.IsKeyboardFocusWithin,
            string.Format(CultureInfo.InvariantCulture, "handled {0}, search focused {1}", backAgain, w.Search.IsKeyboardFocusWithin)));

        w.Search.Text = string.Empty;
        w.SessionList.Focus();
        Pump(w);

        // ---- a shortcut whose act is not ported must NOT eat the key --------
        //
        // 🔴 REPORTING A KEY AS HANDLED WHEN NOTHING HAPPENED IS HOW A SHORTCUT
        // BECOMES A HOLE: the key is gone and the window did nothing with it.
        // Five of the fourteen acts belong to panels this port has not reached -
        // the spawn panel, the settings and project panels, the manager's
        // ticking and folding, and the reading pane's tail budget - so they are
        // decided and then declined, rather than decided and swallowed.
        //
        // 🪤 THIS CHECK IS A STATEMENT OF WHAT IS NOT WIRED YET, and it is
        // MEANT to fail when the reading pane arrives. At that point `l` starts
        // being handled and this line says so out loud instead of the change
        // going unnoticed.
        var bareL = Press(w, Key.L);
        var bareSpace = Press(w, Key.Space);
        Pump(w);
        checks.Add(new HandlerChecks.Check(
            "a shortcut whose act is not ported yet declines the key rather than swallowing it",
            !bareL && !bareSpace,
            string.Format(CultureInfo.InvariantCulture, "l handled {0}, space handled {1} (both are unported acts today)",
                bareL, bareSpace)));

        return checks;
    }

    /// <summary>
    /// 🪤 PreviewKeyDown IS A REAL TUNNELLING EVENT AND NEEDS A REAL SOURCE.
    /// Raised on the focused element it runs the window's handler first, which
    /// is the whole order under test.
    /// </summary>
    private static bool Press(SessionsWindow w, Key key)
    {
        var src = PresentationSource.FromVisual(w);
        if (src is null)
        {
            return false;
        }

        var target = Keyboard.FocusedElement as IInputElement ?? w;
        var e = new KeyEventArgs(Keyboard.PrimaryDevice, src, 0, key)
        {
            RoutedEvent = UIElement.PreviewKeyDownEvent,
        };
        target.RaiseEvent(e);
        return e.Handled;
    }

    /// <summary>
    /// 🔴 THE MODIFIER CANNOT BE FAKED, so the chord is put to the routing
    /// directly and the ACT is carried out through the window. What the real
    /// press proves is the tunnel; what this proves is that Ctrl+1 reaches the
    /// fold even from inside a text box, which is the rule that sits above the
    /// typing guard.
    /// </summary>
    private static bool PressWithCtrl(SessionsWindow w, Key key)
    {
        var pressed = key == Key.D1 ? Core.Keys.PressedKey.Digit1 : Core.Keys.PressedKey.Digit2;
        var r = Core.Keys.KeyRoute.Of(pressed, ctrl: true, typing: true, searchWithText: false,
                                      configOpen: false, projectOpen: false, termTyping: false, manageSurface: false);
        if (r.Act == Core.Keys.KeyAct.FoldRail)
        {
            (w.RailPane.Visibility == Visibility.Visible ? w.RailFold : w.RailOpen)
                .RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, 0, MouseButton.Left)
                { RoutedEvent = UIElement.MouseLeftButtonUpEvent });
        }

        return r.Handled;
    }

    private static void Pump(Window w) =>
        w.Dispatcher.Invoke(static () => { }, System.Windows.Threading.DispatcherPriority.ContextIdle);
}
