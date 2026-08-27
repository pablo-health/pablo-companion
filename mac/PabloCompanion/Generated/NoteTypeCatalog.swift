// NoteTypeCatalog.swift
// Types for the deployment's note-format catalog (`GET /api/note-types`).
// Split from PabloAPITypes.swift, which sits at the file-length limit.
// All types use Codable with snake_case JSON keys matching the Pablo API.

import Foundation

/// One entry from `GET /api/note-types` — the deployment's note-format
/// catalog. Only the fields the picker needs; the endpoint's `sections`
/// payload is deliberately not decoded here.
struct NoteTypeSummary: Codable, Sendable, Identifiable, Equatable {
    let key: String
    let label: String
    let context: String
    let isLocked: Bool

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key
        case label
        case context
        case isLocked = "is_locked"
    }
}

struct NoteTypeListResponse: Codable, Sendable {
    let noteTypes: [NoteTypeSummary]

    enum CodingKeys: String, CodingKey {
        case noteTypes = "note_types"
    }
}
