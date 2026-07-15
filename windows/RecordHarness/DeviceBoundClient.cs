using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using PabloCompanion.Core;

namespace RecordHarness;

/// <summary>
/// Device-bound HTTP plumbing for the headless scenario.
///
/// Owns the enrollment handshake (<c>/api/auth/native/code</c> →
/// <c>/exchange</c> carrying a real enrollment payload) and DPoP-signed requests
/// (<c>Bearer</c> + <c>X-Install-ID</c> + a fresh proof), so the scenario drives
/// the identical device-binding code the shipping app uses. Every signed request
/// produces its proof from the real <see cref="DpopProof"/>, so a drift between
/// the client crypto and the server's DPoP middleware fails here.
///
/// The key is an ephemeral in-memory P-256 keypair with a fresh install id per
/// run: no credential vault, nothing persisted, and no collision with a real
/// install on the same machine.
///
/// The C# port of the harness's Swift <c>DeviceBoundClient</c>.
/// </summary>
public sealed class DeviceBoundClient : IDisposable
{
    /// <summary>
    /// The redirect URI only has to be an allowed native scheme — the harness
    /// never opens it; the code comes back in the POST body.
    /// </summary>
    public const string DefaultRedirectUri = "pablohealth://auth/callback";

    private readonly string _baseUrl;
    private readonly HttpClient _http;
    private readonly ECDsa _deviceKey;

    public string InstallId { get; }

    public DeviceBoundClient(string baseUrl, string installId, HttpClient? http = null)
    {
        _baseUrl = baseUrl.TrimEnd('/');
        InstallId = installId;
        _http = http ?? new HttpClient();
        _deviceKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    }

    public void Dispose() => _deviceKey.Dispose();

    /// <param name="Status">HTTP status code.</param>
    /// <param name="Body">Raw response body.</param>
    public sealed record Response(int Status, string Body)
    {
        /// <summary>The body parsed as JSON, or null when it isn't JSON.</summary>
        public JsonElement? Json
        {
            get
            {
                try
                {
                    using var doc = JsonDocument.Parse(Body);
                    return doc.RootElement.Clone();
                }
                catch (JsonException)
                {
                    return null;
                }
            }
        }

        public string BodyPrefix => Body.Length <= 200 ? Body : Body[..200];
    }

    /// <param name="IdToken">Refreshed id token returned by /exchange (falls back to the input).</param>
    /// <param name="ExchangeStatus">HTTP status of the /exchange call (200 on success).</param>
    /// <param name="KeyStorage">key_storage reported in the enrollment payload.</param>
    public sealed record Enrollment(string IdToken, int ExchangeStatus, string KeyStorage);

    // --- Enrollment ---

    /// <summary>
    /// Runs the OAuth code exchange carrying a real device-enrollment payload,
    /// returning the refreshed id token. Throws if <c>/native/code</c> fails.
    /// </summary>
    public async Task<Enrollment> EnrollAsync(
        string idToken,
        string refreshToken,
        string redirectUri = DefaultRedirectUri,
        CancellationToken cancellationToken = default)
    {
        var code = await PostJsonAsync("/api/auth/native/code", new
        {
            id_token = idToken,
            refresh_token = refreshToken,
            redirect_uri = redirectUri,
        }, cancellationToken);

        var oneTimeCode = code.Json.GetStringOrNull("code");
        if (code.Status != 200 || string.IsNullOrEmpty(oneTimeCode))
            throw new HarnessException($"native/code failed: {code.Status} {code.BodyPrefix}");

        // The real enrollment payload, built by the shared core from this run's
        // ephemeral key — the same builder the app uses with its vault key.
        var enrollment = DeviceEnrollment.BuildPayload(
            InstallId,
            DeviceEnrollment.PublicJwk(_deviceKey),
            DeviceEnrollment.SoftwareKeyStorage);

        var exchange = await PostJsonAsync("/api/auth/native/exchange", new
        {
            code = oneTimeCode,
            redirect_uri = redirectUri,
            enrollment,
        }, cancellationToken);

        var refreshed = exchange.Json.GetStringOrNull("id_token") ?? idToken;
        return new Enrollment(refreshed, exchange.Status, DeviceEnrollment.SoftwareKeyStorage);
    }

    // --- HTTP ---

    /// <summary>Unauthenticated JSON POST (the native code/exchange endpoints).</summary>
    public async Task<Response> PostJsonAsync(
        string path, object body, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, _baseUrl + path)
        {
            Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json"),
        };
        return await SendAsync(request, cancellationToken);
    }

    /// <summary>
    /// Authenticated request carrying the device binding exactly like the app:
    /// <c>Bearer</c> + <c>X-Install-ID</c> + a fresh <c>DPoP</c> proof.
    /// </summary>
    public async Task<Response> RequestAsync(
        HttpMethod method,
        string path,
        string idToken,
        object? jsonBody = null,
        CancellationToken cancellationToken = default)
    {
        var url = _baseUrl + path;
        using var request = new HttpRequestMessage(method, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", idToken);
        request.Headers.Add("X-Install-ID", InstallId);
        request.Headers.Add("DPoP", DpopProof.Create(_deviceKey, method.Method, url));

        if (jsonBody is not null)
        {
            request.Content = new StringContent(
                JsonSerializer.Serialize(jsonBody), Encoding.UTF8, "application/json");
        }

        return await SendAsync(request, cancellationToken);
    }

    /// <summary>
    /// Stamps the device binding onto a request built elsewhere — the delegate the
    /// shared <see cref="AudioUploadClient"/> takes, so the harness's upload carries
    /// the same headers as the app's.
    /// </summary>
    public void AttachBinding(HttpRequestMessage request)
    {
        if (request.RequestUri is null) return;
        request.Headers.Add("DPoP", DpopProof.Create(
            _deviceKey, request.Method.Method, request.RequestUri.ToString()));
        request.Headers.Add("X-Install-ID", InstallId);
    }

    private async Task<Response> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken)
    {
        using var response = await _http.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        return new Response((int)response.StatusCode, body);
    }

    /// <summary>ISO-8601 with an internet date-time format, matching the Swift harness.</summary>
    public static string Iso8601(DateTimeOffset date) =>
        date.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ");
}
