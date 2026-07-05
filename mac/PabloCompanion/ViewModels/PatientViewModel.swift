import Foundation
import os
import SwiftUI

/// Manages fetching and displaying the patient list from the backend.
@MainActor
@Observable
final class PatientViewModel {
    var patients: [Patient] = []
    var isLoading = false
    var errorMessage: String?
    var showError = false
    var searchText = ""

    var backendURL = "https://api.pablo.health" {
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

    private var apiClient: APIClient
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "PatientViewModel")

    init() {
        self.apiClient = APIClient()
    }

    /// Configures the API client with a token provider for authenticated
    /// requests and an optional handler for server-side session rejection.
    func configureAuth(
        getToken: @escaping @Sendable () async throws -> String,
        onAuthRejected: ((Bool) -> Void)? = nil
    ) {
        apiClient.getToken = getToken
        apiClient.onAuthRejected = onAuthRejected
    }

    /// Debug status visible in the UI during development.
    var debugStatus = ""

    func loadPatients() async {
        guard apiClient.getToken != nil else {
            debugStatus = "Waiting for auth..."
            return
        }
        debugStatus = "Loading from \(apiClient.baseURL)..."
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await apiClient.fetchPatients(search: searchText)
            patients = response.data
            debugStatus = "Loaded \(response.data.count) of \(response.total) patients"
            logger.info("Loaded patients")
        } catch {
            debugStatus = "Error: \(error.localizedDescription)"
            logger.error("Failed to load patients: \(error.localizedDescription)")
            errorMessage = "Failed to load patients: \(error.localizedDescription)"
            showError = true
        }
    }
}
