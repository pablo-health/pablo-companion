using System.Diagnostics;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Extensions.DependencyInjection;
using PabloCompanion.Services;

namespace PabloCompanion.ViewModels;

public enum AuthState
{
    Unauthenticated,
    Authenticating,
    Authenticated,
    TokenExpired,
}

/// <summary>
/// Manages authentication state, sign-in flow, and token refresh.
/// Uses loopback redirect (RFC 8252 §7.3):
///   1. App starts local HTTP server on ephemeral port
///   2. Browser opens {authServerUrl}/native-auth?redirect_uri=http://127.0.0.1:{port}/callback
///   3. Browser redirects to loopback; app captures the code
///   4. App exchanges code for tokens via POST to {authServerUrl}/api/auth/native/exchange
/// </summary>
public partial class AuthViewModel : ObservableObject
{

    private readonly CredentialManager _credentials;
    private readonly TokenRefresher _tokenRefresher;
    private readonly APIClient _apiClient;
    private readonly InactivityMonitor _inactivityMonitor;
    private System.Threading.Timer? _refreshTimer;
    private string? _pkceCodeVerifier;
    private string? _oauthState;
    private static readonly HttpClient s_httpClient = new();

    [ObservableProperty]
    public partial AuthState AuthState { get; set; } = AuthState.Unauthenticated;

    [ObservableProperty]
    public partial string? UserEmail { get; set; }

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    [ObservableProperty]
    public partial string ServerUrl { get; set; } = "";

    public AuthViewModel(CredentialManager credentials, TokenRefresher tokenRefresher, APIClient apiClient, InactivityMonitor inactivityMonitor)
    {
        _credentials = credentials;
        _tokenRefresher = tokenRefresher;
        _apiClient = apiClient;
        _inactivityMonitor = inactivityMonitor;
        _inactivityMonitor.OnTimeout += OnInactivityTimeout;
        _inactivityMonitor.OnScreenLocked += OnInactivityTimeout;
    }

    private void OnInactivityTimeout()
    {
        // HIPAA: lock the app after 15 minutes of inactivity.
        // Skip if a session is actively recording (therapist is talking, not at keyboard).
        App.UiDispatcherQueue?.TryEnqueue(() =>
        {
            var recordingVm = App.Services.GetRequiredService<RecordingViewModel>();
            if (recordingVm.ActiveSessionId != null) return;
            SignOut();
        });
    }

    /// <summary>
    /// Attempts to restore a saved session on app launch.
    /// </summary>
    public async Task TryRestoreSessionAsync()
    {
        var token = _credentials.IdToken;
        var refreshToken = _credentials.RefreshToken;
        var email = _credentials.UserEmail;

        if (token == null || refreshToken == null || email == null) return;

        // Restore server URL for the UI field
        var authUrl = _credentials.AuthServerUrl;
        if (!string.IsNullOrEmpty(authUrl))
            ServerUrl = authUrl;

        // Discover backend URL from server config (like Mac's configureAndLoad)
        await DiscoverServerConfigAsync();

        // Fall back to saved backend URL if config discovery failed
        var backendUrl = _credentials.BackendApiUrl;
        if (!string.IsNullOrEmpty(backendUrl))
            _apiClient.BaseUrl = backendUrl;

        var expiry = JwtDecoder.GetExpiry(token);
        if (expiry != null && expiry.Value > DateTimeOffset.UtcNow.AddMinutes(5))
        {
            UserEmail = email;
            _credentials.ActiveUserEmail = email;
            AuthState = AuthState.Authenticated;
            ScheduleTokenRefresh(expiry.Value);
        }
        else
        {
            await RefreshTokenAsync();
        }
    }

