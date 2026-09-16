using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using SessionRestore.App.Views;

namespace SessionRestore.App.Bench;

/// <summary>
/// Plan item 4.1's done-when: the window opens, and every control in
/// <c>01-CAPABILITIES.md</c> is present - by name AND by kind.
/// </summary>
/// <remarks>
/// 🔴 THE LIST IS READ FROM THE CAPABILITY DOCUMENT, NOT TYPED HERE. That file is
/// generated from the shipped XAML and the shipped script; a second copy of its
/// 164 names in this file would be one more list to drift, and a check against a
/// list that drifted with the port proves nothing about the port.
///
/// 🔴 AND NO DATA. The window is built with no data context and nothing is
/// started - no registry read, no background pass, no handler - and it is shown
/// the way render-driver shows one: at -32000, not activated, not hit-testable.
/// </remarks>
public static class SurfaceCheck
{
    /// <summary>One expected element and what was found.</summary>
    public sealed record Row(string Name, string Kind, string? Found, string Where)
    {
        public bool Passed => string.Equals(Kind, Found, StringComparison.Ordinal);
    }

    /// <summary>The result of one check.</summary>
    public sealed record Result(
        bool Opened, Typefaces.Installed Faces, IReadOnlyList<Row> Rows, string Source,
        IReadOnlyList<Divergence> Used, IReadOnlyList<string> DeadRows)
    {
        // 🪤 A MISSING FACE FAILS TOO. The shipped window survives without one,
        // on the system face - but the port embeds them precisely so that it
        // never has to, and a check that only PRINTED "NOT installed" would read
        // green over a window in the wrong typeface.
        public int Failures =>
            (Opened ? 0 : 1) + (Faces.Manrope ? 0 : 1) + (Faces.Plex ? 0 : 1)
            + Rows.Count(r => !r.Passed) + DeadRows.Count;
    }

    /// <summary>Where the capability document is, walking up from the executable.</summary>
    public static string? Document()
    {
        var here = AppContext.BaseDirectory;
        for (var i = 0; i < 10 && here is not null; i++)
        {
            var p = Path.Combine(here, "rebuild", "01-CAPABILITIES.md");
            if (File.Exists(p))
            {
                return p;
            }

            here = Path.GetDirectoryName(here.TrimEnd(Path.DirectorySeparatorChar));
        }

        return null;
    }

    /// <summary>A control this port deliberately builds as a different kind.</summary>
    /// <param name="Name">The control's name, which must be in the record above.</param>
    /// <param name="Was">The kind the shipped window uses.</param>
    /// <param name="Is">The kind this port uses.</param>
    /// <param name="Why">The reason, printed whenever the row is used.</param>
    public sealed record Divergence(string Name, string Was, string Is, string Why);

    /// <summary>Every `name` | kind row in both control tables.</summary>
    public static List<(string Name, string Kind)> Expected(string document)
    {
        var rows = new List<(string, string)>();
        var inTable = false;
        foreach (var line in File.ReadLines(document))
        {
            if (line.StartsWith("## ", StringComparison.Ordinal))
            {
                inTable = line.StartsWith("## Controls that do something", StringComparison.Ordinal)
                       || line.StartsWith("## Named controls with no handler", StringComparison.Ordinal);
                continue;
            }

            if (!inTable)
            {
                continue;
            }

            var m = Regex.Match(line, @"^\| `([^`]+)` \| (\w+) \|");
            if (m.Success)
            {
                rows.Add((m.Groups[1].Value, m.Groups[2].Value));
            }
        }

        return rows;
    }

    /// <summary>
    /// Every row of the named-divergence table.
    /// </summary>
    /// <remarks>
    /// 🔴 A NAMED DIVERGENCE, NEVER A SILENT ONE. The record above describes
    /// the SHIPPED window; a port that needed a different kind used to have two
    /// options, and both were bad - edit the record, which destroys the only
    /// account of what is being replaced, or loosen the check, which stops it
    /// being a check. This is the third: say so, in the document, where the check
    /// reads it and prints it.
    /// </remarks>
    public static List<Divergence> Diverges(string document)
    {
        var rows = new List<Divergence>();
        var inTable = false;
        foreach (var line in File.ReadLines(document))
        {
            if (line.StartsWith("## ", StringComparison.Ordinal))
            {
                inTable = line.StartsWith("## Named divergences", StringComparison.Ordinal);
                continue;
            }

            if (!inTable)
            {
                continue;
            }

            var m = Regex.Match(line, @"^\| `([^`]+)` \| (\w+) \| (\w+) \| (.*?)\s*\|?$");
            if (m.Success)
            {
                rows.Add(new Divergence(
                    m.Groups[1].Value, m.Groups[2].Value, m.Groups[3].Value, m.Groups[4].Value));
            }
        }

        return rows;
    }

