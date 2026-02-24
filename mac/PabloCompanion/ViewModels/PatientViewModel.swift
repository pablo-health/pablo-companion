import Foundation
import SwiftUI
import os

/// Manages fetching and displaying the patient list from the backend.
@MainActor
@Observable
final class PatientViewModel {
    var patients: [Patient] = []
    var isLoading: Bool = false
    var errorMessage: String?
    var showError: Bool = false
    var searchText: String = ""

    var backendURL: String = "http://localhost:8000" {
        didSet { apiClient = APIClient(baseURL: backendURL) }
    }

    private var apiClient: APIClient
    private let logger = Logger(subsystem: "com.macos-sample", category: "PatientViewModel")

    init() {
        self.apiClient = APIClient()
    }

    /// Configures the API client with a token provider for authenticated requests.
    func configureAuth(getToken: @escaping @Sendable () async throws -> String) {
        apiClient = APIClient(baseURL: backendURL)
        apiClient.getToken = getToken
    }

    /// Debug status visible in the UI during development.
    var debugStatus: String = ""

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
