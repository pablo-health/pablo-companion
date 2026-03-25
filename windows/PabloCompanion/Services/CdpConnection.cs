using System.Net.Http;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PabloCompanion.Services;

/// <summary>
/// Minimal Chrome DevTools Protocol (CDP) client over WebSocket.
/// Connects to Chrome's remote debugging port, evaluates JavaScript,
/// and sends CDP commands.
/// Mirrors CDPConnection.swift on macOS.
/// </summary>
public sealed class CdpConnection : IAsyncDisposable
{
    private readonly ClientWebSocket _ws = new();
    private int _nextId;
    private readonly Dictionary<int, TaskCompletionSource<JsonElement>> _pending = new();
    private readonly object _lock = new();
    private CancellationTokenSource? _receiveCts;
    private Task? _receiveLoop;

    /// <summary>
    /// Connects to Chrome's debugging endpoint and opens a WebSocket to the first tab.
    /// </summary>
    public async Task ConnectAsync(int port = 9222, CancellationToken ct = default)
    {
        // Get the first debuggable page target
        using var http = new HttpClient();
        var json = await http.GetStringAsync($"http://127.0.0.1:{port}/json", ct);
        var targets = JsonSerializer.Deserialize<CdpTarget[]>(json);
        var pageTarget = targets?.FirstOrDefault(t => t.Type == "page")
            ?? throw new EhrNavigatorException("No debuggable page found in Chrome");

        var wsUrl = pageTarget.WebSocketDebuggerUrl
            ?? throw new EhrNavigatorException("No WebSocket URL for Chrome page target");

        await _ws.ConnectAsync(new Uri(wsUrl), ct);

        // Start receive loop
        _receiveCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _receiveLoop = Task.Run(() => ReceiveLoopAsync(_receiveCts.Token), _receiveCts.Token);

        // Verify connection
        var result = await EvaluateJsAsync("'cdp_ok'", ct);
        if (result != "cdp_ok")
        {
            throw new EhrNavigatorException($"CDP handshake failed: got '{result}'");
        }
    }

    /// <summary>
    /// Evaluates a JavaScript expression and returns the result as a string.
    /// </summary>
    public async Task<string> EvaluateJsAsync(string expression, CancellationToken ct = default)
    {
        var result = await SendCommandAsync("Runtime.evaluate", new
        {
            expression,
            returnByValue = true,
            awaitPromise = false,
        }, ct);

        if (result.TryGetProperty("result", out var inner)
            && inner.TryGetProperty("value", out var value))
        {
            return value.ValueKind switch
            {
                JsonValueKind.String => value.GetString() ?? "",
                JsonValueKind.True => "true",
                JsonValueKind.False => "false",
                JsonValueKind.Number => value.GetRawText(),
                JsonValueKind.Null => "",
                _ => value.GetRawText(),
            };
        }

        return "";
    }

    /// <summary>
    /// Sends a raw CDP command and returns the result property of the response.
    /// </summary>
    public async Task<JsonElement> SendCommandAsync(
        string method,
        object? parameters = null,
        CancellationToken ct = default)
    {
        var id = Interlocked.Increment(ref _nextId);
        var tcs = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);

        lock (_lock) { _pending[id] = tcs; }

        var request = new Dictionary<string, object?> { ["id"] = id, ["method"] = method };
        if (parameters != null) request["params"] = parameters;

        var payload = JsonSerializer.Serialize(request);
        var bytes = Encoding.UTF8.GetBytes(payload);
        await _ws.SendAsync(bytes, WebSocketMessageType.Text, true, ct);

        using var reg = ct.Register(() => tcs.TrySetCanceled(ct));
        return await tcs.Task;
    }

    /// <summary>
    /// Adds a script to run on every new document (page navigation).
    /// </summary>
    public async Task AddScriptOnNewDocumentAsync(string script, CancellationToken ct = default)
    {
        await SendCommandAsync("Page.addScriptToEvaluateOnNewDocument", new { source = script }, ct);
    }

    private async Task ReceiveLoopAsync(CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        var sb = new StringBuilder();

        while (!ct.IsCancellationRequested && _ws.State == WebSocketState.Open)
        {
            try
            {
                sb.Clear();
                WebSocketReceiveResult result;
                do
                {
                    result = await _ws.ReceiveAsync(buffer, ct);
                    sb.Append(Encoding.UTF8.GetString(buffer, 0, result.Count));
                }
                while (!result.EndOfMessage);

                if (result.MessageType == WebSocketMessageType.Close)
                    break;

                var doc = JsonDocument.Parse(sb.ToString());
                if (doc.RootElement.TryGetProperty("id", out var idProp))
                {
                    var id = idProp.GetInt32();
                    TaskCompletionSource<JsonElement>? tcs;
                    lock (_lock) { _pending.Remove(id, out tcs); }

                    if (tcs != null)
                    {
                        if (doc.RootElement.TryGetProperty("error", out var error))
                        {
                            var msg = error.TryGetProperty("message", out var m)
                                ? m.GetString() ?? "CDP error"
                                : "CDP error";
                            tcs.TrySetException(new EhrNavigatorException($"CDP error: {msg}"));
                        }
                        else
                        {
                            var resultProp = doc.RootElement.TryGetProperty("result", out var r)
                                ? r.Clone()
                                : default;
                            tcs.TrySetResult(resultProp);
                        }
                    }
                }
            }
            catch (OperationCanceledException) { break; }
            catch (WebSocketException) { break; }
        }

        // Cancel any pending requests
        lock (_lock)
        {
            foreach (var tcs in _pending.Values)
            {
                tcs.TrySetCanceled();
            }
            _pending.Clear();
        }
    }

    public async ValueTask DisposeAsync()
    {
        _receiveCts?.Cancel();
        if (_ws.State == WebSocketState.Open)
        {
            try
            {
                await _ws.CloseAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None);
            }
            catch { /* best effort */ }
        }
        _ws.Dispose();
        _receiveCts?.Dispose();
    }

    private sealed record CdpTarget(
        [property: JsonPropertyName("type")] string Type,
        [property: JsonPropertyName("webSocketDebuggerUrl")] string? WebSocketDebuggerUrl
    );
}
