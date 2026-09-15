using System.Globalization;
using System.Windows.Threading;
using SessionRestore.App.Services;
using SessionRestore.App.ViewModels;
using SessionRestore.Core.Registry;
using SessionRestore.Core.Sessions;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.App.Bench;

/// <summary>
/// The three background tiers, driven over readers this machine does not own.
/// </summary>
/// <remarks>
/// 🔴 THE READERS ARE SUBSTITUTED, AND THAT IS THE ONLY WAY THIS IS CHECKABLE.
/// What has to be proven about a background pass is its COMPOSITION - that a
/// pass lands on the UI thread, that rows are patched rather than rebuilt, that
/// it stands still while a sheet is up, that one bad pass does not stop the
/// clock, that a menu seen reaches the send box and a menu gone clears it.
/// Driving that over the operator's own conversations would make every line
/// depend on what he happens to be running, and would put a screen probe onto
/// thirty live consoles inside a check.
///
/// 🔴 AND NOTHING HERE READS A LIVE SCREEN AT ALL. Every reader is a lambda
/// over invented data; the real ones are never called.
///
/// 🪤 THE CADENCES ARE THE REAL ONES, so a check cannot wait for a tick - the
/// fast tier is six seconds and the live one fifteen. What is waited on is the
/// FIRST pass of each, which every tier takes immediately.
/// </remarks>
public static class PassChecks
{
    public static IReadOnlyList<HandlerChecks.Check> Run(Dispatcher ui)
    {
        ArgumentNullException.ThrowIfNull(ui);
        var checks = new List<HandlerChecks.Check>();

        var vm = new SessionsVm();
        var model = Model(3);
        var agents = new Dictionary<string, AgentStatus>(StringComparer.OrdinalIgnoreCase)
        {
            [model[0].Id] = new(model[0].Id, "busy", string.Empty, false, 999101, "interactive", "working", string.Empty, DateTimeOffset.Now),
            [model[1].Id] = new(model[1].Id, "idle", string.Empty, false, 999102, "interactive", "idle", string.Empty, DateTimeOffset.Now),
        };

        // What the substituted screen reader will answer, per pid.
        var screens = new Dictionary<int, string?>
        {
            [999101] = "some prose\nnothing is being asked here",
            [999102] = "\u276F 1. alpha\n  2. bravo",
        };

        var reads = 0;
        var paused = false;
        var explode = false;
        var screenReads = new Dictionary<int, int>();

        var pass = new ModelPass(vm, ui)
        {
            Paused = () => paused,
            ReadModel = () =>
            {
                reads++;
                if (explode)
                {
                    throw new InvalidOperationException("the reader was told to fail");
                }

                return model;
            },
            ReadAgents = () => agents,
            ReadSaid = m =>
            {
                var said = new Dictionary<string, SaidResult>(StringComparer.OrdinalIgnoreCase);
                foreach (var (id, _, _) in m)
                {
                    said[id] = new SaidResult("it said something worth reading here, at length", string.Empty,
                                              string.Empty, DateTimeOffset.Now, "it said something worth reading here, at length");
                }

                return said;
            },
            ReadScreen = pid =>
            {
                screenReads[pid] = screenReads.TryGetValue(pid, out var n) ? n + 1 : 1;
                return screens.TryGetValue(pid, out var sc) ? sc : null;
            },
        };

        var failures = 0;
        pass.Failed += (_, _) => failures++;

        try
        {
            pass.Start();

            // ---- 1. the board actually fills -----------------------------
            var filled = Until(ui, () => vm.Rows.Count() == model.Count && vm.Rows.Any(r => r.Busy));
            checks.Add(new HandlerChecks.Check(
                "the background pass fills the board and says which conversation is mid-turn",
                filled,
                string.Format(CultureInfo.InvariantCulture, "{0} row(s), {1} mid-turn, passes {2}",
                    vm.Rows.Count(), vm.Rows.Count(r => r.Busy), pass.Passes)));

            // ---- 2. and patches rather than rebuilds ----------------------
            //
            // 🔴 THE WHOLE PERFORMANCE CASE. A pass that replaced the rows would
            // take the reading pane's selection with it every six seconds, and
            // rebuild every container. The row OBJECTS have to survive.
            var before = vm.Rows.ToList();
            var structural = 0;
            ((System.Collections.Specialized.INotifyCollectionChanged)vm.Items).CollectionChanged += (_, _) => structural++;
            var was = pass.Passes.Live;
            var again = Until(ui, () => pass.Passes.Live > was || pass.Passes.Fast > 0);
            var kept = vm.Rows.ToList();
            checks.Add(new HandlerChecks.Check(
                "a later pass patches the rows it already has and makes no new ones",
                again && structural == 0 && kept.Count == before.Count
                    && kept.Zip(before).All(p => ReferenceEquals(p.First, p.Second)),
                string.Format(CultureInfo.InvariantCulture, "{0} structural change(s), {1} row object(s) kept of {2}",
                    structural, kept.Zip(before).Count(p => ReferenceEquals(p.First, p.Second)), before.Count)));

            // ---- 3. the ask poll finds the menu ---------------------------
            //
            // 🔴 THE GAP THE LAST THREE COMMITS HAD TO NAME AS OPEN. The send
            // box refuses a conversation sitting on a menu, and nothing filled
            // the record it reads.
            var found = Until(ui, () => pass.AskSeen[model[1].Id]);
            checks.Add(new HandlerChecks.Check(
                "the ask poll records the conversation whose screen is showing a menu, and only that one",
                found && !pass.AskSeen[model[0].Id] && pass.AskSeen.Count == 1,
                string.Format(CultureInfo.InvariantCulture, "flagged: {0}", string.Join(", ", pass.AskSeen.Ids))));

            // ---- 4. and clears it when the menu goes -----------------------
            screens[999102] = "the question was answered\n? for shortcuts";
            var cleared = Until(ui, () => !pass.AskSeen[model[1].Id]);
            checks.Add(new HandlerChecks.Check(
                "and clears it once a later read finds no menu",
                cleared && pass.AskSeen.Count == 0,
                string.Format(CultureInfo.InvariantCulture, "{0} still flagged", pass.AskSeen.Count)));

            // 🪤 A FAILED READ IS NOT A MISSING MENU. An unreadable screen must
            // leave the flag exactly as it was - the reader sometimes comes back
            // empty about a menu that is plainly still there.
            screens[999102] = "\u276F 1. alpha\n  2. bravo";
            Until(ui, () => pass.AskSeen[model[1].Id]);
            screens[999102] = null;
            var held = Until(ui, () => false, rounds: 6) || pass.AskSeen[model[1].Id];
            checks.Add(new HandlerChecks.Check(
                "a screen that will not read leaves the flag where it was, rather than clearing it",
                pass.AskSeen[model[1].Id],
                "still flagged: " + pass.AskSeen[model[1].Id].ToString(CultureInfo.InvariantCulture)));
            _ = held;

            // ---- 4b. a background agent has no console and is never asked
            //
            // 🔴 A PID OF ZERO OR A NON-INTERACTIVE KIND IS NOT A SCREEN. The
            // shipped poll skips both, and a port that did not would spend a
            // console read per tick on something that has none - and would then
            // flag or clear a conversation on the strength of a failed read.
            agents[model[2].Id] = new AgentStatus(model[2].Id, "busy", string.Empty, false, 999103,
                                                  "agent", "a background agent", string.Empty, DateTimeOffset.Now);
            screens[999103] = "❯ 1. alpha\n  2. bravo";
            Until(ui, () => false, rounds: 6);
            checks.Add(new HandlerChecks.Check(
                "a background agent's screen is never read, however loudly it would answer",
                !screenReads.ContainsKey(999103) && !pass.AskSeen[model[2].Id],
                string.Format(CultureInfo.InvariantCulture, "{0} read(s) of the background agent, flagged {1}",
                    screenReads.TryGetValue(999103, out var bg) ? bg : 0, pass.AskSeen[model[2].Id])));

            // ---- 4c. and a poll whose answer did not move costs nothing
            //
            // 🪤 COUNTED AS REBANDS, NOT AS MODEL READS. The first version
            // counted reads and could not tell this tier's from the fast tier's:
            // it measured "1 read during 4 polls" and could not say which clock
            // had struck. A check that cannot attribute what it measured is not
            // measuring the rule.
            var pollsBefore = pass.Passes.Ask;
            var rebandsBefore = pass.AskRebands;
            Until(ui, () => pass.Passes.Ask >= pollsBefore + 4);
            var steady = pass.AskRebands == rebandsBefore;

            // And when the answer DOES move, it rebands - exactly once.
            screens[999102] = "nothing on screen now\n? for shortcuts";
            var moved = Until(ui, () => pass.AskRebands > rebandsBefore);

            checks.Add(new HandlerChecks.Check(
                "an ask poll rebands when its answer moves, and not otherwise",
                pass.Passes.Ask >= pollsBefore + 4 && steady && moved
                    && pass.AskRebands == rebandsBefore + 1,
                string.Format(CultureInfo.InvariantCulture,
                    "{0} poll(s) with no change and {1} reband(s); then the menu went and it rebanded {2} time(s)",
                    pass.Passes.Ask - pollsBefore, steady ? 0 : pass.AskRebands - rebandsBefore,
                    pass.AskRebands - rebandsBefore)));

            // ---- 5. the sheet gate -----------------------------------------
            //
            // 🔴 LOAD-BEARING. A sheet blocks its CALLER on a nested dispatcher
            // frame while the dispatcher keeps pumping, so without this the
            // model rebuilds underneath an open confirmation - and the caller is
            // parked holding the very rows the sheet is naming.
            paused = true;
            var quiet = reads;
            Until(ui, () => false, rounds: 8);
            var duringSheet = reads - quiet;
            paused = false;
            checks.Add(new HandlerChecks.Check(
                "every tier stands still while a sheet is up",
                duringSheet == 0,
                string.Format(CultureInfo.InvariantCulture, "{0} read(s) while the sheet was up", duringSheet)));

            // ---- 6. and a failing pass does not stop the clock --------------
            // 🪤 IT HAS TO KEEP FAILING UNTIL EVERY TIER HAS THROWN. The first
            // version cleared the flag the moment ONE failure was reported, so
            // a tier that had never thrown kept the read count moving and the
            // check passed while the loop that threw was dead. It proved that
            // SOME loop survived, which is not the rule.
            var before6 = reads;
            explode = true;
            var threw = Until(ui, () => failures >= 2, rounds: 200);
            explode = false;
            var after = Until(ui, () => reads > before6 + failures, rounds: 200);
            checks.Add(new HandlerChecks.Check(
                "a pass that throws is reported and the loop carries on",
                threw && failures >= 2 && after,
                string.Format(CultureInfo.InvariantCulture, "{0} failure(s) reported, reads {1} -> {2}",
                    failures, before6, reads)));
        }
        finally
        {
            // 🔴 PUMPED, NOT BLOCKED. This runs ON the UI thread, and a pass
            // parked waiting for that thread cannot finish while the disposer
            // holds it - the run hung for four minutes the first time a break
            // made the race easy to lose. The cancellation now reaches the
            // pending invoke too; this waits by pumping either way.
            var closing = pass.DisposeAsync().AsTask();
            Until(ui, () => closing.IsCompleted, rounds: 100);
        }

        return checks;
    }

