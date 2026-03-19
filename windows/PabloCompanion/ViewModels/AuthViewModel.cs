using System.Diagnostics;
using System.Net.Http;
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
/// Uses authorization code exchange (matching macOS flow):
///   1. Browser opens {authServerUrl}/native-auth?redirect_uri=pablohealth://auth/callback
///   2. Callback returns pablohealth://auth/callback?code={AUTH_CODE}
///   3. App exchanges code for tokens via POST to {authServerUrl}/api/auth/native/exchange
/// </summary>
public partial class AuthViewModel : ObservableObject
{
    private const string RedirectUri = "pablohealth://auth/callback";

    private readonly CredentialManager _credentials;
    private readonly TokenRefresher _tokenRefresher;
    private readonly APIClient _apiClient;
    private System.Threading.Timer? _refreshTimer;
    private static readonly HttpClient s_httpClient = new();

    [ObservableProperty]
    public partial AuthState AuthState { get; set; } = AuthState.Unauthenticated;

    [ObservableProperty]
    public partial string? UserEmail { get; set; }

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    [ObservableProperty]
    public partial string ServerUrl { get; set; } = "";

    public AuthViewModel(CredentialManager credentials, TokenRefresher tokenRefresher, APIClient apiClient)
    {
        _credentials = credentials;
        _tokenRefresher = tokenRefresher;
        _apiClient = apiClient;
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

        AuthState = AuthState.Authenticating;
        ErrorMessage = null;

        var redirectEncoded = Uri.EscapeDataString(RedirectUri);
        var loginUrl = $"{ServerUrl.TrimEnd('/')}/native-auth?redirect_uri={redirectEncoded}";

        var tenantId = _credentials.TenantId;
        if (!string.IsNullOrEmpty(tenantId))
        {
            loginUrl += $"&tenant_id={Uri.EscapeDataString(tenantId)}";
        }

        Process.Start(new ProcessStartInfo
        {
            FileName = loginUrl,
            UseShellExecute = true,
        });
    }

    /// <summary>
    /// Called when the app receives a pablohealth:// protocol callback.
    /// Extracts the authorization code and exchanges it for tokens.
    /// </summary>
    public async Task HandleAuthCallbackAsync(Uri uri)
    {
        try
        {
            var query = System.Web.HttpUtility.ParseQueryString(uri.Query);
            var code = query["code"];

            if (string.IsNullOrEmpty(code) || !Regex.IsMatch(code, @"^[a-zA-Z0-9_\-\.]{10,2000}$"))
            {
                ErrorMessage = "Invalid authorization code.";
                AuthState = AuthState.Unauthenticated;
                return;
            }

            await ExchangeCodeForTokensAsync(code);
        }
        catch (Exception)
        {
            ErrorMessage = "Authentication failed. Please try again.";
            AuthState = AuthState.Unauthenticated;
        }
    }

    [RelayCommand]
    private void SignOut()
    {
        _refreshTimer?.Dispose();
        _refreshTimer = null;
        _credentials.ClearAll();
        UserEmail = null;
        AuthState = AuthState.Unauthenticated;

        // Clear all singleton ViewModels that hold PHI
        var sessionVm = App.Services.GetRequiredService<SessionViewModel>();
        sessionVm.ClearAllData();
    }


    /// <summary>
    /// Exchanges an authorization code for id_token and refresh_token
    /// by POSTing to {authServerUrl}/api/auth/native/exchange.
    /// </summary>
    private async Task ExchangeCodeForTokensAsync(string code)
    {
        var authUrl = _credentials.AuthServerUrl;
        if (string.IsNullOrWhiteSpace(authUrl))
        {
            ErrorMessage = "Auth server URL not configured.";
            AuthState = AuthState.Unauthenticated;
            return;
        }

        var exchangeUrl = $"{authUrl.TrimEnd('/')}/api/auth/native/exchange";
        var payload = JsonSerializer.Serialize(new { code, redirect_uri = RedirectUri });
        var content = new StringContent(payload, Encoding.UTF8, "application/json");

        var response = await s_httpClient.PostAsync(exchangeUrl, content);
        if (!response.IsSuccessStatusCode)
        {
            ErrorMessage = $"Token exchange failed (HTTP {(int)response.StatusCode}).";
            AuthState = AuthState.Unauthenticated;
            return;
        }

        var responseBody = await response.Content.ReadAsStringAsync();
        var doc = JsonDocument.Parse(responseBody);

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
            var doc = JsonDocument.Parse(response);

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
