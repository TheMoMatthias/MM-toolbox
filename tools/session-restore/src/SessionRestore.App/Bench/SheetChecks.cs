using SessionRestore.App.Services;
using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using SessionRestore.App.Views;
using SessionRestore.Core.Acting;

namespace SessionRestore.App.Bench;

/// <summary>
/// The confirmation sheet, answered through its real buttons and its real keys.
/// </summary>
/// <remarks>
/// 🔴 THE SHEET IS THE FIRST OF THE TWO PRECONDITIONS IN FRONT OF ANYTHING THAT
/// CAN ACT, so what has to be proven is not that it draws - it is that the
/// ANSWER is the one the operator gave. A sheet that returned the primary
/// whatever was pressed would look identical on screen and would silently turn
/// every Cancel into a relaunch.
///
/// 🪤 IT BLOCKS, SO THE ANSWER HAS TO BE POSTED BEFORE THE QUESTION IS ASKED.
/// <c>Show</c> parks the caller on a nested dispatcher frame; the press is
/// queued on that same dispatcher first and runs while the frame is pumping.
/// A check that pressed the button after calling Show would hang the run, which
/// is a distinct and much louder failure than a wrong answer.
/// </remarks>
public static class SheetChecks
{
    public static IReadOnlyList<HandlerChecks.Check> Run(SessionsWindow w, Sheet sheet)
    {
        ArgumentNullException.ThrowIfNull(w);
        ArgumentNullException.ThrowIfNull(sheet);
        var checks = new List<HandlerChecks.Check>();

        // ---- the layout: filled from the right, the primary last -----------
        var seen = Answer(w, sheet, () => Press(w, w.SheetB3), s =>
            s.Show("Relaunch this conversation", "It is running.", [("no", "Cancel"), ("yes", "Relaunch")], "no"));

        checks.Add(new HandlerChecks.Check(
            "two choices fill from the right - Cancel on B2, the verb on B3, B1 not shown",
            seen.B1 == Visibility.Collapsed
                && seen.B2 == Visibility.Visible && Equals(seen.B2Text, "Cancel")
                && seen.B3 == Visibility.Visible && Equals(seen.B3Text, "Relaunch"),
            string.Format(CultureInfo.InvariantCulture, "B1 {0}, B2 '{1}', B3 '{2}'", seen.B1, seen.B2Text, seen.B3Text)));

        checks.Add(new HandlerChecks.Check(
            "pressing the primary answers with the primary's key",
            string.Equals(seen.Pick, "yes", StringComparison.Ordinal),
            "answered '" + seen.Pick + "'"));

        checks.Add(new HandlerChecks.Check(
            "the scrim is up while the question is up, and gone once it is answered",
            seen.ScrimWhileUp == Visibility.Visible
                && w.Scrim.Visibility == Visibility.Collapsed
                && w.Sheet.Visibility == Visibility.Collapsed,
            string.Format(CultureInfo.InvariantCulture, "while up {0}, after {1}", seen.ScrimWhileUp, w.Scrim.Visibility)));

        checks.Add(new HandlerChecks.Check(
            "the primary has the keyboard when the question appears",
            seen.FocusedB3,
            seen.FocusedB3 ? "B3 focused" : "focus was elsewhere"));

        // ---- Cancel ---------------------------------------------------------
        var cancelled = Answer(w, sheet, () => Press(w, w.SheetB2), s =>
            s.Show("Relaunch this conversation", "It is running.", [("no", "Cancel"), ("yes", "Relaunch")], "no"));
        checks.Add(new HandlerChecks.Check(
            "pressing Cancel answers with Cancel's key, not the primary's",
            string.Equals(cancelled.Pick, "no", StringComparison.Ordinal),
            "answered '" + cancelled.Pick + "'"));

        // ---- Esc means the safe way out, whatever it is ---------------------
        var escaped = Answer(w, sheet, () => Key(w, System.Windows.Input.Key.Escape), s =>
            s.Show("The registry changed while you were working", "Something else wrote it.",
                   [("keep", "Leave it for now"), ("force", "Save mine anyway")], "keep"));
        checks.Add(new HandlerChecks.Check(
            "Escape answers with what the caller nominated, which is never the destructive choice",
            string.Equals(escaped.Pick, "keep", StringComparison.Ordinal),
            "answered '" + escaped.Pick + "'"));

        // ---- Enter takes the primary ----------------------------------------
        var entered = Answer(w, sheet, () => Key(w, System.Windows.Input.Key.Enter), s =>
            s.Show("Relaunch this conversation", "It is running.", [("no", "Cancel"), ("yes", "Relaunch")], "no"));
        checks.Add(new HandlerChecks.Check(
            "Enter presses the primary",
            string.Equals(entered.Pick, "yes", StringComparison.Ordinal),
            "answered '" + entered.Pick + "'"));

        // ---- one choice still lands on B3 -----------------------------------
        var notice = Answer(w, sheet, () => Press(w, w.SheetB3), s =>
        {
            s.Notice("That did not work", "The console refused it.");
            return "ok";
        });
        checks.Add(new HandlerChecks.Check(
            "a one-button notice puts its button on B3 and leaves B1 and B2 down",
            notice.B3 == Visibility.Visible && Equals(notice.B3Text, "Close")
                && notice.B2 == Visibility.Collapsed && notice.B1 == Visibility.Collapsed,
            string.Format(CultureInfo.InvariantCulture, "B3 '{0}', B2 {1}, B1 {2}", notice.B3Text, notice.B2, notice.B1)));

        // ---- Confirm-Action, through the interface the handlers hold ---------
        var asked = sheet.Asked;
        var yes = Answer(w, sheet, () => Press(w, w.SheetB3), s =>
            ((IConfirms)s).Ask(new Confirm("Relaunch this conversation", "It is running.", "Relaunch"))
                ? "true" : "false");
        var no = Answer(w, sheet, () => Press(w, w.SheetB2), s =>
            ((IConfirms)s).Ask(new Confirm("Relaunch this conversation", "It is running.", "Relaunch"))
                ? "true" : "false");
        checks.Add(new HandlerChecks.Check(
            "Ask returns true only for the verb, and the verb is what the caller named",
            string.Equals(yes.Pick, "true", StringComparison.Ordinal)
                && string.Equals(no.Pick, "false", StringComparison.Ordinal)
                && Equals(yes.B3Text, "Relaunch"),
            string.Format(CultureInfo.InvariantCulture, "verb '{0}', yes {1}, cancel {2}", yes.B3Text, yes.Pick, no.Pick)));

        checks.Add(new HandlerChecks.Check(
            "every question put reached the operator - none was answered without being shown",
            sheet.Asked == asked + 2,
            string.Format(CultureInfo.InvariantCulture, "{0} question(s) put", sheet.Asked - asked)));

        // ---- too many choices is a mistake, not a truncation -----------------
        var threw = false;
        try
        {
            sheet.Show("x", "y", [("a", "A"), ("b", "B"), ("c", "C"), ("d", "D")], "a");
        }
        catch (ArgumentOutOfRangeException)
        {
            threw = true;
        }

        checks.Add(new HandlerChecks.Check(
            "a fourth choice is refused rather than quietly dropped",
            threw && w.Scrim.Visibility == Visibility.Collapsed,
            threw ? "refused, and nothing was left on screen" : "it took four choices"));

        // ---- a sheet under a sheet ------------------------------------------
        // 🔴 THE SCRIM GOES ONLY AT DEPTH ZERO. The registry's stale-write
        // question comes up while a relaunch confirmation is open; hiding the
        // scrim when the INNER one closes leaves the outer question floating
        // over a window that still refuses input.
        //
        // 🪤 AND WHAT IS RESTORED IS THE FRAME AND THE ESCAPE KEY, NOT THE
        // BUTTONS. The first version of this check pressed B3 after the inner
        // sheet had closed and expected the OUTER's answer - and got the inner's
        // key, because a closing sheet does not put the outer one's labels back.
        // That is the shipped behaviour, character for character: Show-Sheet
        // saves $sheetFrame and $sheetEscape and nothing else. The check was
        // wrong, not the port - so what is asserted is the thing that IS
        // restored, which is the outer's own safe way out.
        Visibility scrimAfterInner = Visibility.Visible;
        var outer = Answer(w, sheet, () =>
        {
            // Inside the outer sheet: raise a second one, answer it, then leave
            // by the outer's Escape.
            w.Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
            {
                var inner = Answer(w, sheet, () => Press(w, w.SheetB3), s =>
                    s.Show("inner", "the second question", [("ok", "Close")], "ok"));
                scrimAfterInner = w.Scrim.Visibility;
                _ = inner;
                Key(w, System.Windows.Input.Key.Escape);
            });
        }, s => s.Show("outer", "the first question", [("leave", "Leave it"), ("go", "Go on")], "leave"));

