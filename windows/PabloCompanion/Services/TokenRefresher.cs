using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PabloCompanion.Services;

/// <summary>
/// Refreshes Firebase ID tokens using the securetoken.googleapis.com REST API.
/// Mirrors TokenRefresher.swift on macOS.
/// </summary>
public sealed class TokenRefresher
{
    private static readonly HttpClient HttpClient = new();

    public record TokenResponse(
        [property: JsonPropertyName("id_token")] string IdToken,
        [property: JsonPropertyName("refresh_token")] string RefreshToken,
        [property: JsonPropertyName("expires_in")] string ExpiresIn
    );

    public async Task<TokenResponse> RefreshTokenAsync(string refreshToken, string apiKey)
    {
        var url = $"https://securetoken.googleapis.com/v1/token?key={Uri.EscapeDataString(apiKey)}";

        var content = new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["grant_type"] = "refresh_token",
            ["refresh_token"] = refreshToken,
        });

        var request = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = content,
        };

        var response = await HttpClient.SendAsync(request);

        if (!response.IsSuccessStatusCode)
        {
            var errorBody = await response.Content.ReadAsStringAsync();
            throw new TokenRefreshException($"Token refresh failed (HTTP {(int)response.StatusCode}): {errorBody}");
        }

        var result = await response.Content.ReadFromJsonAsync<TokenResponse>();
        return result ?? throw new TokenRefreshException("Empty token response");
    }
}

public class TokenRefreshException : Exception
{
    public TokenRefreshException(string message) : base(message) { }
}
