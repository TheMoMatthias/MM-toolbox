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
        vm.Search = "al";
        vm.Search = string.Empty;
        vm.Sort = SessionSort.Name;
        vm.Sort = SessionSort.Recent;
        ((INotifyCollectionChanged)vm.View).CollectionChanged -= OnView;
        checks.Add(new Check(
            "the VIEW answers a gesture without a Reset",
            !actions.Contains("Reset", StringComparer.Ordinal),
            actions.Count == 0 ? "the view raised nothing" : string.Join(",", actions)));

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
