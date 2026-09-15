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

    /// <summary>
    /// Whether a picked band lets this row be DRAWN.
    /// </summary>
    /// <remarks>
    /// 🔴 THE BAND PICK IS NOT A FILTER, AND THAT IS THE WHOLE DIFFICULTY.
    /// The shipped column keeps EVERY heading when one band is picked, with its
    /// count beside it - "hiding the others would leave no way back except a
    /// control that is now off screen, and the counts beside them are the reason
    /// to switch in the first place". A grouped view builds its headings FROM
    /// its items, so a band whose rows are filtered out has no heading at all.
    ///
    /// 🔑 SO THE ROWS STAY IN THE VIEW AND THE CONTAINER COLLAPSES. Every group
    /// keeps its heading and its <c>ItemCount</c> - which is what the shipped
    /// one shows too: <c>BandCount</c> is taken BEFORE the pick skips anything.
    /// Two different questions, and a row type that answered only one of them
    /// would have had to lose one of the two behaviours.
    /// </remarks>
    bool Listed { get; set; }

    /// <summary>Where the band sits in the column. The first sort, always.</summary>
    int BandOrder { get; }

    /// <summary>The heading this row groups under.</summary>
    string BandLabel { get; }

    /// <summary>
    /// The one key the column actually sorts on, inside its band.
    /// </summary>
    /// <remarks>
    /// 🔴 THE SORT MODE CHANGES THIS VALUE; IT DOES NOT CHANGE THE VIEW'S
    /// SortDescriptions. Replacing a description raises Reset, and a Reset makes
    /// WPF drop and rebuild every realised container - which on the ported row
    /// template is the whole cost of the gesture: the same cycle measured 8,7 ms
    /// against a placeholder ListBox with no template and 17,2 ms against the
    /// real one, and four structural suspects (live sorting, live grouping,
    /// grouping at all, the number of keys) were each removed and moved neither
    /// figure.
    ///
    /// 🔑 SO THE THREE DESCRIPTIONS ARE SET ONCE AND NEVER TOUCHED AGAIN -
    /// band, this, then the sub-order - and cycling the sort assigns a new key
    /// to each row. With live sorting on, the view MOVES the rows that moved.
    ///
    /// 🪤 WHICH MEANS IT HAS TO BE ONE COMPARABLE STRING. "By project" is two
    /// keys in the shipped window and "most recent" is DESCENDING, so both have
    /// to survive being flattened into one ascending string - see
    /// <c>SessionsVm.KeyFor</c>.
    /// </remarks>
    string SortKey { get; }

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
