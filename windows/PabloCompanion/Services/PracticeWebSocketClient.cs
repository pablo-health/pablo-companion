using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace PabloCompanion.Services;

/// <summary>
/// WebSocket client for practice mode audio streaming.
/// Sends therapist mic audio (PCM 16kHz mono 16-bit) and receives
/// Pablo Bear's response audio (PCM 24kHz mono 16-bit).
/// Uses the hybrid text/binary protocol defined in practice-mode-api.md.
/// </summary>
public sealed class PracticeWebSocketClient : IDisposable
{
    // ── Public state ────────────────────────────────────────────────────────

    public enum ConnectionState { Disconnected, Connecting, Authenticating, WaitingForSession, Active, Ending }
    public enum PabloState { Listening, Processing, Speaking }

    // ── Events ──────────────────────────────────────────────────────────────

    public event Action<ConnectionState>? ConnectionStateChanged;
    public event Action<PabloState>? PabloStateChanged;
    public event Action<byte[], bool>? AudioReceived;
    public event Action<string>? SessionStarted;
    public event Action<int>? SessionEnded;
    public event Action<string, bool>? ErrorOccurred; // message, isFatal

    // ── Properties ──────────────────────────────────────────────────────────

    public ConnectionState State
    {
        get { lock (_lock) return _state; }
    }

    public ushort LastReceivedSequence
    {
        get { lock (_lock) return _lastReceivedSequence; }
    }

    // ── Private fields ──────────────────────────────────────────────────────

    private readonly object _lock = new();
    private ClientWebSocket? _ws;
    private CancellationTokenSource? _cts;
    private ConnectionState _state = ConnectionState.Disconnected;
    private ushort _sendSequence;
    private ushort _lastReceivedSequence;

    // ── Connect ─────────────────────────────────────────────────────────────

    public async Task ConnectAsync(Uri uri)
    {
        Disconnect();

        SetState(ConnectionState.Connecting);

        _cts = new CancellationTokenSource();
        _ws = new ClientWebSocket();

        try
        {
            PabloCompanion.App.Log($"[WS] connecting to {uri}");
            await _ws.ConnectAsync(uri, _cts.Token);
            PabloCompanion.App.Log("[WS] connected, entering authenticating state");
            SetState(ConnectionState.Authenticating);
            _ = Task.Run(() => ReceiveLoopAsync(_cts.Token));
        }
        catch (Exception ex)
        {
            PabloCompanion.App.LogException("[WS] connect failed", ex);
            ErrorOccurred?.Invoke($"Connection failed: {ex.Message}", true);
            SetState(ConnectionState.Disconnected);
        }
    }

    // ── Session lifecycle ───────────────────────────────────────────────────

    public void StartSession(string sessionId)
    {
        SendJson(new { type = "session_start", session_id = sessionId });
        SetState(ConnectionState.WaitingForSession);
    }

    public void ResumeSession(string sessionId, ushort lastSequence)
    {
        SendJson(new { type = "session_resume", session_id = sessionId, last_sequence = (int)lastSequence });
        SetState(ConnectionState.WaitingForSession);
    }

    public void EndSession()
    {
        SendJson(new { type = "session_end" });
        SetState(ConnectionState.Ending);
    }

    public void PauseAudio()
    {
        SendJson(new { type = "audio_pause" });
    }

    public void ResumeAudio()
    {
        SendJson(new { type = "audio_resume" });
    }

    // ── Send audio ──────────────────────────────────────────────────────────

    /// <summary>
    /// Sends a 20ms PCM audio frame with the 4-byte protocol header.
    /// </summary>
    public void SendAudioFrame(byte[] pcmData)
    {
        if (State != ConnectionState.Active) return;

        ushort seq;
        lock (_lock)
        {
            seq = _sendSequence;
            _sendSequence++;
        }

        var frame = new byte[4 + pcmData.Length];
        frame[0] = 0x01; // direction: client-to-server
        frame[1] = 0x00; // flags: reserved
        frame[2] = (byte)(seq >> 8); // sequence high byte
        frame[3] = (byte)(seq & 0xFF); // sequence low byte
        Buffer.BlockCopy(pcmData, 0, frame, 4, pcmData.Length);

        _ = SendBinaryAsync(frame);
    }

    // ── Disconnect ──────────────────────────────────────────────────────────

    public void Disconnect(bool forReconnect = false)
    {
        _cts?.Cancel();
        _cts?.Dispose();
        _cts = null;

        if (_ws?.State == WebSocketState.Open)
        {
            try { _ws.CloseAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None).Wait(1000); }
            catch { /* best-effort close */ }
        }
        _ws?.Dispose();
        _ws = null;

        if (!forReconnect)
        {
            lock (_lock)
            {
                _sendSequence = 0;
                _lastReceivedSequence = 0;
            }
        }

