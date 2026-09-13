using System.IO;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Threading;
using SessionRestore.App.Services;
using SessionRestore.App.ViewModels;
using SessionRestore.App.Views;
using SessionRestore.Core;

namespace SessionRestore.App.Bench;

/// <summary>
/// Plan item 4.2 - every handler the window-state tranche wires, driven by
/// raising its real event on the real control, and a structural proof that
/// nothing in the App can act on a session yet.
/// </summary>
/// <remarks>
/// 🔴 THE MAXIMISE AND MINIMISE BUTTONS ARE NOT PRESSED. Maximising a window that
/// sits at -32000 moves it onto the operator's monitor, over his conversations.
/// Their glyph rule is checked as the value it is; Close is pressed, last.
/// </remarks>
public static class HandlerChecks
{
    public sealed record Check(string What, bool Passed, string Detail);

    /// <summary>Types the App must not reference before the acting handlers get their seam.</summary>
    private static readonly string[] Forbidden =
    [
        "SessionRestore.Core.Console.ConsoleWriter",
        "SessionRestore.Core.Registry.RegistryWriter",
        "SessionRestore.Core.Registry.RegistryTarget",
    ];

    public static IReadOnlyList<Check> Run()
    {
        var checks = new List<Check> { Structure() };

        var vm = new SessionsVm();
        vm.Sync(KeystrokeBench.Model());
        var prefs = new NoPreferences();
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
        var shell = new WindowShell(w, vm, prefs);
        shell.Attach();
        var closed = false;
        w.Closed += (_, _) => closed = true;

        w.Show();
        try
        {
            Pump(w);

            // ---- chrome: the glyph rule, as a value
            var max = WindowShell.MaxGlyph(WindowState.Maximized);
            var normal = WindowShell.MaxGlyph(WindowState.Normal);
            checks.Add(new Check("the maximise glyph says restore when maximised, maximise otherwise",
                max == ("\uE923", "Restore down") && normal == ("\uE922", "Maximise")
                    && Equals(w.WinMax.Content, "\uE922"),
                $"now showing U+{(int)((string)w.WinMax.Content)[0]:X4}"));

            // ---- the sort cycle
            var labels = new List<string>();
            for (var i = 0; i < 3; i++)
            {
                Mouse(w.ListSort, UIElement.MouseLeftButtonDownEvent);
                labels.Add(w.ListSort.Text + "=" + vm.Sort);
            }

            checks.Add(new Check("the sort label cycles newest first, by name, by project, and round",
                string.Join(",", labels) == "by name=Name,by project=Project,newest first=Recent",
                string.Join(", ", labels)));

            // ---- search: a burst of typing is ONE filter, after the debounce
            var searches = 0;
            vm.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName == nameof(SessionsVm.Search))
                {
                    searches++;
                }
            };
            w.Search.Text = "a";
            w.Search.Text = "al";
            w.Search.Text = "alg";
            var before = vm.Search;
            Wait(w, Cadences.Debounce * 3);
            checks.Add(new Check("three keystrokes inside the debounce become one search, after it",
                before.Length == 0 && vm.Search == "alg" && searches == 1,
                $"before the timer '{before}', after '{vm.Search}', {searches} search(es)"));

            w.ListSearch.Text = "zzzz-nothing";
            Wait(w, Cadences.Debounce * 3);
            var narrowed = vm.View.Cast<object>().Count();
            w.ListSearch.Text = string.Empty;
            w.Search.Text = string.Empty;
            Wait(w, Cadences.Debounce * 3);
            checks.Add(new Check("the sessions column's own box narrows the column, and clearing it widens it",
                vm.ListSearch.Length == 0 && narrowed == 0 && vm.View.Cast<object>().Any(),
                $"narrowed to {narrowed}, back to {vm.View.Cast<object>().Count()}"));

            // ---- folding: at 1480 px both columns start open
            var railOpen = w.RailPane.Visibility == Visibility.Visible && w.RailStrip.Visibility != Visibility.Visible;
            Mouse(w.RailFold, UIElement.MouseLeftButtonUpEvent);
            Pump(w);
            var railFolded = w.RailPane.Visibility != Visibility.Visible && w.RailStrip.Visibility == Visibility.Visible
                             && Math.Abs(w.RailCol.Width.Value - WindowShell.RailStripWidth) < 0.01;
            Mouse(w.RailOpen, UIElement.MouseLeftButtonUpEvent);
            Pump(w);
            var railBack = w.RailPane.Visibility == Visibility.Visible && w.RailCol.Width.Value > WindowShell.RailStripWidth;
            checks.Add(new Check("folding the projects column shows its strip, and opening it puts the width back",
                railOpen && railFolded && railBack,
                $"open {railOpen}, folded {railFolded}, back {railBack} at {w.RailCol.Width.Value} px"));

            Mouse(w.ListFold, UIElement.MouseLeftButtonUpEvent);
            Pump(w);
            var strip = shell.StripItems();
            var listFolded = w.ListStrip.Visibility == Visibility.Visible
                             && ReferenceEquals(w.StripList.ItemsSource, null) is false;
            Mouse(w.ListOpen, UIElement.MouseLeftButtonUpEvent);
            Pump(w);
            checks.Add(new Check("folding the sessions column leaves the strip saying who needs you",
                listFolded && w.ListPane.Visibility == Visibility.Visible,
                $"folded {listFolded}, {strip.Count} mark(s) on the strip, reopened {w.ListPane.Visibility}"));

