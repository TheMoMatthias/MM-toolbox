using System.Collections.Specialized;
using System.ComponentModel;
using SessionRestore.App.ViewModels;
using SessionRestore.Core.Registry;

namespace SessionRestore.App.Bench;

/// <summary>
/// Plan item 3.1's done-when, asserted rather than assumed.
/// </summary>
/// <remarks>
/// 🔴 THE BENCH ALONE CANNOT PROVE THIS. "12 ms" is consistent with a fast
/// rebuild as well as with no rebuild, and the two have completely different
/// futures: a rebuild that is fast today is slow again at twice the
/// conversations, and it also destroys the selection and the scroll position
/// every time. So the structural claim is checked separately - **a gesture
/// raises no Add or Remove at all** - and a number is only worth reading once
/// that holds.
///
/// 🪤 THESE RUN ON THE BENCH'S OWN STA THREAD, in the App, rather than in the
/// xUnit project. `ListCollectionView` is WPF and wants an STA dispatcher, and
/// giving the whole test assembly a WPF reference and an STA runner to check
/// three things is a large change for a small assertion.
/// </remarks>
public static class BindingChecks
{
    public sealed record Check(string What, bool Passed, string Detail);

    public static IReadOnlyList<Check> Run(
        IReadOnlyList<(string Id, RegistrySession S, RegistryDirectory D)> model)
    {
        ArgumentNullException.ThrowIfNull(model);
        var checks = new List<Check>();

        var vm = new SessionsVm();
        vm.Sync(model.Select(m => (m.Id, m.S, m.D)));

        // 🔴 THE VIEW HAS TO BE BOUND, OR THESE CHECKS ARE ABOUT A DIFFERENT
        // OBJECT. A ListCollectionView only subscribes to its items'
        // PropertyChanged while something is USING it, so with no control
        // attached IsLiveFiltering never engages: the count stayed at 428 through
        // a search that matches nothing, and the "no Reset" check passed because
        // the view was doing nothing at all. Caught by asking whether the filter
        // still filters - the bench's own numbers had said it did, because the
        // BENCH binds its view to a ListBox and this did not.
        var list = new System.Windows.Controls.ListBox
        {
            ItemsSource = vm.View,
            IsHitTestVisible = false,
        };
        var window = new System.Windows.Window
        {
            Content = list,
            Width = 460,
            Height = 940,
            WindowStartupLocation = System.Windows.WindowStartupLocation.Manual,
            Left = -32000,
            Top = -32000,
            ShowInTaskbar = false,
            ShowActivated = false,
        };
        window.Show();
        try
        {

            var structural = 0;
            ((INotifyCollectionChanged)vm.Rows).CollectionChanged += Count;
            void Count(object? s, NotifyCollectionChangedEventArgs e)
            {
                if (e.Action != NotifyCollectionChangedAction.Move)
                {
                    structural++;
                }
            }

            // 1. A second Sync over the same model changes nothing.
            structural = 0;
            vm.Sync(model.Select(m => (m.Id, m.S, m.D)));
            checks.Add(new Check(
                "a refresh over an unchanged model adds and removes nothing",
                structural == 0,
                structural + " structural change(s)"));

            // 2. A search is a filter, not a rebuild.
            structural = 0;
            vm.Search = "a";
            vm.Search = "al";
            vm.Search = string.Empty;
            checks.Add(new Check(
                "three keystrokes add and remove nothing",
                structural == 0,
                structural + " structural change(s)"));

            // 3. A sort is a reorder, not a rebuild.
            structural = 0;
            vm.Sort = SessionSort.Name;
            vm.Sort = SessionSort.Recent;
            checks.Add(new Check(
                "changing the sort adds and removes nothing",
                structural == 0,
                structural + " structural change(s)"));

            // 4. One property change repaints ONE row.
            if (vm.Rows.Count > 0)
            {
                var row = vm.Rows[0];
                var touched = new List<string>();
                void OnRow(object? s, PropertyChangedEventArgs e) => touched.Add(e.PropertyName ?? "?");
                row.PropertyChanged += OnRow;

                structural = 0;
                row.Session.Title = "(sr-bench) a name it did not have";
                row.Refresh(null, null, DateTime.Now.Ticks);
                row.PropertyChanged -= OnRow;
                row.Session.Title = string.Empty;

                checks.Add(new Check(
                    "changing one row's title repaints that row and rebuilds nothing",
                    structural == 0 && touched.Contains(nameof(ConversationVm.Title), StringComparer.Ordinal),
                    structural + " structural change(s), row raised: " + string.Join(",", touched)));
            }

            // 5. WHAT THE ITEMS CONTROL ACTUALLY SEES. The four checks above watch
            //    the SOURCE collection, and the source is not what a ListBox binds
            //    to - it binds to the VIEW. A view that answers a filter change with
            //    Reset makes WPF drop and rebuild every container, which is a
            //    rebuild by another name and would not show up above at all.
            var actions = new List<string>();
            void OnView(object? s, NotifyCollectionChangedEventArgs e) => actions.Add(e.Action.ToString());
            ((INotifyCollectionChanged)vm.View).CollectionChanged += OnView;

            // A keystroke: live filtering should move the rows that changed.
            //
            // 🔴 AND THE VIEW'S COUNT IS CHECKED TOO, because "raised no Reset" is
            // also what a view that has stopped filtering ALTOGETHER would report.
            // Silence is only good news if the filtering still happens.
            // 🪤 THE DISPATCHER HAS TO BE PUMPED BEFORE COUNTING. WPF applies
            // live shaping through the dispatcher, so a count taken on the very
            // next line reads the PREVIOUS set - which showed up as 428 -> 428 ->
            // 428 and looked exactly like a filter that had stopped working. The
            // bench never saw it because Measure drains between the gesture and
            // the count.
            var all = Showing(window, vm);
            vm.Search = "zzzz-nothing-matches-this";
            var narrowed = Showing(window, vm);
            vm.Search = string.Empty;
            var widened = Showing(window, vm);
            checks.Add(new Check(
                "and the filter still filters",
                all > 0 && narrowed == 0 && widened == all,
                all + " -> " + narrowed + " -> " + widened));

            vm.Search = "al";
            vm.Search = string.Empty;
            var afterTyping = new List<string>(actions);
            checks.Add(new Check(
                "the VIEW answers a KEYSTROKE without a Reset",
                !afterTyping.Contains("Reset", StringComparer.Ordinal),
                Summarise(afterTyping)));

            // 🪤 A SORT STILL RESETS, AND IT IS TOLD APART ON PURPOSE. Changing
            // SortDescriptions resets the view whatever IsLiveSorting says, so the
            // containers are rebuilt - which is why `cycle the sort` is the gesture
            // still over a frame. Reporting it as the same failure as a filter Reset
            // would have hidden that the filter fix worked.
            actions.Clear();
            vm.Sort = SessionSort.Name;
            vm.Sort = SessionSort.Recent;
            var afterSort = new List<string>(actions);
            ((INotifyCollectionChanged)vm.View).CollectionChanged -= OnView;
            checks.Add(new Check(
                "the VIEW answers a SORT without a Reset (known: it does not)",
                !afterSort.Contains("Reset", StringComparer.Ordinal),
                Summarise(afterSort)));

            // 6. A row that genuinely leaves the model is removed - the check that
            //    stops #1 from passing by doing nothing at all.
            structural = 0;
            vm.Sync(model.Skip(1).Select(m => (m.Id, m.S, m.D)));
            checks.Add(new Check(
                "and a conversation that really left IS removed",
                structural > 0,
                structural + " structural change(s)"));

            ((INotifyCollectionChanged)vm.Rows).CollectionChanged -= Count;
        return checks;
        }
        finally
        {
            window.Close();
        }
    }

    private static int Showing(System.Windows.Window w, SessionsVm vm)
    {
        w.Dispatcher.Invoke(static () => { }, System.Windows.Threading.DispatcherPriority.ContextIdle);
        return vm.View.Cast<object>().Count();
    }

    /// <summary>Counts rather than lists: live filtering raises hundreds.</summary>
    private static string Summarise(List<string> actions)
    {
        if (actions.Count == 0)
        {
            return "the view raised nothing";
        }

        return string.Join(", ", actions.GroupBy(a => a, StringComparer.Ordinal)
            .Select(g => g.Count().ToString(System.Globalization.CultureInfo.InvariantCulture) + " x " + g.Key));
    }

    public static string Report(IReadOnlyList<Check> checks)
    {
        ArgumentNullException.ThrowIfNull(checks);
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("  plan item 3.1 - rows are bound once, and a gesture moves them.");
        foreach (var c in checks)
        {
            sb.AppendLine("  " + (c.Passed ? "ok   " : "FAIL ") + c.What + "  (" + c.Detail + ")");
        }

        return sb.ToString();
    }
}
