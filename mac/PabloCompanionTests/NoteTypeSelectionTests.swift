import Foundation
@testable import Pablo
import Testing

@Suite("Note-type selection wire format")
struct NoteTypeSelectionTests {
    @Test func createSessionRequestEncodesNoteTypeSnakeCase() throws {
        let request = CreateSessionRequest(
            patientId: "p-1",
            scheduledAt: "2026-01-01T10:00:00Z",
            durationMinutes: 50,
            videoLink: nil,
            videoPlatform: nil,
            sessionType: .individual,
            source: .companion,
            notes: nil,
            noteType: "narrative"
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["note_type"] as? String == "narrative")
    }

    @Test func createSessionRequestOmitsNilNoteType() throws {
        let request = CreateSessionRequest(
            patientId: "p-1",
            scheduledAt: "2026-01-01T10:00:00Z",
            durationMinutes: 50,
            videoLink: nil,
            videoPlatform: nil,
            sessionType: .individual,
            source: .companion,
            notes: nil,
            noteType: nil
        )
        let data = try JSONEncoder().encode(request)
        let body = try #require(String(data: data, encoding: .utf8))
        // Encoding a nil optional must omit the key entirely so the
        // backend applies its own default, not decode a JSON null.
        #expect(!body.contains("note_type"))
    }

    @Test func noteTypeListResponseDecodesCatalogSubset() throws {
        // A real /api/note-types entry carries more fields (description,
        // tier, sections); the client type must tolerate and ignore them.
        let payload = """
        {
          "note_types": [
            {
              "key": "soap",
              "label": "SOAP",
              "description": "Default clinical format.",
              "tier": "core",
              "context": "session",
              "sections": [],
              "is_locked": false
            },
            {
              "key": "treatment_plan",
              "label": "Treatment Plan",
              "description": "Patient-context plan.",
              "tier": "extension",
              "context": "patient",
              "sections": [],
              "is_locked": true
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(
            NoteTypeListResponse.self, from: Data(payload.utf8)
        )
        #expect(decoded.noteTypes.count == 2)
        #expect(decoded.noteTypes[0] == NoteTypeSummary(
            key: "soap", label: "SOAP", context: "session", isLocked: false
        ))
        #expect(decoded.noteTypes[1].isLocked)
        #expect(decoded.noteTypes[1].context == "patient")
    }

    // MARK: - Picker selection reconciliation

    private static let catalog = [
        NoteTypeSummary(key: "soap", label: "SOAP", context: "session", isLocked: false),
        NoteTypeSummary(key: "narrative", label: "Narrative", context: "session", isLocked: false),
    ]

    @Test func resolvedSelectionKeepsCurrentWhenStillOffered() {
        #expect(Self.catalog.resolvedSelection(current: "narrative") == "narrative")
    }

    @Test func resolvedSelectionFallsBackToPreferredKey() {
        // Stale selection from a previous catalog: prefer "soap" when present.
        #expect(Self.catalog.resolvedSelection(current: "dap") == "soap")
        #expect(Self.catalog.resolvedSelection(current: nil) == "soap")
    }

    @Test func resolvedSelectionFallsBackToFirstEntryWithoutPreferred() {
        let noSoap = [
            NoteTypeSummary(key: "dap", label: "DAP", context: "session", isLocked: false),
            NoteTypeSummary(key: "birp", label: "BIRP", context: "session", isLocked: false),
        ]
        #expect(noSoap.resolvedSelection(current: "soap") == "dap")
        #expect(noSoap.resolvedSelection(current: nil) == "dap")
    }

    @Test func resolvedSelectionIsNilForEmptyCatalog() {
        // No catalog yet (or fetch failed): send nothing so the server
        // applies its default rather than an unsupported key.
        #expect([NoteTypeSummary]().resolvedSelection(current: "soap") == nil)
    }
}
