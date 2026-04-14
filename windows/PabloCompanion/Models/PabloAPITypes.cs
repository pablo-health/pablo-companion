using System.Text.Json;
using System.Text.Json.Serialization;
using PabloCompanion.Services;

namespace PabloCompanion.Models;

// ── Enums ────────────────────────────────────────────────────────────────────

[JsonConverter(typeof(JsonStringEnumConverter<SessionStatus>))]
public enum SessionStatus
{
    [JsonStringEnumMemberName("scheduled")]
    Scheduled,

    [JsonStringEnumMemberName("in_progress")]
    InProgress,

    [JsonStringEnumMemberName("recording_complete")]
    RecordingComplete,

    [JsonStringEnumMemberName("transcribing")]
    Transcribing,

    [JsonStringEnumMemberName("queued")]
    Queued,

    [JsonStringEnumMemberName("processing")]
    Processing,

    [JsonStringEnumMemberName("pending_review")]
    PendingReview,

    [JsonStringEnumMemberName("finalized")]
    Finalized,

    [JsonStringEnumMemberName("cancelled")]
    Cancelled,

    [JsonStringEnumMemberName("failed")]
    Failed,
}

[JsonConverter(typeof(JsonStringEnumConverter<VideoPlatform>))]
public enum VideoPlatform
{
    [JsonStringEnumMemberName("zoom")]
    Zoom,

    [JsonStringEnumMemberName("teams")]
    Teams,

    [JsonStringEnumMemberName("meet")]
    Meet,

    [JsonStringEnumMemberName("none")]
    None,
}

[JsonConverter(typeof(JsonStringEnumConverter<SessionType>))]
public enum SessionType
{
    [JsonStringEnumMemberName("individual")]
    Individual,

    [JsonStringEnumMemberName("couples")]
    Couples,
}

[JsonConverter(typeof(JsonStringEnumConverter<SessionSource>))]
public enum SessionSource
{
    [JsonStringEnumMemberName("web")]
    Web,

    [JsonStringEnumMemberName("companion")]
    Companion,

    [JsonStringEnumMemberName("calendar")]
    Calendar,

    [JsonStringEnumMemberName("practice")]
    Practice,
}

[JsonConverter(typeof(JsonStringEnumConverter<SessionMode>))]
public enum SessionMode
{
    [JsonStringEnumMemberName("one_to_one")]
    OneToOne,

    [JsonStringEnumMemberName("couples")]
    Couples,
}

[JsonConverter(typeof(JsonStringEnumConverter<QualityPreset>))]
public enum QualityPreset
{
    [JsonStringEnumMemberName("fast")]
    Fast,

    [JsonStringEnumMemberName("balanced")]
    Balanced,

    [JsonStringEnumMemberName("accurate")]
    Accurate,
}

[JsonConverter(typeof(JsonStringEnumConverter<SpeakerLabel>))]
public enum SpeakerLabel
{
    [JsonStringEnumMemberName("therapist")]
    Therapist,

    [JsonStringEnumMemberName("client")]
    Client,

    [JsonStringEnumMemberName("client_a")]
    ClientA,

    [JsonStringEnumMemberName("client_b")]
    ClientB,

    [JsonStringEnumMemberName("unknown")]
    Unknown,
}

// ── Appointment types ────────────────────────────────────────────────────────

public sealed record Appointment(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("patient_id")] string PatientId,
    [property: JsonPropertyName("title")] string Title,
    [property: JsonPropertyName("start_at")] string StartAt,
    [property: JsonPropertyName("end_at")] string EndAt,
    [property: JsonPropertyName("duration_minutes")] int DurationMinutes,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("session_type")] string? SessionType = null,
    [property: JsonPropertyName("video_link")] string? VideoLink = null,
    [property: JsonPropertyName("video_platform")] string? VideoPlatform = null,
    [property: JsonPropertyName("notes")] string? Notes = null,
    [property: JsonPropertyName("ical_source")] string? ICalSource = null,
    [property: JsonPropertyName("ehr_appointment_url")] string? EhrAppointmentUrl = null,
    [property: JsonPropertyName("session_id")] string? SessionId = null,
    [property: JsonPropertyName("created_at")] string? CreatedAt = null,
    [property: JsonPropertyName("updated_at")] string? UpdatedAt = null
);

