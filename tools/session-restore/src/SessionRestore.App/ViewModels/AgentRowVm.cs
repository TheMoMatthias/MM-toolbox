using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using SessionRestore.Core.Rows;
using SessionRestore.Core.Sessions;

namespace SessionRestore.App.ViewModels;

/// <summary>
/// One sub-agent, as a row under the conversation that spawned it.
/// </summary>
/// <remarks>
/// 🔑 A SUB-AGENT IS A CONVERSATION. Claude Code writes each one its own
/// transcript beside the parent's, so opening one is the same act as opening a
/// session - which is why it belongs in this list rather than in a panel of its
/// own, and why it is selectable exactly like a session row.
///
/// 🔴 IT MIRRORS ITS PARENT'S SORT KEYS AND OWNS NONE OF THEM. Band, band
/// order, title and last-active all come from the conversation, so the pair
/// cannot be separated by any sort the column offers; <see cref="SubOrder"/>
/// is the only key of its own. The parent's changes are forwarded, because a
/// conversation that moves band has to take its agents with it - otherwise the
/// agent rows stay under a heading their parent has left.
///
/// 🪤 AND THE PARENT'S <see cref="ConversationVm.Matches"/> IS NOT ENOUGH.
/// These rows exist only while the parent is the row being read, so the
/// expansion is a second condition - see <see cref="Expanded"/>.
/// </remarks>
public sealed class AgentRowVm : INotifyPropertyChanged, IListRow
{
    /// <summary>The id prefix that tells a selection apart from a conversation's.</summary>
    /// <remarks>
    /// 🪴 Every comparison against it is Ordinal. See the project memory: a
    /// culture-sensitive StartsWith is how ("· x").StartsWith("⏵") came out True.
    /// </remarks>
    public const string IdPrefix = "agent:";

    private readonly ConversationVm _parent;
    private bool _matches;
    private bool _expanded = true;
    private string _tag = string.Empty;
    private string _age = string.Empty;
    private double _opacity = 1.0;

    public AgentRowVm(ConversationVm parent, SubAgent agent, int order)
    {
        ArgumentNullException.ThrowIfNull(parent);
        ArgumentNullException.ThrowIfNull(agent);

        _parent = parent;
        Agent = agent;
        Id = IdPrefix + agent.Id;
        SubOrder = order;

        // 🔴 FORWARDED, NOT COPIED. The keys below are read off the parent on
        // every get, so they cannot go stale - but a ListCollectionView only
        // re-sorts and re-groups when it is TOLD a key changed, and the parent's
        // notification names the parent's own property. Re-raising it here is
        // what makes the agent row follow.
        //
        // 🪤 TODAY ONLY Band, BandOrder AND Matches ACTUALLY NOTIFY on the
        // parent - the three sort keys are plain auto-properties there, so a
        // retitled conversation does not re-sort itself either. The other names
        // are forwarded anyway: this row must not become the reason a fix over
        // there does not take.
        _parent.PropertyChanged += OnParentChanged;

        Refresh(agent.IsLive(), 0);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>The agent this row draws. Replaced only by a new row.</summary>
    public SubAgent Agent { get; }

    public string Id { get; }

    /// <summary>
    /// Where this agent sits under its parent.
    /// </summary>
    /// <remarks>
    /// 🪤 IT CAN MOVE. A retained row keeps the object it had, so an agent that
    /// changes place in the list - one ahead of it finishing and dropping out -
    /// would otherwise keep the position it was created with and sort into the
    /// wrong slot for the rest of the selection.
    /// </remarks>
    public int SubOrder { get; private set; }

    /// <summary>The conversation this agent belongs to.</summary>
    public ConversationVm Parent => _parent;

    // ---- the four keys that come from the parent, so the pair never separates

    public int BandOrder => _parent.BandOrder;

    public string BandLabel => _parent.BandLabel;

    public string SortTitle => _parent.SortTitle;

    public string SortProject => _parent.SortProject;

    public long LastActiveTicks => _parent.LastActiveTicks;

    /// <summary>
    /// Whether the conversation above it is the one being read.
    /// </summary>
    /// <remarks>
    /// 🔴 UNDER THE SELECTED CONVERSATION ONLY, and that is a density decision
    /// with history: rendering every conversation's agents took the shipped list
    /// from 36 rows to 106 in review, on a surface that had been asked to get
    /// LESS dense. One session on this machine has 31 agents of its own.
    /// </remarks>
    public bool Expanded
    {
        get => _expanded;
        set
        {
            if (Set(ref _expanded, value))
            {
                Matches = _expanded && _parent.Matches;
            }
        }
    }

    public bool Matches
    {
        get => _matches;
        set => Set(ref _matches, value);
    }

    // ---- what the row draws

    /// <summary>The template binds this; an agent row is always shown once it exists.</summary>
    public Visibility SubVis { get; } = Visibility.Visible;

    public string SubName => Agent.Label;

    public string SubDesc { get; private set; } = string.Empty;

    public string SubTag
    {
        get => _tag;
        private set => Set(ref _tag, value);
    }

    public string SubAge
    {
        get => _age;
        private set => Set(ref _age, value);
    }

    public double SubOpacity
    {
        get => _opacity;
        private set => Set(ref _opacity, value);
    }

    public string SubTip { get; private set; } = string.Empty;

    /// <summary>
    /// Brings the drawn fields into line with what the agent is doing now.
    /// </summary>
    /// <param name="live">
    /// Whether it is still writing - handed in rather than asked of the agent,
    /// so the row and the amber count on the parent can only ever use ONE
    /// definition of live. Two would drift.
    /// </param>
    /// <param name="nowTicks">Now, for the age. 0 reads the clock.</param>
    public void Refresh(bool live, long nowTicks, int order = -1)
    {
        if (order >= 0 && order != SubOrder)
        {
            SubOrder = order;
            Raise(nameof(SubOrder));
        }

        var text = AgentRow.Of(Agent, live, nowTicks);
        SubTag = text.Tag;
        SubAge = text.Age;
        SubOpacity = text.Opacity;
        SubDesc = text.Description;
        SubTip = text.Tip;
        Raise(nameof(SubDesc));
        Raise(nameof(SubTip));
    }

    /// <summary>Lets go of the parent. Called when the row leaves the column.</summary>
    /// <remarks>
    /// 🪤 A ROW THAT IS DROPPED WITHOUT THIS STAYS ALIVE. The parent outlives
    /// the expansion, so its event would hold every agent row every selection
    /// has ever made - a leak that grows with use and shows up as nothing at
    /// all until the list is slow.
    /// </remarks>
    public void Detach() => _parent.PropertyChanged -= OnParentChanged;

    private void OnParentChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(ConversationVm.BandOrder):
            case nameof(ConversationVm.BandLabel):
            case nameof(ConversationVm.SortTitle):
            case nameof(ConversationVm.SortProject):
            case nameof(ConversationVm.LastActiveTicks):
                Raise(e.PropertyName);
                break;
            case nameof(ConversationVm.Matches):
                Matches = _expanded && _parent.Matches;
                break;
            default:
                break;
        }
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
