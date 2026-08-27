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

    /// Removes the sidecars for a confirmed-uploaded session.
    ///
    /// Never throws. The bytes are already safely on the backend, so a delete
    /// that fails is recoverable — leaving files behind costs disk, whereas
    /// failing the upload would cost the session.
    public static func removeAudio(micPath: String, systemPath: String?) {
        for path in [micPath, systemPath].compactMap(\.self) {
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
}
