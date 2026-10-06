using System.Text;
using System.Text.Json;

namespace RecordHarness;

/// <summary>
/// Minimal Firebase Identity Platform REST client for the harness's
/// self-contained sign-in, so the runner can authenticate the pinned test user
/// without Node or any prior e2e state.
///
/// Strategy: try the cached refresh token first (cheap, and it avoids the
/// rate-limited <c>mfaSignIn:finalize</c> quota); on ANY failure — 401, expired or
/// revoked refresh token, network error — fall back to the full TOTP MFA dance.
/// Either path returns a fresh, MFA-stamped ID token plus a NEW refresh token
/// (the old one is invalidated within seconds of exchange).
///
/// The C# port of the harness's Swift <c>FirebaseAuth</c>.
/// </summary>
public sealed class FirebaseAuth(string apiKey, HttpClient? http = null)
{
    private const string IdpBase = "https://identitytoolkit.googleapis.com";
    private const string SecureTokenBase = "https://securetoken.googleapis.com";

    private readonly HttpClient _http = http ?? new HttpClient();

    /// <param name="IdToken">Fresh, MFA-stamped ID token.</param>
    /// <param name="RefreshToken">New refresh token; the one passed in is now invalid.</param>
    /// <param name="Mode">Which path produced it — <c>refresh-exchange</c> or <c>totp-mfa</c>.</param>
    public sealed record MintResult(string IdToken, string RefreshToken, string Mode);

    /// <summary>
    /// Mints an ID token: refresh-token exchange when one is supplied and works,
    /// otherwise password + TOTP MFA.
    /// </summary>
    public async Task<MintResult> MintAsync(
        string? refreshToken,
        string? email,
        string? password,
        string? totpSecret,
        CancellationToken cancellationToken = default)
    {
        if (!string.IsNullOrEmpty(refreshToken))
        {
            try
            {
                var (id, rt) = await ExchangeRefreshTokenAsync(refreshToken, cancellationToken);
                return new MintResult(id, rt, "refresh-exchange");
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // Expected whenever the cached token has aged out or been rotated;
                // the TOTP path below is the recovery, so this is a note, not a failure.
                Harness.Log($"refresh exchange failed, falling back to TOTP MFA: {ex.Message}");
            }
        }

        if (string.IsNullOrEmpty(email) || string.IsNullOrEmpty(password) || string.IsNullOrEmpty(totpSecret))
            throw new HarnessException("TOTP fallback requires FB_EMAIL, FB_PASSWORD, FB_TOTP_SECRET");

        // The account is shared with other test runs, and Identity Platform accepts
        // each TOTP code once. Every client waits for the start of a fresh 30 s window
        // before computing its code, so two sign-ins in the same half-minute send the
        // same code and the second gets INVALID_CODE. Retry that in the next window:
        // FreshCodeAsync waits for it, so each retry sends a different, valid code.
        for (var usedCodeRetries = 0; ; usedCodeRetries++)
        {
            try
            {
                var (idToken, newRefresh) = await SignInWithMfaAsync(email, password, totpSecret, cancellationToken);
                return new MintResult(idToken, newRefresh, "totp-mfa");
            }
            catch (HarnessException ex) when (IsCodeAlreadyUsed(ex) && usedCodeRetries < MaxUsedCodeRetries)
            {
                Harness.Log(
                    "mfaSignIn:finalize refused this window's code (another sign-in used it?) — "
                    + $"retrying in the next window ({usedCodeRetries + 1}/{MaxUsedCodeRetries})");
            }
        }
    }

    private const int MaxUsedCodeRetries = 2;

    /// <summary>
    /// True when Identity Platform refused the TOTP code. With a correct secret and
    /// clock that means a concurrent sign-in to the same account already spent it; a
    /// wrong secret fails the same way on every window, so the bounded retry still
    /// surfaces it.
    /// </summary>
    internal static bool IsCodeAlreadyUsed(HarnessException ex) =>
        ex.Message.StartsWith("v2/accounts/mfaSignIn:finalize failed: 400", StringComparison.Ordinal)
        && ex.Message.Contains("INVALID_CODE", StringComparison.Ordinal);

