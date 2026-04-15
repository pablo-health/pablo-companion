import Foundation

// MARK: - Error Type

enum PabloError: LocalizedError, Sendable {
    case audioPreprocessing(message: String)
    case whisperInit(message: String)
    case whisperTranscribe(message: String)
    case apiClient(statusCode: UInt16, message: String)
    case jsonParse(message: String)
    case unauthenticated
    case forbidden
    case notFound(resource: String)
    case conflictState(message: String)
    case updateRequired(message: String)

    var errorDescription: String? {
        switch self {
        case .audioPreprocessing(let message):
            return "Audio preprocessing error: \(message)"
        case .whisperInit(let message):
            return "Whisper model init error: \(message)"
        case .whisperTranscribe(let message):
            return "Whisper transcription error: \(message)"
        case let .apiClient(statusCode, message):
            return "API error (HTTP \(statusCode)): \(message)"
        case .jsonParse(let message):
            return "JSON parse error: \(message)"
        case .unauthenticated:
            return "Unauthenticated — login required"
        case .forbidden:
            return "Forbidden — insufficient permissions"
        case .notFound(let resource):
            return "Not found: \(resource)"
        case .conflictState(let message):
            return "Conflict: \(message)"
        case .updateRequired(let message):
            return "Update required: \(message)"
        }
    }
}
