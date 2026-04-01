using System.Net;
using System.Net.Sockets;
using System.Text;

namespace PabloCompanion.Services;

/// <summary>
/// Lightweight loopback HTTP server for OAuth redirect capture (RFC 8252 §7.3).
///
/// Binds to 127.0.0.1 on an OS-assigned ephemeral port. The authorization server
/// redirects the browser to http://127.0.0.1:{port}/callback?code=..., this server
/// captures the code, serves a branded "close this tab" page, and returns the callback URI.
///
/// Uses raw TcpListener (no HttpListener) to avoid Windows URL ACL requirements.
/// </summary>
internal sealed class LoopbackServer : IDisposable
{
    private TcpListener? _listener;

    /// <summary>The OS-assigned port, available after the listener starts.</summary>
    public int Port { get; private set; }

    /// <summary>The redirect URI to send to the authorization server.</summary>
    public string RedirectUri => $"http://127.0.0.1:{Port}/callback";

    /// <summary>
    /// Starts the loopback listener and waits for the browser to redirect
    /// to the callback URL. Returns the full callback URI including query parameters.
    /// </summary>
    public async Task<Uri> StartAndWaitForCallbackAsync(TimeSpan timeout, CancellationToken ct = default)
    {
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start(1);
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout);

        try
        {
            while (!cts.Token.IsCancellationRequested)
            {
                using var client = await _listener.AcceptTcpClientAsync(cts.Token);
                await using var stream = client.GetStream();

                var buffer = new byte[4096];
                var bytesRead = await stream.ReadAsync(buffer, cts.Token);
                var request = Encoding.UTF8.GetString(buffer, 0, bytesRead);

                var uri = ParseCallbackUri(request);
                if (uri != null)
                {
                    var response = Encoding.UTF8.GetBytes(
                        $"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n{SuccessHtml}");
                    await stream.WriteAsync(response, cts.Token);
                    return uri;
                }

                // Non-callback request (favicon, etc.) — send 404
                var notFound = "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n"u8.ToArray();
                await stream.WriteAsync(notFound, cts.Token);
            }

            throw new OperationCanceledException();
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new TimeoutException("Sign-in timed out. Please try again.");
        }
    }

    public void Dispose()
    {
        try { _listener?.Stop(); }
        catch { /* best effort */ }
        _listener = null;
    }

    private Uri? ParseCallbackUri(string httpRequest)
    {
        var firstLine = httpRequest.Split("\r\n", StringSplitOptions.None)[0];
        var parts = firstLine.Split(' ');
        if (parts.Length < 2 || parts[0] != "GET") return null;

        var path = parts[1];
        if (!path.StartsWith("/callback", StringComparison.Ordinal)) return null;

        return new Uri($"http://127.0.0.1:{Port}{path}");
    }

    private const string SuccessHtml = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>Pablo</title>
        <style>body{font-family:'Segoe UI','DM Sans',sans-serif;background:#FDF6EC;color:#2C1810;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}.card{text-align:center;padding:48px}h1{font-size:24px;margin-bottom:8px}p{color:#6B5B4F;font-size:16px}</style></head>
        <body><div class="card"><h1>Sign-in successful!</h1><p>You can close this tab and return to Pablo.</p></div>
        <script>setTimeout(function(){window.close()},2000)</script></body></html>
        """;
}