public sealed record AppointmentListResponse(
    [property: JsonPropertyName("data")] Appointment[] Data,
    [property: JsonPropertyName("total")] uint Total
);

// ── Records / Classes ────────────────────────────────────────────────────────

public sealed record PatientSummary(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("first_name")] string FirstName,
    [property: JsonPropertyName("last_name")] string LastName
);

public sealed record Session(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("patient_id")] string? PatientId,
    [property: JsonPropertyName("patient")] PatientSummary? Patient,
    [property: JsonPropertyName("status")] SessionStatus Status,
    [property: JsonPropertyName("scheduled_at")] string? ScheduledAt,
    [property: JsonPropertyName("started_at")] string? StartedAt,
    [property: JsonPropertyName("ended_at")] string? EndedAt,
    [property: JsonPropertyName("duration_minutes")] uint? DurationMinutes,
    [property: JsonPropertyName("video_link")] string? VideoLink,
    [property: JsonPropertyName("video_platform")] VideoPlatform? VideoPlatform,
    [property: JsonPropertyName("session_type")] SessionType? SessionType,
    [property: JsonPropertyName("source")] SessionSource? Source,
    [property: JsonPropertyName("notes")] string? Notes,
    [property: JsonPropertyName("created_at")] string? CreatedAt,
    [property: JsonPropertyName("updated_at")] string? UpdatedAt
);

