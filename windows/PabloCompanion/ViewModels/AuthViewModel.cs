using System.Diagnostics;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Extensions.DependencyInjection;
using PabloCompanion.Core;
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
/// Uses custom URL scheme protocol activation (RFC 8252 §7.1):
///   1. AuthViewModel awaits ProtocolActivationListener for the next pablohealth:// URI
///   2. Browser opens {authServerUrl}/native-auth?redirect_uri=pablohealth://callback
///   3. Browser redirects to pablohealth://callback?code=...&state=...
///   4. Windows reactivates the packaged app with the URI; listener delivers it
///   5. App exchanges code for tokens via POST to {authServerUrl}/api/auth/native/exchange
///
/// Replaces the prior loopback HTTP listener pattern, which required a
/// CheckNetIsolation LoopbackExempt entry that isn't viable for Store-distributed
/// packaged apps.
/// </summary>
public partial class AuthViewModel : ObservableObject
{
    private const string NativeRedirectUri = "pablohealth://callback";

    private readonly CredentialManager _credentials;
    private readonly DeviceKeyService _deviceKey;
    private readonly TokenRefresher _tokenRefresher;
    private readonly APIClient _apiClient;
    private readonly InactivityMonitor _inactivityMonitor;
    private readonly ProtocolActivationListener _protocolListener;
    private System.Threading.Timer? _refreshTimer;
    private string? _pkceCodeVerifier;
    private string? _oauthState;
    private bool _isHandlingAuthFailure;
    private bool _isSigningOut;
    private static readonly HttpClient s_httpClient = new();

    [ObservableProperty]
    public partial AuthState AuthState { get; set; } = AuthState.Unauthenticated;

    [ObservableProperty]
    public partial string? UserEmail { get; set; }

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    [ObservableProperty]
    public partial string ServerUrl { get; set; } = AppConstants.DefaultAuthServerUrl;

    /// <summary>
    /// Controls visibility of the "Connect to a different server" UI on the login screen.
    /// Hidden by default — therapists installing from the Store sign in against
    /// <see cref="AppConstants.DefaultAuthServerUrl"/> without ever seeing a URL field.
    /// Auto-shown when a saved URL exists that differs from the default (dev / self-host).
    /// </summary>
    [ObservableProperty]
    public partial bool IsAdvancedVisible { get; set; }

    /// <summary>
    /// True when the last sign-in could not register this PC with the server.
    /// Until it is registered the web dashboard cannot tell the app is installed
    /// and keeps offering the download, so the main window shows a note with a
    /// retry. Mirrors <c>deviceLinkFailed</c> on macOS.
    /// </summary>
    [ObservableProperty]
    public partial bool DeviceLinkFailed { get; set; }

    /// <summary>A retry from <see cref="RetryDeviceLinkCommand"/> is in flight.</summary>
    [ObservableProperty]
    public partial bool IsRelinkingDevice { get; set; }

    /// <summary>The client used for the code exchange and config discovery. Replaced in tests.</summary>
    internal HttpClient Http { get; set; } = s_httpClient;

