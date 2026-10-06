// PabloAPITypes+Appointment.swift
// Appointment types, split from PabloAPITypes.swift to keep each file short.
// Codable with snake_case JSON keys matching the Pablo API.

import Foundation

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
    /// Raw `session_status`; read via `sessionStatus` (Models/Appointment+SessionStatus.swift).
    var sessionStatusRaw: String?
    /// The video service the visit is held on (e.g. `doxy_me`), if any.
    var provider: String?
    /// The visit's place-of-service code ("11" office, "02"/"10" telehealth).
    var placeOfService: String?

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
        case sessionStatusRaw = "session_status"
        case provider
        case placeOfService = "place_of_service"
    }
}

struct AppointmentListResponse: Codable, Sendable {
    let data: [Appointment]
    let total: UInt32
}
