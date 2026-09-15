namespace SessionRestore.Core.Keys;

/// <summary>What the window does with one key press, before anything else sees it.</summary>
public enum KeyAct
{
    /// <summary>Nothing. The key carries on down the tunnel, unhandled.</summary>
    PassOn,

    /// <summary>Open the panel that starts a new conversation. Ctrl+N.</summary>
    Spawn,

    /// <summary>Fold or unfold the projects rail. Ctrl+1.</summary>
    FoldRail,

    /// <summary>Fold or unfold the sessions column. Ctrl+2.</summary>
    FoldList,

    /// <summary>Put the settings panel away, discarding what was typed.</summary>
    CloseConfig,

    /// <summary>Put the project panel away. It applies as you press, so there is nothing to discard.</summary>
    CloseProject,

    /// <summary>Empty the search box that has the keyboard.</summary>
    ClearSearch,

    /// <summary>Take the keyboard out of wherever it is and give it to the conversation list.</summary>
    FocusList,

    /// <summary>Give the keyboard to the header's search box. The bare slash.</summary>
    FocusSearch,

    /// <summary>Tick or untick the selected row. Space, on the manage surface.</summary>
    ToggleTick,

    /// <summary>Show or hide the older conversations. O, on the manage surface.</summary>
    ToggleOlder,

    /// <summary>Fold a project in the manager. Left.</summary>
    FoldProject,

    /// <summary>Unfold a project in the manager. Right.</summary>
    UnfoldProject,

    /// <summary>Take the tail budget off and draw the whole conversation. L.</summary>
    LoadWhole,
}

/// <summary>
/// One key press, and what the window is about to do with it.
/// </summary>
/// <param name="Act">What happens.</param>
/// <param name="Handled">
/// Whether the window stops the key here. 🔴 <see cref="KeyAct.PassOn"/> is
/// ALWAYS unhandled, and that is the whole of the fix below - the key has to
/// carry on down the tunnel to whatever is holding the keyboard.
/// </param>
public readonly record struct KeyRouting(KeyAct Act, bool Handled);

/// <summary>
/// Which key the window is being given, in the names its own handler uses.
/// </summary>
/// <remarks>
/// 🪤 <c>Oem2</c> IS THE SLASH and <c>D1</c> IS THE DIGIT ONE. The shipped
/// handler tests WPF's own key names, so the port keeps them rather than
/// inventing readable ones that would have to be mapped somewhere.
/// </remarks>
public enum PressedKey
{
    Other,
    Escape,
    Slash,
    Space,
    KeyL,
    KeyN,
    KeyO,
    Digit1,
    Digit2,
    Left,
    Right,
}

/// <summary>
/// The window's own keyboard rules - what it takes, and what it lets past.
/// </summary>
/// <remarks>
/// 🔴 THIS EXISTS BECAUSE THE ORDER WAS WRONG AND COST THE OPERATOR REWIND.
/// Reported as "the escape button is not working, and the rewind is also not
/// working" - one cause, and the second is a consequence of the first.
/// <c>PreviewKeyDown</c> TUNNELS, root to leaf, so the window's handler runs
/// BEFORE the one on the terminal watcher. With the watcher focused, Escape hit
/// the window's own rule, was swallowed, AND threw the focus out of the pane -
/// so Escape never reached the session, and because focus had left, the SECOND
/// Escape of the rewind gesture went to the conversation list too. Neither
/// could ever work.
///
/// 🪤 AND IT WAS NEVER ONLY ESCAPE. <c>/</c> and <c>l</c> are bare shortcuts on
/// the work surface, so typing <c>/compact</c> into a watched terminal sent
/// <c>compact</c> and <c>hello</c> sent <c>heo</c> - each swallowed <c>l</c>
/// also doubling the transcript tail budget and rebuilding the reading pane.
///
/// 🔑 SO THE RULE IS A VALUE, AND THE ORDER IS THE VALUE'S OWN. The shipped
/// window extracted two halves of it into functions for exactly this reason -
/// a headless suite cannot raise a key into a window that has never been shown,
/// because there is no PresentationSource and a KeyEventArgs cannot even be
/// constructed. The rebuild's window IS shown, off the desktop, so the checks
/// raise real keys as well - but the ORDER is compared against the shipped
/// source as a value, over states a real window would take a long time to reach.
/// </remarks>
public static class KeyRoute
{
    /// <summary>
    /// Is the keyboard somewhere that a bare letter means a letter?
    /// </summary>
    /// <remarks>
    /// 🔒 IT IS DELIBERATELY NOT "the pane is visible". The pane is visible
    /// while it shows the transcript too, where <c>/</c> and <c>l</c> must still
    /// be shortcuts. What suspends them is the conversation in it being STREAMED
    /// and the pane holding the keyboard - the same two facts the header uses to
    /// promise where the keys are going, so the promise and the behaviour cannot
    /// drift apart.
    /// </remarks>
    /// <param name="focused">The watcher has the keyboard.</param>
    /// <param name="shown">Which conversation it is showing. Empty means none.</param>
    /// <param name="streaming">
    /// Which conversations are being streamed into a terminal. Null is "nothing
    /// is", which is not the same as an empty set and is tested separately by
    /// the shipped line.
    /// </param>
    public static bool TermTyping(bool focused, string? shown, IReadOnlyDictionary<string, bool>? streaming)
    {
        if (!focused)
        {
            return false;
        }

        if (string.IsNullOrEmpty(shown))
        {
            return false;
        }

        if (streaming is null)
        {
            return false;
        }

        return streaming.TryGetValue(shown, out var on) && on;
    }

