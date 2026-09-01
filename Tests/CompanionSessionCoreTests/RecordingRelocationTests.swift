@testable import CompanionSessionCore
import Foundation
import Testing

/// The path rewrite that follows the recordings directory when it moves.
@Suite("RecordingRelocation")
struct RecordingRelocationTests {
    private let old = URL(fileURLWithPath: "/Users/t/Documents/PabloCompanion-Recordings", isDirectory: true)
    private let new = URL(fileURLWithPath: "/Users/t/Library/Application Support/PabloCompanion/Recordings", isDirectory: true)

    @Test func aPathInsideTheOldDirectoryMoves() {
        let rewritten = RecordingRelocation.rewrite(old.path + "/recording_x_mic.pcm", from: old, to: new)
        #expect(rewritten == new.path + "/recording_x_mic.pcm")
    }

    @Test func aPathElsewhereIsUntouched() {
        // A sibling directory that merely shares the prefix string must not match.
        let sibling = "/Users/t/Documents/PabloCompanion-Recordings-old/recording_x_mic.pcm"
        #expect(RecordingRelocation.rewrite(sibling, from: old, to: new) == sibling)
        #expect(RecordingRelocation.rewrite("/tmp/other.pcm", from: old, to: new) == "/tmp/other.pcm")
    }

    @Test func nilStaysNil() {
        #expect(RecordingRelocation.rewrite(nil, from: old, to: new) == nil)
    }
}
