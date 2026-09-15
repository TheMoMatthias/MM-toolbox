using System.Windows.Threading;
using SessionRestore.App.ViewModels;
using SessionRestore.Core;
using SessionRestore.Core.Registry;
using SessionRestore.Core.Sessions;
using SessionRestore.Core.Transcripts;

namespace SessionRestore.App.Services;

/// <summary>
/// What the background readers found on one pass.
/// </summary>
/// <param name="Model">The registry, as conversations on the surface.</param>
/// <param name="Agents">What claude says is holding each one, or null to keep what is held.</param>
/// <param name="Said">The last thing each one said, or null to keep what is held.</param>
public sealed record PassResult(
    IReadOnlyList<(string Id, RegistrySession Session, RegistryDirectory Directory)> Model,
    IReadOnlyDictionary<string, AgentStatus>? Agents,
    IReadOnlyDictionary<string, SaidResult>? Said);

/// <summary>
/// The three tiers that keep the board live.
/// </summary>
/// <remarks>
/// 🔴 A BOARD THAT DOES NOT REFRESH IS A SCREENSHOT. Every reader this rebuild
/// needs was finished in Phase 2 and nothing had ever called them on a clock, so
/// the ported window showed whatever was true when it opened. These are the
/// three cadences the shipped window runs, and they are three rather than one
/// for a measured reason:
///
/// | tier | every | what it costs |
/// |---|---|---|
/// | fast | 6 s | a registry read. Re-derives the bands from the agent map WITHOUT re-reading transcripts - which is what makes a conversation move into NEEDS YOU |
/// | live | 15 s | <c>claude agents --json</c>, a SUBPROCESS: 295 ms of a 508 ms refresh, the single dominant cost |
/// | ask | 400 ms | one screen read through the held-open reader. The difference between a question appearing in fifteen seconds and in under half of one |
///
/// 🔑 THE PROBE'S TWO HALVES COLLAPSE INTO ONE PASS HERE, and that is the one
/// deliberate difference from the shipped structure. Over there the live probe
/// is a runspace started by one timer and harvested by a 200 ms collector,
/// because a DispatcherTimer tick cannot await. <see cref="BackgroundPass"/>
/// already reads on the thread pool and applies on the UI thread, so the starter
/// and the collector are the same statement.
///
/// 🔴 AND ALL THREE STAND DOWN WHILE A SHEET IS UP. That is load-bearing, not
/// tidiness: a sheet blocks its CALLER on a nested dispatcher frame while the
/// dispatcher itself keeps pumping, so without the gate the model would rebuild
/// underneath an open confirmation - and the caller is parked mid-function
/// holding the very rows the sheet is naming. Press the button and the act lands
/// on orphans.
///
/// 🔴 NOTHING HERE WRITES ANYTHING. The registry is read, transcripts are read,
/// screens are read. The structural guard still refuses this assembly any
/// reference to a console writer, a registry writer or a process start.
/// </remarks>
public sealed class ModelPass : IAsyncDisposable
{
    private readonly SessionsVm _vm;
    private readonly Dispatcher _ui;
    private readonly BackgroundPass _fast;
    private readonly BackgroundPass _live;
    private readonly BackgroundPass _ask;

    private IReadOnlyDictionary<string, AgentStatus>? _agents;
    private IReadOnlyDictionary<string, SaidResult>? _said;

    public ModelPass(SessionsVm vm, Dispatcher ui)
    {
        _vm = vm ?? throw new ArgumentNullException(nameof(vm));
        _ui = ui ?? throw new ArgumentNullException(nameof(ui));
        _fast = new BackgroundPass("fast", Cadences.Fast, ui);
        _live = new BackgroundPass("live", Cadences.Live, ui);
        _ask = new BackgroundPass("ask", Cadences.AskPollFast, ui);

        _fast.Failed += (_, e) => Failed?.Invoke(this, e);
        _live.Failed += (_, e) => Failed?.Invoke(this, e);
        _ask.Failed += (_, e) => Failed?.Invoke(this, e);
    }

    /// <summary>Raised when a pass threw. The loop carries on.</summary>
    /// <remarks>
    /// 🪤 A FAILING LOOP MUST NOT DIE QUIETLY. The tool would go on drawing a
    /// board that had stopped updating, which is indistinguishable from a quiet
    /// machine.
    /// </remarks>
    public event EventHandler<Exception>? Failed;

    /// <summary>
    /// Whether the window is asking the operator something. All three tiers
    /// stand still while it is true.
    /// </summary>
    public Func<bool> Paused { get; set; } = static () => false;

    /// <summary>
    /// Reads the registry. Substitutable so the checks can drive the tiers
    /// without this machine's own conversations.
    /// </summary>
    /// <remarks>
    /// 🔑 THE SEAM IS THE READER, NOT THE LOOP. What has to be checked here is
    /// the COMPOSITION - that a pass applies on the UI thread, that rows are
    /// patched rather than rebuilt, that the gate holds, that one bad pass does
    /// not stop the clock. Driving that over the operator's own 415 conversations
    /// would make every check depend on what he happens to be running.
    /// </remarks>
    public Func<IReadOnlyList<(string Id, RegistrySession Session, RegistryDirectory Directory)>> ReadModel { get; set; }
        = static () => Surface();

    /// <summary>Asks claude what is holding each conversation. The expensive one.</summary>
    public Func<IReadOnlyDictionary<string, AgentStatus>> ReadAgents { get; set; }
        = static () => AgentMap.Read(refresh: true);

