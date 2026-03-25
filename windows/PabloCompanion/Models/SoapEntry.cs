namespace PabloCompanion.Models;

/// <summary>
/// Phase of the EHR navigation pipeline shown to the therapist.
/// </summary>
public enum SoapEntryPhase
{
    Idle,
    Connecting,
    Navigating,
    MatchingPatient,
    AwaitingConfirmation,
    Entering,
    Completed,
    Failed,
    Cancelled,
}

/// <summary>
/// Dynamic data passed to the orchestrator for a specific session.
/// </summary>
public sealed record NoteEntryInput(
    string SessionId,
    string EhrSystem,
    string NoteId,
    string PatientName,
    /// <summary>ISO 8601 appointment time (e.g. "2026-03-23T20:00:00Z").</summary>
    string AppointmentTime,
    /// <summary>Human-readable time for display (e.g. "8:00 PM on March 23, 2026").</summary>
    string AppointmentDisplay,
    /// <summary>Note template to select (e.g. "SOAP Note", "DAP Note").</summary>
    string NoteType,
    /// <summary>
    /// Note content sections keyed by lowercase label.
    /// e.g. [("subjective", "..."), ("objective", "..."), ("assessment", "..."), ("plan", "...")]
    /// </summary>
    IReadOnlyList<(string Label, string Content)> Sections
);

/// <summary>
/// What the therapist sees before confirming EHR entry.
/// </summary>
public sealed record SoapEntryConfirmation(
    string PatientMatch,
    string AppointmentMatch,
    string EhrTargetField,
    string? SoapPreview,
    IReadOnlyDictionary<string, string>? FormFields
);

/// <summary>
/// Convenience builder for SOAP note input.
/// </summary>
public static class SoapNoteBuilder
{
    public static NoteEntryInput Build(
        string sessionId,
        string ehrSystem,
        string noteId,
        string patientName,
        string appointmentTime,
        string appointmentDisplay,
        string subjective,
        string objective,
        string assessment,
        string plan)
    {
        return new NoteEntryInput(
            SessionId: sessionId,
            EhrSystem: ehrSystem,
            NoteId: noteId,
            PatientName: patientName,
            AppointmentTime: appointmentTime,
            AppointmentDisplay: appointmentDisplay,
            NoteType: "SOAP Note",
            Sections: [
                ("subjective", subjective),
                ("objective", objective),
                ("assessment", assessment),
                ("plan", plan),
            ]
        );
    }
}
