using System.Globalization;
using System.IO;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Threading;
using SessionRestore.App.Services;
using SessionRestore.App.ViewModels;
using SessionRestore.App.Views;
using SessionRestore.Core.Registry;
using SessionRestore.Core.Rows;
using SessionRestore.Core.Sessions;

namespace SessionRestore.App.Bench;

/// <summary>
/// Plan item 4.2c - selection: the pane's header, and a conversation's
/// sub-agents appearing under it.
/// </summary>
/// <remarks>
/// 🔴 THE MODEL IS BUILT, NOT READ. A green over the live registry proves only
/// the paths this machine happens to reach - and "a conversation with sub-agents,
/// on the surface, one of them still writing" is a coincidence, not a state the
/// check can rely on. Everything below runs over conversations written into a
/// temp directory for the purpose, so every rule has a row that reaches it.
///
/// 🔴 IT STILL DRIVES REAL EVENTS. The selection is made by setting the
/// ListBox's <c>SelectedItem</c> and pumping the dispatcher, so what runs is the
/// handler the window wires - not a method called directly, which is how three
/// checks in Phase 3 passed while the thing they named was untrue.
///
/// 🪤 AND THE TEMP DIRECTORY GOES IN A FINALLY. A bare mkdtemp that leaks
/// degrades every later session on this machine.
/// </remarks>
public static class SelectionChecks
{
    /// <summary>Enough rows that the view's sort is introsort rather than a stable insertion sort.</summary>
    private const int Filler = 35;

