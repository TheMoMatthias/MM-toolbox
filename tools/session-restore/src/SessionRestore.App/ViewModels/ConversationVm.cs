using System.ComponentModel;
using System.Runtime.CompilerServices;
using SessionRestore.Core.Registry;
using SessionRestore.Core.Rows;
using SessionRestore.Core.Sessions;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.App.ViewModels;

/// <summary>
/// One conversation, as a row. Plan item 3.1.
/// </summary>
/// <remarks>
/// 🔴 THE WHOLE PERFORMANCE CASE IS THAT THIS OBJECT IS NOT REBUILT. Measured on
/// the PowerShell: **81% of a column rebuild is constructing and drawing 32
/// rows** - about a millisecond each - and only 19% is the walk over all 434
/// conversations. One search keystroke rebuilt both columns twice, which is most
/// of the 512 ms a keystroke cost.
///
/// So a row is created when the MODEL changes and never because a gesture
/// happened. A filter, a sort or a search moves an existing row; it does not
/// make a new one. Everything a gesture can read is a property that raises
/// <see cref="PropertyChanged"/>, so changing one repaints one row rather than
/// rebuilding a list.
///
/// 🪤 AND THE PROPERTIES ARE PRE-COMPUTED, NOT COMPUTED IN THE GETTER. A getter
/// that walks a transcript or reads the clock is a getter WPF will call during
/// layout, once per visible row, on every pass - which is the same cost the
/// rebuild had, moved somewhere harder to see. <see cref="Refresh"/> does the
/// work once when the model changes.
/// </remarks>
public sealed class ConversationVm : INotifyPropertyChanged
{
    private string _title = string.Empty;
    private bool _derivedTitle;
    private string _lane = string.Empty;
    private string _band = Bands.Quiet;
    private int _bandOrder = Bands.OrderOf(Bands.Quiet);
    private string _bandLabel = Bands.LabelOf(Bands.Quiet);
    private string _said = string.Empty;
    private string _age = string.Empty;
    private bool _live;
    private bool _matches = true;
    private bool _enabled;
    private bool _pinned;

    public ConversationVm(string id, RegistrySession session, RegistryDirectory directory)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(directory);

        Id = id;
        Session = session;
        Directory = directory;
        Refresh(null, null, 0);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>The session id, lower-cased. Stable for the life of the row.</summary>
    public string Id { get; }

    /// <summary>
    /// 🪤 A LIVE REFERENCE INTO THE REGISTRY GRAPH, deliberately. Ticking a row
    /// mutates this object and saving writes the registry it belongs to - and
    /// those two only agree while the rows came from THAT registry. A background
    /// refresh that swapped the registry and left the rows pointing into the old
    /// graph wrote every tick to an orphan, silently, on a 45-second timer.
    /// </summary>
    public RegistrySession Session { get; }

    public RegistryDirectory Directory { get; }

    /// <summary>The project's path - what the rail filters on.</summary>
    public string ProjectPath => Directory.Path;

    /// <summary>Sorting reads this, so it is a number rather than a parse.</summary>
    public long LastActiveTicks { get; private set; }

    /// <summary>
    /// 🔑 THE HAYSTACK, BUILT ONCE. Search runs over every row on every
    /// keystroke, so the one thing it must not do is concatenate and lower-case
    /// four strings 434 times per character typed.
    /// </summary>
    public string SearchText { get; private set; } = string.Empty;

    /// <summary>
    /// Whether this row passes the current filter.
    /// </summary>
    /// <remarks>
    /// 🔴 THE FILTER IS A PROPERTY ON THE ROW, NOT A PREDICATE ON THE VIEW,
    /// and that is the whole point of it. Changing a `ListCollectionView`'s
    /// `Filter` - or calling `Refresh()` - raises **Reset**, and a Reset makes
    /// WPF drop and rebuild every realised container. Measured: that alone kept
    /// a keystroke at 15 ms and put "clear the project" over a frame every time.
    ///
    /// 🔑 With `IsLiveFiltering` on and this property named in
    /// `LiveFilteringProperties`, the view watches it and raises **Add and Remove
    /// for the rows that actually moved**. The containers that stay, stay.
    ///
    /// 🪤 SO THE SETTER MUST BE A NO-OP WHEN NOTHING CHANGED. Typing narrows,
    /// so most rows hold the same answer from one keystroke to the next, and it
    /// is <see cref="Set{T}"/> returning false for those that keeps this cheap.
    /// </remarks>
    public bool Matches
    {
        get => _matches;
        set => Set(ref _matches, value);
    }

