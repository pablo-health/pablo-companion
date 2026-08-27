import Foundation

extension [NoteTypeSummary] {
    /// The registry key the Quick Start picker should show as selected.
    ///
    /// Keeps `current` when the catalog still offers it; otherwise falls
    /// back to `preferredKey` (the server's conventional default) and
    /// finally to the first entry. Returns nil for an empty catalog so
    /// the caller sends no `note_type` and the server applies its own
    /// default — the picker must never submit a key the catalog does not
    /// contain.
    func resolvedSelection(
        current: String?,
        preferredKey: String = "soap"
    ) -> String? {
        if let current, contains(where: { $0.key == current }) {
            return current
        }
        if contains(where: { $0.key == preferredKey }) {
            return preferredKey
        }
        return first?.key
    }
}
