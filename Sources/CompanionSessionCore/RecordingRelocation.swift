import Foundation

/// Rewrites stored audio paths after the recordings directory moves.
///
/// Both persisted stores hold absolute paths. When the directory changes homes
/// (Documents to Application Support) the files are moved first, then every
/// entry that pointed into the old directory is pointed at the new one, so a
/// session waiting on an upload is not stranded with a path to a file that is
/// no longer there.
public enum RecordingRelocation {
    /// `path` with the `old` directory prefix swapped for `new`, or `path`
    /// unchanged when it lived somewhere else.
    public static func rewrite(_ path: String, from old: URL, to new: URL) -> String {
        let oldPrefix = old.standardizedFileURL.path
        guard path == oldPrefix || path.hasPrefix(oldPrefix + "/") else { return path }
        let suffix = String(path.dropFirst(oldPrefix.count))
        return new.standardizedFileURL.path + suffix
    }

    public static func rewrite(_ path: String?, from old: URL, to new: URL) -> String? {
        path.map { rewrite($0, from: old, to: new) }
    }
}