    /// <summary>Opens the sign-in page in the browser. Replaced in tests.</summary>
    internal Action<string> OpenBrowser { get; set; } = url =>
        Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });

    public AuthViewModel(
        CredentialManager credentials,
        DeviceKeyService deviceKey,
        TokenRefresher tokenRefresher,
        APIClient apiClient,
        InactivityMonitor inactivityMonitor,
        ProtocolActivationListener protocolListener)
    {
        _credentials = credentials;
        _deviceKey = deviceKey;
        _tokenRefresher = tokenRefresher;
        _apiClient = apiClient;
        _inactivityMonitor = inactivityMonitor;
        _protocolListener = protocolListener;
        _inactivityMonitor.OnTimeout += OnInactivityTimeout;
        _inactivityMonitor.OnScreenLocked += OnInactivityTimeout;
        // When the server invalidates our session mid-flight (401), drive the
        // UI back to the login screen instead of leaving the user on a page
        // that can no longer load data. Mirrors macOS getValidToken → signOut.
        _apiClient.UnauthenticatedDetected += OnApiUnauthenticated;

        // Restore saved server URL if non-empty; otherwise stay on the default.
        // Show the "Connect to a different server" panel only when the saved URL
        // differs from the default — i.e. self-host or dev configuration.
        var saved = _credentials.AuthServerUrl;
        if (!string.IsNullOrEmpty(saved))
        {
            ServerUrl = saved;
            IsAdvancedVisible = saved != AppConstants.DefaultAuthServerUrl;
        }
    }

    [RelayCommand]
    private void ShowAdvanced() => IsAdvancedVisible = true;

    private void OnInactivityTimeout()
    {
        // HIPAA: lock the app after 15 minutes of inactivity.
        // Skip if a session is actively recording (therapist is talking, not at keyboard).
        App.UiDispatcherQueue?.TryEnqueue(() =>
        {
            var recordingVm = App.Services.GetRequiredService<RecordingViewModel>();
            if (recordingVm.ActiveSessionId != null) return;
            _ = SignOutAsync();
        });
    }

    /// <summary>
    /// Fires when an API client gets a 401 on an authenticated request. Signs the
    /// user out so MainWindow swaps back to LoginPage — refreshing the Firebase
    /// token wouldn't help here. The backend enforces a server-side idle timeout
    /// (HIPAA §164.312(a)(2)(iii)) keyed on auth_time, and a Firebase refresh
    /// re-issues a token with the same auth_time, so the revoked-session tombstone
    /// still rejects it (see backend/app/auth/idle_session.py). Only a fresh
    /// sign-in (new auth_time) recovers. The proactive refresh timer above already
    /// handles natural id_token expiry, so a 401 here means real backend rejection.
    /// <paramref name="errorCode"/> is the body's structured error code;
    /// <see cref="APIClient.IdleTimeoutCode"/> gets a distinct "expired due to
    /// inactivity" message on the login screen instead of a generic auth failure.
    /// Debounced so parallel 401s from concurrent requests don't stack.
    /// </summary>
    private void OnApiUnauthenticated(string? errorCode)
    {
        App.UiDispatcherQueue?.TryEnqueue(async () =>
        {
            if (_isHandlingAuthFailure) return;
            if (this.AuthState != AuthState.Authenticated) return;
            _isHandlingAuthFailure = true;
            try
            {
                await SignOutAsync();
                ErrorMessage = SessionRejectedMessage(errorCode);
            }
            finally
            {
                _isHandlingAuthFailure = false;
            }
        });
    }

    /// <summary>
    /// User-facing message for a server-side session rejection. Idle timeouts get
    /// a distinct message so the therapist knows why they were signed out.
    /// Mirrors <c>AuthViewModel.sessionRejectedMessage</c> on macOS.
    /// </summary>
    internal static string SessionRejectedMessage(string? errorCode) =>
        errorCode == APIClient.IdleTimeoutCode
            ? "Your session expired due to inactivity. Please sign in again."
            : "Your session is no longer valid. Please sign in again.";

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
        {
            _apiClient.BaseUrl = backendUrl;
        }

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

        // A device-link retry runs this flow while the clinician is already
        // signed in; the authenticated UI stays up throughout.
        if (!IsRelinkingDevice)
        {
            AuthState = AuthState.Authenticating;
            ErrorMessage = null;
        }

        try
        {
            // Arm the protocol activation listener BEFORE opening the browser,
            // so a fast redirect can't race ahead of the awaiter.
            var listenerTask = _protocolListener.WaitForCallbackAsync(TimeSpan.FromSeconds(120));

            var redirectUri = NativeRedirectUri;
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

            OpenBrowser(loginUrl);

            var callbackUri = await listenerTask;

            // Extract authorization code from callback
            var query = System.Web.HttpUtility.ParseQueryString(callbackUri.Query);
            var code = query["code"];

            if (string.IsNullOrEmpty(code) || !Regex.IsMatch(code, @"^[a-zA-Z0-9_\-\.]{10,2000}$"))
            {
                FailSignIn("Invalid authorization code.");
                return;
            }

            // Verify state matches the one we generated (constant-time compare).
            var returnedState = query["state"];
            var expectedState = _oauthState;
            _oauthState = null;
            if (expectedState == null || returnedState == null ||
                !PkceHelper.ConstantTimeEquals(expectedState, returnedState))
            {
                FailSignIn("Sign-in failed. Please try again.");
                return;
            }

            await ExchangeCodeForTokensAsync(code, redirectUri);
        }
        catch (TimeoutException)
        {
            FailSignIn("Sign-in timed out. Please try again.");
        }
        catch (Exception)
        {
            FailSignIn("Sign-in failed. Please try again.");
        }
    }

    /// <summary>
    /// Registers this PC again by repeating the browser sign-in (same PKCE flow).
    /// Enrollment only happens in the code exchange; the server has no separate
    /// endpoint for it. The clinician stays signed in here whatever happens: a
    /// failed or abandoned retry leaves the note up rather than signing them out.
    /// Mirrors <c>retryDeviceLink()</c> on macOS.
    /// </summary>
    [RelayCommand]
    private async Task RetryDeviceLinkAsync()
    {
        if (IsRelinkingDevice) return;
        IsRelinkingDevice = true;
        try
        {
            await SignInAsync();
        }
        finally
        {
            IsRelinkingDevice = false;
        }
    }

    /// <summary>
    /// Records a failed sign-in step. During a device-link retry the clinician
    /// is already signed in, so nothing changes.
    /// </summary>
    internal void FailSignIn(string? message)
    {
        if (IsRelinkingDevice) return;
        ErrorMessage = message;
        AuthState = AuthState.Unauthenticated;
    }

    [RelayCommand]
    private async Task SignOutAsync()
    {
        if (_isSigningOut) return;
        _isSigningOut = true;
        try
        {
            await StopAndQueueRecordingAsync();
            ClearSignedInState();
        }
        finally
        {
            _isSigningOut = false;
        }
    }

    /// <summary>
    /// A session recording when the sign-out arrives (a 401 mid-session, say)
    /// keeps its audio: capture ends cleanly and the audio is queued for upload
    /// with no network call, before the credentials go, because the queue is
    /// encrypted with the signed-in user's key. The upload runs after the next
    /// sign-in. Mirrors <c>stopAndQueueActiveRecording</c> on macOS.
    /// </summary>
    private static async Task StopAndQueueRecordingAsync()
    {
        var recordingVm = App.Services.GetRequiredService<RecordingViewModel>();
        if (recordingVm.ActiveSessionId is null) return;
        try
        {
            var queued = await recordingVm.StopAndQueueAsync(App.Services.GetRequiredService<PendingTranscriptionStore>());
            App.Log($"SignOut: stopped the recording; queued={queued is not null}");
        }
        catch (Exception ex)
        {
            // The audio is still on disk; the next launch's orphan scan adopts it.
            App.LogException("SignOut.StopAndQueue", ex);
        }
    }

    private void ClearSignedInState()
    {
        _refreshTimer?.Dispose();
        _refreshTimer = null;
        _credentials.ClearAuthTokens();
        _credentials.ActiveUserEmail = null;
        UserEmail = null;
        DeviceLinkFailed = false;
        AuthState = AuthState.Unauthenticated;

        // Clear all singleton ViewModels that hold PHI
        var sessionVm = App.Services.GetRequiredService<SessionViewModel>();
        sessionVm.ClearAllData();

        var recordingVm = App.Services.GetRequiredService<RecordingViewModel>();
        recordingVm.ClearAllData();

        App.Services.GetRequiredService<RecordingConsentViewModel>().ClearAllData();
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
            FailSignIn("Auth server URL not configured.");
            return;
        }

        var exchangeUrl = $"{authUrl.TrimEnd('/')}/api/auth/native/exchange";
        var bodyObj = new Dictionary<string, object?>
        {
            ["code"] = code,
            ["redirect_uri"] = redirectUri,
        };
        if (_pkceCodeVerifier != null)
        {
            bodyObj["code_verifier"] = _pkceCodeVerifier;
            _pkceCodeVerifier = null;
        }

        // Device enrollment piggy-backs on the code exchange: registers this install
        // (id + public device key) so the web dashboard can detect it and hand off.
        // Enrollment is optional server-side and the payload, when present, must be
        // schema-complete (the backend requires the JWK + key_storage). Best-effort:
        // if key generation fails we omit enrollment entirely rather than block
        // sign-in. An omitted payload still counts as a failed enrollment (see
        // DeviceEnrollment.Outcome), so the clinician hears about it.
        var sentEnrollment = false;
        try
        {
            bodyObj["enrollment"] = DeviceEnrollment.BuildPayload(
                _credentials.GetOrCreateInstallId(),
                _deviceKey.GetOrCreatePublicJwk(),
                DeviceKeyService.KeyStorage);
            sentEnrollment = true;
        }
        catch (Exception ex)
        {
            App.LogException("BuildEnrollmentPayload", ex);
        }

        var payload = JsonSerializer.Serialize(bodyObj);
        var content = new StringContent(payload, Encoding.UTF8, "application/json");

        var response = await Http.PostAsync(exchangeUrl, content);
        if (!response.IsSuccessStatusCode)
        {
            FailSignIn($"Token exchange failed (HTTP {(int)response.StatusCode}).");
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
            FailSignIn("Invalid token exchange response — missing tokens.");
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

        switch (DeviceEnrollment.Outcome(sentEnrollment, doc.RootElement))
        {
            case EnrollmentOutcome.Enrolled: DeviceLinkFailed = false; break;
            case EnrollmentOutcome.Failed: DeviceLinkFailed = true; break;
            case EnrollmentOutcome.Unreported: break;
        }
        if (DeviceLinkFailed) App.Log("Device enrollment did not complete");

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
            var response = await Http.GetStringAsync(configUrl);
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
