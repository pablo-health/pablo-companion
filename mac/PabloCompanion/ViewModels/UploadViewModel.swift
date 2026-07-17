import Foundation
import os

/// Owns backend-URL configuration, auth wiring, and the backend health check.
@MainActor
@Observable
final class UploadViewModel {
    var backendURL = AppConstants.defaultBackendAPIURL {
        didSet {
            if URLValidator.validateScheme(backendURL) == nil {
                let token = apiClient.getToken
                let onAuthRejected = apiClient.onAuthRejected
                apiClient = APIClient(baseURL: backendURL)
                apiClient.getToken = token
                apiClient.onAuthRejected = onAuthRejected
            }
        }
    }

    var isBackendReachable = false
    var lastHealthStatus: HealthStatus?

    private var apiClient: APIClient
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "UploadViewModel")

    init() {
        self.apiClient = APIClient()
    }

    /// Configures the API client with a token provider for authenticated
    /// uploads and an optional handler for server-side session rejection.
    func configureAuth(
        getToken: @escaping @Sendable () async throws -> String,
        onAuthRejected: ((Bool) -> Void)? = nil
    ) {
        apiClient.getToken = getToken
        apiClient.onAuthRejected = onAuthRejected
    }

    func checkBackendHealth() async {
        do {
            let status = try await apiClient.healthCheck()
            lastHealthStatus = status
            isBackendReachable = true
            if status.clientUpdateRequired {
                logger.warning("Client update required (min: \(status.minClientVersion))")
            }
            if status.serverUpdateRequired {
                let sv = status.serverVersion
                let msv = status.minServerVersion
                logger.warning("Server update required (server: \(sv), min: \(msv))")
            }
            logger.info("Backend health check: OK (server \(status.serverVersion))")
        } catch {
            isBackendReachable = false
            logger.warning("Backend unreachable: \(error.localizedDescription)")
        }
    }
}
