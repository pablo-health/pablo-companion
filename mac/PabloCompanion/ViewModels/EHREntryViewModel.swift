import Foundation
import os

/// State of the EHR entry process.
enum EHREntryState: Equatable {
    /// Idle — no entry in progress.
    case idle
    /// Navigating to the correct patient/appointment in the EHR.
    case navigating(step: Int, description: String)
    /// Model is analyzing the a11y tree to find SOAP fields.
    case identifying
    /// Waiting for user to confirm field mappings.
    case confirming
    /// Filling the SOAP fields.
    case filling(section: String)
    /// All fields filled successfully.
    case completed
    /// Something went wrong — user may need to help.
    case error(message: String)
    /// Agent is asking the user for help (e.g. can't find patient).
    case askingHuman(question: String)
}

/// A single field identification from the model, awaiting user confirmation.
struct IdentifiedField: Identifiable {
    let id: String // soap section name
    let soapSection: String
    let elementLabel: String
    let confidence: Double
    var confirmed: Bool
}

/// Orchestrates the full "Send to EHR" flow:
/// 1. Navigate to correct patient/appointment (agent loop)
/// 2. Snapshot a11y tree
/// 3. Model identifies SOAP fields (or use cache)
/// 4. User confirms (if first time or low confidence)
/// 5. Fill fields
///
/// Assumes therapist is already logged into their EHR.
@MainActor
@Observable
final class EHREntryViewModel {
    // MARK: - Published State

    /// Current state of the entry process.
    var state: EHREntryState = .idle

    /// Fields identified by the model, pending user confirmation.
    var identifiedFields: [IdentifiedField] = []

    /// Navigation step count (for progress display).
    var navigationStep = 0
    var maxNavigationSteps = 20

    /// The EHR name we're sending to (for display).
    var ehrDisplayName: String?

    // MARK: - Dependencies

    private let accessibilityObserver = AccessibilityObserver()
    private let fieldFiller = RecipeExecutor()
    private let logger = Logger(subsystem: "health.pablo.companion", category: "EHREntryViewModel")

    // MARK: - Session Context

    /// The SOAP note to fill in (from the backend).
    private var soapNote: SoapNoteContent?
    /// Patient info for navigation.
    private var patientName: String?
    /// Appointment date/time for navigation.
    private var appointmentDate: String?
    private var appointmentTime: String?

    // MARK: - Public API

    /// Start the full send-to-EHR flow for a given session.
    ///
    /// - Parameters:
    ///   - soapNote: The SOAP note content from the backend.
    ///   - patientFirstName: Patient's first name (for EHR navigation).
    ///   - patientLastName: Patient's last name.
    ///   - appointmentDate: ISO date string (e.g. "2026-03-23").
    ///   - appointmentTime: Display time (e.g. "2:00 PM").
    ///   - ehrName: Optional EHR display name.
    func startEntry(
        soapNote: SoapNoteContent,
        patientFirstName: String,
        patientLastName: String,
        appointmentDate: String,
        appointmentTime: String,
        ehrName: String? = nil
    ) async {
        self.soapNote = soapNote
        self.patientName = "\(patientFirstName) \(patientLastName)"
        self.appointmentDate = appointmentDate
        self.appointmentTime = appointmentTime
        self.ehrDisplayName = ehrName

        logger.info("Starting EHR entry for \(patientFirstName) \(patientLastName) on \(appointmentDate)")

        // Check accessibility permission
        guard AccessibilityObserver.hasAccessibilityPermission() else {
            state = .error(message: "Pablo needs Accessibility permission to fill in your EHR. Please grant it in System Settings > Privacy & Security > Accessibility.")
            AccessibilityObserver.requestAccessibilityPermission()
            return
        }

        // Phase 1: Navigate to the correct patient/appointment
        await navigateToNote()
    }

    /// User confirms all identified field mappings.
    func confirmFields() async {
        guard let soapNote else { return }

        state = .filling(section: "Subjective")
        logger.info("User confirmed fields — filling SOAP note")

        // Build recipe data from identified fields and fill
        // For now, use the RecipeExecutor with a dynamically built recipe
        for field in identifiedFields where field.confirmed {
            state = .filling(section: field.soapSection)
            // The actual fill will be done via the AX APIs
            // This is a placeholder for the model-identified element filling
            try? await Task.sleep(for: .milliseconds(300))
        }

        state = .completed
        logger.info("EHR entry complete")
    }

    /// User corrects a field mapping (teach-as-correction).
    func correctField(section: String) {
        logger.info("User correcting field: \(section)")
        // Enter observation mode for just this one field
        accessibilityObserver.onElementCaptured = { [weak self] observation in
            guard let self else { return }
            // Update the identified field with the user's correction
            if let index = self.identifiedFields.firstIndex(where: { $0.soapSection == section }) {
                self.identifiedFields[index] = IdentifiedField(
                    id: section,
                    soapSection: section,
                    elementLabel: observation.element.label,
                    confidence: 1.0, // user-confirmed = max confidence
                    confirmed: true
                )
            }
            self.accessibilityObserver.stopObserving()
        }
        accessibilityObserver.startObserving()
    }

    /// Cancel the current entry process.
    func cancel() {
        accessibilityObserver.stopObserving()
        state = .idle
        identifiedFields = []
        navigationStep = 0
        logger.info("EHR entry cancelled")
    }

    /// Answer the agent's question and continue navigation.
    func answerAgent(response: String) async {
        // The agent asked a question — the user's response helps it continue.
        // For now, this just resumes navigation.
        logger.info("User answered agent: \(response)")
        await navigateToNote()
    }

    // MARK: - Private: Navigation Phase

    private func navigateToNote() async {
        state = .navigating(step: 0, description: "Looking for the EHR window...")
        navigationStep = 0

        // TODO: Full agent navigation loop
        // For v1: skip navigation, assume therapist is already on the note page
        // The full loop will:
        // 1. Snapshot the foreground window's a11y tree
        // 2. Send to model with NavigationContext (patient name, date, time)
        // 3. Execute the model's suggested action (click, type, etc.)
        // 4. Repeat until model says "done" or asks for help

        // Skip to field identification
        await identifyFields()
    }

    // MARK: - Private: Field Identification Phase

    private func identifyFields() async {
        state = .identifying
        logger.info("Identifying SOAP fields in foreground window")

        // TODO: Full implementation:
        // 1. Snapshot the foreground window's a11y tree via AccessibilityObserver
        // 2. Compute tree fingerprint
        // 3. Check cache: if fingerprint matches, use cached selectors
        // 4. Otherwise: build model prompt from tree snapshot
        // 5. Run model inference via LocalModelService
        // 6. Parse response, validate, present to user

        // For now, create placeholder identified fields
        // In production this will be populated by the model's response
        identifiedFields = [
            IdentifiedField(id: "subjective", soapSection: "Subjective", elementLabel: "(scanning...)", confidence: 0, confirmed: false),
            IdentifiedField(id: "objective", soapSection: "Objective", elementLabel: "(scanning...)", confidence: 0, confirmed: false),
            IdentifiedField(id: "assessment", soapSection: "Assessment", elementLabel: "(scanning...)", confidence: 0, confirmed: false),
            IdentifiedField(id: "plan", soapSection: "Plan", elementLabel: "(scanning...)", confidence: 0, confirmed: false),
        ]

        state = .confirming
    }
}
