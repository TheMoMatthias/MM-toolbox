using SessionRestore.Core.Acting;
using SessionRestore.Core.Registry;

namespace SessionRestore.App.Services;


/// <summary>
/// The sheet in front of an act that cannot be taken back.
/// </summary>
/// <remarks>
/// 🔴 IT IS A SEAM SO THAT "WAS IT ASKED?" BECOMES CHECKABLE. A relaunch loses
/// the turn and the process; the shipped window puts a sheet in front of it, and
/// the interrupt beside it deliberately has none because stopping a turn is the
/// recoverable half of the pair. With the sheet behind an interface, a check can
/// assert the harder thing: that the destructive act is NEVER requested unless a
/// confirmation was asked for first.
/// </remarks>
public interface IConfirms
{
    /// <summary>Put the question to the operator. False means do not proceed.</summary>
    bool Ask(Core.Acting.Confirm confirm);
}

/// <summary>Answers yes and records what it was asked. For checks, and for nothing else.</summary>
public sealed class NoConfirms : IConfirms
{
    public List<Core.Acting.Confirm> Asked { get; } = [];

    /// <summary>What to answer next. Set false to check the path where the operator says no.</summary>
    public bool Answer { get; set; } = true;

    public bool Ask(Core.Acting.Confirm confirm)
    {
        Asked.Add(confirm);
        return Answer;
    }
}

/// <summary>
/// Does nothing at all, and says exactly what it was asked to do.
/// </summary>
/// <remarks>
/// 🔴 THE ONLY IMPLEMENTATION THE REBUILD HAS BEFORE CUTOVER. It is the same
/// shape as <see cref="NoPreferences"/> and for a sharper reason: a test that
/// CAN reach live state WILL destroy it, and the standing rule here is that
/// nothing may launch, end or type into a session - not to test, not once, not
/// against what somebody believes is a spare.
/// </remarks>
public sealed class NoActs : IActs
{
    /// <summary>Every act that was asked for, in order.</summary>
    public List<ActRequest> Asked { get; } = [];

    /// <summary>The registries it was asked to write. None of them reached a file.</summary>
    public List<SessionRegistry> Saves { get; } = [];

    public ActResult Carry(ActRequest request)
    {
        Asked.Add(request);
        return ActResult.Ok(string.Empty);
    }

    public ActResult Save(SessionRegistry registry)
    {
        ArgumentNullException.ThrowIfNull(registry);
        Saves.Add(registry);
        return ActResult.Ok(string.Empty);
    }

    /// <summary>The last act asked for, or a request with no act in it.</summary>
    public ActRequest Last => Asked.Count > 0 ? Asked[^1] : default;
}
