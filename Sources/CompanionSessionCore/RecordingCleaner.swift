import Foundation

#if canImport(os)
import os
#endif

/// Deletes a session's local audio once the backend has confirmed the upload.
///
/// Local audio is PHI on a therapist's laptop with no expiry, and each session
/// keeps a mixed WAV plus mic and system PCM sidecars — enough to fill a disk in
/// weeks of ordinary use. Once the backend has the audio the local copy has no
/// job: the app has no way to fetch it back and, since session playback was
/// removed, nothing reads it.
///
/// Deleting also makes file-presence the "not yet uploaded" state, which is what
/// stops a completed session being re-adopted and re-uploaded on every launch.
///
/// Mirrors the Windows `RecordingCleaner` from #108.
public enum RecordingCleaner {
    #if canImport(os)
    private static let logger = Logger(subsystem: "health.pablo.companion", category: "RecordingCleaner")
    #endif

    /// Removes a confirmed-uploaded session's audio: the mixed file and both
    /// sidecars.
    ///
    /// `mixedPath` is optional only because queue entries written before it
    /// was recorded have no such path; `siblingMixedFile(forMicPath:)` finds
    /// it from the sidecar's name for those.
    ///
    /// Never throws. The bytes are already safely on the backend, so a delete
    /// that fails is recoverable — leaving files behind costs disk, whereas
    /// failing the upload would cost the session.
    public static func removeAudio(micPath: String, systemPath: String?, mixedPath: String? = nil) {
        for path in [mixedPath, micPath, systemPath].compactMap(\.self) {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch CocoaError.fileNoSuchFile {
                // Already gone — the desired end state.
            } catch {
                #if canImport(os)
                logger.error("Could not delete uploaded audio: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// The mixed file captured alongside `micPath`, located by the capture's
    /// naming convention: `<base>_mic.<ext>` sits beside `<base>.<ext>`, with an
    /// optional `.enc` before the extension on both. Returns nil when no such
    /// file is on disk.
    public static func siblingMixedFile(forMicPath micPath: String) -> String? {
        let micURL = URL(fileURLWithPath: micPath)
        let stem = stripEncryptedMarker(micURL.deletingPathExtension().lastPathComponent)
        guard stem.hasSuffix("_mic") else { return nil }
        let base = String(stem.dropLast(4))
        let dir = micURL.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        for name in names.sorted() {
            let candidate = stripEncryptedMarker(
                URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            )
            if candidate == base { return dir.appendingPathComponent(name).path }
        }
        return nil
    }

    private static func stripEncryptedMarker(_ stem: String) -> String {
        stem.hasSuffix(".enc") ? String(stem.dropLast(4)) : stem
    }
}
