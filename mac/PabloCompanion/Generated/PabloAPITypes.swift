// PabloAPITypes.swift
// Native Swift types replacing UniFFI-generated types from pablo-core.
// All types use Codable with snake_case JSON keys matching the Pablo API.

import Foundation

// MARK: - Enums

enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case scheduled = "scheduled"
    case inProgress = "in_progress"
    case recordingComplete = "recording_complete"
    case transcribing = "transcribing"
    case queued = "queued"
    case processing = "processing"
    case pendingReview = "pending_review"
    case finalized = "finalized"
    case cancelled = "cancelled"
    case failed = "failed"
}

enum VideoPlatform: String, Codable, Sendable {
    case zoom
    case teams
    case meet
    case none
}

enum SessionType: String, Codable, Sendable {
    case individual
    case couples
}

enum SessionSource: String, Codable, Sendable {
    case web
    case companion
    case calendar
    case practice
}

enum QualityPreset: String, Codable, Sendable {
    case fast
    case balanced
    case accurate
}

enum SpeakerLabel: String, Codable, Sendable {
    case therapist = "therapist"
    case client = "client"
    case clientA = "client_a"
    case clientB = "client_b"
    case unknown = "unknown"
}

enum SessionMode: String, Codable, Sendable {
    case oneToOne = "one_to_one"
    case couples = "couples"
}

// SoapEntryPhase is defined in Models/SoapEntry.swift (has additional cases used by UI)

// MARK: - Appointment

struct Appointment: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let patientId: String
    let title: String
    let startAt: String
    let endAt: String
    let durationMinutes: Int
    let status: String
    let sessionType: String?
    let videoLink: String?
    let videoPlatform: String?
    let notes: String?
    let icalSource: String?
    let ehrAppointmentUrl: String?
    let sessionId: String?
    let createdAt: String
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case patientId = "patient_id"
        case title
        case startAt = "start_at"
        case endAt = "end_at"
        case durationMinutes = "duration_minutes"
        case status
        case sessionType = "session_type"
        case videoLink = "video_link"
        case videoPlatform = "video_platform"
        case notes
        case icalSource = "ical_source"
        case ehrAppointmentUrl = "ehr_appointment_url"
        case sessionId = "session_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct AppointmentListResponse: Codable, Sendable {
    let data: [Appointment]
    let total: UInt32
}

// MARK: - Structs

struct PatientSummary: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let firstName: String
    let lastName: String

    enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case lastName = "last_name"
    }
}

struct Session: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let patientId: String?
    let patient: PatientSummary?
    let status: SessionStatus
    let scheduledAt: String?
    let startedAt: String?
    let endedAt: String?
    let durationMinutes: UInt32?
    let videoLink: String?
    let videoPlatform: VideoPlatform?
    let sessionType: SessionType?
    let source: SessionSource?
    let notes: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case patientId = "patient_id"
        case patient
        case status
        case scheduledAt = "scheduled_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMinutes = "duration_minutes"
        case videoLink = "video_link"
        case videoPlatform = "video_platform"
        case sessionType = "session_type"
        case source
        case notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct CreateSessionRequest: Codable, Sendable {
    let patientId: String
    let scheduledAt: String
    let durationMinutes: UInt32?
    let videoLink: String?
    let videoPlatform: VideoPlatform?
    let sessionType: SessionType?
    let source: SessionSource?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case patientId = "patient_id"
        case scheduledAt = "scheduled_at"
        case durationMinutes = "duration_minutes"
        case videoLink = "video_link"
        case videoPlatform = "video_platform"
        case sessionType = "session_type"
        case source
        case notes
    }
}

struct UpdateSessionRequest: Codable, Sendable {
    let scheduledAt: String?
    let videoLink: String?
    let videoPlatform: VideoPlatform?
    let durationMinutes: UInt32?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case scheduledAt = "scheduled_at"
        case videoLink = "video_link"
        case videoPlatform = "video_platform"
        case durationMinutes = "duration_minutes"
        case notes
    }
}

struct UserPreferences: Codable, Sendable {
    let defaultVideoPlatform: VideoPlatform
    let defaultSessionType: SessionType
    let defaultDurationMinutes: UInt32
    let autoTranscribe: Bool
    let qualityPreset: QualityPreset
    let therapistDisplayName: String

    enum CodingKeys: String, CodingKey {
        case defaultVideoPlatform = "default_video_platform"
        case defaultSessionType = "default_session_type"
        case defaultDurationMinutes = "default_duration_minutes"
        case autoTranscribe = "auto_transcribe"
        case qualityPreset = "quality_preset"
        case therapistDisplayName = "therapist_display_name"
    }
}

struct UserProfile: Codable, Sendable {
    let id: String
    let email: String
    let firstName: String
    let lastName: String
    let role: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case firstName = "first_name"
        case lastName = "last_name"
        case role
        case createdAt = "created_at"
    }
}

struct BaaStatus: Codable, Sendable {
    let baaAccepted: Bool
    let acceptedAt: String?

    enum CodingKeys: String, CodingKey {
        case baaAccepted = "baa_accepted"
        case acceptedAt = "accepted_at"
    }
}

