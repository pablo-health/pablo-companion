import Foundation

/// One capture segment's files: the per-channel sidecars and the mixed file.
///
/// A session is recorded in more than one segment when capture restarts
/// mid-session — the output device changing invalidates the system-audio tap,
/// so the app stops and starts a fresh capture. Each restart leaves its own set
/// of files, and every one of them is the same session's audio.
public struct AudioSegment: Codable, Equatable, Sendable {
    public let micPath: String
    public let systemPath: String?
    public let mixedPath: String?
    /// Capture rate of the sidecars. `nil` for entries queued before the rate
    /// was persisted; the uploader falls back to 48 kHz for those.
    public let sampleRate: Double?

    public init(micPath: String, systemPath: String?, mixedPath: String?, sampleRate: Double?) {
        self.micPath = micPath
        self.systemPath = systemPath
        self.mixedPath = mixedPath
        self.sampleRate = sampleRate
    }
}

/// The plaintext channel files to upload for one queued session, and the rate
/// they are at.
public struct StagedSessionAudio: Sendable {
    public let micURL: URL
    public let systemURL: URL?
    public let sampleRate: Double
    /// Files staging created (decrypted copies, converted channels). The caller
    /// deletes them once the upload attempt is over — they are plaintext PHI.
    public let tempFiles: [URL]
}

/// Turns a queued session's segments into one upload file per channel.
///
/// The backend takes exactly one file per channel: `upload-audio/init` mints one
/// signed URL for the therapist channel and one for the client channel, and
/// `finalize` transcribes whatever sits at those two paths. A session recorded
/// in several segments is therefore joined here, channel by channel, in
/// recording order, and uploaded once.
///
/// Every channel leaves the device as 16 kHz mono signed 16-bit PCM
/// (``uploadRate``), whatever it was captured at. The sidecars are headerless
/// PCM (mic mono, system stereo; `RecordingService` keeps AudioCaptureKit's
/// raw-PCM default) at the capture rate, usually 48 kHz: six times what
/// transcription uses for the stereo client channel, which made an hour-long
/// session's client file over a gigabyte. That is past the per-file upload
/// ceiling, so a session longer than about 45 minutes could never upload. At
/// 16 kHz mono an hour is about 115 MB per channel. 16 kHz is the rate speech
/// recognition works at, so nothing it uses is lost, and a mono client channel
/// also gets the backend's silence trimming, which it skips for stereo.
///
/// Converting also settles mixed-rate sessions: a Bluetooth headset in
/// hands-free mode drops the mic to 8-24 kHz, and a device change is exactly
/// what starts a new segment, so segments can arrive at different rates.
/// Bringing each to ``uploadRate`` before appending keeps one header honest for
/// the whole file. The conversion streams chunk by chunk, so memory stays flat
/// however long the session ran. Joining by appending assumes this raw format;
/// AAC sidecars would need joining by frame.
public enum SessionAudioStager {
    /// Makes a segment's sidecar readable: decrypts it to a temp file and
    /// returns that, or returns the path itself when it is already plaintext.
    public typealias Decrypt = (_ path: String) throws -> (url: URL, isTemp: Bool)

    /// The rate every uploaded channel is at.
    public static let uploadRate: Double = 16000
    /// The channel count of every uploaded file.
    public static let uploadChannels = 1

    static let micChannels = 1
    static let systemChannels = 2

    /// - Parameters:
    ///   - segments: in recording order.
    ///   - fallbackRate: rate assumed for a segment with none recorded.
    ///   - workDirectory: where the upload files are written.
    public static func stage(
        _ segments: [AudioSegment],
        fallbackRate: Double,
        decrypt: Decrypt,
        workDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> StagedSessionAudio {
        guard !segments.isEmpty else {
            throw SessionUploadError(statusCode: -1, code: nil, message: "No audio segments to upload")
        }
        var tempFiles: [URL] = []
        do {
            return try stageConverted(
                segments, fallbackRate: fallbackRate, decrypt: decrypt, in: workDirectory, tempFiles: &tempFiles
            )
        } catch {
            tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
    }

    private static func stageConverted(
        _ segments: [AudioSegment],
        fallbackRate: Double,
        decrypt: Decrypt,
        in workDirectory: URL,
        tempFiles: inout [URL]
    ) throws -> StagedSessionAudio {
        let hasSystem = segments.contains { $0.systemPath != nil }

        let micOut = try makeTempFile(in: workDirectory)
        tempFiles.append(micOut)
        let systemOut = hasSystem ? try makeTempFile(in: workDirectory) : nil
        if let systemOut { tempFiles.append(systemOut) }

        let micWriter = try FileHandle(forWritingTo: micOut)
        defer { try? micWriter.close() }
        let systemWriter = try systemOut.map { try FileHandle(forWritingTo: $0) }
        defer { try? systemWriter?.close() }

        for segment in segments {
            let rate = segment.sampleRate ?? fallbackRate
            let mic = try decrypt(segment.micPath)
            defer { if mic.isTemp { try? FileManager.default.removeItem(at: mic.url) } }
            let micFrames = try append(mic.url, rate: rate, channels: micChannels, into: micWriter)

            guard let systemWriter else { continue }
            if let systemPath = segment.systemPath {
                let system = try decrypt(systemPath)
                defer { if system.isTemp { try? FileManager.default.removeItem(at: system.url) } }
                _ = try append(system.url, rate: rate, channels: systemChannels, into: systemWriter)
            } else {
                // No client channel for this stretch: keep the channels aligned
                // in time by filling it with silence as long as the mic part.
                try writeSilence(frames: micFrames, into: systemWriter)
            }
        }
        return StagedSessionAudio(micURL: micOut, systemURL: systemOut, sampleRate: uploadRate, tempFiles: tempFiles)
    }

    // MARK: - PCM

    /// Streams one sidecar into `writer` as ``uploadRate`` mono. Returns the frames written.
    private static func append(_ source: URL, rate: Double, channels: Int, into writer: FileHandle) throws -> Int {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        var converter = UploadFormatConverter(inputRate: rate, inputChannels: channels, outputRate: uploadRate)
        var bytes = 0
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            let converted = converter.process(chunk)
            try writer.write(contentsOf: converted)
            bytes += converted.count
        }
        let tail = converter.finish()
        try writer.write(contentsOf: tail)
        bytes += tail.count
        return bytes / (2 * uploadChannels)
    }

    private static func writeSilence(frames: Int, into writer: FileHandle) throws {
        var remaining = frames * uploadChannels * 2
        let block = Data(count: min(remaining, 1 << 20))
        while remaining > 0 {
            let count = min(remaining, block.count)
            try writer.write(contentsOf: block.prefix(count))
            remaining -= count
        }
    }

    private static func makeTempFile(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("pablo-segments-\(UUID().uuidString).pcm")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw SessionUploadError(statusCode: -1, code: nil, message: "Could not stage session audio")
        }
        return url
    }
}
