using SessionRestore.Core.Registry;

namespace SessionRestore.App.Services;

/// <summary>
/// Everything the window can do TO a conversation, rather than to what is shown.
/// </summary>
/// <remarks>
/// 🪤 FIVE OF THESE ARE NOT REQUESTED BY ANYTHING YET - <see cref="Close"/>,
/// <see cref="Key"/>, <see cref="SignIn"/>, <see cref="SaveRegistry"/> and
/// <see cref="WriteConfig"/> belong to the bulk buttons, the terminal keys and
/// the settings sheet, which are not ported. They are named here rather than
/// added later because the list is what the gate in front of the operator is
/// ABOUT: this is the whole surface an implementation would have to be trusted
/// with, and a list that grew quietly after the decision was taken would not be
/// the thing that was agreed.
/// </remarks>
public enum Act
{
    /// <summary>Start a conversation that is not running.</summary>
    Open,

    /// <summary>Close a running conversation and start it again.</summary>
    Relaunch,

    /// <summary>End one without starting it again.</summary>
    Close,

    /// <summary>Press Escape in it, to stop the turn it is running.</summary>
    Interrupt,

    /// <summary>Type a message into it and commit it.</summary>
    Send,

    /// <summary>Send one key or chord into its terminal.</summary>
    Key,

    /// <summary>Bring its terminal to the front.</summary>
    GoTo,

    /// <summary>Open a terminal to sign in.</summary>
    SignIn,

    /// <summary>Write the registry - the ticks, the names, the shelved projects.</summary>
    SaveRegistry,

    /// <summary>Write session-restore's own configuration.</summary>
    WriteConfig,
}

/// <summary>One act, named with everything needed to carry it out or to check it was asked for.</summary>
/// <param name="What">Which act.</param>
/// <param name="SessionId">The conversation it is about, or empty.</param>
/// <param name="Title">What that conversation is called - for anything said to the operator.</param>
/// <param name="Detail">The message, the key, the setting - whatever this act carries.</param>
public readonly record struct ActRequest(Act What, string SessionId, string Title, string Detail)
{
    public ActRequest(Act what)
        : this(what, string.Empty, string.Empty, string.Empty)
    {
    }
}

/// <summary>What came of it.</summary>
/// <param name="Done">Whether it happened.</param>
/// <param name="Said">What to put on the status line - a refusal, or what was done.</param>
public readonly record struct ActResult(bool Done, string Said)
{
    public static ActResult Refused(string why) => new(false, why);

    public static ActResult Ok(string said) => new(true, said);
}

/// <summary>
/// The one way anything in this window reaches a conversation.
/// </summary>
/// <remarks>
/// 🔴 THE OPERATOR RUNS ABOUT THIRTY LIVE CONVERSATIONS HE CANNOT RELAUNCH, and
/// a registry-overwrite bug in this repo's history cost him 210 of them. So the
/// acting half of the window is a SEAM before it is an implementation: every
/// handler that could launch, end, type into, sign into or save goes through
/// this interface and nothing else, and the only implementation in the build is
/// <see cref="NoActs"/> - which performs nothing and records what it was asked.
///
/// 🔑 THAT IS NOT A PLACEHOLDER, IT IS THE CHECK. A launch can be verified
/// without launching: drive the real button through its real event and assert
/// that the right act was requested, for the right conversation, carrying the
/// right text. The decisions themselves - who may be interrupted, what a
/// relaunch refuses, what the sheet says - are values in
/// <see cref="Core.Acting"/> and are compared against the shipped window by the
/// oracle.
///
/// 🔴 AND THE STRUCTURAL GUARD STAYS. <c>Sessions2.dll</c> is read by the
/// handler check and must reference no console writer, no registry writer and no
/// process start. An implementation that really acts cannot live in this
/// assembly; it gets its own, so that this one can go on being provably unable
/// to touch a session.
/// </remarks>
public interface IActs
{
    /// <summary>Carry out one act, or say why not.</summary>
    ActResult Carry(ActRequest request);

    /// <summary>Write a registry. Separate because the whole graph is the argument.</summary>
    ActResult Save(SessionRegistry registry);
}

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
