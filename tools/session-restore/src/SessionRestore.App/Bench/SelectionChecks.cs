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
                    $"{agents.Count} row(s) after it: {string.Join(", ", agents.Select(a => a.SubName))}"));

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

                checks.Add(new HandlerChecks.Check(
                    "the pane's dot breathes while a conversation is mid-turn, and stops when it is not",
                    breathing && still,
                    $"mid-turn animated {breathing}, then animated {w.PaneStateDot.HasAnimatedProperties} at opacity {w.PaneStateDot.Opacity.ToString("0.00", CultureInfo.InvariantCulture)}"));
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
