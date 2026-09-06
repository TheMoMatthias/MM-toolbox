# Control inventory — session-restore GUI

Every control a person can press, click, select, toggle, type into, drag or trigger
by keyboard, with a verdict.

**Verdict vocabulary (exactly five):**

- **WORKS** — positive evidence it fires and does the right thing (a gui2 assertion that
  actually exercises it, or a handler read end-to-end whose every branch is reachable and correct).
- **BROKEN** — positive evidence it does not. What happens instead is named.
- **INERT** — exists and is clickable, but the handler cannot have an effect (a guard that
  never passes, state cleared before it is read, a branch keyed on something always false).
- **UNPROVEN** — read, looks right, nothing in the suite covers it and it could not be reached
  from the console replica. An honest gap, not a criticism.
- **UNPRESSABLE-BY-POLICY** — the handler launches, kills, types into, saves, sends to, or signs
  into a live session. Never invoked. Verdict from source reading only.

Line numbers: `window2.xaml` = W, `sessions-window.ps1` = S, `spawn2.xaml` = X.
All paths relative to `C:\Users\mauri\Documents\MM-toolbox\tools\session-restore\lib\`.

---

## 1. Window chrome / title bar

| control | where (file:line) | what it should do | verdict | evidence |
|---|---|---|---|---|
| `WinMin` | W1458 decl; S10576 handler | minimise the window | WORKS | one-line handler sets `WindowState=Minimized`; no branches. gui2 references `WinMin` (2 sites) in the frame/seam section (`--- the seam, and the frame ---`, gui2:4953). |
| `WinMax` | W1460 decl; S10577 handler | maximise / restore, and swap the glyph | WORKS | handler toggles `WindowState` and calls `Update-MaxGlyph`; `Update-Frame` is re-driven from `Add_StateChanged` (S10627) so the shell inset re-pads on both edges. gui2 asserts the glyph pair. |
| `WinClose` | W1462 decl; S10582 handler | close the window | WORKS | `$window.Close()`; `Add_Closing` (S) guards a send in flight — gui2 `--- closing the window does not abandon a send mid-flight ---` (gui2:4236). |
| `TitleBar` drag | W1362 | drag the window by its title bar | UNPROVEN | the border is the drag surface; `DragMove` wiring is in the same region as `SpTitleBar` (S10199) for the spawn dialog. Nothing in gui2 raises a mouse-drag on the main title bar — no `PresentationSource` on an unshown window, so a drag cannot be synthesised. Would need a shown-window harness. |

## 2. Header row (search, primary actions)

| control | where (file:line) | what it should do | verdict | evidence |
|---|---|---|---|---|
| `Search` (header text box) | W1433 decl; S7971 handler | filter every surface; debounced | WORKS | `Add_TextChanged` restarts `$script:searchTimer` rather than rebuilding per keystroke. gui2 `--- each pane searches, sorts and filters itself ---` (gui2:1021) exercises `Search` (14 mentions). |
| `NewSession` | W1441 decl; S10301 handler | open the spawn dialog | UNPRESSABLE-BY-POLICY | handler is `Show-Spawn` — the dialog itself is inert until `SpStart`, but `Show-Spawn` is the entry to a launch path. Source reads correct: single call, no argument, and `Ctrl+N` dispatches the same function (S10648) so the two entries cannot diverge. |
| `SignIn` | W1447 decl; S8690 handler | sign a session in / refresh the token | UNPRESSABLE-BY-POLICY | 60-line handler, plans before it acts — gui2 `--- the logon buttons plan before they act ---` (gui2:90) asserts the PLAN (mid-turn excluded, already-running excluded, unticked excluded) without executing it. Wiring reads correct; the act half is never run. |
| `Rescan` | W1449 decl; S10534 handler | re-read the registry and repaint | UNPROVEN | handler calls the model refresh; gui2 mentions `Rescan` twice. Reads correct end-to-end but no assertion drives the click itself. Would need the replica to invoke the delegate and compare `$script:modelGen` before/after. |
| `Broadcast` ("Send to many") | W1504 decl; S10351 handler | open the cast panel | WORKS | handler shows `CastBox` and builds `CastList`. gui2 `--- send to many ---` (gui2:513) covers the panel it opens; the opener itself is a visibility flip with no branch. |

## 3. Surface switch

| control | where (file:line) | what it should do | verdict | evidence |
|---|---|---|---|---|
| `ModeWork` | W1480 decl; S7741 handler | switch to the work surface | WORKS | `Add_Checked` → `Set-Surface 'work'`. Checked (not Click) is correct for a radio group. gui2 calls `Set-Surface 'manage'` / `'work'` directly across many sections. |
| `ModeManage` | W1482 decl; S7742 handler | switch to the session manager | WORKS | as above → `Set-Surface 'manage'`. `--- switching to the manager does not rebuild it unless it has to ---` (gui2:3445). |

## 4. Projects rail (left column)

| control | where (file:line) | what it should do | verdict | evidence |
|---|---|---|---|---|
| `RailFold` (‹) | W1561 decl; S10359 handler | collapse the projects column | WORKS | `Invoke-ColumnFold -Which 'rail'`. gui2 `--- collapsing the projects and sessions columns ---` (gui2:4671), 3 mentions. |
| `RailOpen` (›) | W1631 decl; S10361 handler | re-open the collapsed projects column | WORKS | same function, same argument — the pair cannot diverge. Covered by gui2:4671. |
| `RailClear` ("clear") | W1566 decl; S7926 handler | drop the project filter | UNPROVEN | `$script:railPick = $null; Build-Rail; Build-Sessions` — reads correct, three statements, no branch. Zero mentions in gui2. Would need the replica to set `$script:railPick`, invoke the delegate, and assert the session list widened. |
| `RailSearch` | W1572 decl; S8199 handler | filter the rail; debounced | WORKS | shares `$script:searchTimer` with the header box. gui2:1021 exercises it (5 mentions) and gui2:6231 (`--- bare-letter shortcuts stand down wherever you can type ---`) proves keystrokes reach it rather than being eaten by the window shortcuts. |
| `RailSort` | W1577 decl; S8169 handler | cycle the rail sort order | UNPROVEN | cycles `$script:RailSorts` by index, wraps with `%`, calls `Update-RailLabels` then `Build-Rail`. Read end-to-end and correct — but `[array]::IndexOf` returns `-1` for an unknown current key, and `(-1 + 1) % n` = 0, so it self-heals rather than throwing. Zero mentions in gui2. |
| `RailOnlyLive` | W1581 decl; S8178 handler | toggle rail between all / running | UNPROVEN | boolean flip → `Update-RailLabels` → `Build-Rail`; label and foreground both re-driven. Zero mentions in gui2. |
| `RailShelved` | W1593 decl; S8185 handler | show / hide shelved projects | WORKS | flip → `Build-Rail` → a status line naming the count. gui2 `--- shelving a project takes it off the rail, and says how many are away ---` (gui2:1554), 3 mentions. |
| `RailList` row click | W1613 decl; S7903 handler | pick a project | WORKS | `Add_PreviewMouseLeftButtonDown` + `Add_SelectionChanged` (S7914). gui2 `--- the projects rail, in age bands you can fold ---` (gui2:1249) and `--- the project tiles ---` (gui2:1779); 27 mentions. |
| `RailList` right-click | S8301 handler | shelve / unshelve a project | UNPROVEN | opens a context menu; the menu items are built at S8262. gui2 covers what the rail SUGGESTS shelving (gui2:1641) but the right-click path itself is not driven. |
| rail age-band fold headers | built at runtime in `Build-Rail` | fold an age band | WORKS | gui2:1249 asserts the bands fold. |

## 5. Sessions column (middle) and its collapsed strip

| control | where (file:line) | what it should do | verdict | evidence |
|---|---|---|---|---|
| `ListSearch` | W1679 decl; S8200 handler | filter the sessions column; debounced | WORKS | same debounce as the rail box; gui2:1021, 5 mentions; gui2:6231 proves keystrokes are not eaten by the bare-letter shortcuts. |
| `ListSort` | W1661 decl; S8206 handler | cycle the order inside each band | UNPROVEN | cycles `$script:ListSorts` by index, wraps with `%`, `Update-ListSortLabel` then `Build-Sessions`. Read end-to-end and correct. Zero mentions in gui2. |
| `ListFold` (left caret) | W1670 decl; S10360 handler | collapse the sessions column to the dot strip | WORKS | `Invoke-ColumnFold -Which 'list'`. gui2:4671, 3 mentions. |
| `ListOpen` (right caret) | W1712 decl; S10362 handler | re-open the collapsed sessions column | WORKS | same function, same argument as `ListFold`. gui2:4671. |
| `SessionList` row click / selection | W1682 decl; S7888 handler | show that conversation in the reading pane | WORKS | `Add_SelectionChanged` calls `Request-ShowSelected` (S7873), a leading-edge debounce at 90 ms. gui2 `--- selecting a conversation is not evidence about it ---` (gui2:538), `--- clicking a waiting conversation leaves it in NEEDS YOU ---` (gui2:2648), `--- selecting a conversation must not read its vitals ---` (gui2:2596). 59 mentions. |
| `SessionList` band-heading click | S7806 handler | filter the list to one band; click again for all | WORKS | `Add_PreviewMouseLeftButtonDown` (not Click - `ListBoxItem` marks button-down handled when it selects, which is why a Click handler would never fire). Toggles `$script:bandPick`, rebuilds, and says which state it is now in. gui2 `--- the state filter, on the band headings ---` (gui2:973). |
| `SessionList` arrow keys | S7888, via WPF's own selection movement | step the selection; chrome moves per key, the document settles once | WORKS | no arrow handler, by design; `Request-ShowSelected` coalesces a run onto one draw with a leading edge so a single press still draws immediately. gui2 `--- end to end: how long until you SEE something ---` (gui2:3563). |
| `StripList` dot | W1721 decl; S10366 handler | jump straight to a conversation that needs you | WORKS | `Add_PreviewMouseLeftButtonUp`; gui2 `--- the strip selects a conversation without rebuilding the list ---` (gui2:3411). |
| list scrollbar `Thumb` / `RepeatButton` x2 | W509, W518, W521 | scroll the lists | UNPROVEN | template parts driven by the stock `ScrollBar.PageUp/PageDownCommand`; the page buttons are `Opacity="0" Focusable="False"` by design. No custom code, nothing asserted. |
| reading-pane scroll wheel | S4091 `$sv.Add_PreviewMouseWheel` | scroll the transcript | UNPROVEN | intercepts the wheel on the pane's `ScrollViewer`. Reads correct; no gui2 assertion raises a wheel event (a headless window has no `PresentationSource`, so the event cannot be constructed). |

## 6. Pane header buttons (the reading pane's own strip)

| control | where (file:line) | what it should do | verdict | evidence |
|---|---|---|---|---|
| `PaneCompact` | W1823 decl; S9236 handler | run the morning compact on this conversation | UNPRESSABLE-BY-POLICY | `Invoke-Compact` types into a live session. Wiring reads correct - single call, no argument. gui2 `--- the morning compact, across every ticked conversation ---` (gui2:4815) and `--- the live screen while a compact runs ---` (gui2:4847) test the machinery against fixtures; the button itself is never pressed. |
| `PaneTools` ("Steps: folded") | W1825 decl; S9226 handler | cycle how much tool traffic the pane shows | WORKS | `Step-ToolView`. gui2 mentions `PaneTools` twice, in `--- the two new buttons in the pane header ---` (gui2:2535). |
| `PaneZoom` ("Text: 100%") | W1832 decl; S9228 handler | step the text size | WORKS | `Step-Zoom`. gui2 `--- one type scale, and the zoom moves all of it ---` (gui2:5056) and `--- the text size reaches the rows without regenerating the list ---` (gui2:3917) assert the effect end to end, though they call the function rather than the button. |
| `PaneWorktree` | W1834 decl; S9990 handler | start the next session on a worktree | UNPRESSABLE-BY-POLICY | leads to a launch. gui2 mentions `PaneWorktree` twice in the control-plane section (gui2:412) and asserts the per-session settings reach the command a session is started with - without starting one. |
| `PaneSettings` | W1836 decl; S9223 handler | show / hide the per-session settings panel | WORKS | a pure visibility toggle read off `SettingsBox.Visibility`; both branches reachable, both call a named function (`Show-Settings` / `Hide-Settings`). |
| `PaneStop` ("Interrupt") | W1846 decl; S9024 handler | interrupt the current turn | UNPRESSABLE-BY-POLICY | `Invoke-Interrupt` sends Esc to a live console. Source: it refuses on a blocker (`Get-InterruptBlocker`) and refuses a second press while one is in flight (`$script:ansPs`). gui2 `--- interrupting a turn, and refusing to press Esc anywhere else ---` (gui2:2251) asserts both refusals against fixtures. Deliberately not sheet-confirmed; the note at S9010 argues why. |
| `PaneGoTo` | W1848 decl; S9026 handler | raise that session's terminal tab | UNPRESSABLE-BY-POLICY | calls `Invoke-SRJumpToSession`, which touches a live window. Source reads correct: guards on `Kind -ne 'session'` and on `-not $r.A` with a spoken reason, and wraps the jump in try/catch so a failure becomes a status line rather than a crash. |
| `PaneRelaunch` | W1849 decl; S9093 handler | relaunch the conversation | UNPRESSABLE-BY-POLICY | kills and restarts a process. Source reads correct and it DOES confirm through `Show-Sheet` - the asymmetry with Interrupt is stated deliberately at S9010. |
| `ShellFold` ("hide") | W2113 decl; S9232 handler | collapse the running-shells panel; "It comes back on its own when another shell starts" (its own tooltip, W2115) | **BROKEN** | the collapse half works. The advertised recovery does not: `$script:shellHidden` is set at S9235 and cleared in exactly one place, S3953 — `if ($script:shellFor -ne $id) { $script:shellHidden = $false }` — which fires only when the SELECTED CONVERSATION changes. A new shell starting in the same conversation raises the count `$n`, which makes `$stale` true and re-reads the list, but the very next line (S3962) `if ($script:shellHidden) { collapse; return }` hides it again. So within one conversation, once you press "hide", the panel never returns however many shells start. The one accidental escape: if every shell stops first, the `-not $id -or $n -le 0` branch (S3942) resets `$script:shellFor = ''`, so the next shell does revive it. Zero mentions in gui2 by name; gui2 `--- the running-shells panel puts what it is given on screen ---` (gui2:5375) covers the panel's content, not its fold button. See §16. |
| `ShellList` row | W2120 row template; list at W2117 | (implied by the hand cursor) go to that shell or open its output | **INERT** | the row `Border` carries `Background="Transparent" Cursor="Hand"` — the exact pair every other clickable surface in this window uses (`StripList` W1725, `CastList` W1888, `TickBox` W1301, the rail tiles W1197, and all four of those have handlers). `ShellList` has none: no `Add_Click`, no `Add_PreviewMouseLeftButtonDown`, no `Add_SelectionChanged`, and as an `ItemsControl` it does not even select. The only four references to it in `sessions-window.ps1` are the `x:Name` lookup list (S171) and the two `ItemsSource` assignments (S3945, S4021). The pointer changes and the click is swallowed. See §16. |

## 7. The question panel (ask / answer surfaces, built at runtime)

| control | where (file:line) | what it should do | verdict | evidence |
|---|---|---|---|---|
| option buttons (one per choice) | built in `Show-Ask`; S5344 `$b.Add_Click({ Invoke-Answer ([int]$s.Tag) })` | answer the question with that option | UNPRESSABLE-BY-POLICY | `Invoke-Answer` types into a live console. Wiring reads correct: the index is carried on `.Tag` and cast to `[int]`, so a button cannot answer for its neighbour. gui2 `--- the panel drawing a real batched round ---` (gui2:1984) and `--- all three sends are off the UI thread, and none of them can answer by accident ---` (gui2:2152). |
| round-navigation buttons | S5429 `$b.Add_Click({ Invoke-AskMove ([int]$s.Tag) })` | move between the questions of a batched round | **UNPRESSABLE-BY-POLICY** | ⚠️ **This row previously said "not policy-blocked" because `Invoke-AskMove` "only moves the panel - it does not send". That is wrong and it is wrong in the dangerous direction.** `Invoke-AskMove` calls `Start-AskSend -Kind 'move'` (sessions-window.ps1:6584), which types ARROW KEYS into the selected conversation's live menu - the same mechanism as answering. Pressing it from a harness would drive a picker in one of the operator's sessions. NOT pressed. What `press-driver.ps1` proves instead is the three guards between the click and the send - nothing selected, not running, a send already in flight - with `Start-AskSend` replaced by a counter asserted to stay at zero, because a guard that stopped working would surface as a send rather than as a wrong answer. |
| `AskFree` (answer in your own words) | W2232 decl; S8945 + S8947 handlers | type an answer; Enter sends, Shift+Enter is a newline | WORKS | **Both previously-found INERT defects on this control are fixed and now covered.** (1) the dirty flag no longer resets on the hidden-panel path - the reset is keyed to a change of question (S5410); (2) the key now includes `$script:selId` (S5409), so one conversation's typing cannot survive into another's. gui2 `--- the answer box you are typing in is not typed over ---` (gui2:6121); 12 mentions. |
| `AskFreeSend` | W2235 decl; S8937 handler | send what you typed | UNPRESSABLE-BY-POLICY | `Invoke-AskTyped` types into a live console. Reads correct - it refuses an empty send, and the `AskFree` Enter path calls the same function, so the two entries cannot diverge. |
| foldable block header, reading pane | S3729 `$bd.Add_PreviewMouseLeftButtonDown({ Invoke-FoldToggle $s })` | fold / unfold a tool block | WORKS | gui2 `--- a foldable block in the reading pane can actually be clicked ---` (gui2:4003) and `--- the turns folded off-thread are the turns folded inline ---` (gui2:3351). |
| agent-doc open (`$op`) | S4237 `Add_PreviewMouseLeftButtonDown` | open a sub-agent's document | UNPROVEN | reads correct; no assertion drives the click. |
| agent-doc close (`$bb`) | S4609 `Add_PreviewMouseLeftButtonDown({ Close-AgentDoc })` | close the sub-agent document | UNPROVEN | single call plus `$e.Handled = $true`; no assertion drives it. |
| agent-doc fold (`$bd`) | S4641 `Add_PreviewMouseLeftButtonDown` | fold a block inside the sub-agent document | UNPROVEN | same shape as the pane fold above; not separately asserted. |

## 8. Composer dock (the send box under the reading pane)

| control | where (file:line) | what it should do | verdict | evidence |
|---|---|---|---|---|
| `SendBox` | W2322 decl; S8921 `Add_TextChanged`, S8962 `Add_PreviewKeyDown`, S8994 `Add_LostKeyboardFocus` | type a message; Enter sends, Shift+Enter is a newline; `/` opens the skill picker | WORKS | the most-covered control in the window - 35 mentions across gui2 `--- the composer grows with what you type ---` (gui2:4362), `--- the skill picker ---` (gui2:4338), `--- what happens between pressing Send and the reply ---` (gui2:4501). Enter is preserved as send by an operator ruling recorded at S8924. |
| `SendBtn` | W2373 decl; S8922 handler | send what is in the composer | UNPRESSABLE-BY-POLICY | `Invoke-Send` types into a live console. Wiring reads correct, and the Enter path checks `$ui.SendBtn.IsEnabled` before calling the same function (S8988) - so a disabled Send cannot be reached by the keyboard either, and Enter is swallowed rather than inserting a stray newline. |
| `SkillPop` / `SkillList` (skill picker) | W2332, W2344 decl; S8956 `Add_MouseLeftButtonUp` + arrow/Tab/Enter/Escape in S8962 | pick a `/skill` and complete it into the box | WORKS | gui2 `--- the skill picker ---` (gui2:4338); `SkillPop` 4 mentions. The `LostKeyboardFocus` handler (S8994) walks the visual tree so that clicking a skill does not tear down the popup mid-click - a defect that had made the picker keyboard-only. |
| `QueueBox` / `QueueList` | W2289, W2293 | show what is queued to send | UNPROVEN | display only - the row template is three `TextBlock`s with tooltips, no handler. gui2 `--- the queue mark ages the message, not the transcript file ---` (gui2:6277) covers the content, not an interaction (there is none to cover). |

## 9. Session manager surface

| control | where (file:line) | what it should do | verdict | evidence |
|---|---|---|---|---|
| `MgrAll` / `MgrTicked` / `MgrRunning` / `MgrNeeds` | W2445-2451 decl; S8155 loop | filter the manager | WORKS | wired with `Add_Checked`, not `Add_Click` - correct for a radio group, since the handler must fire for whichever ends up ON, including a programmatic uncheck. The `Tag` is assigned in the same loop (S8154) that reads it, so a chip cannot carry a filter key it was never given. gui2 `--- the manager filter strip ---` (gui2:871). |
| `HdrLogon` / `HdrName` / `HdrLane` / `HdrSaid` / `HdrAge` | S8129 loop | sort the manager by that column; click again to reverse | WORKS | each header's base text is captured once (S8109) so the arrow can be appended without a second copy of the wording drifting; clicking the current column reverses, a new column starts at its most useful end. gui2 `--- the manager sorts by its column headers ---` (gui2:911). |
| `ManageList` tick box (`TickBox`) | W1301 template; S8009 handler | tick a conversation for the next logon | WORKS | `Test-ClickedTick` (S7999) walks up from `OriginalSource` and stops at the `ListBoxItem`, so only a hit on the box itself counts - plus a double-click anywhere on the row, for people who try that. `Set-TickOn` (S896) drops just that one row from the cache instead of clearing it. gui2 `--- the manager row cache cannot show a stale tick ---` (gui2:3481). |
| `ManageList` project-header click | S8014 (`'project'` branch) | fold / unfold a project | WORKS | toggles `$script:fold[$it.Path]` then `Build-Manager`. gui2:209 (`--- the session manager can actually be used ---`). |
| `ManageList` "older conversations" row | S8015 (`'more'` branch) | reveal the older conversations | WORKS | sets `$script:showOlder = $true` then rebuilds. Reachable from the keyboard too (`O` on the manage surface, S10694). |
| `ManageList` right-click menu | S8218 opener; `New-ManageMenu` S8038 | act on one conversation | UNPRESSABLE-BY-POLICY | four items: **Open it now** (launch), **Relaunch it** (kill + launch, sheet-confirmed), **Go to its terminal** (raises a live window), **Settings...** (safe - it only switches surface and opens the panel). The opener refuses on a non-`conv` row and sets `$script:manageMenuRow`; `Get-ManageRow` (S8095) takes it ONCE and clears it, so a later keyboard invocation cannot act on a row the mouse pointed at minutes earlier. gui2 asserts the menu is templated (`--- a numbered list in prose is not a menu ---` region and gui2:209). |
| `SaveBtn` | W2493 decl; S8321 handler | write the ticks to the registry | UNPRESSABLE-BY-POLICY | calls `Save-RegistryOrAsk`, which writes `sessions-registry.json`. Never pressed. Source reads correct: the rebuild and the status line are both inside the `if`, so a refused or failed save says nothing misleading. |
| `OpenNotRunning` | W2467 decl; S8578 handler | open the ticked conversations that are not running | UNPRESSABLE-BY-POLICY | plans first (`Get-TickedPlan -Adopt`, `Limit-ToCap`), names every conversation in a `Confirm-Action` sheet, reports the blocked ones and the ones over the `maxSessions` cap, and only then calls `Start-LaunchQueue`. gui2 `--- the logon buttons plan before they act ---` (gui2:90) asserts the plan (mid-turn excluded, already-running excluded, unticked excluded) without launching. |
| `RelaunchSessions` | W2468 decl; S8752 handler | close and reopen the ticked running ones, and open the ticked stopped ones | UNPRESSABLE-BY-POLICY | same plan-then-confirm shape; the confirmation names both counts. The comment at S8754 records why it no longer takes only the running set (after a reboot nothing is running, so the button appeared dead). gui2:90. |
| `SignIn` | W1447 decl; S8692 handler | run `claude auth login` in a real terminal, then notice when it lands | UNPRESSABLE-BY-POLICY | refuses a second press while one is outstanding (`$script:signInWatch`), stamps `Get-SRCredStamp` before starting, and bounds the watch to 10 minutes so a sign-in that never happens cannot leave a timer polling for the life of the window. Uses `claude auth login` (not `claude /login`) specifically so it does not manufacture a transcript - see the note at S8703. |

## 10. Per-session settings panel

| control | where (file:line) | what it should do | verdict | evidence |
|---|---|---|---|---|
| `SetName` | W1948 decl | rename the conversation | UNPROVEN | no handler - read at Apply. `SetApply` refuses an empty name (S10006) before writing anything. gui2 mentions `SetName` twice. |
| `SetModel` | W1959 decl | choose the model | UNPROVEN | no handler - read at Apply via `Get-DropValue`. ⚠️ `Set-DropValue` (S9167) falls back to `SelectedIndex = 0` when the stored value matches no item's `Tag`, so opening the panel on a session whose stored model is unrecognised silently displays the first entry, and Apply would then persist that. Not inert, but worth knowing. |
| `SetEffort` | W1963 decl | choose the reasoning effort | UNPROVEN | same shape and same `Set-DropValue` fallback as `SetModel`. |
| `SetPerm` | W1968 decl; S9222 `Add_SelectionChanged` | choose the permission mode, and explain it | WORKS | `Update-PermNote` (S9179) has two reachable branches and colours `bypassPermissions` / `dontAsk` in the NEEDS accent. gui2 mentions `SetPerm` twice. |
| `SetRemote` | W1972 decl | let the session be driven from the Claude app | UNPROVEN | no handler; read at Apply as `[bool]$ui.SetRemote.IsChecked`. Correct that it has none - nothing in the panel depends on it. gui2 mentions it once. |
| `SetHidden` | W1974 decl | run with no window | UNPROVEN | as above. gui2 mentions it once. |
| `SetToolsFold` (Expander) | W1983 decl | reveal the tool-limit boxes | WORKS | a stock `Expander` with no custom code; `SetAllow` / `SetDeny` are declared inside it, and `Show-Settings` opens it only when there is something in it (S9147), so it cannot hide a limit you forgot you set. |
| `SetAllow` / `SetDeny` | W1991, W1994 decl | limit the tools | UNPROVEN | no handler; read at Apply. `SetApply` splits on whitespace and drops empties (S10018) specifically so a trailing space cannot become an empty `--allowedTools`, which claude reads as "allow nothing". 4 gui2 mentions each - the splitting rule is asserted; the boxes themselves are not driven. |
| `SetCancel` | W2005 decl; S9996 handler | close the panel, change nothing | WORKS | two unconditional statements: `Hide-Settings` (which also clears `$script:setFor`) and a status line. No branch to be unreachable. |
| `SetApply` | W2006 decl; S9998 handler | write the settings, then offer a relaunch | UNPRESSABLE-BY-POLICY | writes the registry and can kill and restart a live session. Source reads correct end-to-end: it re-finds the row by `$script:setFor` (pinned to an id, never to the selection, so a list rebuild cannot redirect the write), refuses an empty name, reports a failed save without claiming success, says "nothing changed" when the label round-trips identically, and only offers the relaunch when the session is actually running and not mid-turn. |

## 11. Send-to-many (cast) panel

| control | where (file:line) | what it should do | verdict | evidence |
|---|---|---|---|---|
| `CastList` row | W1884 decl; S10444 handler | tick / untick a conversation to send to | WORKS | refuses a mid-turn row with a spoken reason, otherwise toggles `$script:castPick` and rebuilds. `Build-Cast` (S10317) drops a row from the picks the moment it goes busy, so a pick cannot survive into a send it would be refused for. gui2 `--- send to many ---` (gui2:513). |
| `CastText` | W1913 decl; S10443 `Add_TextChanged` | type the message | WORKS | 11 gui2 mentions. **Checked specifically for the state-cleared-before-read shape and it is clean:** `CastSend.IsEnabled` is recomputed on BOTH inputs - here on every keystroke, and again at the end of `Build-Cast` (S10341) - so typing before ticking and ticking before typing both end with the button in the right state. |
| `CastCompact` | W1922 decl; S10437 handler | drop the morning-compact brief into the box | WORKS | sets the text (which raises `TextChanged`, so the Send state follows), moves the caret to the end, focuses the box, and says how many conversations it would reach. Reads the brief from config with a hard-coded fallback (`Get-SRCompactBrief`, S10431). gui2 `--- the morning compact, across every ticked conversation ---` (gui2:4815); 2 mentions. |
| `CastCancel` | W1926 decl; S10442 handler | close the panel, send nothing | WORKS | two unconditional statements. Zero gui2 mentions, but there is no branch to miss. |
| `CastSend` | W1927 decl; S10453 handler | type the message into every ticked conversation | UNPRESSABLE-BY-POLICY | the highest-blast-radius control in the window. Source is careful: it re-checks `busy` at press time (a conversation can start a turn between ticking and sending), refuses when nothing survives that re-check, names every target in a `Confirm-Action` sheet, then drains a 300 ms `DispatcherTimer` queue **one send per tick** rather than looping - and the tick re-checks `busy` a third time and stands down entirely while a sheet is open (`$script:sheetDepth`). Deliberately sends without `-Force`, so a refusal is reported rather than overridden. |
| `Broadcast` (correction to §2) | W1504 decl; S10353 handler | toggle the cast panel; switch to the work surface first if needed | WORKS | the row in §2 called this "open the cast panel" - it is a toggle: pressing it while the panel is open hides it, and it forces `ModeWork` first, because a panel opened on a surface you cannot see is not an action. |

## 12. The sheet (the window's own confirmation dialog)

| control | where (file:line) | what it should do | verdict | evidence |
|---|---|---|---|---|
| `SheetB1` / `SheetB2` / `SheetB3` | W2553-2557 decl; S220 loop | answer a confirmation | WORKS | the loop assigns one handler that reads its own `.Tag`, and `Show-Sheet` fills the slots FROM THE RIGHT so the primary always lands on `SheetB3` whether there are one, two or three choices. gui2 `--- the window asks in its own voice ---` (gui2:5464); `SheetB1` 6 mentions, `SheetB3` 7. |
| Esc / Enter on an open sheet | S259 `$window.Add_PreviewKeyDown` | Esc takes the nominated safe way out; Enter takes the primary | WORKS | a separate, earlier `PreviewKeyDown` than the main shortcut handler, and it returns immediately unless `$script:sheetFrame` is set - so it cannot interfere when no sheet is up. Registered before the list and transcript bindings, which also want arrows and Enter. gui2:5464. |
| `Scrim` | W2516 | block the window behind an open sheet | WORKS | shown and hidden by `Show-Sheet` under a depth counter (`$script:sheetDepth`), so a nested sheet cannot uncover the window when the inner one closes. |

## 13. New-session dialog (`spawn2.xaml`)

A fresh window is loaded from XAML on **every** `Show-Spawn` call (S10088), so these handlers
cannot accumulate across openings - pressing Start twice in two sittings cannot launch twice.

| control | where (file:line) | what it should do | verdict | evidence |
|---|---|---|---|---|
| `SpTitleBar` drag | X56 decl; S10199 handler | move the dialog | UNPROVEN | `try { $sp.DragMove() } catch { }` - the catch is correct here (DragMove throws if the button is already up). Not drivable headless. |
| `SpClose` | X66 decl; S10200 handler | dismiss | WORKS | `$sp.DialogResult = $false`; identical to `SpCancel` and to the Escape key, so the three cannot diverge. |
| `SpCancel` | X143 decl; S10201 handler | dismiss | WORKS | as above. |
| Escape on the dialog | S10202 `$sp.Add_KeyDown` | dismiss | WORKS | same one-line result as the two buttons. |
| `SpDir` | X80 decl; S10194 `Add_SelectionChanged` | choose the project | WORKS | drives `$refresh`, which updates the resolved path, the permission note and the worktree warning. A preset directory that is not in the recent list is INSERTED rather than left to miss (S10156) - without that, `Set-DropValue`'s index-0 fallback would silently start the session somewhere else. |
| `SpBrowse` | X82 decl; S10204 handler | pick a folder that is not in the list | UNPROVEN | opens a `FolderBrowserDialog`, appends the choice as a new item, selects it and re-runs `$refresh`. Reads correct; a modal OS dialog is not drivable from the replica. |
| `SpName` | X89 decl | name the conversation | UNPROVEN | no handler; read at Start, which refuses an empty name. |
| `SpModel` / `SpEffort` | X99, X104 decl | choose model / effort | UNPROVEN | no handler by design - `$refresh` reads neither, so nothing on the dialog depends on them; they are read at Start. |
| `SpPerm` | X110 decl; S10195 `Add_SelectionChanged` | choose the permission mode | WORKS | drives `$refresh`, which writes `SpPermNote` and colours the two dangerous modes in the NEEDS accent - the same rule as the settings panel. |
| `SpRemote` | X115 decl | drivable from the Claude app | UNPROVEN | deliberately NOT wired to `$refresh`: `$refresh` reads only `SpDir`, `SpPerm`, `SpWorktree` and `SpHidden`, which are exactly the four that ARE wired. Read at Start. |
| `SpHidden` | X117 decl; S10197 `Add_Click` | run with no window | WORKS | drives `$refresh`, which rewrites `SpHint` to say which of the two things will happen. |
| `SpWorktree` | X119 decl; S10196 `Add_Click` | start on a git worktree | WORKS | drives `$refresh`, which checks for a `.git` in the chosen directory and warns BEFORE the launch rather than letting it fail in a terminal you then have to go and read. gui2 mentions `PaneWorktree` (the other entry to the same preset) twice. |
| `SpStart` | X145 decl; S10221 handler | start the session | UNPRESSABLE-BY-POLICY | launches. Source reads correct: three refusals before anything happens (no directory, directory gone, no name), each writing `SpWarn` and returning; the result is packed into `$script:spawnGo` and the dialog closes with `DialogResult = $true` - the launch itself is the caller's. gui2 `--- the new-session dialog reads the same palette ---` (gui2:5798). |

## 14. Keyboard

The window-level guard is `$window.Add_PreviewKeyDown` at **S10638**. There is a second,
earlier `PreviewKeyDown` at S259 that belongs to the sheet and returns immediately unless one
is open.

| control | where (file:line) | what it should do | verdict | evidence |
|---|---|---|---|---|
| `Ctrl+N` | S10648 | new session | UNPRESSABLE-BY-POLICY | checked BEFORE the typing guard, deliberately - no text field wants Ctrl+N. Dispatches the same `Show-Spawn` the button does. |
| `Ctrl+1` / `Ctrl+NumPad1` | S10655 | fold the projects column | WORKS | also before the typing guard; same `Invoke-ColumnFold -Which 'rail'` as the two carets. gui2:4671. |
| `Ctrl+2` / `Ctrl+NumPad2` | S10656 | fold the sessions column | WORKS | as above, `-Which 'list'`. gui2:4671. |
| the typing guard | S10673 `Test-SRTypingTarget` (S249) | bare-letter shortcuts stand down wherever you can type | WORKS | **this is a previously-BROKEN control that is now fixed and covered.** The guard named two boxes while the window had nine, so `hello` typed into the broadcast box arrived as `heo` and each swallowed `l` doubled the transcript tail budget. It now asks the focused element what it IS (`TextBoxBase` or `PasswordBox`) rather than listing boxes, and the decision was lifted out of the handler into a callable function precisely so the headless suite can assert it. gui2 `--- bare-letter shortcuts stand down wherever you can type ---` (gui2:6231). |
| `Escape` while typing | S10682 | empty a search box if it has anything in it, else leave the box | WORKS | moved BELOW the typing guard - it used to be checked first, so pressing it in any box other than the header Search threw focus to the sessions list and lost the box you were in. Covered by gui2:6231. |
| `Escape` otherwise | S10692 | focus the sessions list | WORKS | one statement. |
| `/` (`Oem2`) | S10693 | focus the header search | WORKS | one statement; gui2:6231 proves it no longer fires mid-word inside another box. |
| `Space` (manage surface) | S10695 | tick the selected conversation | WORKS | `Toggle-Tick` (S932) refuses anything that is not a `conv` row and folds a project row instead. Guarded by `$script:surface -eq 'manage'`. gui2:3481. |
| `O` (manage surface) | S10696 | show the older conversations | WORKS | same gesture as the "older conversations" row. |
| `Left` / `Right` (manage surface) | S10697 | fold / unfold the selected project | WORKS | only acts on a `project` row; `Left` folds, `Right` unfolds, which is the direction a person expects. |
| `L` | S10707 | load earlier - double the transcript tail budget | WORKS | doubles `$script:tailBytes`, redraws, and says how much is now loaded. The pane starts at a budget because a 2.5 MB conversation is a multi-second freeze. |
| `Up` / `Down` in the lists | WPF's own selection movement | step the selection | WORKS | see §5 - no handler by design; the draw is coalesced by `Request-ShowSelected`. |
| `Enter` / `Shift+Enter` in `SendBox` | S8962 | send / newline | WORKS (Shift+Enter) · UNPRESSABLE-BY-POLICY (Enter) | the newline half is safe and covered; the send half calls `Invoke-Send` into a live console and is never exercised. |
| `Enter` / `Shift+Enter` in `AskFree` | S8947 | send / newline | WORKS (Shift+Enter) · UNPRESSABLE-BY-POLICY (Enter) | same split; the send half calls `Invoke-AskTyped`. |
| arrows / `Tab` / `Enter` / `Escape` in the skill picker | S8963-8971 | drive the picker from the keyboard | WORKS | `PreviewKeyDown`, not `KeyDown`, specifically so Enter completes the `/name` instead of sending a half-typed one - a keystroke you could not take back. `Math::Min` / `Math::Max` clamp both ends. gui2:4338. |

## 15. Column splitters

| control | where (file:line) | what it should do | verdict | evidence |
|---|---|---|---|---|
| `RailSplit` | W1639 | drag the projects column wider or narrower | UNPROVEN | a stock `GridSplitter`, `Width="4"`, `Background="Transparent"` (which IS hit-testable, unlike a null background), `ResizeBehavior="PreviousAndNext"`. No custom code. A drag cannot be synthesised headless. |
| `ListSplit` | W1737 | drag the sessions column | UNPROVEN | identical declaration. |

## 16. The two actionable findings, in full

These are the only two rows in the table that are not WORKS / UNPROVEN /
UNPRESSABLE-BY-POLICY. Both are in the running-shells panel, which is the one
surface in the window with no gui2 coverage of its interactions.

### BROKEN — `ShellFold` promises a recovery that cannot happen

**Where:** button `W2113` (tooltip `W2115`), handler `S9232`, the state it writes
`S9235`, the only place that state is cleared `S3953`, the read that acts on it `S3962`.

**What it says:** the tooltip reads *"Collapse this panel. It comes back on its own when
another shell starts."* The code comment above the handler (S9231) makes the same claim
twice over: *"it clears when you select a different conversation **or a different set of
shells starts**."*

**What actually happens:** the second half of both sentences is not implemented.

```
S9235   $script:shellHidden = $true          # written by the button
S3953   if ($script:shellFor -ne $id) { $script:shellHidden = $false }
S3962   if ($script:shellHidden) { $ui.ShellBox.Visibility = 'Collapsed'; return }
```

`$script:shellHidden` has exactly three mentions in the file: the initialiser (S3804),
the write (S9235) and the clear (S3953). The clear is keyed on `$script:shellFor -ne $id`
— **the selected conversation changing**. A new shell starting in the *same* conversation
changes `$n` (the shell count), not `$id`, so it makes `$stale` true and re-reads the
list, and then S3962 collapses the panel again nine lines later. The refreshed list is
built and thrown away.

**Consequence:** press "hide" once and, for that conversation, the running-shells panel is
gone for good — through any number of new shells and sub-agents — until you select a
different conversation and come back. There is one accidental escape: if every shell stops
first, the `-not $id -or $n -le 0` branch at S3942 sets `$script:shellFor = ''`, so the
next shell does revive the panel. That is why it will look like it works some of the time.

**Shape:** this is the same class as the two defects the previous audit found — state
whose reset is keyed on a condition that is not the one the feature is about. It is the
inverse of the AskFree bug: there the reset fired too often (on every redraw); here it
fires too rarely (only on a change of conversation).

### INERT — the running-shells rows offer a click that goes nowhere

**Where:** row template `W2120` (`Border Background="Transparent" Cursor="Hand"`), the
list `W2117` (`ShellList`), the only two writes to it `S3945` (`ItemsSource = $null`) and
`S4021` (`ItemsSource = $rows`).

**What it should do:** the template carries `Cursor="Hand"` and a transparent background —
the exact pair used everywhere else in this window to say *this is clickable* (`StripList`
W1725, `CastList` W1888, `TickBox` W1301, the rail tiles W1197 all use it, and every one
of those has a handler). Presumably: go to that shell, or open its output.

**What actually happens:** nothing. `ShellList` has no `Add_Click`, no
`Add_PreviewMouseLeftButtonDown`, no `Add_SelectionChanged` — it is an `ItemsControl`, so
it does not even select. Grep for `ShellList` across `sessions-window.ps1` returns four
hits: the `x:Name` lookup list (S171), the two `ItemsSource` assignments, and nothing else.
The hand cursor is the only affordance and it is a lie: the pointer changes, the row
highlights nothing, and the click is swallowed by the panel.

**Why it matters more than it looks:** the shells panel is where the operator sees
sub-agents and background work, and a hand cursor over a row naming a running sub-agent
reads as "click to go there". Every other hand cursor in this window does something.

---

## 17. Things that look like controls and are not

Recorded so a later sweep does not re-open them as findings. None of these carry a
handler, and none of them advertise one with a hand cursor.

- **The round tab chips** (`New-AskTabChip`, S5110-5146, hosted in `AskTabs` W2197). They
  are `Border`s with a ring/tick mark and a tooltip, and they look like tabs. They are
  **indicators only** — navigation between the questions of a round is by the two
  `New-AskArrow` buttons (S5148) that bracket them. No `Cursor="Hand"`, so the affordance
  is honest, but it is worth knowing that clicking a tab does not jump to that question.
- **The vitals chips** (`PaneChips` W1856, built S7289-7375). Every one is a `Border` with
  a tooltip — model, context bar, branch, diff, remote control, permission mode, effort,
  shell and agent counts, turn clock. Display only.
- **`QueueList`** (W2293), **`AskReview`** (W2246), **`BridgeNote`** (W1411),
  **`RailSuggest`** (W1608), **`SendNote`** (W2316), **`MgrFilterNote`** (W2453),
  **`Stamp`** (W1440), **`Status`** (W2485), **`PaneStateDot`** (W1799), **`LiveMark`**
  (W2051), **`SkillHint`** (W2342), **`StripCount`** (W1716), **`SetPending`**,
  **`SetPermNote`**, **`SpWarn`**, **`SpHint`**, **`SpDirPath`**, **`PaneEmpty`** (W2021).
  All read-only text.
- **Template parts** — `PART_ContentHost`, `PART_Track`, `tb`, `b`, `bb`, `fill`, `ph`,
  `shell`, the `ComboBox` `ToggleButton` (W566) and `Popup` (W593), the scrollbar `Thumb`
  (W509) and its two `RepeatButton`s (W518, W521). Stock WPF plumbing; they work because
  the control they belong to works.

---

## 18. What was never executed, and why

No handler on the forbidden list was invoked — not once, not against a spare row, not
against a row that looked dead. Nothing was launched, killed, typed into, saved, sent to
or signed in. The GUI was never started against live data; `session-restore.config.json`
and `sessions-registry.json` were never opened for writing; no git command was run; the
perf suite was not run (it rewrites `perf-baseline.json`).

Every verdict above therefore comes from one of two places: an assertion that already
exists in `tests\gui2-driver.ps1`, or the handler source read end to end. Where neither
was enough, the row says UNPROVEN and names what would settle it.

**That gap is now closed** — `tests\press-driver.ps1`, 2026-09-06. Every control in it is
pressed with a real routed event on the real element (`RaiseEvent` with a
`MouseButtonEventArgs` built on `Mouse.PrimaryDevice`, which exists without a window), not
by copying the handler body into the test. A copy asserts that the author can transcribe
PowerShell; a raised event asserts that the control the operator clicks moves the state it
claims to.

`RailSort`, `ListSort`, `RailOnlyLive`, `RailShelved`, `RailClear`, `PaneZoom`,
`SetCancel`, `CastCancel` — **all eight work**, twelve assertions, including that both
sort cycles WRAP (the audit noted `IndexOf` returns `-1` for an unknown key and
`(-1+1) % n` = 0, so a broken wrap self-heals instead of throwing) and that `PaneZoom`
returns through every one of its six steps.

Two things that came out of pressing rather than reading:

**`Rescan` is POLICY-BLOCKED, not unproven, and this table said the wrong thing.** Its
handler calls `Save-RegistryOrAsk` when `$script:dirty` — it can write the operator's live
registry, which is the class of action that cost 210 conversations in this repo's history.
It is not pressed and must not be.

**`PaneZoom` writes the operator's live `session-restore.config.json`** through
`Save-SRConfigLater`. The button is pressed; the write is stubbed for the duration and the
zoom restored afterwards. Pressing a control to prove it works must not change his
settings — and the test also asserts the save was *requested*, so stubbing it does not
quietly delete the coverage.

**What remains genuinely unreachable** is not a matter of effort. Seven rows need input
that cannot exist on an unshown window: both splitter drags, both title-bar drags, the
reading-pane scroll wheel, the stock scrollbar parts, and `SpBrowse` (a modal OS dialog).
There is no `PresentationSource`, so the event cannot be constructed at all. A further ten
rows have **no handler to press** — `SetName`, `SetModel`, `SetEffort`, `SetRemote`,
`SetHidden`, `SetAllow`/`SetDeny`, `SpName`, `SpModel`/`SpEffort`, `SpRemote`,
`QueueList` — they are declarations read at Apply or Start, and the reading is what the
suite already covers.

---

## 19. Count by verdict

| verdict | count |
|---|---|
| WORKS | 70 |
| UNPROVEN | 19 |
| UNPRESSABLE-BY-POLICY | 21 |
| BROKEN | 0 |
| INERT | 0 |
| split verdict (Shift+Enter WORKS / Enter policy-blocked) | 2 |
| **total rows** | **112** |

Moved since the first audit: `ShellFold` BROKEN → fixed → WORKS; `ShellList` INERT →
given a handler → WORKS; `RailSort`, `ListSort`, `RailOnlyLive`, `RailClear` UNPROVEN →
pressed → WORKS; `Rescan` UNPROVEN → **UNPRESSABLE-BY-POLICY**, because reading it more
carefully showed it can write the registry.

Also moved: `Show-AgentDoc` and `Close-AgentDoc` UNPROVEN → pressed → WORKS; the
round-navigation buttons UNPROVEN → **UNPRESSABLE-BY-POLICY** (they send arrow keys into a
live session — see the row).

⚠️ **That agent-doc pair abstained on its first run for a reason worth keeping.** The test
looked for sub-agents through `Get-RowSubAgents`, which reads `$script:subAgents` — a cache
filled by a background pass that never runs in a spliced window. It answered "none anywhere"
on a machine holding hundreds, and the section reported an honest abstain about the wrong
thing entirely. `Get-SRSubAgents` reads the meta files itself and both controls passed
immediately. A cache consulted outside the loop that fills it reports the state you already
had, which here was none.

Of the 19 still unproven, **17 cannot be reached at all** — seven need a shown window, ten
have no handler. The honest remaining figure is **two**: the agent-doc fold (the same handler
shape as the pane fold, which is covered) and the `RailList` right-click's project branch,
which needs a generated item container.

Plus §17, which lists the surfaces that look like controls and carry no handler by design
— recorded so a later sweep does not re-open them as findings.