    [RelayCommand]
    private async Task SignInAsync()
    {
        // Validate and save server URL first
        if (string.IsNullOrWhiteSpace(ServerUrl))
        {
            ErrorMessage = "Enter your server URL first.";
            return;
        }

        var error = UrlValidator.ValidateScheme(ServerUrl);
        if (error != null)
        {
            ErrorMessage = error;
            return;
        }

        ServerUrl = UrlValidator.NormalizeToOrigin(ServerUrl);
        _credentials.AuthServerUrl = ServerUrl;

        // Discover backend URL before opening browser
        await DiscoverServerConfigAsync();

        using var server = new LoopbackServer();

        AuthState = AuthState.Authenticating;
        ErrorMessage = null;

        try
        {
            // Start loopback server — must happen BEFORE opening browser
            // so the port is bound and ready to receive the callback.
            // The server starts listening synchronously inside StartAndWaitForCallbackAsync
            // before awaiting the connection. We need to build the URL first though,
            // so we use a two-step approach: start + wait.

            // Use a TcpListener to find the port, then build the URL
            var serverTask = server.StartAndWaitForCallbackAsync(TimeSpan.FromSeconds(120));

            var redirectUri = server.RedirectUri;
            var redirectEncoded = Uri.EscapeDataString(redirectUri);
            var loginUrl = $"{ServerUrl.TrimEnd('/')}/native-auth?redirect_uri={redirectEncoded}";

            var tenantId = _credentials.TenantId;
            if (!string.IsNullOrEmpty(tenantId))
            {
                loginUrl += $"&tenant_id={Uri.EscapeDataString(tenantId)}";
            }

            // PKCE (RFC 7636)
            _pkceCodeVerifier = PkceHelper.GenerateCodeVerifier();
            var challenge = PkceHelper.CodeChallenge(_pkceCodeVerifier);
            loginUrl += $"&code_challenge={Uri.EscapeDataString(challenge)}&code_challenge_method=S256";

            // OAuth state (RFC 6749 §10.12) — CSRF / cross-flow protection
            _oauthState = PkceHelper.GenerateState();
            loginUrl += $"&state={Uri.EscapeDataString(_oauthState)}";

            Process.Start(new ProcessStartInfo
            {
                FileName = loginUrl,
                UseShellExecute = true,
            });

            var callbackUri = await serverTask;

            // Extract authorization code from callback
            var query = System.Web.HttpUtility.ParseQueryString(callbackUri.Query);
            var code = query["code"];

            if (string.IsNullOrEmpty(code) || !Regex.IsMatch(code, @"^[a-zA-Z0-9_\-\.]{10,2000}$"))
            {
                ErrorMessage = "Invalid authorization code.";
                AuthState = AuthState.Unauthenticated;
                return;
            }

            // Verify state matches the one we generated (constant-time compare).
            var returnedState = query["state"];
            var expectedState = _oauthState;
            _oauthState = null;
            if (expectedState == null || returnedState == null ||
                !PkceHelper.ConstantTimeEquals(expectedState, returnedState))
            {
                ErrorMessage = "Sign-in failed. Please try again.";
                AuthState = AuthState.Unauthenticated;
                return;
            }

            await ExchangeCodeForTokensAsync(code, redirectUri);
        }
        catch (TimeoutException)
        {
            ErrorMessage = "Sign-in timed out. Please try again.";
            AuthState = AuthState.Unauthenticated;
        }
        catch (Exception)
        {
            ErrorMessage = "Sign-in failed. Please try again.";
            AuthState = AuthState.Unauthenticated;
        }
    }

    [RelayCommand]
    private void SignOut()
    {
        _refreshTimer?.Dispose();
        _refreshTimer = null;
        _credentials.ClearAuthTokens();
        _credentials.ActiveUserEmail = null;
        UserEmail = null;
        AuthState = AuthState.Unauthenticated;

        // Clear all singleton ViewModels that hold PHI
        var sessionVm = App.Services.GetRequiredService<SessionViewModel>();
        sessionVm.ClearAllData();

        var recordingVm = App.Services.GetRequiredService<RecordingViewModel>();
        recordingVm.ClearAllData();
    }


    /// <summary>
    /// Exchanges an authorization code for id_token and refresh_token
    /// by POSTing to {authServerUrl}/api/auth/native/exchange.
    /// </summary>
    private async Task ExchangeCodeForTokensAsync(string code, string redirectUri)
    {
        var authUrl = _credentials.AuthServerUrl;
        if (string.IsNullOrWhiteSpace(authUrl))
        {
            ErrorMessage = "Auth server URL not configured.";
            AuthState = AuthState.Unauthenticated;
            return;
        }

        var exchangeUrl = $"{authUrl.TrimEnd('/')}/api/auth/native/exchange";
        var bodyObj = new Dictionary<string, string>
        {
            ["code"] = code,
            ["redirect_uri"] = redirectUri,
        };
        if (_pkceCodeVerifier != null)
        {
            bodyObj["code_verifier"] = _pkceCodeVerifier;
            _pkceCodeVerifier = null;
        }
        var payload = JsonSerializer.Serialize(bodyObj);
        var content = new StringContent(payload, Encoding.UTF8, "application/json");

        var response = await s_httpClient.PostAsync(exchangeUrl, content);
        if (!response.IsSuccessStatusCode)
        {
            ErrorMessage = $"Token exchange failed (HTTP {(int)response.StatusCode}).";
            AuthState = AuthState.Unauthenticated;
            return;
        }

        var responseBody = await response.Content.ReadAsStringAsync();
        using var doc = JsonDocument.Parse(responseBody);

        string? idToken = null;
        string? refreshToken = null;
        if (doc.RootElement.TryGetProperty("id_token", out var idProp))
            idToken = idProp.GetString();
        if (doc.RootElement.TryGetProperty("refresh_token", out var rtProp))
            refreshToken = rtProp.GetString();

        if (idToken == null || refreshToken == null)
        {
            ErrorMessage = "Invalid token exchange response — missing tokens.";
            AuthState = AuthState.Unauthenticated;
            return;
        }

        _credentials.IdToken = idToken;
        _credentials.RefreshToken = refreshToken;

        var email = JwtDecoder.GetEmail(idToken);
        _credentials.UserEmail = email;
        _credentials.ActiveUserEmail = email;
        UserEmail = email;

        var expiry = JwtDecoder.GetExpiry(idToken);
        if (expiry != null) ScheduleTokenRefresh(expiry.Value);

        // Fetch server config to discover backend URL + Firebase API key (if not already set)
        await DiscoverServerConfigAsync();

        AuthState = AuthState.Authenticated;
        ErrorMessage = null;
    }