    /// <summary>
    /// What the window does with this key.
    /// </summary>
    /// <param name="key">Which key.</param>
    /// <param name="ctrl">Whether Control is down.</param>
    /// <param name="typing">
    /// The keyboard is in a text field. 🪤 ASK THE ELEMENT WHAT IT IS, NEVER
    /// LIST THE BOXES - a list was correct when the window had two text boxes
    /// and silently wrong for every one added since, and seven boxes were having
    /// their keystrokes eaten.
    /// </param>
    /// <param name="searchWithText">
    /// A search box has the keyboard AND has something in it. The one shortcut a
    /// text field does want.
    /// </param>
    /// <param name="configOpen">The settings panel is up.</param>
    /// <param name="projectOpen">The project panel is up.</param>
    /// <param name="termTyping">The watcher has the keyboard and its conversation is streaming.</param>
    /// <param name="manageSurface">The manage surface is the one being shown.</param>
    /// <param name="projectRowSelected">
    /// A PROJECT row is what is selected in the manager.
    /// 🪤 THE ARROW KEYS ONLY FOLD WHEN ONE IS. The shipped branch checks the
    /// selected item's kind INSIDE the manage-surface block and falls through
    /// when it is not a project - so Left on a conversation row is not handled
    /// here and carries on, and Right is not either. A port that folded
    /// unconditionally would swallow both arrows for the list underneath.
    /// </param>
    public static KeyRouting Of(
        PressedKey key,
        bool ctrl,
        bool typing,
        bool searchWithText,
        bool configOpen,
        bool projectOpen,
        bool termTyping,
        bool manageSurface,
        bool projectRowSelected = false)
    {
        // 🔴 CTRL+N IS CHECKED BEFORE THE TYPING GUARD: a new conversation is
        // worth starting even when the cursor happens to be in the search box,
        // and no text field wants Ctrl+N for itself.
        if (ctrl && key == PressedKey.KeyN)
        {
            return new(KeyAct.Spawn, true);
        }

        // Ctrl+1 / Ctrl+2 for the same reason, and the moment you most want the
        // pane wider is usually while you are reading something in it.
        if (ctrl && key == PressedKey.Digit1)
        {
            return new(KeyAct.FoldRail, true);
        }

        if (ctrl && key == PressedKey.Digit2)
        {
            return new(KeyAct.FoldList, true);
        }

        // 🔑 AHEAD OF THE TYPING GUARD, because the settings panel is mostly
        // text boxes. Behind it, an Escape pressed in one of them would fall
        // through to the search-box rule, empty a box somewhere behind the
        // panel, and leave the panel open - the opposite of what Escape means
        // on a dialog.
        if (key == PressedKey.Escape && configOpen)
        {
            return new(KeyAct.CloseConfig, true);
        }

        if (key == PressedKey.Escape && projectOpen)
        {
            return new(KeyAct.CloseProject, true);
        }

        // 🔴 EVERY REMAINING SHORTCUT STANDS DOWN FOR THE WATCHER, and returning
        // UNHANDLED is the whole point: the key carries on down the tunnel to
        // the watcher's own handler, which owns the closed forwarded set.
        // Handling it here would be the same bug in the other direction.
        //
        // 🪤 BELOW THE TWO PANEL ESCAPES, ABOVE EVERYTHING ELSE. A settings
        // panel in front of the watcher must still close on Escape - it cannot
        // hold the keyboard and the watcher at once, but ordering it this way
        // means the answer does not depend on that being true.
        if (termTyping)
        {
            return new(KeyAct.PassOn, false);
        }

        if (typing)
        {
            // Escape empties a search box if it has anything in it, and
            // otherwise leaves the box.
            if (key == PressedKey.Escape)
            {
                return searchWithText ? new(KeyAct.ClearSearch, true) : new(KeyAct.FocusList, true);
            }

            return new(KeyAct.PassOn, false);
        }

        if (key == PressedKey.Escape)
        {
            return new(KeyAct.FocusList, true);
        }

        if (key == PressedKey.Slash)
        {
            return new(KeyAct.FocusSearch, true);
        }

        if (manageSurface)
        {
            switch (key)
            {
                case PressedKey.Space:
                    return new(KeyAct.ToggleTick, true);
                case PressedKey.KeyO:
                    return new(KeyAct.ToggleOlder, true);
                case PressedKey.Left when projectRowSelected:
                    return new(KeyAct.FoldProject, true);
                case PressedKey.Right when projectRowSelected:
                    return new(KeyAct.UnfoldProject, true);
                default:
                    break;
            }
        }

        if (key == PressedKey.KeyL)
        {
            return new(KeyAct.LoadWhole, true);
        }

        return new(KeyAct.PassOn, false);
    }
}
