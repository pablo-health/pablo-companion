import Foundation

/// A practice session topic from the backend catalog.
struct PracticeTopic: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let category: String
    let estimatedDurationMinutes: Int

    enum CodingKeys: String, CodingKey {
        case id, name, description, category
        case estimatedDurationMinutes = "estimated_duration_minutes"
    }
}

struct PracticeTopicListResponse: Codable, Sendable {
    let data: [PracticeTopic]
    let total: Int
}
