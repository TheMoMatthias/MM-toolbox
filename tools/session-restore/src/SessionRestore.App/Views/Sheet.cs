using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using SessionRestore.App.Services;
using SessionRestore.Core.Acting;

namespace SessionRestore.App.Views;

/// <summary>
/// The window asking, in its own voice - and the first of the two things that
/// were blocking an implementation able to act.
/// </summary>
/// <remarks>
/// 🔴 THE RELAUNCH HANDLER HAS BEEN ASKING <see cref="NoConfirms"/>, WHICH
/// ANSWERS YES. That was fine while the act behind it did nothing; wired in
/// front of anything real it would close conversations without asking anybody,
/// and the operator has about thirty he cannot relaunch. So the sheet is ported
/// BEFORE the implementation, not with it.
///
/// 🔴 IT BLOCKS, AND IT HAS TO. Seven callers in the shipped window are written
/// as <c>if (Confirm-Action ...) { do it }</c> - a non-blocking sheet returns
/// before the operator has answered and every one of them reads the answer as
/// "no". Blocking without freezing is what a nested <see cref="DispatcherFrame"/>
/// is for: the dispatcher keeps pumping, so the sheet paints and its buttons
/// respond, while the CALLER stays parked on its own line. It is the mechanism
/// MessageBox itself uses, which is why swapping one for the other needs no
/// change at any call site.
///
/// 🪤 AND IT IS NOT A MESSAGEBOX. Every question used to be one: a grey system
/// dialog with a shield icon and Segoe UI, in front of a window that shares none
/// of that, and the one surface that could not be restyled - so it grew more
/// conspicuous the better the rest of the window got, at exactly the moments
/// that matter most.
///
/// 🔑 THE NESTING COUNTER IS NOT BOOKKEEPING. A sheet can be raised from under
/// a sheet (the registry's stale-write question comes up while a relaunch
/// confirmation is open), and hiding the scrim when the INNER one closes would
/// leave the outer question floating over a live window that still refuses to
/// take input. The scrim goes only at depth zero.
/// </remarks>
public sealed class Sheet : IConfirms
{
    private readonly SessionsWindow _w;
    private DispatcherFrame? _frame;
    private string _pick = string.Empty;
    private string _escape = string.Empty;
    private int _depth;

    public Sheet(SessionsWindow window)
    {
        _w = window ?? throw new ArgumentNullException(nameof(window));

        foreach (var b in new[] { _w.SheetB1, _w.SheetB2, _w.SheetB3 })
        {
            b.Click += (s, _) =>
            {
                _pick = (s as Button)?.Tag as string ?? string.Empty;
                if (_frame is not null)
                {
                    _frame.Continue = false;
                }
            };
        }

        // Preview, so the sheet gets the key before the list below it does - the
        // transcript and the session list both bind arrows and Enter.
        _w.PreviewKeyDown += (_, e) =>
        {
            if (_frame is null)
            {
                return;
            }

            if (e.Key == Key.Escape)
            {
                // Esc answers with whatever the caller nominated as the safe way
                // out. Never the destructive choice.
                _pick = _escape;
                _frame.Continue = false;
                e.Handled = true;
            }
            else if (e.Key == Key.Enter)
            {
                _pick = _w.SheetB3.Tag as string ?? string.Empty;
                _frame.Continue = false;
                e.Handled = true;
            }
        };
    }

    /// <summary>
    /// 🔴 READ BY EVERY TIMER TICK. A sheet names the exact conversations an
    /// action will touch, and the caller is holding the row objects behind those
    /// names - so letting the model pass run under an open sheet would hand the
    /// caller a list of ORPHANS the moment the operator pressed the button.
    /// Everything that mutates the model stands still while this is up.
    /// </summary>
    public bool IsUp => _depth > 0;

    /// <summary>How many questions this sheet has put, for the checks to count.</summary>
    public int Asked { get; private set; }

    /// <summary>
    /// Put a question with one to three answers and do not return until it has
    /// been answered.
    /// </summary>
    /// <param name="title">The question.</param>
    /// <param name="body">What pressing it will do, naming what it touches.</param>
    /// <param name="choices">
    /// Ordered left to right. The LAST one is the primary: it lands on the
    /// button carrying the primary style, is focused, and is what Enter presses.
    /// </param>
    /// <param name="escape">What Esc means. Never the destructive choice.</param>
    public string Show(string title, string body, IReadOnlyList<(string Key, string Label)> choices, string escape)
    {
        ArgumentNullException.ThrowIfNull(choices);
        if (choices.Count is < 1 or > 3)
        {
            throw new ArgumentOutOfRangeException(
                nameof(choices), choices.Count, "a sheet takes one to three choices");
        }

        _w.SheetTitle.Text = title;
        _w.SheetBody.Text = body;

        // Filled from the RIGHT, so the primary always lands on B3 whether there
        // are one, two or three of them and the row stays right-aligned either
        // way.
        var slots = new[] { _w.SheetB3, _w.SheetB2, _w.SheetB1 };
        foreach (var b in slots)
        {
            b.Visibility = Visibility.Collapsed;
            b.Tag = null;
        }

        for (var i = 0; i < choices.Count; i++)
        {
            var c = choices[choices.Count - 1 - i];
            slots[i].Content = c.Label;
            slots[i].Tag = c.Key;
            slots[i].Visibility = Visibility.Visible;
        }

        var prevFrame = _frame;
        var prevEscape = _escape;
        _pick = escape;
        _escape = escape;
        _w.Scrim.Visibility = Visibility.Visible;
        _w.Sheet.Visibility = Visibility.Visible;
        _depth++;
        Asked++;
        _w.SheetB3.Focus();

        var frame = new DispatcherFrame();
        _frame = frame;
        var pick = escape;
        try
        {
            Dispatcher.PushFrame(frame);
            pick = _pick;
        }
        finally
        {
            _frame = prevFrame;
            _escape = prevEscape;
            _depth--;
            if (_depth <= 0)
            {
                _depth = 0;
                _w.Scrim.Visibility = Visibility.Collapsed;
                _w.Sheet.Visibility = Visibility.Collapsed;
            }
        }

        return pick;
    }

    /// <summary>
    /// <c>Confirm-Action</c>: cancel on the left, the named verb on the right,
    /// and Esc means cancel.
    /// </summary>
    /// <remarks>
    /// 🪤 THE VERB IS NOT DECORATION. "OK" beside a list of twelve live
    /// conversations does not say what pressing it does, and these confirmations
    /// exist precisely because the action is hard to take back. Every caller
    /// names it, and <see cref="Confirm"/> carries it as a field rather than
    /// leaving it to the handler to remember.
    /// </remarks>
    public bool Ask(Confirm confirm) =>
        string.Equals(
            Show(confirm.Title, confirm.Body, [("no", "Cancel"), ("yes", confirm.Verb)], "no"),
            "yes",
            StringComparison.Ordinal);

    /// <summary>One button, nothing to decide: something went wrong and you are being told.</summary>
    public void Notice(string title, string body) => Show(title, body, [("ok", "Close")], "ok");

    /// <summary>
    /// 🪤 THE ANSWER THE SHEET IS CLOSED WITH WHEN THE WINDOW IS GOING AWAY. A
    /// pumped frame left running keeps the process alive after the window
    /// closes, so shutdown has to say so - and it says the SAFE answer, which is
    /// whatever the caller nominated for Esc.
    /// </summary>
    public void Dismiss()
    {
        if (_frame is null)
        {
            return;
        }

        _pick = _escape;
        _frame.Continue = false;
    }
}