    public static Result Run()
    {
        var doc = Document() ?? throw new FileNotFoundException("rebuild\\01-CAPABILITIES.md was not found above the executable");
        var expected = Expected(doc);

        // 🪤 A DEAD DIVERGENCE IS A FAILURE. A row naming a control the record
        // does not have, or claiming a `was` kind it does not give that control,
        // has stopped describing anything - and a row that has stopped firing is
        // exactly what the alignment harness refuses to carry forward.
        var diverges = Diverges(doc);
        var dead = new List<string>();
        var swap = new Dictionary<string, Divergence>(StringComparer.Ordinal);
        foreach (var d in diverges)
        {
            var hit = expected.FindIndex(e =>
                string.Equals(e.Name, d.Name, StringComparison.Ordinal) &&
                string.Equals(e.Kind, d.Was, StringComparison.Ordinal));
            if (hit < 0)
            {
                dead.Add($"{d.Name}: the record has no {d.Was} by that name");
                continue;
            }

            swap[d.Name] = d;
            expected[hit] = (d.Name, d.Is);
        }

        var used = new List<Divergence>();

        var w = new SessionsWindow
        {
            WindowStartupLocation = WindowStartupLocation.Manual,
            Left = -32000,
            Top = -32000,
            ShowInTaskbar = false,
            ShowActivated = false,
            IsHitTestVisible = false,
        };

        try
        {
            w.Show();
            Drain();
            var opened = PresentationSource.FromVisual(w) is not null;
            var faces = w.Faces;

            // Everything reachable in the visual tree after layout, by name - this
            // is where names inside a control's own template live.
            var byName = new Dictionary<string, object>(StringComparer.Ordinal);
            Walk(w, byName);

            var rows = new List<Row>();
            foreach (var (name, kind) in expected)
            {
                if (w.FindName(name) is { } el)
                {
                    rows.Add(new Row(name, kind, el.GetType().Name, "window"));
                }
                else if (byName.TryGetValue(name, out var t))
                {
                    rows.Add(new Row(name, kind, t.GetType().Name, "template"));
                }
                else if (InTemplates(w, name) is { } r)
                {
                    rows.Add(new Row(name, kind, r, "markup of a template nothing has built"));
                }
                else
                {
                    rows.Add(new Row(name, kind, null, "absent"));
                }
            }

            foreach (var row in rows)
            {
                if (row.Passed && swap.TryGetValue(row.Name, out var d))
                {
                    used.Add(d);
                }
            }

            return new Result(opened, faces, rows, doc, used, dead);
        }
        finally
        {
            w.Close();
        }
    }

    public static string Report(Result r)
    {
        ArgumentNullException.ThrowIfNull(r);
        var sb = new StringBuilder();
        var inv = CultureInfo.InvariantCulture;
        sb.AppendLine(inv, $"surface check - plan item 4.1, against {r.Source}");
        sb.AppendLine(inv, $"  {(r.Opened ? "ok  " : "FAIL")}  the window opened (a presentation source exists)");
        sb.AppendLine(inv, $"  {(r.Faces.Manrope && r.Faces.Plex ? "ok  " : "FAIL")}  typefaces: Manrope {(r.Faces.Manrope ? "installed" : "NOT installed")}, IBM Plex Mono {(r.Faces.Plex ? "installed" : "NOT installed")}, every size {r.Faces.Size}");
        var ok = r.Rows.Count(x => x.Passed);
        sb.AppendLine(inv, $"  {(ok == r.Rows.Count ? "ok  " : "FAIL")}  {ok} of {r.Rows.Count} named elements present, by name and by kind");
        foreach (var x in r.Rows.Where(x => !x.Passed))
        {
            sb.AppendLine(inv, $"        FAIL  {x.Name}: expected {x.Kind}, found {x.Found ?? "nothing"} ({x.Where})");
        }

        foreach (var g in r.Rows.Where(x => x.Passed).GroupBy(x => x.Where))
        {
            sb.AppendLine(inv, $"        {g.Count()} found in the {g.Key}");
        }

        // 🔴 PRINTED EVERY RUN, because a divergence nobody reads is a silent one.
        foreach (var d in r.Used)
        {
            sb.AppendLine(inv, $"  note  {d.Name} is a {d.Is} here and a {d.Was} in the shipped window - {d.Why}");
        }

        foreach (var x in r.DeadRows)
        {
            sb.AppendLine(inv, $"  FAIL  a named divergence describes nothing - {x}");
        }

        return sb.ToString();
    }

