using System.Windows;
using System.Windows.Controls;
using SessionRestore.App.ViewModels;

namespace SessionRestore.App.Views;

/// <summary>
/// Which template a row in the sessions column gets.
/// </summary>
/// <remarks>
/// 🔴 THE SHIPPED COLUMN HAS ONE TEMPLATE AND SWITCHES VISIBILITIES INSIDE IT,
/// because a heading, a conversation and a sub-agent were all the same kind of
/// list item - a PSCustomObject carrying every property all three could need,
/// with the ones that do not apply present-but-switched-off. That is why the
/// shipped row object has <c>SubVis</c>, <c>BandVis</c> and <c>RowVis</c> beside
/// each other, and why a binding to a property the item does not have is a
/// silent trace error and an empty cell.
///
/// 🔑 TYPED ROWS MAKE THAT A COMPILER'S PROBLEM. The headings are a real
/// grouping with their own header template, and this picks between the two row
/// kinds that are left - so neither template can bind to something the item does
/// not have.
///
/// 🪤 AND THE FALLBACK IS THE SESSION TEMPLATE, not null. A null template makes
/// WPF call ToString() on the item and draw the type name in the column, which
/// reads as a corrupt row rather than as a missing case here.
/// </remarks>
public sealed class RowTemplates : DataTemplateSelector
{
    public DataTemplate? Session { get; set; }

    public DataTemplate? Agent { get; set; }

    public override DataTemplate? SelectTemplate(object item, DependencyObject container) =>
        item is AgentRowVm ? Agent : Session;
}
