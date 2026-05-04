using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using PabloCompanion.Models;

namespace PabloCompanion.Services;

/// <summary>
/// REST client for practice mode endpoints.
/// Follows the same pattern as APIClient but scoped to practice domain.
/// </summary>
public sealed class PracticeApiClient
{
    private static readonly HttpClient Http = new();

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    private readonly CredentialManager _credentials;

    public string BaseUrl { get; set; } = "https://api.pablo.health";

    public PracticeApiClient(CredentialManager credentials)
    {
        _credentials = credentials;
    }

    private string GetToken()
    {
        return _credentials.IdToken
            ?? throw new InvalidOperationException("Not authenticated");
    }

    private HttpRequestMessage CreateRequest(HttpMethod method, string path)
    {
        var request = new HttpRequestMessage(method, $"{BaseUrl}{path}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", GetToken());
        request.Headers.Add("X-Client-Type", "pablo-companion-windows/1.0");
        request.Headers.Add("X-Client-Version", "1.0.0");
        request.Headers.Add("X-Client-Platform", "windows");
        return request;
    }

    private async Task<T> SendAsync<T>(HttpRequestMessage request)
    {
        var response = await Http.SendAsync(request);

        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync();
            throw new PabloException((ushort)response.StatusCode, body);
        }

        var json = await response.Content.ReadAsStringAsync();
        return JsonSerializer.Deserialize<T>(json, JsonOptions)
            ?? throw new InvalidOperationException($"Failed to deserialize {typeof(T).Name}");
    }

    // ── Topics ───────────────────────────────────────────────────────────────

    public async Task<PracticeTopic[]> FetchTopicsAsync()
    {
        var request = CreateRequest(HttpMethod.Get, "/api/practice/topics");
        var response = await SendAsync<PracticeTopicListResponse>(request);
        return response.Data;
    }

    // ── Sessions ─────────────────────────────────────────────────────────────

    public async Task<PracticeSessionResponse> CreateSessionAsync(string topicId)
    {
        var request = CreateRequest(HttpMethod.Post, "/api/practice/sessions");
        var payload = JsonSerializer.Serialize(new { topic_id = topicId });
        request.Content = new StringContent(payload, Encoding.UTF8, "application/json");
        return await SendAsync<PracticeSessionResponse>(request);
    }

    public async Task EndSessionAsync(string sessionId)
    {
        var request = CreateRequest(HttpMethod.Post, $"/api/practice/sessions/{sessionId}/end");
        var response = await Http.SendAsync(request);

        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync();
            throw new PabloException((ushort)response.StatusCode, body);
        }
    }

    /// <summary>
    /// Fetches a fresh single-use WebSocket ticket for reconnection.
    /// Tickets expire after 30 seconds.
    /// </summary>
    public async Task<string> FetchTicketAsync()
    {
        var request = CreateRequest(HttpMethod.Post, "/api/practice/ws-ticket");
        var response = await SendAsync<PracticeTicketResponse>(request);
        return response.Ticket;
    }

    /// <summary>
    /// Builds the WebSocket URL from the base URL and a single-use ticket.
    /// Forces IPv4 for localhost to avoid WebSocket IPv6 issues.
    /// </summary>
    public Uri BuildWebSocketUri(string ticket)
    {
        var wsBase = BaseUrl
            .Replace("https://", "wss://")
            .Replace("http://", "ws://")
            .Replace("://localhost", "://127.0.0.1");

        return new Uri($"{wsBase}/api/practice/ws?ticket={ticket}");
    }
}
