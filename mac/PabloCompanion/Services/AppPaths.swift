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

    /// Session audio: the mixed file and the PCM sidecars for each session.
    ///
    /// Under Application Support, not Documents. Documents is what iCloud
    /// "Desktop & Documents", Time Machine and folder-sync tools carry off the
    /// machine, and session audio must not follow them. The directory is also
    /// marked excluded from backup once it exists (`excludeFromBackup`).
    static var recordings: URL {
        support.appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Where earlier builds kept session audio. Read only to move it across.
    static var legacyRecordingsDirectories: [URL] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return [
            documents.appendingPathComponent("PabloCompanion-Recordings", isDirectory: true),
            documents.appendingPathComponent("MacOSSample-Recordings", isDirectory: true),
        ]
    }

    /// Asks Time Machine and iCloud backup to skip `url`. Best effort.
    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}
