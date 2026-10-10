using AudioCapture.Capture;
using AudioCapture.Interfaces;
using AudioCapture.Models;
using AudioCapture.Storage;
using PabloCompanion.Core;
using PabloCompanion.Models;

namespace PabloCompanion.Services;

/// <summary>
/// Thrown instead of starting a capture when no encryption key is available.
/// Session audio is never written to disk in the clear (parity with macOS).
/// </summary>
public sealed class RecordingEncryptionUnavailableException()
    : Exception("No encryption key is available, so the recording was not started.");

/// <summary>Why a capture ended on its own while the session was still open.</summary>
public enum CaptureStopReason
{
    /// <summary>The microphone went away, or its capture died with an error.</summary>
    MicDisconnected,

    /// <summary>The capture session failed.</summary>
    Failed,
}

/// <summary>A capture that ended on its own. Carries the finalized recording when the stop could save one.</summary>
public sealed class CaptureStoppedEventArgs(
    string sessionId,
    CaptureStopReason reason,
    string? message,
    LocalRecording? recording,
    int capture) : EventArgs
{
    public string SessionId { get; } = sessionId;

    /// <summary>Which capture this was; see <see cref="RecordingService.CurrentCapture"/>.</summary>
    public int Capture { get; } = capture;

    public CaptureStopReason Reason { get; } = reason;

    /// <summary>A short, therapist-facing reason, when the capture gave one.</summary>
    public string? Message { get; } = message;

    public LocalRecording? Recording { get; } = recording;
}

/// <summary>
/// Wraps AudioCapture's WasapiCaptureSession for use in Pablo Companion.
/// Manages capture lifecycle, encryption key sourcing, and output directory.
///
/// <para><b>One sidecar pair per session.</b> Each session records into fixed,
/// explicit sidecar paths in its own directory, always opened for append. A
/// restart (Restart Recording after a stall or a mic disconnect) is just another
/// capture into the same files: encrypted sidecars are self-delimiting sealed
/// chunks, so the runs concatenate into one decryptable stream, and a torn final
/// chunk from an interrupted run is trimmed before appending. The mixed WAV is
/// written fresh per run and isn't what uploads.</para>
///
/// <para><b>Capture events.</b> Each capture gets its own <see cref="ICaptureDelegate"/>
/// (<see cref="CaptureListener"/>) bound to that session, so a late callback from a
/// capture already replaced is ignored. A mic disconnect or a failed capture stops
/// the capture here, saving what was recorded, and then raises
/// <see cref="CaptureStopped"/>. Callbacks arrive on capture threads; none of them
/// does work inline.</para>
///
/// <para><b>Devices.</b> System audio follows the default output device: the capture
/// re-opens it in place when the default changes or it errors, reporting
/// <see cref="SystemAudioInterrupted"/> while it can't and
/// <see cref="SystemAudioRestored"/> once it has. The mic is the one picked, or the
/// default communications mic at capture start; a capture stays on that mic until it
/// goes away, which stops the capture as <see cref="CaptureStopReason.MicDisconnected"/>,
/// and Restart Recording then records whatever the default is by then.</para>
/// </summary>
public sealed class RecordingService : IDisposable
{
    internal const string MicSidecarName = "session_mic.enc.pcm";
    internal const string SystemSidecarName = "session_system.enc.pcm";

    private readonly CredentialManager _credentials;
    private readonly string _recordingsRoot;
    private readonly Func<WasapiCaptureSession> _sessionFactory;
    private readonly object _gate = new();

    private WasapiCaptureSession? _session;
    private WasapiCaptureSession? _liveSession;
    private AesGcmEncryptor? _encryptor;
    private string? _activeSessionId;
    private RecordingWatchdog? _watchdog;
    private int _captureLost;
    private int _captureNumber;

    // The stop of the latest capture, kept after it completes so a stop that
    // raced a capture ending on its own still gets the recording.
    private Task<LocalRecording>? _stopTask;
    private string? _stopTaskSessionId;

    // Appended runs of one session share their sidecars, so the session's
    // duration is the sum of its runs.
    private string? _durationSessionId;
    private double _priorRunsDuration;

    public RecordingService(CredentialManager credentials)
        : this(credentials, DefaultRecordingsRoot(), () => new WasapiCaptureSession())
    {
    }

