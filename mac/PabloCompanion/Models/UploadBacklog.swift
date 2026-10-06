import CompanionSessionCore
import Foundation

/// Sessions whose audio is still on this Mac because the server hasn't accepted
/// it yet. Entries already uploaded and waiting for their note don't count:
/// that audio has reached the server.
struct UploadBacklog: Equatable {
    /// Sessions whose audio hasn't uploaded.
    var waiting = 0
    /// Whether at least one of them has already failed an attempt.
    var hasFailed = false

    init(waiting: Int = 0, hasFailed: Bool = false) {
        self.waiting = waiting
        self.hasFailed = hasFailed
    }

    init(entries: [PendingAudioUploadStore.PendingAudioUpload]) {
        let pending = entries.filter { $0.state == .pendingUpload }
        waiting = pending.count
        hasFailed = pending.contains { $0.retryCount > 0 }
    }

    /// The line the main window shows, or nil when nothing is waiting.
    var message: String? {
        switch waiting {
        case 0: nil
        case 1: "Audio from 1 session hasn’t uploaded yet."
        default: "Audio from \(waiting) sessions hasn’t uploaded yet."
        }
    }
}
