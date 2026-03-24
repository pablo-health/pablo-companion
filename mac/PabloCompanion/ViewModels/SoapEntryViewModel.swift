import Foundation
import os

/// Drives the SOAP entry UI — connects the EHR navigator to the therapist-facing
/// confirmation flow.
///
/// State machine:
///   idle → fetchingRoute → navigating → matchingPatient → awaitingConfirmation
///     → (therapist confirms) → entering → completed
///     → (therapist cancels) → cancelled
///     → (error at any point) → failed
@MainActor
@Observable
final class SoapEntryViewModel {
    // MARK: - Published state

    var phase: SoapEntryPhase = .idle
    var statusMessage = ""
    var confirmation: SoapEntryConfirmation?
    var errorMessage: String?
    /// Set to true when Chrome needs to be relaunched — the view shows a confirmation alert.
    var showChromeRelaunchAlert = false
    /// Continuation held while waiting for the user's relaunch decision.
    private var relaunchContinuation: CheckedContinuation<Bool, Never>?

    // MARK: - Dependencies

    private var navigator: EHRNavigator?
    private var currentInput: SoapEntryInput?
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "SoapEntryViewModel")

    // MARK: - Setup

    /// Call after auth is configured. Creates the navigator with the backend API client.
    func configure(baseURL: String, getToken: @escaping @Sendable () async throws -> String) {
        let apiClient = NavigationAPIClient(baseURL: baseURL, getToken: getToken)
        let nav = EHRNavigator(apiClient: apiClient)
        nav.onChromeRelaunchNeeded = { [weak self] in
            await self?.requestChromeRelaunch() ?? false
        }
        self.navigator = nav
    }

    /// Called by the navigator when Chrome needs relaunching. Shows alert, waits for user.
    private func requestChromeRelaunch() async -> Bool {
        showChromeRelaunchAlert = true
        return await withCheckedContinuation { continuation in
            relaunchContinuation = continuation
        }
    }

    /// Called by the view when the user responds to the Chrome relaunch alert.
    func respondToChromeRelaunch(approved: Bool) {
        relaunchContinuation?.resume(returning: approved)
        relaunchContinuation = nil
        showChromeRelaunchAlert = false
    }

    // MARK: - Entry flow

    /// Starts the SOAP entry flow. Navigates the EHR and pauses for confirmation.
    func startEntry(input: SoapEntryInput) async {
        guard let navigator else {
            errorMessage = "Navigator not configured. Please sign in first."
            phase = .failed
            return
        }

        currentInput = input
        errorMessage = nil
        phase = .fetchingRoute

        do {
            let result = try await navigator.navigateToSoapForm(input: input) { [weak self] newPhase, message in
                self?.phase = newPhase
                self?.statusMessage = message
            }

            confirmation = result
            phase = .awaitingConfirmation
            statusMessage = "Found \(result.patientMatch) — \(result.appointmentMatch). Confirm to enter note."
        } catch {
            logger.error("SOAP entry navigation failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            phase = .failed
        }
    }

    /// Therapist confirmed — fill the SOAP fields and save.
    func confirmEntry() async {
        guard let navigator, let input = currentInput else { return }

        do {
            try await navigator.commitEntry(input: input) { [weak self] newPhase, message in
                self?.phase = newPhase
                self?.statusMessage = message
            }

            phase = .completed
            statusMessage = "SOAP note entered successfully."
            logger.info("SOAP entry completed for session \(input.sessionId)")
        } catch {
            logger.error("SOAP entry commit failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            phase = .failed
        }
    }

    /// Therapist cancelled — abort without saving.
    func cancelEntry() {
        phase = .cancelled
        statusMessage = "Entry cancelled."
        confirmation = nil
        currentInput = nil
    }

    /// Reset to idle for the next session.
    func reset() {
        phase = .idle
        statusMessage = ""
        confirmation = nil
        errorMessage = nil
        currentInput = nil
    }
}
