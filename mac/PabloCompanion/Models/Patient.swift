import Foundation

/// A patient record from the therapy-assistant-platform backend.
struct Patient: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    let firstName: String
    let lastName: String
    let email: String?
    let phone: String?
    let status: String
    let dateOfBirth: String?
    let diagnosis: String?
    let sessionCount: Int
    let lastSessionDate: String?
    let nextSessionDate: String?
    let createdAt: String
    let updatedAt: String

    var fullName: String {
        "\(lastName), \(firstName)"
    }
}

/// Paginated response wrapper matching the backend's list endpoint.
struct PatientListResponse: Codable, Sendable {
    let data: [Patient]
    let total: Int
    let page: Int
    let pageSize: Int
}
