import Foundation

/// A practice session topic from the backend catalog.
public struct PracticeTopic: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let category: String
    public let estimatedDurationMinutes: Int

    enum CodingKeys: String, CodingKey {
        case id, name, description, category
        case estimatedDurationMinutes = "estimated_duration_minutes"
    }
}

public struct PracticeTopicListResponse: Codable, Sendable {
    public let data: [PracticeTopic]
    public let total: Int
}

/// Response from POST /api/practice/sessions.
public struct PracticeSessionResponse: Codable, Sendable {
    public let sessionId: String
    public let topicId: String
    public let topicName: String
    public let status: String
    public let wsUrl: String
    public let wsTicket: String
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case topicId = "topic_id"
        case topicName = "topic_name"
        case status
        case wsUrl = "ws_url"
        case wsTicket = "ws_ticket"
        case createdAt = "created_at"
    }
}

/// Response from POST /api/practice/ws-ticket.
public struct TicketResponse: Codable, Sendable {
    public let ticket: String
}

/// Response from GET /api/practice/sessions/{id}.
public struct PracticeSessionDetail: Codable, Sendable {
    public let sessionId: String
    public let topicId: String
    public let topicName: String
    public let status: String
    public let durationSeconds: Int?
    public let startedAt: String?
    public let endedAt: String?
    public let createdAt: String

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