struct Patient: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let userId: String
    let firstName: String
    let lastName: String
    let email: String?
    let phone: String?
    let status: String
    let dateOfBirth: String?
    let diagnosis: String?
    let sessionCount: UInt32
    let lastSessionDate: String?
    let nextSessionDate: String?
    let createdAt: String
    let updatedAt: String

    var fullName: String {
        "\(lastName), \(firstName)"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case firstName = "first_name"
        case lastName = "last_name"
        case email
        case phone
        case status
        case dateOfBirth = "date_of_birth"
        case diagnosis
        case sessionCount = "session_count"
        case lastSessionDate = "last_session_date"
        case nextSessionDate = "next_session_date"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct CreatePatientRequest: Codable, Sendable {
    let firstName: String
    let lastName: String
    let email: String?
    let phone: String?
    let dateOfBirth: String?
    let diagnosis: String?

    enum CodingKeys: String, CodingKey {
        case firstName = "first_name"
        case lastName = "last_name"
        case email
        case phone
        case dateOfBirth = "date_of_birth"
        case diagnosis
    }
}

// MARK: - Paginated Response Types

struct SessionListResponse: Codable, Sendable {
    let data: [Session]
    let total: UInt32
    let page: UInt32
    let pageSize: UInt32

    var hasMore: Bool { (page * pageSize) < total }

    enum CodingKeys: String, CodingKey {
        case data
        case total
        case page
        case pageSize = "page_size"
    }
}

struct TodaySessionListResponse: Codable, Sendable {
    let data: [Session]
    let total: UInt32
}

struct PatientListResponse: Codable, Sendable {
    let data: [Patient]
    let total: UInt32
    let page: UInt32
    let pageSize: UInt32

    var hasMore: Bool { (page * pageSize) < total }

    enum CodingKeys: String, CodingKey {
        case data
        case total
        case page
        case pageSize = "page_size"
    }
}

struct TranscriptUploadResponse: Codable, Sendable {
    let id: String
    let status: SessionStatus
    let message: String
}

struct UploadResponse: Codable, Sendable {
    let id: String
    let status: String
}

// MARK: - Health / Version Types

struct HealthStatus: Codable, Sendable {
    let serverVersion: String
    let clientUpdateRequired: Bool
    let serverUpdateRequired: Bool
    let minClientVersion: String
    let minServerVersion: String

    enum CodingKeys: String, CodingKey {
        case serverVersion = "server_version"
        case clientUpdateRequired = "client_update_required"
        case serverUpdateRequired = "server_update_required"
        case minClientVersion = "min_client_version"
        case minServerVersion = "min_server_version"
    }
}

// MARK: - SOAP Entry Types

struct SoapEntryRequest: Codable, Sendable {
    let ehrSystem: String
    let soapNoteId: String
    let patientName: String
    let appointmentTime: String

    enum CodingKeys: String, CodingKey {
        case ehrSystem = "ehr_system"
        case soapNoteId = "soap_note_id"
        case patientName = "patient_name"
        case appointmentTime = "appointment_time"
    }
}

struct SoapEntryStatus: Codable, Sendable {
    let jobId: String
    let phase: String
    let message: String
    let patientMatch: String?
    let appointmentMatch: String?
    let ehrTargetField: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case phase
        case message
        case patientMatch = "patient_match"
        case appointmentMatch = "appointment_match"
        case ehrTargetField = "ehr_target_field"
        case error
    }
}

// SoapEntryConfirmation is defined in Models/SoapEntry.swift (has additional fields used by UI)

// MARK: - Transcript Types

struct RawSegment: Codable, Sendable {
    let startMs: Int64
    let endMs: Int64
    let text: String

    enum CodingKeys: String, CodingKey {
        case startMs = "start_ms"
        case endMs = "end_ms"
        case text
    }
}

struct TranscriptSegment: Codable, Sendable {
    let speaker: SpeakerLabel
    let startSeconds: Double
    let endSeconds: Double
    let text: String

    enum CodingKeys: String, CodingKey {
        case speaker
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case text
    }
}

struct TranscriptResult: Codable, Sendable {
    let sessionId: String
    let sessionMode: SessionMode
    let segments: [TranscriptSegment]

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case sessionMode = "session_mode"
        case segments
    }
}

struct GoogleMeetOptions: Codable, Sendable {
    let sessionDate: String
    let therapistName: String
    let clientName: String
    let clientAName: String
    let clientBName: String

    enum CodingKeys: String, CodingKey {
        case sessionDate = "session_date"
        case therapistName = "therapist_name"
        case clientName = "client_name"
        case clientAName = "client_a_name"
        case clientBName = "client_b_name"
    }
}

struct TranscriptionConfig: Codable, Sendable {
    let modelPath: String
    let micChannels: UInt8
    let micSampleRate: UInt32
    let systemChannels: UInt8
    let systemSampleRate: UInt32
    let swapSpeakers: Bool

    enum CodingKeys: String, CodingKey {
        case modelPath = "model_path"
        case micChannels = "mic_channels"
        case micSampleRate = "mic_sample_rate"
        case systemChannels = "system_channels"
        case systemSampleRate = "system_sample_rate"
        case swapSpeakers = "swap_speakers"
    }
}