    /// <summary>
    /// Fetches /api/config from the auth server to discover apiUrl and firebaseApiKey.
    /// Called after successful code exchange (matches macOS ContentView.configureAndLoad).
    /// </summary>
    private async Task DiscoverServerConfigAsync()
    {
        var authUrl = _credentials.AuthServerUrl;
        if (string.IsNullOrWhiteSpace(authUrl)) return;

        try
        {
            var configUrl = $"{authUrl.TrimEnd('/')}/api/config";
            var response = await s_httpClient.GetStringAsync(configUrl);
            using var doc = JsonDocument.Parse(response);

            if (doc.RootElement.TryGetProperty("apiUrl", out var apiUrl))
            {
                var url = apiUrl.GetString();
                if (url != null)
                {
                    _credentials.BackendApiUrl = url;
                    _apiClient.BaseUrl = url;
                }
            }
            if (doc.RootElement.TryGetProperty("firebaseApiKey", out var fbKey))
            {
                var key = fbKey.GetString();
                if (key != null) _credentials.FirebaseApiKey = key;
            }
        }
        catch
        {
            // Config discovery is best-effort; user can configure manually in settings
        }
    }

    private async Task RefreshTokenAsync()
    {
        var refreshToken = _credentials.RefreshToken;
        var apiKey = _credentials.FirebaseApiKey;

        if (refreshToken == null || apiKey == null)
        {
            AuthState = AuthState.TokenExpired;
            return;
        }

        try
        {
            var result = await _tokenRefresher.RefreshTokenAsync(refreshToken, apiKey);
            _credentials.IdToken = result.IdToken;
            _credentials.RefreshToken = result.RefreshToken;

            var email = JwtDecoder.GetEmail(result.IdToken);
            _credentials.UserEmail = email;
            _credentials.ActiveUserEmail = email;
            UserEmail = email;

            var expiry = JwtDecoder.GetExpiry(result.IdToken);
            if (expiry != null) ScheduleTokenRefresh(expiry.Value);

            AuthState = AuthState.Authenticated;
        }
        catch
        {
            AuthState = AuthState.TokenExpired;
        }
    }

    private void ScheduleTokenRefresh(DateTimeOffset expiry)
    {
        _refreshTimer?.Dispose();

        // Refresh 5 minutes before expiry
        var delay = expiry - DateTimeOffset.UtcNow - TimeSpan.FromMinutes(5);
        if (delay < TimeSpan.Zero) delay = TimeSpan.Zero;

        _refreshTimer = new System.Threading.Timer(
            async _ => await RefreshTokenAsync(),
            null,
            delay,
            Timeout.InfiniteTimeSpan
        );
    }
}

/// <summary>
/// PKCE (RFC 7636) helper for native app OAuth flows.
/// </summary>
internal static class PkceHelper
{
    public static string GenerateCodeVerifier()
    {
        var bytes = new byte[32];
        RandomNumberGenerator.Fill(bytes);
        return Convert.ToBase64String(bytes)
            .Replace("+", "-")
            .Replace("/", "_")
            .TrimEnd('=');
    }

    public static string CodeChallenge(string verifier)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(verifier));
        return Convert.ToBase64String(hash)
            .Replace("+", "-")
            .Replace("/", "_")
            .TrimEnd('=');
    }

    /// <summary>
    /// Generates a cryptographically random OAuth 2.0 state value (RFC 6749 §10.12).
    /// </summary>
    public static string GenerateState() => GenerateCodeVerifier();

    /// <summary>
    /// Constant-time string comparison. Returns false if lengths differ
    /// (leaking only length, which is not sensitive here).
    /// </summary>
    public static bool ConstantTimeEquals(string a, string b)
    {
        var ab = Encoding.UTF8.GetBytes(a);
        var bb = Encoding.UTF8.GetBytes(b);
        return CryptographicOperations.FixedTimeEquals(ab, bb);
    }
}