    // --- Refresh-token exchange (securetoken) ---

    private async Task<(string IdToken, string RefreshToken)> ExchangeRefreshTokenAsync(
        string refreshToken, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(
            HttpMethod.Post, $"{SecureTokenBase}/v1/token?key={apiKey}")
        {
            Content = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["grant_type"] = "refresh_token",
                ["refresh_token"] = refreshToken,
            }),
        };

        using var response = await _http.SendAsync(request, cancellationToken);
        var json = await ReadJsonAsync(response, "securetoken/v1/token", cancellationToken);

        // This endpoint returns snake_case despite the rest of IDP being camelCase.
        var id = json.GetPropertyOrNull("id_token")?.GetString();
        var rt = json.GetPropertyOrNull("refresh_token")?.GetString();
        if (string.IsNullOrEmpty(id) || string.IsNullOrEmpty(rt))
            throw new HarnessException("securetoken response missing id_token/refresh_token");

        return (id, rt);
    }

    // --- Password + TOTP MFA ---

    private async Task<(string IdToken, string RefreshToken)> SignInWithMfaAsync(
        string email, string password, string totpSecret, CancellationToken cancellationToken)
    {
        var signIn = await IdpPostAsync("v1/accounts:signInWithPassword", new
        {
            email,
            password,
            returnSecureToken = true,
        }, cancellationToken);

        var pending = signIn.GetPropertyOrNull("mfaPendingCredential")?.GetString();
        if (string.IsNullOrEmpty(pending))
            throw new HarnessException("no mfaPendingCredential (account not MFA-enrolled?)");

        var enrollmentId = signIn.GetPropertyOrNull("mfaInfo")
            ?.EnumerateArray().FirstOrDefault()
            .GetPropertyOrNull("mfaEnrollmentId")?.GetString();
        if (string.IsNullOrEmpty(enrollmentId))
            throw new HarnessException("no mfaInfo[0].mfaEnrollmentId in sign-in response");

        var code = await Totp.FreshCodeAsync(totpSecret, cancellationToken);
        var final = await IdpPostAsync("v2/accounts/mfaSignIn:finalize", new
        {
            mfaPendingCredential = pending,
            mfaEnrollmentId = enrollmentId,
            totpVerificationInfo = new { verificationCode = code },
        }, cancellationToken);

        var id = final.GetPropertyOrNull("idToken")?.GetString();
        var rt = final.GetPropertyOrNull("refreshToken")?.GetString();
        if (string.IsNullOrEmpty(id) || string.IsNullOrEmpty(rt))
            throw new HarnessException("mfaSignIn:finalize response missing idToken/refreshToken");

        return (id, rt);
    }

    // --- Helpers ---

    private async Task<JsonElement> IdpPostAsync(
        string path, object body, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"{IdpBase}/{path}?key={apiKey}")
        {
            Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json"),
        };
        using var response = await _http.SendAsync(request, cancellationToken);
        return await ReadJsonAsync(response, path, cancellationToken);
    }

    private static async Task<JsonElement> ReadJsonAsync(
        HttpResponseMessage response, string path, CancellationToken cancellationToken)
    {
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
            throw new HarnessException($"{path} failed: {(int)response.StatusCode} {Truncate(body)}");

        try
        {
            // Clone so the element outlives the JsonDocument.
            using var doc = JsonDocument.Parse(body);
            return doc.RootElement.Clone();
        }
        catch (JsonException ex)
        {
            throw new HarnessException($"{path}: response was not JSON: {ex.Message}");
        }
    }

    /// <summary>
    /// Trims an error body before it reaches a log. Firebase error payloads are
    /// small, but they can echo the request — and the request carries a password.
    /// </summary>
    private static string Truncate(string body) =>
        body.Length <= 200 ? body : body[..200] + "…";
}
