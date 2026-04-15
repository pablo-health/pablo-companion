using System.Text.Json.Serialization;

namespace PabloCompanion.Models;

/// <summary>
/// Wrapper for the GET /api/users/me/status response.
/// </summary>
public sealed record SubscriptionResponse(
    [property: JsonPropertyName("subscription")]
    SubscriptionInfo? Subscription);

/// <summary>
/// Subscription details returned by the backend.
/// </summary>
public sealed record SubscriptionInfo(
    [property: JsonPropertyName("status")]
    string Status,
    [property: JsonPropertyName("plan")]
    string Plan,
    [property: JsonPropertyName("trial_sessions_used")]
    int? TrialSessionsUsed,
    [property: JsonPropertyName("trial_sessions_limit")]
    int? TrialSessionsLimit,
    [property: JsonPropertyName("trial_days_limit")]
    int? TrialDaysLimit,
    [property: JsonPropertyName("trial_start")]
    string? TrialStart,
    [property: JsonPropertyName("grace_extension_available")]
    bool GraceExtensionAvailable,
    [property: JsonPropertyName("grace_extension_expires_at")]
    string? GraceExtensionExpiresAt);