    /// <summary>
    /// Reads the last thing each conversation said.
    /// </summary>
    /// <remarks>
    /// 🔴 THE LIVE TIER, NOT THE FAST ONE. Re-reading every transcript is what
    /// the fast tier exists to avoid - it re-bands from the agent map alone, and
    /// that is what moves a conversation into NEEDS YOU within six seconds
    /// without touching a file.
    /// </remarks>
    public Func<IReadOnlyList<(string Id, RegistrySession Session, RegistryDirectory Directory)>,
                IReadOnlyDictionary<string, SaidResult>> ReadSaid
    { get; set; } = static model =>
    {
        var said = new Dictionary<string, SaidResult>(StringComparer.OrdinalIgnoreCase);
        foreach (var (id, session, dir) in model)
        {
            // 🪤 THE RECORDED PATH IS PASSED, and it is not decoration: a
            // conversation that was resumed from elsewhere has a jsonl the
            // derived path does not find.
            var path = TranscriptPath.For(dir.Path, id, session.Jsonl);
            if (path.Length > 0 && System.IO.File.Exists(path))
            {
                said[id] = LastSaid.Pass(path);
            }
        }

        return said;
    };

    /// <summary>
    /// What is on one conversation's screen right now, or null when it could not
    /// be read.
    /// </summary>
    /// <remarks>
    /// 🪤 A FAILED READ IS NOT A MISSING MENU. The reader sometimes comes back
    /// empty about a menu that is plainly still there, so an unreadable screen
    /// leaves the flag exactly as it was rather than clearing it.
    /// </remarks>
    public Func<int, string?> ReadScreen { get; set; } = static pid =>
    {
        var (text, stable) = Core.Console.ScreenReader.ReadStable((uint)pid);
        return stable && !text.StartsWith('!') ? text : null;
    };

    /// <summary>Which conversations have a menu on screen. See <see cref="AskSeenSet"/>.</summary>
    public AskSeenSet AskSeen { get; } = new();

    /// <summary>
    /// How many times the ask poll has re-banded the board.
    /// </summary>
    /// <remarks>
    /// 🔴 IT IS INSTRUMENTATION AND IT EARNS ITS PLACE. The rule is that a poll
    /// whose answer did not move costs NOTHING, and a check that counted model
    /// reads could not tell this tier's from the fast tier's - it measured
    /// "1 read during 4 polls" and could not say which clock had struck. This
    /// counts the thing the rule is actually about.
    /// </remarks>
    public int AskRebands { get; private set; }

    /// <summary>How many passes of each tier have completed. The evidence it is alive.</summary>
    public (int Fast, int Live, int Ask) Passes => (_fast.Passes, _live.Passes, _ask.Passes);

    /// <summary>
    /// 🔑 THE FIRST LIVE PASS GOES NOW, NOT IN FIFTEEN SECONDS. A timer fires
    /// after its first interval, so the window would otherwise open and learn
    /// nothing new for a quarter of a minute.
    /// </summary>
    public void Start(bool withAskPoll = true)
    {
        _fast.Start(
            _ => Task.FromResult(Paused() ? null : ReadModel()),
            model =>
            {
                if (model is not null)
                {
                    // The bands, re-derived from what is already held. No file
                    // is opened on this tier.
                    _vm.Sync(model, _agents, _said);
                }
            });

        _live.Start(
            _ =>
            {
                if (Paused())
                {
                    return Task.FromResult<PassResult?>(null);
                }

                var model = ReadModel();
                var agents = ReadAgents();
                var said = ReadSaid(model);
                return Task.FromResult<PassResult?>(new PassResult(model, agents, said));
            },
            r =>
            {
                if (r is null)
                {
                    return;
                }

                _agents = r.Agents;
                _said = r.Said;
                _vm.Sync(r.Model, r.Agents, r.Said);
            });

        if (!withAskPoll)
        {
            return;
        }

        _ask.Start(
            _ => Task.FromResult(Paused() ? null : Poll()),
            moved =>
            {
                // 🔑 REBAND ONLY WHEN THE ANSWER MOVED. A poll that re-synced on
                // every tick would put the whole model on a 400 ms cadence by
                // accident - which is the one thing this tier must not cost.
                if (moved is true && _agents is not null)
                {
                    AskRebands++;
                    _vm.Sync(ReadModel(), _agents, _said);
                }
            });
    }

    /// <summary>
    /// One round of the ask poll: read the screen of every conversation a
    /// process is holding, and record whether it is on a menu.
    /// </summary>
    private bool? Poll()
    {
        if (_agents is null)
        {
            return null;
        }

        var moved = false;
        foreach (var (id, agent) in _agents)
        {
            if (agent.Pid <= 0 || !string.Equals(agent.Kind, "interactive", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var screen = ReadScreen(agent.Pid);
            if (screen is null)
            {
                // Could not read. The flag stays exactly as it was.
                continue;
            }

            moved |= AskSeen.Set(id, Core.Console.LiveMenu.IsOn(screen));
        }

        return moved;
    }

    /// <summary>Every conversation on the surface, read from the registry.</summary>
    private static List<(string Id, RegistrySession Session, RegistryDirectory Directory)> Surface()
    {
        var reg = SessionRegistry.Read();
        var model = new List<(string Id, RegistrySession Session, RegistryDirectory Directory)>();
        foreach (var d in reg.Directories)
        {
            if (d.Missing)
            {
                continue;
            }

            foreach (var s in d.Sessions)
            {
                if (!s.Gone)
                {
                    model.Add((s.SessionId.ToLowerInvariant(), s, d));
                }
            }
        }

        return model;
    }

    public async ValueTask DisposeAsync()
    {
        await _fast.DisposeAsync().ConfigureAwait(false);
        await _live.DisposeAsync().ConfigureAwait(false);
        await _ask.DisposeAsync().ConfigureAwait(false);
    }
}