        SetState(ConnectionState.Disconnected);
    }

    public void Dispose() => Disconnect();

    // ── Receive loop ────────────────────────────────────────────────────────

    private async Task ReceiveLoopAsync(CancellationToken ct)
    {
        var buffer = new byte[8192];

        try
        {
            while (!ct.IsCancellationRequested && _ws?.State == WebSocketState.Open)
            {
                using var ms = new MemoryStream();
                WebSocketReceiveResult result;

                do
                {
                    result = await _ws.ReceiveAsync(buffer, ct);
                    ms.Write(buffer, 0, result.Count);
                } while (!result.EndOfMessage);

                if (result.MessageType == WebSocketMessageType.Text)
                {
                    HandleTextMessage(Encoding.UTF8.GetString(ms.ToArray()));
                }
                else if (result.MessageType == WebSocketMessageType.Binary)
                {
                    HandleBinaryMessage(ms.ToArray());
                }
                else if (result.MessageType == WebSocketMessageType.Close)
                {
                    break;
                }
            }
        }
        catch (OperationCanceledException) { /* expected on disconnect */ }
        catch (Exception ex)
        {
            if (!ct.IsCancellationRequested)
            {
                ErrorOccurred?.Invoke($"Connection lost: {ex.Message}", true);
                SetState(ConnectionState.Disconnected);
            }
        }
    }

    // ── Text message handling ───────────────────────────────────────────────

    private void HandleTextMessage(string text)
    {
        PabloCompanion.App.Log($"[WS] recv text: {(text.Length > 200 ? text[..200] + "..." : text)}");
        using var doc = JsonDocument.Parse(text);
        var root = doc.RootElement;

        if (!root.TryGetProperty("type", out var typeProp)) return;
        var type = typeProp.GetString();

        switch (type)
        {
            case "auth_result":
                if (root.TryGetProperty("status", out var status) && status.GetString() != "ok")
                {
                    ErrorOccurred?.Invoke("Authentication failed", true);
                    Disconnect();
                }
                break;

            case "session_started":
                SetState(ConnectionState.Active);
                lock (_lock) _sendSequence = 0;
                StartHeartbeat();
                if (root.TryGetProperty("session_id", out var sid))
                    SessionStarted?.Invoke(sid.GetString()!);
                break;

            case "session_ended":
                var duration = root.TryGetProperty("duration_seconds", out var dur) ? dur.GetInt32() : 0;
                SessionEnded?.Invoke(duration);
                SetState(ConnectionState.Disconnected);
                break;

            case "status":
                if (root.TryGetProperty("state", out var stateProp))
                {
                    var pabloState = stateProp.GetString() switch
                    {
                        "listening" => PabloState.Listening,
                        "processing" => PabloState.Processing,
                        "speaking" => PabloState.Speaking,
                        _ => (PabloState?)null,
                    };
                    if (pabloState.HasValue) PabloStateChanged?.Invoke(pabloState.Value);
                }
                break;

            case "pong":
                break;

            case "error":
                var msg = root.TryGetProperty("message", out var m) ? m.GetString() ?? "Unknown error" : "Unknown error";
                var recoverable = root.TryGetProperty("recoverable", out var r) && r.GetBoolean();
                ErrorOccurred?.Invoke(msg, !recoverable);
                break;

            case "fatal_error":
                var fatalMsg = root.TryGetProperty("message", out var fm) ? fm.GetString() ?? "Fatal error" : "Fatal error";
                ErrorOccurred?.Invoke(fatalMsg, true);
                SetState(ConnectionState.Disconnected);
                break;
        }
    }

    // ── Binary message handling ─────────────────────────────────────────────

    private void HandleBinaryMessage(byte[] data)
    {
        if (data.Length < 4) return;

        var direction = data[0];
        if (direction != 0x02) return; // expect server-to-client

        var flags = data[1];
        var isFinal = (flags & 0x01) != 0;
        var seq = (ushort)((data[2] << 8) | data[3]);

        lock (_lock) _lastReceivedSequence = seq;

        var pcm = new byte[data.Length - 4];
        Buffer.BlockCopy(data, 4, pcm, 0, pcm.Length);

        AudioReceived?.Invoke(pcm, isFinal);
    }

    // ── Heartbeat ───────────────────────────────────────────────────────────

    private void StartHeartbeat()
    {
        _ = Task.Run(async () =>
        {
            while (State == ConnectionState.Active && _cts is { IsCancellationRequested: false })
            {
                await Task.Delay(15_000);
                if (State != ConnectionState.Active) break;
                var ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                SendJson(new { type = "ping", ts });
            }
        });
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private void SetState(ConnectionState newState)
    {
        lock (_lock) _state = newState;
        PabloCompanion.App.Log($"[WS] state → {newState}");
        ConnectionStateChanged?.Invoke(newState);
    }

    private void SendJson(object payload)
    {
        if (_ws?.State != WebSocketState.Open) return;
        var json = JsonSerializer.Serialize(payload);
        var bytes = Encoding.UTF8.GetBytes(json);
        _ = SendBinaryAsync(bytes, WebSocketMessageType.Text);
    }

    private async Task SendBinaryAsync(byte[] data, WebSocketMessageType type = WebSocketMessageType.Binary)
    {
        if (_ws?.State != WebSocketState.Open) return;
        try
        {
            await _ws.SendAsync(data, type, true, _cts?.Token ?? CancellationToken.None);
        }
        catch { /* fire-and-forget for audio frames */ }
    }
}
