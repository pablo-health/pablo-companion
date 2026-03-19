using uniffi.pablo_core;

namespace PabloCompanion.Helpers;

public static class SessionFormatting
{
    public static string FormatPatientName(Session session, Patient[]? cachedPatients = null)
    {
        if (session.Patient != null)
        {
            return $"{session.Patient.FirstName} {session.Patient.LastName}";
        }
        var patient = LookupPatient(session, cachedPatients);
        if (patient != null)
        {
            return $"{patient.FirstName} {patient.LastName}";
        }
        return "Unknown Patient";
    }

    public static string GetPatientInitials(Session session, Patient[]? cachedPatients = null)
    {
        if (session.Patient != null)
        {
            return PatientFormatting.GetInitials(session.Patient);
        }
        var patient = LookupPatient(session, cachedPatients);
        if (patient != null)
        {
            return PatientFormatting.GetInitials(patient);
        }
        return "?";
    }

    private static Patient? LookupPatient(Session session, Patient[]? cachedPatients)
    {
        if (session.PatientId == null || cachedPatients == null) return null;
        return cachedPatients.FirstOrDefault(p => p.Id == session.PatientId);
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

    public static string FormatTimeShort(Session session)
    {
        if (session.ScheduledAt != null && DateTimeOffset.TryParse(session.ScheduledAt, out var dt))
        {
            return dt.ToLocalTime().ToString("h:mm tt");
        }
        return "";
    }

    public static string FormatDuration(Session session)
    {
        var mins = session.DurationMinutes ?? 50;
        return $"{mins} min";
    }

    public static string FormatDate(Session session)
    {
        if (session.ScheduledAt != null && DateTimeOffset.TryParse(session.ScheduledAt, out var dt))
        {
            var local = dt.ToLocalTime();
            if (local.Date == DateTime.Today) return "Today";
            if (local.Date == DateTime.Today.AddDays(-1)) return "Yesterday";
            return local.ToString("MMM d, yyyy");
        }
        return "";
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

    public static string GetPlatformIcon(Session session)
    {
        return session.VideoPlatform?.ToString().ToLowerInvariant() switch
        {
            "zoom" => "\uE774",       // Video icon
            "teams" => "\uE717",      // People icon
            "meet" or "google_meet" => "\uE8D6", // Globe icon
            _ => "",
        };
    }

    public static string GetPlatformName(Session session)
    {
        return session.VideoPlatform?.ToString().ToLowerInvariant() switch
        {
            "zoom" => "Zoom",
            "teams" => "Teams",
            "meet" or "google_meet" => "Meet",
            _ => "",
        };
    }

    public static string FormatSessionType(Session session)
    {
        return session.SessionType?.ToString() switch
        {
            "Individual" => "Individual",
            "Couple" => "Couple",
            "Family" => "Family",
            "Group" => "Group",
            _ => "Session",
        };
    }

    public static string? StatusToFilterString(SessionStatus status)
    {
        return status switch
        {
            SessionStatus.Scheduled => "scheduled",
            SessionStatus.InProgress => "in_progress",
            SessionStatus.RecordingComplete => "recording_complete",
            SessionStatus.Queued => "queued",
            SessionStatus.Processing => "processing",
            SessionStatus.PendingReview => "pending_review",
            SessionStatus.Finalized => "finalized",
            SessionStatus.Cancelled => "cancelled",
            SessionStatus.Failed => "failed",
            _ => null,
        };
    }
}
