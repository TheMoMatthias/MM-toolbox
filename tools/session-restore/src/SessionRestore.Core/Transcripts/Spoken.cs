using System.Text.RegularExpressions;

namespace SessionRestore.Core.Transcripts;

/// <summary>
/// What a person actually typed, with the envelope a slash command wraps it in
/// taken off. <c>Convert-SRSpoken</c>.
/// </summary>
/// <remarks>
/// 🔑 THIS IS THE ONE BODY THE PANE EDITS BEFORE DRAWING IT. A turn that reads
/// <c>&lt;command-name&gt;/compact&lt;/command-name&gt;&lt;command-message&gt;compact&lt;/command-message&gt;</c>
/// is one slash command and eleven words of routing; what the operator typed is
/// <c>/compact</c>. Everything else in this pane is drawn as it arrived.
///
/// 🔴 A BARE '&lt;' IS NOT AN ENVELOPE, AND ALMOST EVERY TURN HAS ONE. The first
/// version of the shipped guard tested for '&lt;' alone - true of any body
/// carrying a system-reminder, a task-notification, an HTML tag or a less-than
/// sign - so eight regex passes ran over most of the document instead of over
/// the handful of slash-command turns they exist for. Measured as a **2.36x
/// regression** in "build AND lay out with every block open" the first time the
/// suite saw it.
///
/// 🪤 THREE Ordinal IndexOf CALLS, NOT A REGEX, because the point is to be
/// cheaper than the thing being skipped. A culture-sensitive compare on a tag
/// prefix is the trap <c>CONTEXT.md</c> already records.
/// [[feedback-culture-sensitive-compare]]
/// </remarks>
public static class Spoken
{
    private const RegexOptions Opts = RegexOptions.Singleline | RegexOptions.CultureInvariant;

    private static readonly Regex Caveat = new("<local-command-caveat>.*?</local-command-caveat>", Opts);
    private static readonly Regex Reminder = new("<system-reminder>.*?</system-reminder>", Opts);
    private static readonly Regex Message = new("<command-message>.*?</command-message>", Opts);
    private static readonly Regex EmptyArgs = new(@"<command-args>\s*</command-args>", Opts);
    private static readonly Regex Args = new("<command-args>(.*?)</command-args>", Opts);
    private static readonly Regex Name = new("<command-name>/?(.*?)</command-name>", Opts);
    private static readonly Regex EmptyOut = new(@"<local-command-stdout>\s*</local-command-stdout>", Opts);
    private static readonly Regex Out = new("<local-command-stdout>(.*?)</local-command-stdout>", Opts);

    /// <summary>What is left where a block was removed is a run of blank lines.</summary>
    private static readonly Regex Blanks = new(@"(\r?\n[ \t]*){3,}", Opts);

    /// <summary>The three prefixes that mean this body has an envelope.</summary>
    private static readonly string[] Tells = ["<local-command", "<system-reminder", "<command-"];

    /// <summary>
    /// Whether this body is worth running the eight passes over.
    /// </summary>
    public static bool HasEnvelope(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return false;
        }

        foreach (var tell in Tells)
        {
            if (text.Contains(tell, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>The body as it should be read.</summary>
    /// <remarks>
    /// 🪤 THE ORDER IS LOAD-BEARING IN TWO PLACES. The EMPTY forms of
    /// <c>command-args</c> and <c>local-command-stdout</c> are removed before the
    /// general form unwraps them, or a command with no arguments would leave a
    /// blank line where its arguments were not.
    /// </remarks>
    public static string Of(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return string.Empty;
        }

        if (!HasEnvelope(text))
        {
            return text;
        }

        var s = text;
        s = Caveat.Replace(s, string.Empty);

        // A real message can carry one of these appended to it, and it is
        // context for the model rather than anything the operator wrote.
        s = Reminder.Replace(s, string.Empty);
        s = Message.Replace(s, string.Empty);
        s = EmptyArgs.Replace(s, string.Empty);
        s = Args.Replace(s, "$1");
        s = Name.Replace(s, "/$1");
        s = EmptyOut.Replace(s, string.Empty);
        s = Out.Replace(s, "$1");
        s = Blanks.Replace(s, "\n\n");
        return s.Trim();
    }
}
