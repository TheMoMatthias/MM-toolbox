using System.Windows.Threading;

namespace SessionRestore.App.Services;

/// <summary>
/// One background cadence. Plan item 3.4, replacing a DispatcherTimer.
/// </summary>
/// <remarks>
/// 🔴 THE WHOLE POINT IS THAT THE WORK IS NOT ON THE UI THREAD. Every one of the
/// window's eleven timers ticks on the dispatcher, so a model pass that reads a
/// registry and stats hundreds of transcripts happens *between frames* - which is
/// why a 508 ms refresh is felt as a stutter rather than seen as a delay. Here the
/// reading happens on the thread pool and only the finished answer is marshalled
/// back.
///
/// 🪤 AND A TICK NEVER OVERLAPS ITSELF. A DispatcherTimer cannot re-enter, so the
/// PowerShell got that for free and the port would lose it silently: a pass that
/// takes longer than its own interval would otherwise start again underneath
/// itself, and two passes writing the same rows is the lost-update bug with a
/// different name. The interval here is the gap BETWEEN passes, not the period.
///
/// 🪤 A FAILING LOOP MUST NOT DIE QUIETLY. An unobserved exception in an async
/// loop stops the loop and says nothing - the tool would keep drawing a board
/// that had stopped updating, which is indistinguishable from a quiet machine.
/// Every failure goes to <see cref="Failed"/> and the loop carries on.
/// </remarks>
public sealed class BackgroundPass : IAsyncDisposable
{
    private readonly CancellationTokenSource _stop = new();
    private readonly Dispatcher _ui;
    private Task? _running;

    public BackgroundPass(string name, TimeSpan every, Dispatcher ui)
    {
        ArgumentNullException.ThrowIfNull(ui);
        Name = name;
        Every = every;
        _ui = ui;
    }

    /// <summary>Raised when a pass threw. The loop keeps running.</summary>
    public event EventHandler<Exception>? Failed;

    public string Name { get; }

    public TimeSpan Every { get; }

    /// <summary>How many passes have completed. The evidence that it is alive.</summary>
    public int Passes { get; private set; }

    /// <summary>
    /// Starts the loop.
    /// </summary>
    /// <param name="read">The work, on the thread pool. It must touch no UI.</param>
    /// <param name="apply">What to do with the answer, on the UI thread.</param>
    public void Start<T>(Func<CancellationToken, Task<T>> read, Action<T> apply)
    {
        ArgumentNullException.ThrowIfNull(read);
        ArgumentNullException.ThrowIfNull(apply);
        if (_running is not null)
        {
            throw new InvalidOperationException("the '" + Name + "' loop is already running");
        }

        _running = Task.Run(async () =>
        {
            while (!_stop.IsCancellationRequested)
            {
                try
                {
                    var answer = await read(_stop.Token).ConfigureAwait(false);
                    if (_stop.IsCancellationRequested)
                    {
                        return;
                    }

                    await _ui.InvokeAsync(() => apply(answer), DispatcherPriority.Background)
                             .Task.ConfigureAwait(false);
                    Passes++;
                }
                catch (OperationCanceledException)
                {
                    return;
                }
#pragma warning disable CA1031 // a loop that dies on one bad pass stops the whole board
                catch (Exception ex)
#pragma warning restore CA1031
                {
                    Failed?.Invoke(this, ex);
                }

                try
                {
                    await Task.Delay(Every, _stop.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        });
    }

    public async ValueTask DisposeAsync()
    {
        await _stop.CancelAsync().ConfigureAwait(false);
        if (_running is not null)
        {
            try
            {
                await _running.ConfigureAwait(false);
            }
            catch (OperationCanceledException) { }
        }

        _stop.Dispose();
    }
}