    public static IReadOnlyList<HandlerChecks.Check> Run()
    {
        var checks = new List<HandlerChecks.Check>();
        var dir = Path.Combine(Path.GetTempPath(), "sr-select-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(dir);
        try
        {
            // Two conversations: one with agents beside it, one without.
            var withAgents = Conversation(dir, "aaaaaaaa-0000-0000-0000-000000000001", "has agents");
            var plain = Conversation(dir, "bbbbbbbb-0000-0000-0000-000000000002", "no agents");

            // 🔑 THREE AGENTS, ONE OF EACH STATE the row can draw: still
            // writing, finished, and one that left no transcript at all - 45 of
            // 374 on this machine are that last one.
            Agent(withAgents, "agent-live", "scout", "general-purpose", "sweep the callers", DateTime.Now, transcript: true);
            Agent(withAgents, "agent-done", "archivist", "general-purpose", "read the log", DateTime.Now.AddHours(-3), transcript: true);
            Agent(withAgents, "agent-bare", "ghost", "explorer", string.Empty, DateTime.Now.AddHours(-9), transcript: false);

            var model = new List<(string Id, RegistrySession Session, RegistryDirectory Directory)>
            {
                (withAgents.Session.SessionId, withAgents.Session, withAgents.Dir),
                (plain.Session.SessionId, plain.Session, plain.Dir),
            };

            // 🔴 THIRTY-FIVE MORE, AND THE NUMBER IS THE POINT. The first
            // version of this check ran over two conversations and stayed GREEN
            // when the SubOrder sort key was deleted: Array.Sort - what a
            // ListCollectionView sorts with - falls back to INSERTION SORT below
            // sixteen elements, and insertion sort is stable, so the agent rows
            // stayed beside their parent for a reason that has nothing to do
            // with the code being right. Above the threshold it is introsort and
            // ties are scattered. A check that cannot go red is not a check.
            for (var i = 0; i < Filler; i++)
            {
                var f = Conversation(dir, string.Format(CultureInfo.InvariantCulture, "cccccccc-0000-0000-0000-{0:D12}", i), "filler " + i.ToString("D2", CultureInfo.InvariantCulture));
                f.Session.LastActive = DateTimeOffset.Now.AddMinutes(-i - 1);
                model.Add((f.Session.SessionId, f.Session, f.Dir));
            }

            // 🔑 ONE CONVERSATION THAT IS ACTUALLY RUNNING, so the collapsed
            // strip has a mark on it at all. The strip only carries the three
            // bands that are asking something of you.
            var busy = Conversation(dir, "dddddddd-0000-0000-0000-000000000003", "mid turn");
            model.Add((busy.Session.SessionId, busy.Session, busy.Dir));
            var agentMap = new Dictionary<string, AgentStatus>(StringComparer.OrdinalIgnoreCase)
            {
                [busy.Session.SessionId] = new(busy.Session.SessionId, "busy", string.Empty, false, 4242,
                                               "interactive", "mid turn", dir, DateTimeOffset.Now.AddMinutes(-2)),
            };

            var vm = new SessionsVm();
            vm.Sync(model, agents: agentMap);

            var w = new SessionsWindow
            {
                WindowStartupLocation = WindowStartupLocation.Manual,
                Left = -32000,
                Top = -32000,
                Width = 1480,
                ShowInTaskbar = false,
                ShowActivated = false,
                IsHitTestVisible = false,
            };
            var shell = new WindowShell(w, vm, new NoPreferences(), new NoActs(), new NoConfirms());
            shell.Attach();
            w.Show();
            try
            {
                Pump(w);

                var head = vm.Rows.First(r => string.Equals(r.Id, withAgents.Session.SessionId, StringComparison.OrdinalIgnoreCase));
                var other = vm.Rows.First(r => string.Equals(r.Id, plain.Session.SessionId, StringComparison.OrdinalIgnoreCase));

                // ---- 1. the header
                w.SessionList.SelectedItem = head;
                Pump(w);
                var expected = PaneHeader.OfSession(head.Title, head.Band, head.Detail, head.ProjectLabel, head.Busy);
                checks.Add(new HandlerChecks.Check(
                    "selecting a conversation names it in the pane and says what it is doing",
                    string.Equals(vm.SelectedId, head.Id, StringComparison.Ordinal)
                    && string.Equals(w.PaneName.Text, expected.Name, StringComparison.Ordinal)
                    && string.Equals(w.PaneState.Text, expected.State, StringComparison.Ordinal),
                    $"'{w.PaneName.Text}' / '{w.PaneState.Text}'"));

                // ---- 2. the agents, under it, in the view
                var rows = View(w);
                var at = rows.FindIndex(r => ReferenceEquals(r, head));
                var agents = rows.Skip(at + 1).TakeWhile(r => r is AgentRowVm).Cast<AgentRowVm>().ToList();
                // 🔴 ONE ROW, NOT THREE. Three agents are on disk and two of
                // them finished hours ago; the column answers "what is happening
                // now". The port listed all three until a render was looked at.
                checks.Add(new HandlerChecks.Check(
                    "only the sub-agent that is still working appears under it",
                    at >= 0 && agents.Count == 1
                    && string.Equals(agents[0].SubName, "scout", StringComparison.Ordinal),
                    $"{agents.Count} row(s) after it: {string.Join(", ", agents.Select(a => a.SubName))}"
                    + " | at=" + at.ToString(CultureInfo.InvariantCulture)
                    + " around: " + string.Join(" / ", rows.Skip(Math.Max(0, at - 1)).Take(4).Select(r =>
                        r is AgentRowVm av ? "AGENT:" + av.SubName + "#" + av.SubOrder.ToString(CultureInfo.InvariantCulture) + " k=" + av.SortKey
                        : r is ConversationVm cv ? cv.SortTitle + "#" + cv.SubOrder.ToString(CultureInfo.InvariantCulture) + " k=" + cv.SortKey
                        : "?"))));

                // ---- 3. what the row says about itself
                var live = agents.FirstOrDefault(a => string.Equals(a.SubName, "scout", StringComparison.Ordinal));
                checks.Add(new HandlerChecks.Check(
                    "a working agent says so, and says what it was asked to do",
                    live?.SubTag == "task  -  working"
                    && live?.SubDesc == "sweep the callers"
                    && Math.Abs((live?.SubOpacity ?? 0) - 1.0) < 0.001,
                    $"'{live?.SubTag}' / '{live?.SubDesc}'"));

                // ---- 4. they follow their parent through a sort
                vm.Sort = SessionSort.Name;
                Pump(w);
                var sorted = View(w);
                var atName = sorted.FindIndex(r => ReferenceEquals(r, head));
                var stillUnder = atName >= 0
                    && sorted.Skip(atName + 1).TakeWhile(r => r is AgentRowVm).Count() == 1;
                vm.Sort = SessionSort.Recent;
                Pump(w);
                checks.Add(new HandlerChecks.Check(
                    "sorting the column by name keeps every agent under its own conversation",
                    stillUnder,
                    $"1 expected, {(atName < 0 ? "the parent left the view" : sorted.Skip(atName + 1).TakeWhile(r => r is AgentRowVm).Count() + " found")}"));

                // ---- 5. selecting an agent opens it and keeps the parent's rows
                var pick = View(w).OfType<AgentRowVm>().First();
                w.SessionList.SelectedItem = pick;
                Pump(w);
                var agentHead = PaneHeader.OfAgent(pick.Agent, head.Title);
                checks.Add(new HandlerChecks.Check(
                    "selecting a sub-agent opens the agent and leaves its conversation expanded",
                    string.Equals(vm.SelectedId, pick.Id, StringComparison.Ordinal)
                    && string.Equals(w.PaneName.Text, agentHead.Name, StringComparison.Ordinal)
                    && string.Equals(w.PaneState.Text, agentHead.State, StringComparison.Ordinal)
                    && View(w).OfType<AgentRowVm>().Any(),
                    $"'{w.PaneState.Text}', {View(w).OfType<AgentRowVm>().Count()} agent row(s) still shown"));

                // ---- 5b. and it stays once it stops writing
                // 🪤 AN AGENT HAS USUALLY JUST GONE QUIET BY THE TIME YOU OPEN
                // IT. Filtering to what is live before checking the selection
                // would delete the row under the cursor on the very next pass,
                // and the list would fight the click. Aged here on purpose.
                Age(withAgents, "agent-live", DateTime.Now.AddHours(-1));
                shell.Select(pick);
                Pump(w);
                var kept = View(w).OfType<AgentRowVm>()
                    .FirstOrDefault(a => string.Equals(a.Id, pick.Id, StringComparison.Ordinal));
                checks.Add(new HandlerChecks.Check(
                    "the sub-agent being read stays on the list once it stops writing, and says finished",
                    kept is not null && kept.SubTag == "task  -  finished",
                    kept is null ? "the row was taken away" : $"'{kept.SubTag}'"));

                // ---- 6. another conversation takes them away
                w.SessionList.SelectedItem = other;
                Pump(w);
                checks.Add(new HandlerChecks.Check(
                    "selecting another conversation takes the first one's agent rows away",
                    !View(w).OfType<AgentRowVm>().Any()
                    && string.Equals(w.PaneName.Text, other.Title, StringComparison.Ordinal),
                    $"{View(w).OfType<AgentRowVm>().Count()} agent row(s) left, pane on '{w.PaneName.Text}'"));

                // ---- 7. the collapsed strip selects without re-opening the column
                shell.Select(other);
                Pump(w);
                var stripOk = false;
                var stripDetail = "nothing on the strip";
                var strip = shell.StripItems();
                var mark = strip.Count > 0 ? strip[0] : null;
                if (mark is not null)
                {
                    w.ListFold.RaiseEvent(new System.Windows.Input.MouseButtonEventArgs(
                        System.Windows.Input.Mouse.PrimaryDevice, 0, System.Windows.Input.MouseButton.Left)
                    { RoutedEvent = UIElement.MouseLeftButtonUpEvent });
                    Pump(w);
                    var folded = w.ListStrip.Visibility == Visibility.Visible;

                    // 🪤 PreviewMouseUP, NOT PreviewMouseLeftButtonUp. The
                    // left-button events are DIRECT, raised on each element of
                    // the route by a class handler - so raising one on the
                    // mark's container reaches the container and nothing above
                    // it, and the strip's handler never runs. A real click is a
                    // PreviewMouseUp. The rail learned this the same way.
                    // 🪤 THE STRIP IS AN ItemsControl, NOT A ListBox, so its
                    // container is a ContentPresenter - a `is ListBoxItem` test
                    // simply found nothing and the check failed while the
                    // handler was correct.
                    if (w.StripList.ItemContainerGenerator.ContainerFromItem(mark) is UIElement mc)
                    {
                        mc.RaiseEvent(new System.Windows.Input.MouseButtonEventArgs(
                            System.Windows.Input.Mouse.PrimaryDevice, 0, System.Windows.Input.MouseButton.Left)
                        { RoutedEvent = UIElement.PreviewMouseUpEvent });
                        Pump(w);
                    }

                    stripOk = folded
                        && string.Equals(vm.SelectedId, mark.Id, StringComparison.OrdinalIgnoreCase)
                        && w.ListStrip.Visibility == Visibility.Visible;
                    stripDetail = $"folded {folded}, selected '{vm.SelectedId}', still folded {w.ListStrip.Visibility == Visibility.Visible}";
                }

                checks.Add(new HandlerChecks.Check(
                    "a mark on the collapsed strip opens that conversation without re-opening the column",
                    stripOk,
                    stripDetail));

                // ---- 8. the dot breathes while it is thinking, and only then
                // 🔴 BOTH HALVES, IN ONE CHECK. Asserting only that it is still
                // for a quiet conversation passes just as well when the animation
                // was never started for anything - which is the shape of every
                // check Phase 3 had to be told what it was for.
                //
                // 🪤 AND STOPPING MEANS CLEARING THE ANIMATION, not setting the
                // opacity back to 1. An animation left running holds the property
                // hostage and the later assignment is ignored, so the dot keeps
                // breathing on a conversation that has stopped.
                var busyRow = vm.Rows.First(r => string.Equals(r.Id, busy.Session.SessionId, StringComparison.OrdinalIgnoreCase));
                shell.Select(busyRow);
                Pump(w);
                var breathing = w.PaneStateDot.HasAnimatedProperties;

                shell.Select(other);
                Pump(w);
                var still = !w.PaneStateDot.HasAnimatedProperties
                            && Math.Abs(w.PaneStateDot.Opacity - 1.0) < 0.001;

                // ---- 8a. and it breathes the way the shipped one does
                //
                // 🔴 THE ELEMENT, NOT THE TABLE IT READS. anim/pulse compares
                // the NUMBERS against New-SRPulse, and that check passes just as
                // well if the dot is animated by something else entirely - which
                // is exactly what had happened: 4.2c wrote 1.0 to 0.35 with no
                // easing straight into the shell, every check went green, and
                // the dot read as a fault light rather than as breathing.
                //
                // 🪤 SO IT IS SAMPLED OFF THE DOT. A fade that stops at 0.35
                // NEVER reaches 0.3, whatever the table says; one that goes to
                // 0.25 does, within a half-breath. What is asserted is the thing
                // the operator can see.
                shell.Select(busyRow);
                Pump(w);
                var lowest = 1.0;
                for (var i = 0; i < 40; i++)
                {
                    Pump(w);
                    lowest = Math.Min(lowest, w.PaneStateDot.Opacity);
                    Thread.Sleep(30);
                }

                checks.Add(new HandlerChecks.Check(
                    "the dot really fades to the shipped floor, not to a higher one",
                    lowest <= Core.Rows.Pulse.To + 0.02,
                    string.Format(CultureInfo.InvariantCulture, "it reached {0:0.000}, floor is {1:0.00}",
                        lowest, Core.Rows.Pulse.To)));

                shell.Select(other);
                Pump(w);

                checks.Add(new HandlerChecks.Check(
                    "the pane's dot breathes while a conversation is mid-turn, and stops when it is not",
                    breathing && still,
                    $"mid-turn animated {breathing}, then animated {w.PaneStateDot.HasAnimatedProperties} at opacity {w.PaneStateDot.Opacity.ToString("0.00", CultureInfo.InvariantCulture)}"));

                // ---- 8b. and the sort still SORTS
                //
                // 🔴 THE OTHER HALF OF THE QUESTION, AND PHASE 3 HAD TO LEARN IT
                // THREE TIMES. "The view answers a sort without a Reset" is
                // satisfied perfectly by a view that has stopped sorting - and
                // when the sort moved off SortDescriptions and onto a key the
                // rows carry, that check went from "2 x Reset" to "the view
                // raised nothing", which is the same sentence either way. A
                // check that asks only what must NOT happen never asks whether
                // the thing itself still works.
                vm.Sort = SessionSort.Name;
                Pump(w);
                var byName = Titles(w);

                vm.Sort = SessionSort.Recent;
                Pump(w);
                var byRecent = Titles(w);

                vm.Sort = SessionSort.Project;
                Pump(w);
                var byProject = Titles(w);

                var nameSorted = byName.SequenceEqual(byName.OrderBy(t => t, StringComparer.Ordinal));
                checks.Add(new HandlerChecks.Check(
                    "sorting by name really orders the column by name",
                    byName.Count > 16 && nameSorted,
                    string.Format(CultureInfo.InvariantCulture, "{0} row(s), in order: {1}, first: {2}",
                        byName.Count, nameSorted, byName.Count > 0 ? byName[0] : "(none)")));

                checks.Add(new HandlerChecks.Check(
                    "and each sort gives a different order from the others",
                    !byName.SequenceEqual(byRecent, StringComparer.Ordinal)
                    && !byRecent.SequenceEqual(byProject, StringComparer.Ordinal),
                    string.Format(CultureInfo.InvariantCulture, "name first '{0}', recent first '{1}', project first '{2}'",
                        byName.Count > 0 ? byName[0] : "-",
                        byRecent.Count > 0 ? byRecent[0] : "-",
                        byProject.Count > 0 ? byProject[0] : "-")));

                // 🔑 AND BACK, so the rest of the block runs on the order it
                // expects rather than on whatever the last case left.
                vm.Sort = SessionSort.Recent;
                Pump(w);

                // ---- 8c. and a conversation that just spoke rises to the top
                //
                // 🔴 THE REASON LIVE SORTING IS ON AT ALL, and until now nothing
                // asserted it. Turning it off was considered in Phase 3 and
                // rejected on exactly this ground: a conversation whose
                // lastActive moves on a background refresh has to rise in a
                // recent-first list rather than sit where it was. An untested
                // reason is a reason that stops being true.
                var oldest = vm.Rows
                    .Where(r => string.Equals(r.BandLabel, Bands.LabelOf(Bands.Quiet), StringComparison.Ordinal))
                    .OrderBy(r => r.LastActiveTicks)
                    .First();
                var wasAt = Titles(w).IndexOf(oldest.SortTitle);

                oldest.Session.LastActive = DateTimeOffset.Now.AddSeconds(5);
                vm.Sync(model, agents: agentMap);
                Pump(w);
                var nowAt = Titles(w).IndexOf(oldest.SortTitle);

                checks.Add(new HandlerChecks.Check(
                    "a conversation that just spoke rises to the top of a recent-first column",
                    wasAt > 0 && nowAt == 0,
                    string.Format(CultureInfo.InvariantCulture, "'{0}' was at {1}, now at {2}",
                        oldest.SortTitle, wasAt, nowAt)));

                // ---- 9. the band pick, pressed on the heading itself
                //
                // 🔴 THE HEADINGS ALL STAY, AND THAT IS THE WHOLE DIFFICULTY.
                // A grouped view builds its headings FROM its items, so the
                // obvious implementation - filter the other bands out - takes
                // their headings and their counts with them, and the only way
                // back is a control that is now off screen. The rows are hidden
                // instead.
                // 🔴 WITH THE AGENT-BEARING CONVERSATION OPEN, and that is not
                // arrangement for its own sake. The first version of this block
                // ran with a conversation that has no sub-agents selected, so
                // there were no agent rows in the column at all - and deleting
                // the line that makes an agent follow its parent out of a picked
                // band stayed GREEN. A check has to be standing somewhere the
                // rule applies.
                // 🪤 AND WITH ITS AGENT WRITING AGAIN. Check 5b aged this one to
                // an hour ago on purpose, so by here the column has no live
                // sub-agent at all - which is why the first version of the check
                // below found nothing to hold and passed with zero rows.
                Age(withAgents, "agent-live", DateTime.Now);
                shell.Select(head);
                Pump(w);

                var groupsBefore = Groups(w);
                var headings = groupsBefore.Select(g => g.Name as string ?? string.Empty).ToList();
                var countsBefore = groupsBefore.Select(g => g.ItemCount).ToList();

                var target = vm.Rows.First(r => string.Equals(r.Id, busy.Session.SessionId, StringComparison.OrdinalIgnoreCase));
                var pickLabel = target.BandLabel;

                // The real event, on the real heading, through the real handler.
                PressHeading(w, pickLabel);
                Pump(w);

                var groupsAfter = Groups(w);
                var headingsKept = groupsAfter.Select(g => g.Name as string ?? string.Empty).ToList();
                var countsAfter = groupsAfter.Select(g => g.ItemCount).ToList();

                checks.Add(new HandlerChecks.Check(
                    "picking a band keeps every heading and every count",
                    headings.Count > 1
                    && headingsKept.SequenceEqual(headings, StringComparer.Ordinal)
                    && countsAfter.SequenceEqual(countsBefore),
                    string.Format(CultureInfo.InvariantCulture, "{0} heading(s) before, {1} after: {2}",
                        headings.Count, headingsKept.Count, string.Join(" / ", headingsKept))));

                var drawn = vm.Rows.Count(r => r.Listed);
                var inBand = vm.Rows.Count(r => string.Equals(r.BandLabel, pickLabel, StringComparison.Ordinal));
                checks.Add(new HandlerChecks.Check(
                    "and draws only that band's conversations",
                    Pressed
                    && string.Equals(vm.BandPick, pickLabel, StringComparison.Ordinal)
                    && drawn == inBand && inBand > 0 && drawn < vm.Rows.Count(),
                    string.Format(CultureInfo.InvariantCulture, "heading found {0}, picked '{1}', {2} of {3} drawn",
                        Pressed, vm.BandPick, drawn, vm.Rows.Count()) + " [" + Where + "]"));

                // 🔑 THE CONTAINER IS WHAT ACTUALLY HIDES IT. Listed being false
                // and the row still on screen is the failure this whole approach
                // is exposed to, so the check asks the ListBox, not the model.
                var hidden = vm.Rows.FirstOrDefault(r => !r.Listed);
                var hiddenVis = Visibility.Visible;
                if (hidden is not null)
                {
                    w.SessionList.ScrollIntoView(hidden);
                    Pump(w);
                    hiddenVis = w.SessionList.ItemContainerGenerator.ContainerFromItem(hidden) is UIElement c
                        ? c.Visibility
                        : Visibility.Collapsed;
                }

                checks.Add(new HandlerChecks.Check(
                    "a row in a band that was not picked is not drawn at all",
                    hidden is not null && hiddenVis == Visibility.Collapsed,
                    hidden is null ? "nothing was hidden" : $"'{hidden.SortTitle}' is {hiddenVis}"));

                // Pressing it again gives every conversation back.
                PressHeading(w, pickLabel);
                Pump(w);
                checks.Add(new HandlerChecks.Check(
                    "pressing the same heading again shows every conversation",
                    vm.BandPick is null && vm.Rows.All(r => r.Listed),
                    string.Format(CultureInfo.InvariantCulture, "pick '{0}', {1} of {2} drawn",
                        vm.BandPick ?? "(none)", vm.Rows.Count(r => r.Listed), vm.Rows.Count())));

                // 🪤 AND A CLICK ON A ROW IS NOT A CLICK ON ITS HEADING. The
                // walk up the tree stops at the ListBoxItem, or every click in
                // the column would find the group above it and toggle the band.
                if (w.SessionList.ItemContainerGenerator.ContainerFromItem(target) is UIElement rowC)
                {
                    rowC.RaiseEvent(new System.Windows.Input.MouseButtonEventArgs(
                        System.Windows.Input.Mouse.PrimaryDevice, 0, System.Windows.Input.MouseButton.Left)
                    { RoutedEvent = UIElement.PreviewMouseDownEvent });
                    Pump(w);
                }

                // ---- 10. the heading has to LOOK pressed
                //
                // 🔴 NOTHING ELSE ASSERTS THIS, AND THE BREAK PROVED IT: cutting
                // the PropertyChanged that tells the headings the pick moved left
                // every check above green. The column would narrow with no sign
                // of why, which reads as rows going missing rather than as a
                // choice - and the way back is the heading you cannot see is
                // pressed.
                PressHeading(w, pickLabel);
                Pump(w);

                var pickedBg = HeadingGround(w, pickLabel);
                var otherLabel = headings.First(h => !string.Equals(h, pickLabel, StringComparison.Ordinal));
                var otherBg = HeadingGround(w, otherLabel);
                var sel = w.TryFindResource("SelBg") as System.Windows.Media.Brush;

                checks.Add(new HandlerChecks.Check(
                    "the picked heading takes the selected ground and the others stay transparent",
                    sel is not null && ReferenceEquals(pickedBg, sel)
                    && ReferenceEquals(otherBg, System.Windows.Media.Brushes.Transparent),
                    string.Format(CultureInfo.InvariantCulture, "'{0}' {1}, '{2}' {3}",
                        pickLabel, Describe(pickedBg), otherLabel, Describe(otherBg))));

                checks.Add(new HandlerChecks.Check(
                    "and says 'only this' beside that heading alone",
                    string.Equals(HeadingHint(w, pickLabel), BandPickedHint.Hint, StringComparison.Ordinal)
                    && HeadingHint(w, otherLabel).Length == 0,
                    string.Format(CultureInfo.InvariantCulture, "'{0}' says '{1}', '{2}' says '{3}'",
                        pickLabel, HeadingHint(w, pickLabel), otherLabel, HeadingHint(w, otherLabel))));

                // ---- 11. a sub-agent leaves with its conversation
                var inModel = vm.Items.OfType<AgentRowVm>().ToList();
                var agentRows = View(w).OfType<AgentRowVm>().ToList();
                var agentDrawn = agentRows.Count(r => r.Listed);
                checks.Add(new HandlerChecks.Check(
                    "a sub-agent is not drawn when its conversation's band is not the picked one",
                    inModel.Count > 0 && agentDrawn == 0 && inModel.All(r => !r.Listed)
                    && !string.Equals(head.BandLabel, pickLabel, StringComparison.Ordinal),
                    string.Format(CultureInfo.InvariantCulture,
                        "{0} in the model, {1} in the view, {2} drawn, parent in '{3}', picked '{4}'",
                        inModel.Count, agentRows.Count, agentDrawn, head.BandLabel, vm.BandPick)));

                // ---- 11b. and one that appears WHILE a band is picked
                //
                // 🔴 THE ROW IS BUILT, NOT MOVED. Selecting a conversation makes
                // its agent rows from nothing, so the pick has to reach them at
                // construction - a row that started out drawn put sub-agents on
                // screen under a heading whose own conversations were hidden.
                shell.Select(other);
                Pump(w);
                shell.Select(head);
                Pump(w);
                var madeUnderAPick = vm.Items.OfType<AgentRowVm>().ToList();
                checks.Add(new HandlerChecks.Check(
                    "a sub-agent row built while a band is picked is not drawn either",
                    madeUnderAPick.Count > 0 && madeUnderAPick.All(r => !r.Listed),
                    string.Format(CultureInfo.InvariantCulture, "{0} row(s) made, {1} drawn",
                        madeUnderAPick.Count, madeUnderAPick.Count(r => r.Listed))));

                PressHeading(w, pickLabel);
                Pump(w);

                checks.Add(new HandlerChecks.Check(
                    "clicking a conversation does not pick its band",
                    vm.BandPick is null,
                    "pick '" + (vm.BandPick ?? "(none)") + "'"));
            }
            finally
            {
                w.Close();
            }
        }
        finally
        {
            try
            {
                Directory.Delete(dir, recursive: true);
            }
            catch (IOException)
            {
            }
        }

        return checks;
    }

    /// <summary>The ground behind one band's heading, as the window actually drew it.</summary>
    private static System.Windows.Media.Brush? HeadingGround(SessionsWindow w, string band) =>
        InHeading<Border>(w, band)?.Background;

    /// <summary>The words beside one band's heading - "only this", or nothing.</summary>
    private static string HeadingHint(SessionsWindow w, string band)
    {
        var header = HeaderOf(w, band);
        if (header is null)
        {
            return "(no heading)";
        }

        foreach (var t in Everything(header).OfType<TextBlock>())
        {
            if (string.Equals(t.Text, BandPickedHint.Hint, StringComparison.Ordinal))
            {
                return t.Text;
            }
        }

        // The hint TextBlock is the one after the count; empty is the answer
        // when nothing is picked, and it has to be told apart from "no heading".
        return string.Empty;
    }

    private static string Describe(System.Windows.Media.Brush? b) =>
        b is System.Windows.Media.SolidColorBrush s
            ? s.Color.ToString(CultureInfo.InvariantCulture)
            : b?.GetType().Name ?? "null";

    private static GroupItem? HeaderOf(SessionsWindow w, string band)
    {
        var group = Groups(w).FirstOrDefault(g => string.Equals(g.Name as string, band, StringComparison.Ordinal));
        return group is null ? null : Headers(w).FirstOrDefault(h => ReferenceEquals(h.DataContext, group));
    }

    /// <summary>The first element of a kind that belongs to the HEADING, not to a row under it.</summary>
    private static T? InHeading<T>(SessionsWindow w, string band)
        where T : FrameworkElement
    {
        var header = HeaderOf(w, band);
        if (header is null)
        {
            return null;
        }

        foreach (var e in Everything(header).OfType<T>())
        {
            if (ReferenceEquals(e.DataContext, header.DataContext))
            {
                return e;
            }
        }

        return null;
    }

    private static IEnumerable<DependencyObject> Everything(DependencyObject root)
    {
        for (var i = 0; i < System.Windows.Media.VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = System.Windows.Media.VisualTreeHelper.GetChild(root, i);
            yield return child;
            foreach (var deeper in Everything(child))
            {
                yield return deeper;
            }
        }
    }

    /// <summary>
    /// Whether the last <see cref="PressHeading"/> actually found a heading to
    /// press.
    /// </summary>
    /// <remarks>
    /// 🔴 A CHECK THAT CANNOT TELL MUST NOT PRINT GREEN, and the shape here is
    /// the one this repo keeps meeting: "the band is not picked" is what a press
    /// that never happened looks like AND what a broken handler looks like. The
    /// two are different findings and the check has to say which.
    /// </remarks>
    private static bool Pressed { get; set; }

    /// <summary>What the press actually landed on, for the detail line.</summary>
    private static string Where { get; set; } = string.Empty;

    /// <summary>
    /// The conversations the column is showing, in the order it shows them -
    /// within ONE band, so a band order that never changes cannot make two
    /// different sorts look the same.
    /// </summary>
    private static List<string> Titles(SessionsWindow w) =>
        [.. View(w).OfType<ConversationVm>()
            .Where(r => string.Equals(r.BandLabel, Bands.LabelOf(Bands.Quiet), StringComparison.Ordinal))
            .Select(r => r.SortTitle)];

    /// <summary>The view's groups - one per band that has anything in it.</summary>
    private static List<CollectionViewGroup> Groups(SessionsWindow w) =>
        [.. (w.SessionList.ItemsSource as ListCollectionView)?.Groups?.OfType<CollectionViewGroup>() ?? []];

    /// <summary>
    /// Presses one band's heading the way a mouse does.
    /// </summary>
    /// <remarks>
    /// 🪤 THE HEADING IS NOT AN ITEM CONTAINER, so there is nothing to ask the
    /// generator for. It lives inside the GroupItem the panel builds for that
    /// group, and the only way to reach it is down the visual tree - which means
    /// the group has to have been REALISED, so this scrolls to the group's first
    /// row first.
    /// </remarks>
    private static void PressHeading(SessionsWindow w, string band)
    {
        var group = Groups(w).FirstOrDefault(g => string.Equals(g.Name as string, band, StringComparison.Ordinal));
        if (group?.Items.Count > 0)
        {
            w.SessionList.ScrollIntoView(group.Items[0]);
            Pump(w);
        }

        // 🪤 BY DATA CONTEXT, NOT BY Content. A GroupItem's Content is set from
        // the group, but what the heading's own elements inherit - and what the
        // handler walks up looking for - is the DataContext. Matching on Content
        // found nothing, the press never happened, and two checks read as a
        // broken handler while the handler had never run.
        var header = Headers(w).FirstOrDefault(h => ReferenceEquals(h.DataContext, group));
        Pressed = header is not null;
        var target = header is null || group is null ? null : Down(header, group);
        Where = target is null
            ? "no element in the heading"
            : target.GetType().Name + " ctx=" + (((target as FrameworkElement)?.DataContext)?.GetType().Name ?? "null");
        // 🪤 PreviewMouseDown, NOT PreviewMouseLeftButtonDown. The Left variant
        // is a DIRECT routed event: raised on a leaf it reaches that leaf and
        // nothing above it, so the column's handler never ran and two checks
        // read as a broken handler for the second time in one afternoon. A real
        // click routes PreviewMouseDown, which every element on the way re-raises
        // as the Left variant on ITSELF. The strip learned this the same way, and
        // so did the rail.
        target?.RaiseEvent(new System.Windows.Input.MouseButtonEventArgs(
            System.Windows.Input.Mouse.PrimaryDevice, 0, System.Windows.Input.MouseButton.Left)
        { RoutedEvent = UIElement.PreviewMouseDownEvent });
    }

    private static IEnumerable<GroupItem> Headers(DependencyObject root)
    {
        for (var i = 0; i < System.Windows.Media.VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = System.Windows.Media.VisualTreeHelper.GetChild(root, i);
            if (child is GroupItem g)
            {
                yield return g;
            }

            foreach (var deeper in Headers(child))
            {
                yield return deeper;
            }
        }
    }

    /// <summary>
    /// An element inside the HEADING that a mouse could land on.
    /// </summary>
    /// <remarks>
    /// 🪤 A GroupItem CONTAINS ITS ROWS AS WELL AS ITS HEADING. The first
    /// version took the first TextBlock anywhere under it, which is a
    /// conversation's own title - and the handler correctly refused to read a
    /// band out of a row, so the press did nothing and two checks read as a
    /// broken handler. The heading's elements are the ones whose DataContext is
    /// still the GROUP.
    /// </remarks>
    private static UIElement? Down(DependencyObject from, object group)
    {
        for (var i = 0; i < System.Windows.Media.VisualTreeHelper.GetChildrenCount(from); i++)
        {
            var child = System.Windows.Media.VisualTreeHelper.GetChild(from, i);
            if (child is FrameworkElement fe && !ReferenceEquals(fe.DataContext, group))
            {
                continue;
            }

            if (child is TextBlock t)
            {
                return t;
            }

            if (Down(child, group) is { } deeper)
            {
                return deeper;
            }
        }

        return null;
    }

    private sealed record Made(RegistrySession Session, RegistryDirectory Dir, string Jsonl);

    private static Made Conversation(string root, string id, string title)
    {
        var project = Path.Combine(root, "project");
        Directory.CreateDirectory(project);
        var jsonl = Path.Combine(project, id + ".jsonl");
        File.WriteAllText(jsonl, string.Empty);
        return new Made(
            new RegistrySession
            {
                SessionId = id,
                Title = title,
                Enabled = true,
                LastActive = DateTimeOffset.Now,
                Jsonl = jsonl,
                Cwd = project,
                Lane = "main",
            },
            new RegistryDirectory { Path = project, Enabled = true },
            jsonl);
    }

    /// <summary>
    /// One sub-agent on disk: the meta beside the conversation, and its own
    /// transcript if it left one.
    /// </summary>
    /// <remarks>
    /// 🔑 THE MTIME IS THE EVIDENCE OF LIFE. A sub-agent has no process to ask -
    /// it runs inside its parent - so a file written in the last three minutes is
    /// the only thing that says it is still going. Setting the time is what makes
    /// "working" and "finished" both reachable here.
    /// </remarks>
    private static void Agent(Made of, string stem, string name, string type, string description, DateTime when, bool transcript)
    {
        var dir = Core.Sessions.SubAgents.Directory(of.Jsonl);
        Directory.CreateDirectory(dir);
        var meta = new JsonObject
        {
            ["name"] = name,
            ["agentType"] = type,
            ["description"] = description,
        };
        var metaPath = Path.Combine(dir, stem + ".meta.json");
        File.WriteAllText(metaPath, meta.ToJsonString());
        File.SetLastWriteTime(metaPath, when);

        if (transcript)
        {
            var t = Path.Combine(dir, stem + ".jsonl");
            File.WriteAllText(t, "{\"type\":\"user\"}\n");
            File.SetLastWriteTime(t, when);
        }
    }

    /// <summary>Moves an agent's files back in time, so it reads as finished.</summary>
    private static void Age(Made of, string stem, DateTime when)
    {
        var dir = Core.Sessions.SubAgents.Directory(of.Jsonl);
        foreach (var f in new[] { Path.Combine(dir, stem + ".meta.json"), Path.Combine(dir, stem + ".jsonl") })
        {
            if (File.Exists(f))
            {
                File.SetLastWriteTime(f, when);
            }
        }
    }

    private static List<object> View(SessionsWindow w) =>
        ((CollectionView)w.SessionList.ItemsSource).Cast<object>().ToList();

    /// <summary>
    /// 🔴 A PUMP BEFORE COUNTING, ALWAYS. WPF applies live filtering, grouping
    /// and sorting through the dispatcher, so a count on the next line reads the
    /// PREVIOUS set - which is how a Phase 3 check reported "groups 1 -> 1" for a
    /// row that had moved.
    /// </summary>
    private static void Pump(Window w) =>
        w.Dispatcher.Invoke(static () => { }, DispatcherPriority.ContextIdle);
}
