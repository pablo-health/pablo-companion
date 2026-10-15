using System.Net.Http.Headers;

namespace PabloCompanion.Core;

/// <summary>
/// The authenticated-request recipe the Core clients share: backend origin,
/// Bearer token, client identification headers, and device binding.
///
/// Every value is injected, so the same code runs under the app's
/// credential-vault identity and under the headless runner's ephemeral test key,
/// and this assembly stays free of WinRT.
/// </summary>
public sealed class BackendRequest
{
    private readonly Func<string> _baseUrl;
    private readonly Func<Task<string>> _token;
    private readonly Action<HttpRequestMessage>? _attachBinding;
    private readonly IReadOnlyDictionary<string, string> _clientHeaders;

    /// <param name="baseUrl">Supplies the backend origin (no trailing slash). A delegate, not a
    /// string, because the app rediscovers its backend at sign-in and requests must follow.</param>
    /// <param name="token">Supplies a fresh Bearer token per request.</param>
    /// <param name="attachBinding">Stamps device-binding headers (<c>DPoP</c> + <c>X-Install-ID</c>)
    /// onto a request, or neither when unenrolled.</param>
    /// <param name="clientHeaders">Client identification headers (<c>X-Client-Type</c> etc.).</param>
    public BackendRequest(
        Func<string> baseUrl,
        Func<Task<string>> token,
        Action<HttpRequestMessage>? attachBinding = null,
        IReadOnlyDictionary<string, string>? clientHeaders = null)
    {
        ArgumentNullException.ThrowIfNull(baseUrl);
        ArgumentNullException.ThrowIfNull(token);

        _baseUrl = baseUrl;
        _token = token;
        _attachBinding = attachBinding;
        _clientHeaders = clientHeaders ?? new Dictionary<string, string>();
    }

    /// <summary>The absolute URL for a backend <paramref name="path"/> (leading slash included).</summary>
    public string Url(string path) => $"{_baseUrl()}{path}";

    /// <summary>
    /// Adds the Bearer token, the client headers and the device binding. The
    /// binding signs the request's method and URL, so call this once both are final.
    /// </summary>
    public async Task AuthorizeAsync(HttpRequestMessage request)
    {
        ArgumentNullException.ThrowIfNull(request);

        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await _token());
        foreach (var (name, value) in _clientHeaders)
            request.Headers.Add(name, value);
        _attachBinding?.Invoke(request);
    }
}