    /// <summary>
    /// Pumps the dispatcher until something is true, or gives up.
    /// </summary>
    /// <remarks>
    /// 🪤 A PUMP, NOT A SLEEP. The pass applies its answer through the
    /// dispatcher, so a check that slept would be asleep at exactly the moment
    /// the answer arrived and would then read the previous state. The same
    /// reason every count in this suite is taken after a drain to ContextIdle.
    /// </remarks>
    private static bool Until(Dispatcher ui, Func<bool> done, int rounds = 60)
    {
        for (var i = 0; i < rounds; i++)
        {
            ui.Invoke(static () => { }, DispatcherPriority.ContextIdle);
            if (done())
            {
                return true;
            }

            Thread.Sleep(50);
        }

        return done();
    }

    private static List<(string Id, RegistrySession Session, RegistryDirectory Directory)> Model(int n)
    {
        var dir = new RegistryDirectory { Path = @"C:\invented\project" };
        var model = new List<(string, RegistrySession, RegistryDirectory)>();
        for (var i = 0; i < n; i++)
        {
            var id = string.Format(CultureInfo.InvariantCulture, "eeeeeeee-0000-0000-0000-{0:D12}", i);
            model.Add((id, new RegistrySession
            {
                SessionId = id,
                Title = "invented " + i.ToString("D2", CultureInfo.InvariantCulture),
                LastActive = DateTimeOffset.Now.AddMinutes(-i),
            }, dir));
        }

        return model;
    }
}
