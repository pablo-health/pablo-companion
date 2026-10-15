using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using PabloCompanion.Core;
using PabloCompanion.Services;
using PabloCompanion.ViewModels;

namespace PabloCompanion.Tests.ViewModels;

/// <summary>
/// A device-link retry repeats the browser sign-in (same PKCE flow) while the
/// clinician is already signed in. A failed retry must not sign them out.
/// The browser and the exchange endpoint are stubbed; the rest of the sign-in
/// flow is the real one. Mirrors <c>DeviceLinkTests</c> on macOS.
/// </summary>
public sealed class DeviceLinkRetryTests : IDisposable
{
    private const string Email = "clinician@example.com";

    private readonly InMemoryCredentialManager _credentials = new();
    private readonly InactivityMonitor _inactivity = new();
    private readonly ProtocolActivationListener _listener = new();
    private readonly List<string> _exchangeBodies = [];

    public void Dispose() => _inactivity.Dispose();

    private AuthViewModel SignedInViewModel(Func<HttpResponseMessage> exchange)
    {
        var deviceKey = new DeviceKeyService(_credentials);
        var vm = new AuthViewModel(
            _credentials,
            deviceKey,
            new TokenRefresher(),
            new APIClient(_credentials, deviceKey),
            _inactivity,
            _listener)
        {
            ServerUrl = "https://auth.example.test",
            Http = new HttpClient(new StubHandler(request =>
            {
                if (request.RequestUri!.AbsolutePath == "/api/auth/native/exchange")
                {
                    _exchangeBodies.Add(request.Content!.ReadAsStringAsync().Result);
                    return exchange();
                }
                return new HttpResponseMessage(HttpStatusCode.NotFound);
            })),
        };

        // The browser redirects straight back with a code and the state it was given.
        vm.OpenBrowser = url =>
        {
            var state = System.Web.HttpUtility.ParseQueryString(new Uri(url).Query)["state"];
            _listener.Deliver(new Uri($"pablohealth://callback?code=abcdefghij123456&state={state}"));
        };

        vm.UserEmail = Email;
        vm.AuthState = AuthState.Authenticated;
        vm.DeviceLinkFailed = true;
        return vm;
    }

    [Fact]
    public async Task AFailedRetry_KeepsTheClinicianSignedIn()
    {
        var vm = SignedInViewModel(() => new HttpResponseMessage(HttpStatusCode.InternalServerError));

        await vm.RetryDeviceLinkCommand.ExecuteAsync(null);

        Assert.Equal(AuthState.Authenticated, vm.AuthState);
        Assert.Equal(Email, vm.UserEmail);
        Assert.Null(vm.ErrorMessage);
        Assert.True(vm.DeviceLinkFailed);
        Assert.False(vm.IsRelinkingDevice);

        // The retry really did run the PKCE exchange.
        var body = Assert.Single(_exchangeBodies);
        using var doc = JsonDocument.Parse(body);
        Assert.True(doc.RootElement.TryGetProperty("code_verifier", out _));
    }

    [Fact]
    public async Task ARetryTheServerEnrolls_ClearsTheNote()
    {
        var vm = SignedInViewModel(() => Json(new
        {
            id_token = Jwt(Email, DateTimeOffset.UtcNow.AddHours(1)),
            refresh_token = "refresh-token",
            enrollment = "enrolled",
        }));

        await vm.RetryDeviceLinkCommand.ExecuteAsync(null);

        Assert.Equal(AuthState.Authenticated, vm.AuthState);
        Assert.False(vm.DeviceLinkFailed);
        Assert.False(vm.IsRelinkingDevice);
    }

    [Fact]
    public void AFailedSignIn_SignsOutWhenNotRetrying()
    {
        var vm = SignedInViewModel(() => new HttpResponseMessage(HttpStatusCode.InternalServerError));
        vm.AuthState = AuthState.Authenticating;

        vm.FailSignIn("Sign-in failed. Please try again.");

        Assert.Equal(AuthState.Unauthenticated, vm.AuthState);
        Assert.Equal("Sign-in failed. Please try again.", vm.ErrorMessage);
    }

    private static HttpResponseMessage Json(object body) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json"),
    };

    private static string Jwt(string email, DateTimeOffset expiry)
    {
        static string Segment(string json) =>
            Convert.ToBase64String(Encoding.UTF8.GetBytes(json)).Replace('+', '-').Replace('/', '_').TrimEnd('=');
        var claims = JsonSerializer.Serialize(new { email, exp = expiry.ToUnixTimeSeconds() });
        return $"{Segment("""{"alg":"RS256"}""")}.{Segment(claims)}.signature";
    }

    /// <summary>Keeps credentials in memory so the test never touches the real vault.</summary>
    private sealed class InMemoryCredentialManager : CredentialManager
    {
        private readonly Dictionary<string, string> _values = [];

        public override string? GetValue(string key) => _values.GetValueOrDefault(key);

        public override void SetValue(string key, string value) => _values[key] = value;
    }

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(respond(request));
    }
}
