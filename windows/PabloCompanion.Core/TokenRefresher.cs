using System.Net.Http.Json;
using System.Text.Json.Serialization;

namespace PabloCompanion.Core;

/// <summary>
/// Refreshes Firebase ID tokens using the securetoken.googleapis.com REST API.
/// Shared by the app and the headless runner so the two send the same request.
/// Mirrors TokenRefresher.swift on macOS.
/// </summary>
public sealed class TokenRefresher
{
    private const string TokenUrl = "https://securetoken.googleapis.com/v1/token";

    private static readonly HttpClient SharedHttp = new();

    private readonly HttpClient _http;

    public TokenRefresher() : this(SharedHttp) { }

    public TokenRefresher(HttpClient http)
    {
        ArgumentNullException.ThrowIfNull(http);
        _http = http;
    }

    public record TokenResponse(
        [property: JsonPropertyName("id_token")] string IdToken,
        [property: JsonPropertyName("refresh_token")] string RefreshToken,
        [property: JsonPropertyName("expires_in")] string ExpiresIn
    );

    public async Task<TokenResponse> RefreshTokenAsync(
        string refreshToken, string apiKey, CancellationToken cancellationToken = default)
    {
        var content = new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["grant_type"] = "refresh_token",
            ["refresh_token"] = refreshToken,
        });

        using var request = new HttpRequestMessage(HttpMethod.Post, TokenUrl)
        {
            Content = content,
        };
        // Header, not a ?key= query parameter: keeps the key out of URLs and logs.
        request.Headers.Add("X-Goog-Api-Key", apiKey);

        using var response = await _http.SendAsync(request, cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            throw new TokenRefreshException($"Token refresh failed (HTTP {(int)response.StatusCode}).");
        }

        var result = await response.Content.ReadFromJsonAsync<TokenResponse>(cancellationToken);
        return result ?? throw new TokenRefreshException("Empty token response");
    }
}

public class TokenRefreshException : Exception
{
    public TokenRefreshException(string message) : base(message) { }
}
