using System.Web;

namespace PabloCompanion.Services;

/// <summary>
/// Outcome of inspecting an incoming deep-link URI for the session-handoff flow.
/// </summary>
public enum LaunchLinkKind
{
    /// <summary>Not a recognized session-handoff link — caller should ignore it.</summary>
    None,

    /// <summary>
    /// A launch intent to redeem via <c>POST /api/launch/redeem</c>. Covers both the
    /// domain-verified <c>https://&lt;host&gt;/launch/&lt;intent_id&gt;</c> shape and the
    /// legacy <c>pablohealth://session/start?intent=&lt;intent_id&gt;</c> fallback.
    /// </summary>
    Intent,

    /// <summary>
    /// Legacy <c>pablohealth://session/start?appointment=&lt;id&gt;</c> with no intent —
    /// the pre-handoff "trust the raw appointment id" path. Only used when no
    /// <c>intent</c> param is present.
    /// </summary>
    LegacyAppointment,
}

/// <summary>
/// Result of parsing a deep-link URI: what kind of handoff it is and the
/// extracted identifier (intent id or appointment id, depending on kind).
/// </summary>
public readonly record struct LaunchLink(LaunchLinkKind Kind, string? Value)
{
    public static LaunchLink None { get; } = new(LaunchLinkKind.None, null);
}

/// <summary>
/// Pure parsing logic for the companion's two deep-link entry points:
///   * domain-verified App URI Handler links: <c>https://&lt;host&gt;/launch/&lt;intent_id&gt;</c>
///   * legacy custom scheme: <c>pablohealth://session/start?intent=&lt;id&gt;</c>
///     (and the older <c>?appointment=&lt;id&gt;</c> form).
///
/// Kept free of UI / network dependencies so the dispatch rules are unit-testable.
/// Per the handoff contract: when an <c>intent</c> is present we redeem it and
/// ignore any <c>appointment</c> param; only an intent-less legacy link falls
/// back to the raw appointment id.
/// </summary>
public static class LaunchIntentParser
{
    /// <summary>
    /// Hosts whose verified <c>/launch/&lt;intent_id&gt;</c> links this build accepts.
    /// Both env hosts are listed so one signed build serves dev and prod, matching
    /// the AppUriHandler hosts declared in <c>Package.appxmanifest</c>.
    /// </summary>
    private static readonly string[] VerifiedHosts =
    [
        "app.pablo.health",
        "dev.pablo.health",
    ];

    /// <summary>
    /// Classifies an incoming deep-link URI. Returns <see cref="LaunchLink.None"/>
    /// for anything that isn't a session-handoff link (OAuth callbacks, unknown
    /// shapes). Never throws — malformed input maps to <see cref="LaunchLink.None"/>.
    /// </summary>
    public static LaunchLink Parse(Uri? uri)
    {
        if (uri is null) return LaunchLink.None;

        // Domain-verified App URI Handler link: https://<host>/launch/<intent_id>
        if (string.Equals(uri.Scheme, "https", StringComparison.OrdinalIgnoreCase) &&
            IsVerifiedHost(uri.Host))
        {
            var intentId = ExtractLaunchSegment(uri.AbsolutePath);
            return intentId is null
                ? LaunchLink.None
                : new LaunchLink(LaunchLinkKind.Intent, intentId);
        }

        // Legacy custom scheme: pablohealth://session/start?intent=... | ?appointment=...
        if (string.Equals(uri.Scheme, "pablohealth", StringComparison.OrdinalIgnoreCase) &&
            string.Equals(uri.Host, "session", StringComparison.OrdinalIgnoreCase) &&
            string.Equals(uri.AbsolutePath.Trim('/'), "start", StringComparison.OrdinalIgnoreCase))
        {
            var query = HttpUtility.ParseQueryString(uri.Query);

            // Intent wins: redeem it and ignore any appointment param.
            var intent = query.Get("intent");
            if (!string.IsNullOrEmpty(intent))
            {
                return new LaunchLink(LaunchLinkKind.Intent, intent);
            }

            var appointment = query.Get("appointment");
            if (!string.IsNullOrEmpty(appointment))
            {
                return new LaunchLink(LaunchLinkKind.LegacyAppointment, appointment);
            }
        }

        return LaunchLink.None;
    }

    private static bool IsVerifiedHost(string host)
    {
        foreach (var h in VerifiedHosts)
        {
            if (string.Equals(host, h, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    /// <summary>
    /// Extracts the trailing <c>&lt;intent_id&gt;</c> from a <c>/launch/&lt;intent_id&gt;</c>
    /// path. Returns null if the path isn't exactly <c>/launch/&lt;single-segment&gt;</c>
    /// with a non-empty id. We do not trust anything in the URL beyond this segment.
    /// </summary>
    private static string? ExtractLaunchSegment(string absolutePath)
    {
        var segments = absolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length != 2) return null;
        if (!string.Equals(segments[0], "launch", StringComparison.OrdinalIgnoreCase)) return null;

        var id = Uri.UnescapeDataString(segments[1]);
        return string.IsNullOrWhiteSpace(id) ? null : id;
    }
}
