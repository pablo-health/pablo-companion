namespace RecordHarness;

/// <summary>
/// Watches the requests the shared <c>AudioUploadClient</c> sends, so the gate
/// can say which upload path a run actually took.
///
/// The client takes its two <see cref="HttpClient"/>s injected (one for the
/// backend, one for the direct-to-storage PUTs); handing it clients built on this
/// handler is the whole hook, with no change to the client. Only the method, the
/// host, the path and the status are kept: a signed URL's query string is its
/// credential, so it is never stored or logged.
/// </summary>
internal sealed class WireRecorder : DelegatingHandler
{
    /// <param name="Method">HTTP method.</param>
    /// <param name="Host">Request host.</param>
    /// <param name="Path">Request path, without the query string.</param>
    /// <param name="Status">Response status, or -1 when the request threw.</param>
    internal sealed record Exchange(string Method, string Host, string Path, int Status)
    {
        internal bool Succeeded => Status is >= 200 and < 300;
    }

    private readonly List<Exchange> _exchanges = [];
    private readonly object _lock = new();

    internal WireRecorder(HttpMessageHandler? inner = null) : base(inner ?? new HttpClientHandler()) { }

    /// <summary>Every exchange so far, in the order it completed.</summary>
    internal IReadOnlyList<Exchange> Exchanges
    {
        get { lock (_lock) return [.. _exchanges]; }
    }

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var uri = request.RequestUri;
        var method = request.Method.Method;
        var host = uri?.Host ?? "";
        var path = uri?.AbsolutePath ?? "";
        try
        {
            var response = await base.SendAsync(request, cancellationToken);
            Add(new Exchange(method, host, path, (int)response.StatusCode));
            return response;
        }
        catch
        {
            Add(new Exchange(method, host, path, -1));
            throw;
        }
    }

    private void Add(Exchange exchange)
    {
        lock (_lock) _exchanges.Add(exchange);
    }

    /// <summary>
    /// The signed-URL gate: init and finalize went to the backend and succeeded,
    /// both channels were PUT straight to a host that is not the backend, and the
    /// legacy multipart POST (the one the load balancer 413s on a long session)
    /// was never sent.
    /// </summary>
    internal static Check SignedUrlCheck(
        IReadOnlyList<Exchange> backend, IReadOnlyList<Exchange> storage, string backendHost)
    {
        bool Ok(string suffix) => backend.Any(e =>
            e.Method == "POST" && e.Path.EndsWith(suffix, StringComparison.Ordinal) && e.Succeeded);

        var init = Ok("/upload-audio/init");
        var finalize = Ok("/upload-audio/finalize");
        var multipart = backend.Any(e =>
            e.Method == "POST" && e.Path.EndsWith("/upload-audio", StringComparison.Ordinal));
        var puts = storage.Where(e => e.Method == "PUT" && e.Succeeded).ToList();
        var offBackend = puts.All(e => !string.Equals(e.Host, backendHost, StringComparison.OrdinalIgnoreCase));
        var hosts = string.Join(",", puts.Select(e => e.Host).Distinct());

        return new Check(
            "signed-URL upload (init, PUT x2 to storage, finalize)",
            init && finalize && puts.Count >= 2 && offBackend && !multipart,
            $"init {(init ? "ok" : "missing")}, {puts.Count} PUT(s) to [{hosts}], "
                + $"finalize {(finalize ? "ok" : "missing")}, multipart POST {(multipart ? "SENT" : "not sent")}");
    }
}