    /// <summary>
    /// Test seam: a recordings root of the caller's choosing and a capture-session
    /// factory, so injected sources (<c>WasapiCaptureSession(Func&lt;IWaveIn&gt;, ...)</c>)
    /// can stand in for the WASAPI endpoints.
    /// </summary>
    internal RecordingService(
        CredentialManager credentials,
        string recordingsRoot,
        Func<WasapiCaptureSession> sessionFactory)
    {
        _credentials = credentials;
        _recordingsRoot = recordingsRoot;
        _sessionFactory = sessionFactory;
    }

    /// <summary>
    /// Raised when the capture stops writing new audio to disk. The capture
    /// itself reports nothing when it dies, so this is the only warning the
    /// therapist gets while the session can still be salvaged.
    /// Mirrors <c>onRecordingStalled</c> on macOS.
    /// </summary>
    public event EventHandler? RecordingStalled;

    /// <summary>Raised when a stalled capture starts writing again.</summary>
    public event EventHandler? RecordingResumed;

    /// <summary>
    /// Raised after a capture ended on its own (mic disconnected, capture failed)
    /// and has been stopped and saved. Raised on a background thread.
    /// </summary>
    public event EventHandler<CaptureStoppedEventArgs>? CaptureStopped;

    /// <summary>System audio stopped reaching the recording; the mic carries on.</summary>
    public event EventHandler? SystemAudioInterrupted;

    /// <summary>System audio capture was re-opened.</summary>
    public event EventHandler? SystemAudioRestored;

    /// <summary>
    /// Counts captures started by this service. Lets a listener tell a report
    /// about an earlier capture from one about the capture running now.
    /// </summary>
    public int CurrentCapture => Volatile.Read(ref _captureNumber);

    public bool IsRecording => _session?.State.Kind == CaptureStateKind.Capturing
                            || _session?.State.Kind == CaptureStateKind.Paused;

    public AudioLevels GetCurrentLevels() =>
        _session?.CurrentLevels ?? AudioLevels.Zero;

    /// <summary>The directory a session's capture writes to.</summary>
    public string SessionDirectory(string sessionId) => Path.Combine(_recordingsRoot, sessionId);

    /// <summary>Test seam: watchdog timings in place of the one-minute production ones.</summary>
    internal (TimeSpan FirstCheck, TimeSpan Interval)? WatchdogTimings { get; set; }

    /// <summary>Test seam: the configuration the latest capture was started with.</summary>
    internal CaptureConfiguration? LastConfiguration { get; private set; }

    /// <summary>
    /// Starts capture for the session and returns once it is capturing; a capture
    /// that can't start faults the task and leaves nothing running. Starting again
    /// for the same session appends to its sidecars. Without an encryption key it
    /// throws <see cref="RecordingEncryptionUnavailableException"/> before
    /// anything touches the disk or the audio devices.
    /// <para>A null <paramref name="micDeviceId"/> records the Windows default
    /// communications microphone as it is when the capture starts, so a restart
    /// after the default changes records the new one. System audio follows the
    /// default output device for the whole capture.</para>
    /// </summary>
    public Task StartAsync(string sessionId, string? micDeviceId = null,
        MixingStrategy mixingStrategy = MixingStrategy.Blended, bool exportRawPcm = false)
    {
        try
        {
            Start(sessionId, micDeviceId, mixingStrategy, exportRawPcm);
            return Task.CompletedTask;
        }
        catch (Exception ex)
        {
            return Task.FromException(ex);
        }
    }

