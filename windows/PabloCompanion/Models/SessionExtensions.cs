using uniffi.pablo_core;

namespace PabloCompanion.Models;

/// <summary>
/// Display helpers on the UniFFI-generated Session type.
/// </summary>
public static class SessionExtensions
{
    public static bool IsActive(this Session session) =>
        session.Status == SessionStatus.InProgress;

    public static bool IsStartable(this Session session) =>
        session.Status == SessionStatus.Scheduled;

    public static bool IsEndable(this Session session) =>
        session.Status == SessionStatus.InProgress;

    public static string DisplayName(this Session session) =>
        session.Patient != null
            ? $"{session.Patient.FirstName} {session.Patient.LastName}"
            : "Unknown Patient";
}
