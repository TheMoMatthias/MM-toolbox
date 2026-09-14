using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Threading;
using SessionRestore.App.Services;
using SessionRestore.App.ViewModels;
using SessionRestore.App.Views;
using SessionRestore.Core.Acting;
using SessionRestore.Core.Registry;
using SessionRestore.Core.Sessions;

namespace SessionRestore.App.Bench;

/// <summary>
/// Plan item 4.2d - the handlers that would act on a conversation, driven
/// through their real events, with nothing behind them that can.
/// </summary>
/// <remarks>
/// 🔴 THE BUTTONS ARE PRESSED. Every one of them. That is only safe - and only
/// worth doing - because the seam behind them is <see cref="NoActs"/>, which
/// performs nothing and records what it was asked: so pressing Relaunch on a
/// conversation asserts that a RELAUNCH was requested, for THAT conversation,
/// after a sheet was shown. A launch verified without launching.
///
/// 🔴 AND THE CONVERSATIONS ARE INVENTED. Not one of them is on this machine:
/// the model is three registry records with pids that belong to nothing, written
/// into a temp directory. The standing rule is that nothing may launch, end or
/// type into a session - not to test, not once, not against what somebody
/// believes is a spare - and a check that CAN reach live state eventually will.
/// </remarks>
public static class ActingChecks
{
    public static IReadOnlyList<HandlerChecks.Check> Run()
    {
        var checks = new List<HandlerChecks.Check>();
        var dir = Path.Combine(Path.GetTempPath(), "sr-acting-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(dir);
        try
        {
            var idle = Made(dir, "11111111-0000-0000-0000-000000000001", "an idle one");
            var busy = Made(dir, "22222222-0000-0000-0000-000000000002", "a busy one");
            var cold = Made(dir, "33333333-0000-0000-0000-000000000003", "a cold one");

            var model = new List<(string Id, RegistrySession Session, RegistryDirectory Directory)>
            {
                (idle.SessionId, idle, Dir(dir)),
                (busy.SessionId, busy, Dir(dir)),
                (cold.SessionId, cold, Dir(dir)),
            };

            // 🪤 PIDS THAT BELONG TO NOTHING. They are never looked up - the seam
            // records the act rather than carrying it out - but a check whose
            // fixture named a REAL pid would be one refactor away from a
            // conversation on this machine.
            var agents = new Dictionary<string, AgentStatus>(StringComparer.OrdinalIgnoreCase)
            {
                [idle.SessionId] = new(idle.SessionId, "idle", string.Empty, false, 999001, "interactive", "an idle one", dir, null),
                [busy.SessionId] = new(busy.SessionId, "busy", string.Empty, false, 999002, "interactive", "a busy one", dir, null),
            };

            var vm = new SessionsVm();
            vm.Sync(model, agents: agents);

            var acts = new NoActs();
            var confirms = new NoConfirms();
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
            var shell = new WindowShell(w, vm, new NoPreferences(), acts, confirms);
            shell.Attach();
            w.Show();
            try
            {
                Pump(w);
                var idleRow = vm.Rows.First(r => string.Equals(r.Id, idle.SessionId, StringComparison.OrdinalIgnoreCase));
                var busyRow = vm.Rows.First(r => string.Equals(r.Id, busy.SessionId, StringComparison.OrdinalIgnoreCase));
                var coldRow = vm.Rows.First(r => string.Equals(r.Id, cold.SessionId, StringComparison.OrdinalIgnoreCase));

                // ---- 1. Stop refuses what it cannot interrupt, and asks for nothing
                Select(w, idleRow);
                acts.Asked.Clear();
                Press(w.PaneStop, w);
                var refusedStop = acts.Asked.Count == 0 && w.Status.Text.StartsWith("it is not mid-turn", StringComparison.Ordinal);

                Select(w, busyRow);
                acts.Asked.Clear();
                Press(w.PaneStop, w);
                var stop = acts.Last;
                checks.Add(new HandlerChecks.Check(
                    "Stop presses Escape in a conversation that is mid-turn, and refuses one that is not",
                    refusedStop
                    && acts.Asked.Count == 1
                    && stop.What == Act.Interrupt
                    && string.Equals(stop.SessionId, busyRow.Id, StringComparison.OrdinalIgnoreCase),
                    $"idle: {(refusedStop ? "refused" : "ACTED")}; busy: {stop.What} on '{stop.Title}'"));

                // ---- 2. and it asks NO sheet, deliberately
                checks.Add(new HandlerChecks.Check(
                    "stopping a turn is not put behind a confirmation - it is the recoverable half of the pair",
                    confirms.Asked.Count == 0,
                    $"{confirms.Asked.Count} sheet(s) shown"));

                // ---- 3. Relaunch shows the sheet FIRST, and obeys a no
                Select(w, idleRow);
                acts.Asked.Clear();
                confirms.Asked.Clear();
                confirms.Answer = false;
                Press(w.PaneRelaunch, w);
                var saidNo = confirms.Asked.Count == 1 && acts.Asked.Count == 0;

                confirms.Answer = true;
                confirms.Asked.Clear();
                Press(w.PaneRelaunch, w);
                var relaunch = acts.Last;
                var sheet = confirms.Asked.Count == 1 ? confirms.Asked[0] : default;
                checks.Add(new HandlerChecks.Check(
                    "Relaunch asks before it acts, and does nothing at all when the answer is no",
                    saidNo
                    && acts.Asked.Count == 1
                    && relaunch.What == Act.Relaunch
                    && sheet.Verb == "Relaunch"
                    && sheet == Relaunch.PaneAsk(idleRow.Agent, idleRow.Title),
                    $"no -> {(saidNo ? "nothing" : "IT ACTED")}; yes -> {relaunch.What} behind '{sheet.Title}'"));

                // ---- 4. a conversation that is not running is OPENED, not relaunched
                Select(w, coldRow);
                acts.Asked.Clear();
                confirms.Asked.Clear();
                Press(w.PaneRelaunch, w);
                var opened = acts.Last;
                var openSheet = confirms.Asked.Count == 1 ? confirms.Asked[0] : default;
                checks.Add(new HandlerChecks.Check(
                    "the same button OPENS a conversation nothing is holding, and says so on the sheet",
                    opened.What == Act.Open && openSheet.Verb == "Open"
                    && openSheet.Title == "Open this conversation",
                    $"{opened.What} behind '{openSheet.Title}' / '{openSheet.Verb}'"));

                // ---- 5. and it refuses one that is mid-turn, without a sheet
                Select(w, busyRow);
                acts.Asked.Clear();
                confirms.Asked.Clear();
                Press(w.PaneRelaunch, w);
                checks.Add(new HandlerChecks.Check(
                    "Relaunch refuses a conversation that is mid-turn before it asks anything",
                    acts.Asked.Count == 0 && confirms.Asked.Count == 0
                    && string.Equals(w.Status.Text, Relaunch.Refusal(busyRow.Agent, busyRow.Title), StringComparison.Ordinal),
                    $"'{w.Status.Text}', {acts.Asked.Count} act(s), {confirms.Asked.Count} sheet(s)"));

                // ---- 6. /compact is text, and it is not confirmed
                Select(w, busyRow);
                acts.Asked.Clear();
                confirms.Asked.Clear();
                Press(w.PaneCompact, w);
                var compact = acts.Last;
                checks.Add(new HandlerChecks.Check(
                    "the compact button types /compact into the conversation, as text and without a sheet",
                    acts.Asked.Count == 1 && compact.What == Act.Send
                    && compact.Detail == "/compact" && confirms.Asked.Count == 0
                    && string.Equals(w.Status.Text, "sent /compact", StringComparison.Ordinal),
                    $"{compact.What} '{compact.Detail}', {confirms.Asked.Count} sheet(s), '{w.Status.Text}'"));

                Select(w, coldRow);
                acts.Asked.Clear();
                Press(w.PaneCompact, w);
                checks.Add(new HandlerChecks.Check(
                    "and it refuses a conversation nothing is holding",
                    acts.Asked.Count == 0
                    && string.Equals(w.Status.Text, "that conversation is not running, so there is nothing to compact", StringComparison.Ordinal),
                    $"'{w.Status.Text}', {acts.Asked.Count} act(s)"));

                // ---- 7. the send box carries what was typed, trimmed
                Select(w, busyRow);
                acts.Asked.Clear();
                w.SendBox.Text = "  check the logs  ";
                Press(w.SendBtn, w);
                var sent = acts.Last;
                checks.Add(new HandlerChecks.Check(
                    "Send types what is in the box into the selected conversation, trimmed",
                    acts.Asked.Count == 1 && sent.What == Act.Send
                    && sent.Detail == "check the logs"
                    && string.Equals(sent.SessionId, busyRow.Id, StringComparison.OrdinalIgnoreCase),
                    $"'{sent.Detail}' to '{sent.Title}'"));

                w.SendBox.Text = "   ";
                acts.Asked.Clear();
                Press(w.SendBtn, w);
                checks.Add(new HandlerChecks.Check(
                    "an empty box sends nothing",
                    acts.Asked.Count == 0,
                    $"{acts.Asked.Count} act(s) asked"));

                // ---- 8. Go to terminal
                Select(w, busyRow);
                acts.Asked.Clear();
                Press(w.PaneGoTo, w);
                var goTo = acts.Last;
                Select(w, coldRow);
                acts.Asked.Clear();
                Press(w.PaneGoTo, w);
                checks.Add(new HandlerChecks.Check(
                    "Go to terminal asks for the running conversation's tab, and refuses one with no terminal",
                    goTo.What == Act.GoTo && acts.Asked.Count == 0
                    && string.Equals(w.Status.Text, "that conversation is not running - there is no terminal to go to", StringComparison.Ordinal),
                    $"running: {goTo.What}; cold: '{w.Status.Text}'"));

                // ---- 9. nothing was written anywhere
                checks.Add(new HandlerChecks.Check(
                    "not one of those acts reached a registry, a console or a process",
                    acts.Saves.Count == 0,
                    $"{acts.Saves.Count} registry write(s) asked for, 0 performed by construction"));
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

    private static RegistrySession Made(string dir, string id, string title)
    {
        var jsonl = Path.Combine(dir, id + ".jsonl");
        File.WriteAllText(jsonl, string.Empty);
        return new RegistrySession
        {
            SessionId = id,
            Title = title,
            Enabled = true,
            LastActive = DateTimeOffset.Now,
            Jsonl = jsonl,
            Cwd = dir,
            Lane = "main",
        };
    }

    private static RegistryDirectory Dir(string path) => new() { Path = path, Enabled = true };

    /// <summary>Selects through the real event, so the pane and the acting handlers see what the operator would.</summary>
    private static void Select(SessionsWindow w, ConversationVm row)
    {
        w.SessionList.SelectedItem = row;
        Pump(w);
    }

    private static void Press(ButtonBase b, Window w)
    {
        b.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        Pump(w);
    }

    private static void Pump(Window w) =>
        w.Dispatcher.Invoke(static () => { }, DispatcherPriority.ContextIdle);
}