    private static void Walk(DependencyObject d, Dictionary<string, object> byName)
    {
        if (d is FrameworkElement fe && fe.Name.Length > 0)
        {
            byName.TryAdd(fe.Name, fe);
        }

        var n = VisualTreeHelper.GetChildrenCount(d);
        for (var i = 0; i < n; i++)
        {
            Walk(VisualTreeHelper.GetChild(d, i), byName);
        }
    }

    /// <summary>
    /// A name declared inside a template that nothing on screen has instantiated.
    /// </summary>
    /// <remarks>
    /// 🪤 THREE PLACES A SHOWN WINDOW NEVER BUILDS, and each hid one name on the
    /// first run: an inline ItemTemplate on a list with no items (CastTick), a
    /// DataTemplate in the resources (TickBox), and a template NESTED inside
    /// another template (bb, the ComboBox's own toggle). Loading each template's
    /// content, and every template found inside that content, is how to ask
    /// whether the markup declares the name without needing data to reach it.
    /// </remarks>
    private static string? InTemplates(FrameworkElement w, string name)
    {
        var seen = new HashSet<FrameworkTemplate>();
        var queue = new Queue<FrameworkTemplate>();
        foreach (var v in w.Resources.Values)
        {
            Enqueue(v, queue, seen);
        }

        foreach (var d in Everything(w))
        {
            Collect(d, queue, seen);
        }

        while (queue.Count > 0)
        {
            var t = queue.Dequeue();
            DependencyObject? root;
            try
            {
                root = t.LoadContent();
            }
            catch (InvalidOperationException)
            {
                continue;
            }

            if (root is null)
            {
                continue;
            }

            foreach (var d in Everything(root))
            {
                if (d is FrameworkElement fe && string.Equals(fe.Name, name, StringComparison.Ordinal))
                {
                    return fe.GetType().Name;
                }

                Collect(d, queue, seen);
            }
        }

        return null;
    }

    /// <summary>Every template an element carries: its own, its items', its content's, its style's.</summary>
    private static void Collect(DependencyObject d, Queue<FrameworkTemplate> queue, HashSet<FrameworkTemplate> seen)
    {
        if (d is Control c)
        {
            Enqueue(c.Template, queue, seen);
        }

        if (d is ItemsControl ic)
        {
            Enqueue(ic.ItemTemplate, queue, seen);
            Enqueue(ic.ItemsPanel, queue, seen);
        }

        if (d is ContentControl cc)
        {
            Enqueue(cc.ContentTemplate, queue, seen);
        }

        if (d is ContentPresenter cp)
        {
            Enqueue(cp.ContentTemplate, queue, seen);
        }

        if (d is FrameworkElement fe)
        {
            Enqueue(fe.Style, queue, seen);
            foreach (var v in fe.Resources.Values)
            {
                Enqueue(v, queue, seen);
            }
        }
    }

    private static void Enqueue(object? v, Queue<FrameworkTemplate> queue, HashSet<FrameworkTemplate> seen)
    {
        switch (v)
        {
            case FrameworkTemplate t when seen.Add(t):
                queue.Enqueue(t);
                break;
            case Style s:
                foreach (var setter in s.Setters.OfType<Setter>())
                {
                    Enqueue(setter.Value, queue, seen);
                }

                foreach (var trigger in s.Triggers.OfType<Trigger>())
                {
                    foreach (var setter in trigger.Setters.OfType<Setter>())
                    {
                        Enqueue(setter.Value, queue, seen);
                    }
                }

                Enqueue(s.BasedOn, queue, seen);
                break;
        }
    }

    /// <summary>An element and everything under it, logical and visual.</summary>
    private static IEnumerable<DependencyObject> Everything(DependencyObject root)
    {
        var seen = new HashSet<DependencyObject>();
        var stack = new Stack<DependencyObject>();
        stack.Push(root);
        while (stack.Count > 0)
        {
            var d = stack.Pop();
            if (!seen.Add(d))
            {
                continue;
            }

            yield return d;
            foreach (var child in LogicalTreeHelper.GetChildren(d).OfType<DependencyObject>())
            {
                stack.Push(child);
            }

            if (d is Visual or System.Windows.Media.Media3D.Visual3D)
            {
                var n = VisualTreeHelper.GetChildrenCount(d);
                for (var i = 0; i < n; i++)
                {
                    stack.Push(VisualTreeHelper.GetChild(d, i));
                }
            }
        }
    }

    private static void Drain() =>
        Dispatcher.CurrentDispatcher.Invoke(() => { }, DispatcherPriority.ContextIdle);
}
