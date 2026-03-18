using uniffi.pablo_core;

namespace PabloCompanion.Helpers;

public static class PatientFormatting
{
    public static string GetInitials(Patient patient)
    {
        var first = string.IsNullOrEmpty(patient.FirstName) ? "" : patient.FirstName[..1];
        var last = string.IsNullOrEmpty(patient.LastName) ? "" : patient.LastName[..1];
        return $"{first}{last}".ToUpperInvariant();
    }

    public static string GetInitials(PatientSummary patient)
    {
        var first = string.IsNullOrEmpty(patient.FirstName) ? "" : patient.FirstName[..1];
        var last = string.IsNullOrEmpty(patient.LastName) ? "" : patient.LastName[..1];
        return $"{first}{last}".ToUpperInvariant();
    }

    public static string FormatFullName(Patient patient)
    {
        return $"{patient.FirstName} {patient.LastName}";
    }

    public static string FormatSessionCount(Patient patient)
    {
        return patient.SessionCount switch
        {
            0 => "No sessions",
            1 => "1 session",
            _ => $"{patient.SessionCount} sessions",
        };
    }

    public static string FormatLastSession(Patient patient)
    {
        if (string.IsNullOrEmpty(patient.LastSessionDate)) return "No sessions yet";
        if (DateTimeOffset.TryParse(patient.LastSessionDate, out var dt))
        {
            var local = dt.ToLocalTime();
            var diff = DateTimeOffset.Now - local;
            if (diff.TotalDays < 1) return "Today";
            if (diff.TotalDays < 2) return "Yesterday";
            if (diff.TotalDays < 7) return $"{(int)diff.TotalDays} days ago";
            return local.ToString("MMM d, yyyy");
        }
        return patient.LastSessionDate;
    }

    public static string FormatStatusBadge(Patient patient)
    {
        return patient.Status?.ToLowerInvariant() switch
        {
            "active" => "Active",
            "inactive" => "Inactive",
            "discharged" => "Discharged",
            _ => patient.Status ?? "Unknown",
        };
    }

    public static string GetStatusColor(Patient patient)
    {
        return patient.Status?.ToLowerInvariant() switch
        {
            "active" => "#7A9E7E",
            "inactive" => "#6B5344",
            "discharged" => "#89B4C8",
            _ => "#6B5344",
        };
    }

    public static string GetStatusForeground(Patient patient)
    {
        return patient.Status?.ToLowerInvariant() switch
        {
            "active" => "#FFFFFF",
            "inactive" => "#FFFFFF",
            "discharged" => "#FFFFFF",
            _ => "#FFFFFF",
        };
    }
}