    private void Start(string sessionId, string? micDeviceId, MixingStrategy mixingStrategy, bool exportRawPcm)
    {
        lock (_gate)
        {
            if (_session != null)
                throw new InvalidOperationException("A recording is already active.");

            // Fail closed: no key, no capture. Recording without an encryptor would
            // put session audio on disk in the clear.
            var keyBytes = _credentials.GetOrCreateUserEncryptionKey()
                ?? throw new RecordingEncryptionUnavailableException();

            var outputDir = SessionDirectory(sessionId);
            var encryptor = new AesGcmEncryptor(keyBytes, "device-key");
            var config = new CaptureConfiguration
            {
                SampleRate = 48000,
                BitDepth = 16,
                Channels = 2,
                Encryptor = encryptor,
                OutputDirectory = outputDir,
                MicDeviceId = micDeviceId,
                EnableMicCapture = true,
                EnableSystemCapture = true,
                MixingStrategy = mixingStrategy,
                ExportRawPcm = exportRawPcm,
                MicSidecarPath = Path.Combine(outputDir, MicSidecarName),
                SystemSidecarPath = Path.Combine(outputDir, SystemSidecarName),
                // Always append: for a new session there is nothing to continue,
                // and for a restart this is what keeps the earlier audio.
                AppendToSidecars = true,
                // A headset plugged in, Bluetooth connecting, or a call app moving
                // its output re-opens system capture on the new default output in
                // place, instead of losing the client's side until a restart.
                FollowDefaultOutputDevice = true,
            };
            LastConfiguration = config;

            var session = _sessionFactory();
            session.Delegate = new CaptureListener(this, session);
            _session = session;
            _encryptor = encryptor;
            _activeSessionId = sessionId;
            _captureLost = 0;
            Interlocked.Increment(ref _captureNumber);
            _stopTask = null;
            _stopTaskSessionId = null;
            if (_durationSessionId != sessionId)
            {
                _durationSessionId = sessionId;
                _priorRunsDuration = 0;
            }

            try
            {
                session.Configure(config);

                // StartCaptureAsync runs synchronously until the capture is live and
                // then waits for the stop, so on return it has either failed or is
                // capturing. Its task completes only at stop time.
                var capture = session.StartCaptureAsync();
                if (capture.IsCompleted)
                    capture.GetAwaiter().GetResult();
                if (session.State.Kind != CaptureStateKind.Capturing)
                    throw CaptureException.Unknown($"Capture did not start (state {session.State.Kind}).");
                _ = capture.ContinueWith(
                    t => _ = t.Exception,
                    CancellationToken.None,
                    TaskContinuationOptions.OnlyOnFaulted,
                    TaskScheduler.Default);

                _watchdog = WatchdogTimings is { } timings
                    ? new RecordingWatchdog(outputDir, timings.FirstCheck, timings.Interval)
                    : new RecordingWatchdog(outputDir);
                _watchdog.Stalled += (_, e) => RecordingStalled?.Invoke(this, e);
                _watchdog.Resumed += (_, e) => RecordingResumed?.Invoke(this, e);
                _watchdog.Start();

                Volatile.Write(ref _liveSession, session);
            }
            catch
            {
                TearDown(session);
                throw;
            }
        }
    }

    /// <summary>
    /// Stops the capture and returns its recording. A capture that already ended
    /// on its own returns the recording that stop saved.
    /// </summary>
    public async Task<LocalRecording> StopAsync() =>
        await TryStopAsync(sessionId: null) ?? throw new InvalidOperationException("No active recording.");

    /// <summary>
    /// Stops the session's capture if one is running (or returns the recording of
    /// one that just stopped); null when this session has nothing to stop. A null
    /// <paramref name="sessionId"/> matches whichever capture is current.
    /// </summary>
    public Task<LocalRecording?> TryStopAsync(string? sessionId)
    {
        TaskCompletionSource<LocalRecording> tcs;
        WasapiCaptureSession session;
        lock (_gate)
        {
            if (_stopTask != null && (sessionId == null || sessionId == _stopTaskSessionId))
                return AsNullable(_stopTask);
            if (_session == null || _stopTask != null || (sessionId != null && sessionId != _activeSessionId))
                return Task.FromResult<LocalRecording?>(null);

            session = _session;
            tcs = new TaskCompletionSource<LocalRecording>(TaskCreationOptions.RunContinuationsAsynchronously);
            _stopTask = tcs.Task;
            _stopTaskSessionId = _activeSessionId;

            // Before the capture winds down, so a final flush can't be misread as a stall.
            _watchdog?.Stop();
        }

        _ = CompleteStopAsync(session, tcs);
        return AsNullable(tcs.Task);
    }

    private async Task CompleteStopAsync(WasapiCaptureSession session, TaskCompletionSource<LocalRecording> tcs)
    {
        try
        {
            var result = await session.StopCaptureAsync().ConfigureAwait(false);
            var sampleRate = SidecarSampleRate(session.Diagnostics);
            LocalRecording recording;
            lock (_gate)
            {
                _priorRunsDuration += result.DurationSecs;
                recording = ToLocalRecording(result, _priorRunsDuration, sampleRate);
                TearDown(session);
            }
            tcs.TrySetResult(recording);
        }
        catch (Exception ex)
        {
            lock (_gate) TearDown(session);
            tcs.TrySetException(ex);
        }
    }

