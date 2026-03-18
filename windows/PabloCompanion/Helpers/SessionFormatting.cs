using uniffi.pablo_core;

namespace PabloCompanion.Helpers;

public static class SessionFormatting
{
    public static string FormatPatientName(Session session)
    {
        if (session.Patient != null)
        {
            return $"{session.Patient.FirstName} {session.Patient.LastName}";
        }
        return "Unknown Patient";
    }

    public static string FormatTime(Session session)
    {
        if (session.ScheduledAt != null && DateTimeOffset.TryParse(session.ScheduledAt, out var dt))
        {
            var local = dt.ToLocalTime();
            var duration = session.DurationMinutes ?? 50;
            var end = local.AddMinutes(duration);
            return $"{local:h:mm tt} - {end:h:mm tt}";
        }
        return "Time not set";
    }

    public static string FormatStatus(SessionStatus status)
    {
        return status switch
        {
            SessionStatus.Scheduled => "Scheduled",
            SessionStatus.InProgress => "In Progress",
            SessionStatus.RecordingComplete => "Recorded",
            SessionStatus.Queued => "Queued",
            SessionStatus.Processing => "Processing",
            SessionStatus.PendingReview => "Pending Review",
            SessionStatus.Finalized => "Finalized",
            SessionStatus.Cancelled => "Cancelled",
            SessionStatus.Failed => "Failed",
            _ => "Unknown",
        };
    }
}
