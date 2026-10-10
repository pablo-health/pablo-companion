using System.Text.Json;

namespace PabloCompanion.Models;

/// <summary>
/// Display helpers on <see cref="Appointment"/>. Mirrors
/// <c>Appointment+SessionStatus.swift</c> on macOS.
/// </summary>
public static class AppointmentExtensions
{
    /// <summary>
    /// Lifecycle of the linked session. <c>session_status</c> is decoded raw so a
    /// status a newer backend adds reads as <c>null</c> here instead of failing
    /// the whole appointment list; older backends omit it entirely.
    /// </summary>
    public static SessionStatus? ParsedSessionStatus(this Appointment appointment)
    {
        if (string.IsNullOrEmpty(appointment.SessionStatusRaw)) return null;
        try
        {
            // Round-trip through the enum's own converter so the wire names stay
            // defined in exactly one place (the JsonStringEnumMemberName attributes).
            return JsonSerializer.Deserialize<SessionStatus>(
                JsonSerializer.Serialize(appointment.SessionStatusRaw));
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