    private static async Task<LocalRecording?> AsNullable(Task<LocalRecording> task) => await task.ConfigureAwait(false);

    public void Pause()
    {
        // A paused capture is supposed to stop growing the file — that isn't a stall.
        _watchdog?.Stop();
        _session?.PauseCapture();
    }

    public void Resume()
    {
        _session?.ResumeCapture();
        _watchdog?.Start();
    }

    public Task<AudioSource[]> GetAvailableDevicesAsync()
    {
        using var session = new WasapiCaptureSession();
        return session.GetAvailableAudioSourcesAsync();
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_session is { } session) TearDown(session);
        }
    }

    /// <summary>Releases a capture's resources if it is still the current one. Call under <see cref="_gate"/>.</summary>
    private void TearDown(WasapiCaptureSession session)
    {
        if (!ReferenceEquals(_session, session)) return;
        Volatile.Write(ref _liveSession, null);
        _watchdog?.Dispose();
        _watchdog = null;
        session.Dispose();
        _session = null;
        _encryptor?.Dispose();
        _encryptor = null;
        _activeSessionId = null;
    }

    // --- Capture events ---

    private bool IsLive(WasapiCaptureSession session) =>
        ReferenceEquals(Volatile.Read(ref _liveSession), session);

    private void OnCaptureError(WasapiCaptureSession session, CaptureException error)
    {
        if (!IsLive(session)) return;

        // The capture reports source failures only through OnError, distinguished
        // by message: "Mic stopped: ..." from the mic's RecordingStopped, and
        // "System audio ..." from loopback. Device text only; no session content.
        if (error.Message.StartsWith("Mic stopped", StringComparison.Ordinal))
        {
            OnCaptureLost(session, CaptureStopReason.MicDisconnected, RecordingTrouble.MicDisconnectedMessage);
        }
        else if (error.Message.StartsWith("System audio", StringComparison.Ordinal))
        {
            App.Log($"Capture: system audio error kind={error.ErrorKind}");
            SystemAudioInterrupted?.Invoke(this, EventArgs.Empty);
        }
        else
        {
            // Mix/write errors repeat per cycle; a persistent one stops the sidecar
            // growing, which the watchdog reports as a stall.
            App.Log($"Capture: error kind={error.ErrorKind}");
        }
    }

    private void OnCaptureStateChanged(WasapiCaptureSession session, CaptureState state)
    {
        if (state.Kind == CaptureStateKind.Failed)
            OnCaptureLost(session, CaptureStopReason.Failed, RecordingTrouble.CaptureFailedMessage);
    }

    private void OnCaptureDeviceChanged(WasapiCaptureSession session, CaptureDeviceChange change)
    {
        if (!IsLive(session)) return;
        App.Log($"Capture: device change kind={change.Kind} reason={change.Reason}");
        switch (change.Kind)
        {
            case CaptureDeviceChangeKind.MicDisconnected:
                OnCaptureLost(session, CaptureStopReason.MicDisconnected, RecordingTrouble.MicDisconnectedMessage);
                break;
            case CaptureDeviceChangeKind.SystemOutputUnavailable:
                SystemAudioInterrupted?.Invoke(this, EventArgs.Empty);
                break;
            case CaptureDeviceChangeKind.SystemOutputSwitched:
                SystemAudioRestored?.Invoke(this, EventArgs.Empty);
                break;
        }
    }

    /// <summary>
    /// The capture can't continue. Stop it (finalizing what was recorded) off the
    /// capture thread, then report. The first report per capture wins.
    /// </summary>
    private void OnCaptureLost(WasapiCaptureSession session, CaptureStopReason reason, string message)
    {
        if (!IsLive(session)) return;
        if (Interlocked.Exchange(ref _captureLost, 1) == 1) return;

        _ = Task.Run(async () =>
        {
            string sessionId;
            var capture = CurrentCapture;
            lock (_gate)
            {
                // A stop already under way (End Session) owns this capture.
                if (!ReferenceEquals(_session, session) || _stopTask != null || _activeSessionId is null) return;
                sessionId = _activeSessionId;
            }

            App.Log($"Capture: stopped on its own reason={reason}");
            LocalRecording? recording = null;
            try
            {
                recording = await TryStopAsync(sessionId).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                App.Log($"Capture: stop after loss failed type={ex.GetType().Name}");
            }
            CaptureStopped?.Invoke(this, new CaptureStoppedEventArgs(sessionId, reason, message, recording, capture));
        });
    }

    /// <summary>One capture's delegate. Hands each event to the service with the session it came from.</summary>
    private sealed class CaptureListener(RecordingService owner, WasapiCaptureSession session) : ICaptureDelegate
    {
        public void OnStateChanged(CaptureState state) => owner.OnCaptureStateChanged(session, state);

        public void OnLevelsUpdated(AudioLevels levels)
        {
        }

        public void OnError(CaptureException error) => owner.OnCaptureError(session, error);

        public void OnCaptureFinished(RecordingResult result)
        {
        }

        public void OnDeviceChanged(CaptureDeviceChange change) => owner.OnCaptureDeviceChanged(session, change);
    }

    private static string DefaultRecordingsRoot() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PabloCompanion", "Recordings");

    /// <summary>
    /// The rate to stamp into the uploaded WAV headers: the frame rate of the bytes
    /// in the mic sidecar.
    ///
    /// <para>The mic sidecar is the mic source's buffers written as delivered, so its
    /// bytes are at the mic's delivered format (<see cref="CaptureDiagnostics.MicSampleRate"/>).
    /// The system sidecar is resampled to <see cref="CaptureDiagnostics.SidecarSampleRate"/>.
    /// For a real microphone the two agree: the capture asks Windows for the configured
    /// format in shared mode with conversion on, so the engine resamples a 16 kHz
    /// hands-free mic before the app sees it. If they ever disagree, one rate can't
    /// describe both files; the therapist channel is the one a note can't be written
    /// without, so it gets the right header and the mismatch is logged.</para>
    ///
    /// <para>The measured rate (<see cref="CaptureDiagnostics.MicMeasuredSampleRate"/>)
    /// is not used: it is frames per wall-clock second, which runs a little under the
    /// format rate in every healthy capture (start-up latency, scheduling), so stamping
    /// it would mis-head good recordings. A large shortfall means frames went missing,
    /// not that the bytes are at another rate; it is logged.</para>
    /// </summary>
    internal static int SidecarSampleRate(CaptureDiagnostics diagnostics)
    {
        var sidecarRate = diagnostics.SidecarSampleRate > 0 ? diagnostics.SidecarSampleRate : AudioUploadClient.DefaultSampleRate;
        var micRate = diagnostics.MicSampleRate;
        if (micRate <= 0) return sidecarRate;

        if (micRate != sidecarRate || diagnostics.MicChannels != 1 || diagnostics.MicBitsPerSample != 16)
        {
            App.Log($"Capture: mic format {micRate} Hz {diagnostics.MicChannels} ch {diagnostics.MicBitsPerSample}-bit " +
                $"{diagnostics.MicEncoding} does not match the {sidecarRate} Hz mono 16-bit sidecar format");
        }

        var measured = diagnostics.MicMeasuredSampleRate;
        if (measured > 0 && Math.Abs(measured - micRate) > micRate * 0.1)
            App.Log($"Capture: mic delivered {measured:F0} frames/s against a {micRate} Hz format");

        return micRate;
    }

    private static LocalRecording ToLocalRecording(RecordingResult result, double duration, int sampleRate)
    {
        return new LocalRecording(
            Id: result.Metadata.Id,
            FilePath: result.FilePath,
            Duration: duration,
            CreatedAt: result.Metadata.CreatedAt,
            IsEncrypted: result.Metadata.IsEncrypted,
            Checksum: result.Checksum,
            ChannelLayout: result.Metadata.ChannelLayout,
            MicPcmFilePath: result.RawPcmFilePaths.Length > 0 ? result.RawPcmFilePaths[0] : null,
            SystemPcmFilePath: result.RawPcmFilePaths.Length > 1 ? result.RawPcmFilePaths[1] : null,
            IsUploaded: false,
            SampleRate: sampleRate);
    }
}