public sealed record CreateSessionRequest(
    [property: JsonPropertyName("patient_id")] string PatientId,
    [property: JsonPropertyName("scheduled_at")] string ScheduledAt,
    [property: JsonPropertyName("duration_minutes"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] uint? DurationMinutes = null,
    [property: JsonPropertyName("video_link"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? VideoLink = null,
    [property: JsonPropertyName("video_platform"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] VideoPlatform? VideoPlatform = null,
    [property: JsonPropertyName("session_type"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] SessionType? SessionType = null,
    [property: JsonPropertyName("source"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] SessionSource? Source = null,
    [property: JsonPropertyName("notes"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Notes = null
);

public sealed record UpdateSessionRequest(
    [property: JsonPropertyName("scheduled_at"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? ScheduledAt = null,
    [property: JsonPropertyName("video_link"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? VideoLink = null,
    [property: JsonPropertyName("video_platform"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] VideoPlatform? VideoPlatform = null,
    [property: JsonPropertyName("duration_minutes"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] uint? DurationMinutes = null,
    [property: JsonPropertyName("notes"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Notes = null
);

public sealed record UserPreferences(
    [property: JsonPropertyName("default_video_platform")] VideoPlatform DefaultVideoPlatform,
    [property: JsonPropertyName("default_session_type")] SessionType DefaultSessionType,
    [property: JsonPropertyName("default_duration_minutes")] uint DefaultDurationMinutes,
    [property: JsonPropertyName("auto_transcribe")] bool AutoTranscribe,
    [property: JsonPropertyName("quality_preset")] QualityPreset QualityPreset,
    [property: JsonPropertyName("therapist_display_name")] string TherapistDisplayName
);

public sealed record UserProfile(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("email")] string Email,
    [property: JsonPropertyName("first_name")] string FirstName,
    [property: JsonPropertyName("last_name")] string LastName,
    [property: JsonPropertyName("role")] string Role,
    [property: JsonPropertyName("created_at")] string CreatedAt
);

public sealed record BaaStatus(
    [property: JsonPropertyName("baa_accepted")] bool BaaAccepted,
    [property: JsonPropertyName("accepted_at")] string? AcceptedAt
);

public sealed record Patient(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("user_id")] string UserId,
    [property: JsonPropertyName("first_name")] string FirstName,
    [property: JsonPropertyName("last_name")] string LastName,
    [property: JsonPropertyName("email")] string? Email,
    [property: JsonPropertyName("phone")] string? Phone,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("date_of_birth")] string? DateOfBirth,
    [property: JsonPropertyName("diagnosis")] string? Diagnosis,
    [property: JsonPropertyName("session_count")] uint SessionCount,
    [property: JsonPropertyName("last_session_date")] string? LastSessionDate,
    [property: JsonPropertyName("next_session_date")] string? NextSessionDate,
    [property: JsonPropertyName("created_at")] string CreatedAt,
    [property: JsonPropertyName("updated_at")] string UpdatedAt
);

public sealed record CreatePatientRequest(
    [property: JsonPropertyName("first_name")] string FirstName,
    [property: JsonPropertyName("last_name")] string LastName,
    [property: JsonPropertyName("email"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Email = null,
    [property: JsonPropertyName("phone"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Phone = null,
    [property: JsonPropertyName("date_of_birth"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? DateOfBirth = null,
    [property: JsonPropertyName("diagnosis"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Diagnosis = null
);

// ── Paginated response types ─────────────────────────────────────────────────

public sealed record SessionListResponse(
    [property: JsonPropertyName("data")] Session[] Data,
    [property: JsonPropertyName("total")] uint Total,
    [property: JsonPropertyName("page")] uint Page,
    [property: JsonPropertyName("page_size")] uint PageSize
)
{
    public bool HasMore => (Page * PageSize) < Total;
}

public sealed record TodaySessionListResponse(
    [property: JsonPropertyName("data")] Session[] Data,
    [property: JsonPropertyName("total")] uint Total
);

public sealed record PatientListResponse(
    [property: JsonPropertyName("data")] Patient[] Data,
    [property: JsonPropertyName("total")] uint Total,
    [property: JsonPropertyName("page")] uint Page,
    [property: JsonPropertyName("page_size")] uint PageSize
)
{
    public bool HasMore => (Page * PageSize) < Total;
}

public sealed record TranscriptUploadResponse(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("status")] SessionStatus Status,
    [property: JsonPropertyName("message")] string Message
);

public sealed record UploadResponse(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("status")] string Status
);

// ── Health / version types ───────────────────────────────────────────────────

public sealed record HealthStatus(
    [property: JsonPropertyName("server_version")] string ServerVersion,
    [property: JsonPropertyName("client_update_required")] bool ClientUpdateRequired,
    [property: JsonPropertyName("server_update_required")] bool ServerUpdateRequired,
    [property: JsonPropertyName("min_client_version")] string MinClientVersion,
    [property: JsonPropertyName("min_server_version")] string MinServerVersion
);

// ── SOAP Entry types ─────────────────────────────────────────────────────────

public sealed record SoapEntryRequest(
    [property: JsonPropertyName("ehr_system")] string EhrSystem,
    [property: JsonPropertyName("soap_note_id")] string SoapNoteId,
    [property: JsonPropertyName("patient_name")] string PatientName,
    [property: JsonPropertyName("appointment_time")] string AppointmentTime
);

public sealed record SoapEntryStatus(
    [property: JsonPropertyName("job_id")] string JobId,
    [property: JsonPropertyName("phase")] string Phase,
    [property: JsonPropertyName("message")] string Message,
    [property: JsonPropertyName("patient_match")] string? PatientMatch,
    [property: JsonPropertyName("appointment_match")] string? AppointmentMatch,
    [property: JsonPropertyName("ehr_target_field")] string? EhrTargetField,
    [property: JsonPropertyName("error")] string? Error
);

// ── Transcript types (not already defined in GoogleMeetRenderer.cs) ──────────

public sealed record RawSegment(
    [property: JsonPropertyName("start_ms")] long StartMs,
    [property: JsonPropertyName("end_ms")] long EndMs,
    [property: JsonPropertyName("text")] string Text
);

public sealed record TranscriptionConfig(
    [property: JsonPropertyName("model_path")] string ModelPath,
    [property: JsonPropertyName("mic_channels")] byte MicChannels,
    [property: JsonPropertyName("mic_sample_rate")] uint MicSampleRate,
    [property: JsonPropertyName("system_channels")] byte SystemChannels,
    [property: JsonPropertyName("system_sample_rate")] uint SystemSampleRate,
    [property: JsonPropertyName("swap_speakers")] bool SwapSpeakers
);

// ── Error type ───────────────────────────────────────────────────────────────

public class PabloException : Exception
{
    public ushort StatusCode { get; }

    public PabloException(ushort statusCode, string message) : base(message)
    {
        StatusCode = statusCode;
    }
}
