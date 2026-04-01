import Foundation

/// Response from POST /api/practice/sessions.
struct PracticeSessionResponse: Codable, Sendable {
    let sessionId: String
    let topicId: String
    let topicName: String
    let status: String
    let wsUrl: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case topicId = "topic_id"
        case topicName = "topic_name"
        case status
        case wsUrl = "ws_url"
        case createdAt = "created_at"
    }
}

/// Response from GET /api/practice/sessions/{id}.
struct PracticeSessionDetail: Codable, Sendable {
    let sessionId: String
    let topicId: String
    let topicName: String
    let status: String
    let durationSeconds: Int?
    let startedAt: String?
    let endedAt: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case topicId = "topic_id"
        case topicName = "topic_name"
        case status
        case durationSeconds = "duration_seconds"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case createdAt = "created_at"
    }
}
