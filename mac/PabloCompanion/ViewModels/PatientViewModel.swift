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

    var backendURL = "http://localhost:8000" {
        didSet {
            if URLValidator.validateScheme(backendURL) == nil {
                apiClient = APIClient(baseURL: backendURL)
            }
        }
    }

    private var apiClient: APIClient
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "PatientViewModel")

    init() {
        self.apiClient = APIClient()
    }

    /// Configures the API client with a token provider for authenticated requests.
    func configureAuth(getToken: @escaping @Sendable () async throws -> String) {
        apiClient = APIClient(baseURL: backendURL)
        apiClient.getToken = getToken
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
            logger.info("Loaded \(response.data.count) of \(response.total) patients")
        } catch {
            debugStatus = "Error: \(error.localizedDescription)"
            logger.error("Failed to load patients: \(error.localizedDescription)")
            errorMessage = "Failed to load patients: \(error.localizedDescription)"
            showError = true
        }
    }
}
