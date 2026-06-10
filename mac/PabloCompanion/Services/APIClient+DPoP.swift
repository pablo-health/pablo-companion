import CompanionAuthCore
import Foundation
import os

extension APIClient {
    /// Attaches the device-binding headers (`DPoP` proof + `X-Install-ID`) to an
    /// authenticated request, when (and only when) this install is enrolled.
    ///
    /// This is the single seam every authenticated request path funnels through
    /// so no call site can forget the headers: `buildRequest(...)` calls it, and
    /// the hand-rolled requests in `APIClient+AudioUpload` / `+Subscription` call
    /// it too.
    ///
    /// Enrolled = an `install_id` exists **and** a device key can sign a proof.
    /// If signing fails (key unavailable), we send **neither** header and log a
    /// non-sensitive warning — never `X-Install-ID` without a valid `DPoP`
    /// proof, which is a guaranteed `401` once enforcement is on (see
    /// `backend/app/middleware/dpop.py`). Not enrolled → neither header, and the
    /// middleware passes the request as a legacy Firebase-bearer call.
    ///
    /// Static + `nonisolated` so it can be reached from the `nonisolated`
    /// `buildRequest` seam and from the extension request builders without
    /// hopping actors.
    nonisolated static func attachDeviceBinding(to request: inout URLRequest) {
        attachDeviceBinding(
            to: &request,
            installID: KeychainManager.installID(),
            makeProof: { method, url in DPoPProof.make(method: method, url: url) }
        )
    }

    /// Pure core of the binding seam, with the install-id source and proof
    /// factory injected so it can be exercised without touching the real
    /// Keychain or Secure Enclave. The invariant under test: attach **both**
    /// headers or **neither** — never `X-Install-ID` alone (that combination is
    /// a guaranteed 401 once enforcement is on).
    nonisolated static func attachDeviceBinding(
        to request: inout URLRequest,
        installID: String?,
        makeProof: (_ method: String, _ url: URL) -> String?
    ) {
        guard let installID, !installID.isEmpty else {
            // Not enrolled (no install_id persisted yet) → legacy request.
            return
        }
        guard let url = request.url, let method = request.httpMethod else {
            return
        }
        guard let proof = makeProof(method, url) else {
            // Key unavailable / signing failed. Send NEITHER header — an
            // X-Install-ID without a matching proof is a guaranteed 401.
            Self.dpopLogger.warning("Device key unavailable; sending request without DPoP binding")
            return
        }
        request.setValue(proof, forHTTPHeaderField: "DPoP")
        request.setValue(installID, forHTTPHeaderField: "X-Install-ID")
    }

    nonisolated private static let dpopLogger = Logger(
        subsystem: AppConstants.appBundleID,
        category: "APIClientDPoP"
    )
}
