import Foundation

// MARK: - SOAP Entry Types

/// Phase of the EHR navigation pipeline.
enum SoapEntryPhase: String, Codable, Sendable {
    case idle
    case fetchingRoute
    case navigating
    case matchingPatient
    case awaitingConfirmation
    case entering
    case completed
    case failed
    case cancelled
}

/// What the orchestrator asks the backend to do (constrained intent — not a free-form prompt).
enum NavigationIntent: String, Codable, Sendable {
    case findPatientList
    case findPatientRow
    case findSoapForm
    case findSaveButton
    case identifyFormFields
    case recoverFromUnexpected
}

/// A single step in a cached navigation route.
struct CachedStep: Codable, Sendable {
    let action: StepAction
    let selector: String
    let a11yFingerprint: String
    let intent: NavigationIntent
    /// If non-nil, this step uses dynamic data (e.g. "patient_name", "appointment_time").
    let dynamicKey: String?
}

/// What action to take on a matched element.
enum StepAction: String, Codable, Sendable {
    case click
    case fill
    case navigate
    case wait
}

/// A cached route for a specific EHR system, shared across all therapists.
struct CachedRoute: Codable, Sendable {
    let ehrSystem: String
    let routeName: String
    let steps: [CachedStep]
    let successCount: Int
    let lastSuccess: String?
}

/// Request sent to the backend when the orchestrator needs LLM help.
/// Note: no patient names — PHI is stripped client-side.
struct NavigationRequest: Codable, Sendable {
    let ehrSystem: String
    let intent: NavigationIntent
    let a11ySnapshot: String
    let failedSelector: String?
}

/// Response from the backend with the LLM-determined next action.
struct NavigationAction: Codable, Sendable {
    let selector: String
    let action: StepAction
    let confidence: Double
    let updatedFingerprint: String?
}

/// What the therapist sees before confirming EHR entry.
struct SoapEntryConfirmation: Sendable {
    let patientMatch: String
    let appointmentMatch: String
    let ehrTargetField: String
    let soapPreview: String?
}

/// Dynamic data passed to the orchestrator for a specific session.
struct SoapEntryInput: Sendable {
    let sessionId: String
    let ehrSystem: String
    let soapNoteId: String
    let patientName: String
    let appointmentTime: String
    /// The actual SOAP note content to enter.
    let soapContent: SoapContent
}

/// Structured SOAP note content for form field mapping.
struct SoapContent: Sendable {
    let subjective: String
    let objective: String
    let assessment: String
    let plan: String
}