        checks.Add(new HandlerChecks.Check(
            "a question raised under a question leaves the scrim up, and gives the outer one its own Escape back",
            scrimAfterInner == Visibility.Visible
                && w.Scrim.Visibility == Visibility.Collapsed
                && string.Equals(outer.Pick, "leave", StringComparison.Ordinal),
            string.Format(CultureInfo.InvariantCulture,
                "after the inner one {0}, after the outer one {1}, outer answered '{2}'",
                scrimAfterInner, w.Scrim.Visibility, outer.Pick)));

        return checks;
    }

    private sealed record Seen(
        string Pick,
        Visibility B1, Visibility B2, Visibility B3,
        object? B2Text, object? B3Text,
        Visibility ScrimWhileUp,
        bool FocusedB3);

    /// <summary>
    /// Queue the answer, then ask the question, and record what was on screen
    /// while it was up.
    /// </summary>
    private static Seen Answer(SessionsWindow w, Sheet sheet, Action press, Func<Sheet, string> ask)
    {
        Visibility b1 = Visibility.Collapsed, b2 = Visibility.Collapsed, b3 = Visibility.Collapsed;
        Visibility scrim = Visibility.Collapsed;
        object? b2t = null, b3t = null;
        var focused = false;

        // Priority matters: this has to run while the nested frame is pumping,
        // which it does at anything the frame will dispatch.
        w.Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            b1 = w.SheetB1.Visibility;
            b2 = w.SheetB2.Visibility;
            b3 = w.SheetB3.Visibility;
            b2t = w.SheetB2.Content;
            b3t = w.SheetB3.Content;
            scrim = w.Scrim.Visibility;
            focused = w.SheetB3.IsFocused || w.SheetB3.IsKeyboardFocusWithin;
            press();
        });

        var pick = ask(sheet);
        return new Seen(pick, b1, b2, b3, b2t, b3t, scrim, focused);
    }

    private static void Press(SessionsWindow w, System.Windows.Controls.Button b)
    {
        _ = w;
        b.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
    }

    /// <summary>
    /// 🪤 THE KEY GOES TO THE WINDOW'S PREVIEW, WHICH IS WHERE THE SHEET LISTENS.
    /// A window that has never been shown has no PresentationSource and a
    /// KeyEventArgs cannot even be constructed against it - this one is shown,
    /// off-screen, so the real tunnelling event can be raised.
    /// </summary>
    private static void Key(SessionsWindow w, Key key)
    {
        var src = PresentationSource.FromVisual(w);
        if (src is null)
        {
            return;
        }

        w.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, src, 0, key)
        {
            RoutedEvent = UIElement.PreviewKeyDownEvent,
        });
    }
}