    public string Title
    {
        get => _title;
        private set => Set(ref _title, value);
    }

    /// <summary>Whether the title was guessed rather than given. Drawn differently.</summary>
    public bool DerivedTitle
    {
        get => _derivedTitle;
        private set => Set(ref _derivedTitle, value);
    }

    public string Lane
    {
        get => _lane;
        private set => Set(ref _lane, value);
    }

    /// <summary>
    /// Which band this conversation is in. 🔴 The column GROUPS on this, so
    /// setting it moves the row between headings - it is not just a colour.
    /// </summary>
    public string Band
    {
        get => _band;
        private set
        {
            if (Set(ref _band, value))
            {
                BandOrder = Bands.OrderOf(value);
                BandLabel = Bands.LabelOf(value);
            }
        }
    }

    /// <summary>
    /// Where the band sits in the column.
    /// </summary>
    /// <remarks>
    /// 🪤 THE COLUMN SORTS ON THIS AND GROUPS ON <see cref="Band"/>, and the
    /// two have to move together. A view forms groups in the order its items
    /// arrive, so sorting by the label instead would head the column FINISHED,
    /// IDLE, NEEDS YOU - alphabetical, and meaningless.
    /// </remarks>
    public int BandOrder
    {
        get => _bandOrder;
        private set => Set(ref _bandOrder, value);
    }

    /// <summary>The heading text, so the group header binds to a row rather than a converter.</summary>
    public string BandLabel
    {
        get => _bandLabel;
        private set => Set(ref _bandLabel, value);
    }

    /// <summary>The one-line headline. Empty until a probe has read it.</summary>
    public string Said
    {
        get => _said;
        private set => Set(ref _said, value);
    }

    public string Age
    {
        get => _age;
        private set => Set(ref _age, value);
    }

    public bool Live
    {
        get => _live;
        private set => Set(ref _live, value);
    }

    /// <summary>The tick that decides what comes back at the next logon.</summary>
    public bool Enabled
    {
        get => _enabled;
        set
        {
            if (Set(ref _enabled, value))
            {
                // The row and the registry are one thing; see Session.
                Session.Enabled = value;
            }
        }
    }

    public bool Pinned
    {
        get => _pinned;
        set
        {
            if (Set(ref _pinned, value))
            {
                Session.Pinned = value;
            }
        }
    }

    /// <summary>
    /// Re-reads everything a row shows from the model it points at.
    /// </summary>
    /// <remarks>
    /// 🔑 CALLED WHEN THE MODEL CHANGES, NEVER WHEN A GESTURE HAPPENS. Each
    /// property setter is a no-op when the value is unchanged, so a refresh over
    /// 434 rows raises events only for the handful that actually moved - which is
    /// what makes a background pass cost a few repaints instead of a rebuild.
    /// </remarks>
    /// <param name="nowTicks">One reading of the clock for the whole pass. 🪤 Per
    /// row it cost 22,3 ms of a 193 ms pass, and compared each row against a
    /// slightly different "now", which is not what an age means.</param>
    public void Refresh(AgentStatus? agent, SaidResult? said, long nowTicks)
    {
        var t = Titles.Of(Session, Directory);
        Title = t.Text;
        DerivedTitle = t.Derived;
        Lane = Titles.LaneLabel(Session, t.Text);

        LastActiveTicks = Session.LastActive?.LocalDateTime.Ticks ?? 0;
        Age = Titles.AgeOf(LastActiveTicks, nowTicks);

        Live = agent is not null && agent.Pid != 0;
        Band = Bands.Of(SessionState.Of(agent), said);
        Said = said?.Said ?? string.Empty;

        _enabled = Session.Enabled;
        _pinned = Session.Pinned;
        Raise(nameof(Enabled));
        Raise(nameof(Pinned));

        SearchText = (t.Text + "" + Session.SessionId + "" + Directory.Path
                      + "" + Session.Cwd).ToLowerInvariant();
    }

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        Raise(name);
        return true;
    }

    private void Raise(string? name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
