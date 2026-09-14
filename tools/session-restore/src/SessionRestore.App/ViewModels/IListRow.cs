namespace SessionRestore.App.ViewModels;

/// <summary>
/// What the sessions column needs of anything it shows.
/// </summary>
/// <remarks>
/// 🔴 THE COLUMN HOLDS TWO KINDS OF ROW AND THE VIEW MUST NOT KNOW IT.
/// A <see cref="ConversationVm"/> and an <see cref="AgentRowVm"/> are filtered,
/// grouped and sorted by the same <see cref="System.Windows.Data.ListCollectionView"/>,
/// and that view resolves every one of those by PROPERTY NAME, per item, by
/// reflection. So a rename on one type and not the other is not an error the
/// compiler sees - the sort silently falls back and the column quietly stops
/// ordering.
///
/// 🔑 THIS INTERFACE IS THE COMPILE-TIME HALF OF THAT CONTRACT. Nothing binds
/// to it and no converter reads it; it exists so that a property the view sorts
/// on cannot be removed from one row type alone.
///
/// 🪤 AND IT IS AN INTERFACE RATHER THAN A BASE CLASS ON PURPOSE.
/// <see cref="ConversationVm"/> already had every member below - the whole
/// change on that side is the declaration and <see cref="SubOrder"/> - and a
/// base class would have meant rewriting a file whose comments carry three
/// measured decisions.
/// </remarks>
public interface IListRow
{
    /// <summary>Identity, stable for the life of the row. Agent rows carry the <c>agent:</c> prefix.</summary>
    string Id { get; }

    /// <summary>Whether the surface, the search and the rail all let this row through.</summary>
    bool Matches { get; set; }

    /// <summary>Where the band sits in the column. The first sort, always.</summary>
    int BandOrder { get; }

    /// <summary>The heading this row groups under.</summary>
    string BandLabel { get; }

    /// <summary>What "by name" sorts on.</summary>
    string SortTitle { get; }

    /// <summary>What "by project" sorts on.</summary>
    string SortProject { get; }

    /// <summary>What "most recent" sorts on.</summary>
    long LastActiveTicks { get; }

    /// <summary>
    /// 🔑 WHAT KEEPS AN AGENT UNDER THE CONVERSATION IT BELONGS TO.
    /// A conversation is 0 and its agents are 1, 2, 3 - and every agent row
    /// mirrors its parent's other four keys exactly, so whichever way the
    /// column is sorted the parent and its agents sort as one block and this
    /// decides the order inside it.
    ///
    /// 🪤 THE SHIPPED WINDOW NEVER NEEDED THIS: it builds the list in order and
    /// the agents are simply appended after their row. A view that sorts is a
    /// different machine - without this key the agents scatter across the
    /// column, which is the one way this port could look like a bug rather than
    /// a difference.
    /// </summary>
    int SubOrder { get; }
}
