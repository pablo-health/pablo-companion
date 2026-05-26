import Foundation
import os

/// Owns backend-URL configuration, auth wiring, and the backend health check.
@MainActor
@Observable
final class UploadViewModel {
    var backendURL = "https://api.pablo.health" {
        didSet {
            if URLValidator.validateScheme(backendURL) == nil {
                let token = apiClient.getToken
                apiClient = APIClient(baseURL: backendURL)
                apiClient.getToken = token
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

    /// Configures the API client with a token provider for authenticated uploads.
    func configureAuth(getToken: @escaping @Sendable () async throws -> String) {
        apiClient.getToken = getToken
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