            // 🔴 AND NOTHING WAS WRITTEN - the folds were only ASKED to be remembered.
            checks.Add(new Check("every fold asked to be remembered, and nothing was written",
                string.Join(",", prefs.Asked.Select(a => a.Key + "=" + a.Value)) == "foldProjects=True,foldProjects=False,foldSessions=True,foldSessions=False",
                string.Join(", ", prefs.Asked.Select(a => a.Key + "=" + a.Value))));

            // ---- the two surfaces
            w.ModeManage.IsChecked = true;
            Pump(w);
            var manage = w.ManageSurface.Visibility == Visibility.Visible && w.WorkSurface.Visibility != Visibility.Visible
                         && w.Status.Text.StartsWith("Session manager", StringComparison.Ordinal);
            w.ModeWork.IsChecked = true;
            Pump(w);
            var work = w.WorkSurface.Visibility == Visibility.Visible && w.ManageSurface.Visibility != Visibility.Visible;
            checks.Add(new Check("the mode buttons swap the work surface and the manager",
                manage && work, $"manage {manage}, work {work}"));

            // ---- zoom
            prefs.Asked.Clear();
            var steps = new List<string>();
            for (var i = 0; i < 6; i++)
            {
                w.PaneZoom.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
                steps.Add(shell.Zoom.ToString(System.Globalization.CultureInfo.InvariantCulture) + ":"
                          + ((double)w.Resources["SzPane"]).ToString(System.Globalization.CultureInfo.InvariantCulture));
            }

            checks.Add(new Check("the zoom steps 110, 125, 150, 80, 90, 100 and every size follows",
                string.Join(",", steps) == "110:14.5,125:16,150:19.5,80:10.5,90:11.5,100:13"
                    && (string)w.PaneZoom.Content == "Text: 100%"
                    && prefs.Asked.Count == 6,
                string.Join(", ", steps) + $"; label '{w.PaneZoom.Content}'"));

            checks.Add(new Check("a zoom between two steps goes on from the LOWER one",
                WindowShell.NextZoom(105) == 110 && WindowShell.NextZoom(117) == 125 && WindowShell.NextZoom(200) == 80,
                $"105 -> {WindowShell.NextZoom(105)}, 117 -> {WindowShell.NextZoom(117)}, 200 -> {WindowShell.NextZoom(200)}"));

            // ---- close, last
            w.WinClose.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            Pump(w);
            checks.Add(new Check("the close button closes the window", closed, $"closed {closed}"));
        }
        finally
        {
            if (!closed)
            {
                w.Close();
            }
        }

        return checks;
    }

    /// <summary>
    /// 🔴 THE PROOF IS THE ASSEMBLY, NOT A GREP. Every member reference compiled into
    /// the App is read out of its metadata, and any whose type is one that acts on
    /// a session or the registry fails the check - so a handler that reached for
    /// one, however indirectly it was written, cannot pass.
    /// </summary>
    private static Check Structure()
    {
        var path = typeof(HandlerChecks).Assembly.Location;
        using var fs = File.OpenRead(path);
        using var pe = new PEReader(fs);
        var md = pe.GetMetadataReader();
        var hits = new SortedSet<string>(StringComparer.Ordinal);
        var seen = 0;
        foreach (var h in md.MemberReferences)
        {
            var m = md.GetMemberReference(h);
            if (m.Parent.Kind != HandleKind.TypeReference)
            {
                continue;
            }

            seen++;
            var t = md.GetTypeReference((TypeReferenceHandle)m.Parent);
            var full = md.GetString(t.Namespace) + "." + md.GetString(t.Name);
            var member = md.GetString(m.Name);
            if (Array.Exists(Forbidden, f => string.Equals(f, full, StringComparison.Ordinal))
                || (full == "System.Diagnostics.Process" && member == "Start"))
            {
                hits.Add(full + "." + member);
            }
        }

        return new Check("the App references nothing that launches, types, ends or saves",
            hits.Count == 0 && seen > 0,
            hits.Count == 0 ? $"{seen} member reference(s) read, none forbidden" : "FORBIDDEN: " + string.Join(", ", hits));
    }

    private static void Mouse(UIElement target, RoutedEvent e) =>
        target.RaiseEvent(new MouseButtonEventArgs(System.Windows.Input.Mouse.PrimaryDevice, 0, MouseButton.Left) { RoutedEvent = e });

    private static void Pump(Window w) =>
        w.Dispatcher.Invoke(static () => { }, DispatcherPriority.ContextIdle);

    /// <summary>Lets the dispatcher run - timers included - for at least <paramref name="span"/>.</summary>
    private static void Wait(Window w, TimeSpan span)
    {
        var frame = new DispatcherFrame();
        var t = new DispatcherTimer(DispatcherPriority.Background, w.Dispatcher) { Interval = span };
        t.Tick += (_, _) =>
        {
            t.Stop();
            frame.Continue = false;
        };
        t.Start();
        Dispatcher.PushFrame(frame);
        Pump(w);
    }

    public static string Report(IReadOnlyList<Check> checks)
    {
        ArgumentNullException.ThrowIfNull(checks);
        var sb = new StringBuilder();
        sb.AppendLine("  plan item 4.2 - the window-state handlers, driven through their real events.");
        foreach (var c in checks)
        {
            sb.Append("  ").Append(c.Passed ? "ok  " : "FAIL").Append("  ").Append(c.What).Append("  (").Append(c.Detail).AppendLine(")");
        }

        return sb.ToString();
    }
}
