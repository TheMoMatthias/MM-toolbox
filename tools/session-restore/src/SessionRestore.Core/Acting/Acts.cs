using SessionRestore.Core.Registry;

namespace SessionRestore.Core.Acting;

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
/// process start. An implementation that really acts cannot live in the App;
/// it lives in <c>SessionRestore.Live</c>, which the App does not reference,
/// so that the window can go on being provably unable to touch a session.
///
/// 🔑 THE CONTRACT LIVES IN CORE FOR EXACTLY THAT REASON. Both the App
/// (which asks) and Live (which acts) have to see it, and the App is the WPF
/// executable - nothing may reference IT. Moved here in 4.2e.
/// </remarks>
public interface IActs
{
    /// <summary>Carry out one act, or say why not.</summary>
    ActResult Carry(ActRequest request);

    /// <summary>Write a registry. Separate because the whole graph is the argument.</summary>
    ActResult Save(SessionRegistry registry);
}
