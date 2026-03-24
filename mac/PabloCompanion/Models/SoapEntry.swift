import Foundation

// MARK: - SOAP Entry Types

/// Phase of the EHR navigation pipeline shown to the therapist.
enum SoapEntryPhase: String, Codable, Sendable {
    case idle = "idle"
    case connecting = "connecting"
    case navigating = "navigating"
    case matchingPatient = "matching_patient"
    case awaitingConfirmation = "awaiting_confirmation"
    case entering = "entering"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
}

/// What action to take on the browser.
enum StepAction: String, Codable, Sendable {
    case click
    case fill
    case navigate
    case wait
    case none
}

// MARK: - Goal-Based Navigation API

/// Request sent to the backend LLM. The client sends the current page DOM
/// and a goal. The LLM decides the next action. No patient names are sent —
/// PHI is stripped client-side before calling this.
struct GoalNavigationRequest: Codable, Sendable {
    let ehrSystem: String
    /// What we're trying to achieve (e.g. "Navigate to SOAP note form for appointment on 2026-03-23 at 8:00 PM")
    let goal: String
    /// Current browser URL.
    let currentUrl: String
    /// Simplified DOM snapshot (interactive elements + text, PHI stripped).
    let domSnapshot: String
    /// Actions taken so far in this session (gives the LLM context on what's been tried).
    let previousActions: [PreviousAction]
    /// If the last action failed, what went wrong.
    let failedAction: String?
}

/// A single action taken in the current navigation session.
struct PreviousAction: Codable, Sendable {
    let action: String
    let target: String
    let result: String
}

/// Response from the backend LLM — one action to take next.
struct GoalNavigationResponse: Codable, Sendable {
    let action: StepAction
    let selector: String
    /// Brief explanation of why this action was chosen.
    let reasoning: String
    let confidence: Double
    /// True when the LLM believes we've arrived at the note form.
    let isOnTargetPage: Bool
    /// If on target page, maps section labels to CSS selectors.
    /// Keys are lowercase section names (e.g. "subjective", "data", "behavior").
    /// Values are CSS selectors (e.g. ".ProseMirror[aria-label='free-text-1']").
    let formFields: [String: String]?
    /// What to try if this action fails.
    let alternativePlan: String?
}

// MARK: - Confirmation & Input

/// What the therapist sees before confirming EHR entry.
struct SoapEntryConfirmation: Sendable {
    let patientMatch: String
    let appointmentMatch: String
    let ehrTargetField: String
    let soapPreview: String?
    /// Maps section labels to CSS selectors (from the LLM).
    let formFields: [String: String]?
}

/// Dynamic data passed to the orchestrator for a specific session.
struct NoteEntryInput: Sendable {
    let sessionId: String
    let ehrSystem: String
    let noteId: String
    let patientName: String
    /// ISO 8601 appointment time (e.g. "2026-03-23T20:00:00Z").
    let appointmentTime: String
    /// Human-readable time for the goal (e.g. "8:00 PM on March 23, 2026").
    let appointmentDisplay: String
    /// The note type to select in the EHR template dropdown (e.g. "SOAP Note", "DAP Note").
    let noteType: String
    /// The note content sections, keyed by lowercase label.
    /// e.g. ["subjective": "...", "objective": "...", "assessment": "...", "plan": "..."]
    /// or   ["data": "...", "assessment": "...", "plan": "..."]
    let sections: [(label: String, content: String)]
}

/// Convenience builder for SOAP note input.
struct SOAPNoteBuilder {
    let sessionId: String
    let ehrSystem: String
    let noteId: String
    let patientName: String
    let appointmentTime: String
    let appointmentDisplay: String
    let subjective: String
    let objective: String
    let assessment: String
    let plan: String

    func build() -> NoteEntryInput {
        NoteEntryInput(
            sessionId: sessionId,
            ehrSystem: ehrSystem,
            noteId: noteId,
            patientName: patientName,
            appointmentTime: appointmentTime,
            appointmentDisplay: appointmentDisplay,
            noteType: "SOAP Note",
            sections: [
                ("subjective", subjective),
                ("objective", objective),
                ("assessment", assessment),
                ("plan", plan),
            ]
        )
    }
}
