import Foundation
import Observation
import OSLog

/// Holds an incoming deep-link URL until ContentView is authenticated and able
/// to act on it. Cold-launch from the browser fires `.onOpenURL` /
/// `.onContinueUserActivity` before sign-in finishes, so the router buffers the
/// URL and ContentView drains it on auth state change.
@Observable
final class DeepLinkRouter {
    var pendingURL: URL?

    static let logger = Logger(subsystem: "health.pablo.companion", category: "DeepLink")
}

/// Hosts the companion accepts as domain-verified Universal Link sources. Both
/// the dev and prod web hosts are served by a single signed build, so both are
/// listed in the Associated Domains entitlement and accepted here.
enum LaunchHosts {
    static let verified: Set<String> = ["app.pablo.health", "dev.pablo.health"]
}

/// Parsed action extracted from a deep-link URL.
///
/// Two transports feed this:
/// - Universal Links (`https://<host>/launch/<intent_id>`) delivered via
///   `NSUserActivity` / `onContinueUserActivity`.
/// - The legacy custom scheme (`pablohealth://…`) delivered via `onOpenURL`,
///   kept for OAuth callback and as a fallback for browsers (Firefox) that do
///   not honour Universal Links.
///
/// A launch *intent* (`redeemLaunchIntent`) always goes through a server-side
/// redemption checkpoint before any session starts. A bare `appointment=`
/// pointer with no intent is a spoofable PHI reference — anyone can craft
/// `pablohealth://session/start?appointment=<guess>` — so it is **not** resolved.
/// It maps to `.expiredPointer`, which surfaces the soft "link expired — start
/// again from the dashboard" state instead of fetching the appointment.
enum DeepLinkAction: Equatable {
    case redeemLaunchIntent(intentId: String)
    /// A raw appointment pointer arrived without a verified intent. Spoofable;
    /// never resolved to PHI. The UI shows the soft expired-link state.
    case expiredPointer
    case unsupported(reason: String)

    init(url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""

        switch scheme {
        case "https":
            self = Self.parseUniversalLink(url)
        case "pablohealth":
            self = Self.parseCustomScheme(url)
        default:
            self = .unsupported(reason: "non-pablohealth scheme: \(url.scheme ?? "nil")")
        }
    }

    /// Parses a domain-verified `https://<host>/launch/<intent_id>` Universal Link.
    /// Only the trusted hosts are honoured; the intent id is the *only* value
    /// trusted out of the URL (per the launch-URL grammar).
    private static func parseUniversalLink(_ url: URL) -> Self {
        let host = url.host?.lowercased() ?? ""
        guard LaunchHosts.verified.contains(host) else {
            return .unsupported(reason: "untrusted universal-link host: \(host)")
        }

        let segments = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard segments.count == 2, segments[0].lowercased() == "launch" else {
            return .unsupported(reason: "unexpected universal-link path: \(url.path)")
        }

        let intentId = segments[1]
        guard isValidIntentId(intentId) else {
            return .unsupported(reason: "malformed intent id")
        }
        return .redeemLaunchIntent(intentId: intentId)
    }

    /// Parses the legacy `pablohealth://` custom scheme.
    ///
    /// Dispatch rule: when handling `session/start`, an `intent` param is
    /// redeemed through the server checkpoint and any `appointment` param is
    /// ignored. A bare `appointment=` pointer with no intent is **never**
    /// resolved — the id is spoofable and resolving it would leak / act on PHI
    /// off an unverified pointer — so it maps to `.expiredPointer` (soft
    /// expired-link state). `pablohealth://launch/<id>` is also accepted as a
    /// fallback form.
    private static func parseCustomScheme(_ url: URL) -> Self {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        // pablohealth://launch/<intent_id>
        if host == "launch" {
            let intentId = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if isValidIntentId(intentId) {
                return .redeemLaunchIntent(intentId: intentId)
            }
            return .unsupported(reason: "malformed intent id")
        }

        if host == "session", path == "start" {
            let intentValue = query.first(where: { $0.name == "intent" })?.value
            if let intentId = intentValue, isValidIntentId(intentId) {
                return .redeemLaunchIntent(intentId: intentId)
            }
            // A raw appointment pointer with no verified intent is spoofable —
            // do NOT fetch the appointment. Treat it as an expired link so the
            // therapist re-launches from the (authenticated) dashboard, which
            // mints a real intent.
            if let id = query.first(where: { $0.name == "appointment" })?.value, !id.isEmpty {
                return .expiredPointer
            }
            return .unsupported(reason: "session/start without intent or appointment param")
        }

        return .unsupported(reason: "deferred resource: \(host)/\(path)")
    }

    /// Validates an opaque launch-intent id. The backend issues a 22-char
    /// base64url (no padding) token (`secrets.token_urlsafe(16)`); accept a small
    /// range to stay forward-compatible while rejecting obvious garbage / injection.
    static func isValidIntentId(_ id: String) -> Bool {
        let pattern = #"^[A-Za-z0-9_\-]{16,64}$"#
        return id.range(of: pattern, options: .regularExpression) != nil
    }
}
