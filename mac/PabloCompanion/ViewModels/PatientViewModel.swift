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

    /// Current page for paginated patient fetching.
    var currentPage = 1

    /// Whether more patients are available beyond the current page.
    var hasMorePatients = false

    /// Total patients matching the current search, as reported by the backend.
    var totalPatients: UInt32 = 0

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

    /// Loads the first page of patients, replacing any current list.
    func loadPatients() async {
        guard apiClient.getToken != nil else {
            debugStatus = "Waiting for auth..."
            return
        }
        debugStatus = "Loading from \(apiClient.baseURL)..."
        isLoading = true
        defer { isLoading = false }
        currentPage = 1

        do {
            let response = try await apiClient.fetchPatients(
                search: searchText,
                page: currentPage,
                pageSize: Self.pageSize
            )
            patients = response.data
            totalPatients = response.total
            hasMorePatients = response.hasMore
            debugStatus = "Loaded \(response.data.count) of \(response.total) patients"
            logger.info("Loaded patients")
        } catch {
            debugStatus = "Error: \(error.localizedDescription)"
            logger.error("Failed to load patients: \(error.localizedDescription)")
            errorMessage = "Failed to load patients: \(error.localizedDescription)"
            showError = true
        }
    }

    /// Fetches the next page of patients and appends them to the current list.
    ///
    /// Without this a caseload larger than one page was unreachable: the list
    /// stopped at the first `pageSize` patients with no way to see the rest.
    func loadMorePatients() async {
        guard apiClient.getToken != nil else { return }
        guard hasMorePatients, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        currentPage += 1

        do {
            let response = try await apiClient.fetchPatients(
                search: searchText,
                page: currentPage,
                pageSize: Self.pageSize
            )
            patients.append(contentsOf: response.data)
            totalPatients = response.total
            hasMorePatients = response.hasMore
            debugStatus = "Loaded \(patients.count) of \(response.total) patients"
            logger.info("Loaded next patients page")
        } catch {
            currentPage -= 1
            logger.error("Failed to load more patients: \(error.localizedDescription)")
            errorMessage = "Failed to load more patients: \(error.localizedDescription)"
            showError = true
        }
    }

    private static let pageSize = 50
}
