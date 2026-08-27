import Foundation

/// On-disk locations the app owns.
///
/// The stores take their directory as a parameter rather than deriving it, so
/// they can live in `CompanionSessionCore` (which must build on Linux, where
/// Application Support does not mean the same thing) and so tests can point them
/// at a temp directory instead of the real one. This is where the app supplies
/// the production answer.
enum AppPaths {
    /// `~/Library/Application Support/PabloCompanion/`
    static var support: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PabloCompanion", isDirectory: true)
    }

    /// Queued audio uploads awaiting a successful send.
    static var pendingAudioUploads: URL {
        support.appendingPathComponent("PendingAudioUploads", isDirectory: true)
    }
}
