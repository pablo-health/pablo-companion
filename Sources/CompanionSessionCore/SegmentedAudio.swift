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
    /// Files staging created (decrypted copies, joined channels). The caller
    /// deletes them once the upload attempt is over — they are plaintext PHI.
    public let tempFiles: [URL]
}

/// Turns a queued session's segments into one file per channel.
///
/// The backend takes exactly one file per channel: `upload-audio/init` mints one
/// signed URL for the therapist channel and one for the client channel, and
/// `finalize` transcribes whatever sits at those two paths. A session recorded
/// in several segments is therefore joined here, channel by channel, in
/// recording order, and uploaded once.
///
/// The app's sidecars are headerless signed 16-bit little-endian PCM (mic mono,
/// system stereo; `RecordingService` keeps AudioCaptureKit's raw-PCM default),
/// so joining at a shared rate is concatenation. Joining assumes that format:
/// AAC sidecars would need joining by frame, not by byte. Segments can
/// differ in rate — a Bluetooth headset in hands-free mode drops the mic to
/// 8-24 kHz, and a device change is exactly what starts a new segment — so a
/// segment at another rate is resampled to the highest rate in the session
/// before it is appended. Uploading mixed-rate bytes under one header would
/// play the off-rate segment at the wrong speed and pitch.
public enum SessionAudioStager {
    /// Makes a segment's sidecar readable: decrypts it to a temp file and
    /// returns that, or returns the path itself when it is already plaintext.
    public typealias Decrypt = (_ path: String) throws -> (url: URL, isTemp: Bool)

    static let micChannels = 1
    static let systemChannels = 2

    /// - Parameters:
    ///   - segments: in recording order.
    ///   - fallbackRate: rate assumed for a segment with none recorded.
    ///   - workDirectory: where joined channels are written.
    public static func stage(
        _ segments: [AudioSegment],
        fallbackRate: Double,
        decrypt: Decrypt,
        workDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> StagedSessionAudio {
        guard let first = segments.first else {
            throw SessionUploadError(statusCode: -1, code: nil, message: "No audio segments to upload")
        }
        var tempFiles: [URL] = []
        do {
            // One segment: upload its sidecars as they are, as before.
            if segments.count == 1 {
                let mic = try decrypt(first.micPath)
                if mic.isTemp { tempFiles.append(mic.url) }
                let system = try first.systemPath.map(decrypt)
                if let system, system.isTemp { tempFiles.append(system.url) }
                return StagedSessionAudio(
                    micURL: mic.url,
                    systemURL: system?.url,
                    sampleRate: first.sampleRate ?? fallbackRate,
                    tempFiles: tempFiles
                )
            }
            return try stageJoined(
                segments, fallbackRate: fallbackRate, decrypt: decrypt, in: workDirectory, tempFiles: &tempFiles
            )
        } catch {
            tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
    }

    private static func stageJoined(
        _ segments: [AudioSegment],
        fallbackRate: Double,
        decrypt: Decrypt,
        in workDirectory: URL,
        tempFiles: inout [URL]
    ) throws -> StagedSessionAudio {
        let targetRate = segments.map { $0.sampleRate ?? fallbackRate }.max() ?? fallbackRate
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
            let micFrames = try append(mic.url, rate: rate, to: targetRate, channels: micChannels, into: micWriter)

            guard let systemWriter else { continue }
            if let systemPath = segment.systemPath {
                let system = try decrypt(systemPath)
                defer { if system.isTemp { try? FileManager.default.removeItem(at: system.url) } }
                _ = try append(system.url, rate: rate, to: targetRate, channels: systemChannels, into: systemWriter)
            } else {
                // No client channel for this stretch: keep the channels aligned
                // in time by filling it with silence as long as the mic part.
                try writeSilence(frames: micFrames, channels: systemChannels, into: systemWriter)
            }
        }
        return StagedSessionAudio(micURL: micOut, systemURL: systemOut, sampleRate: targetRate, tempFiles: tempFiles)
    }

    // MARK: - PCM

    /// Appends one sidecar to `writer` at `targetRate`. Returns the frames written.
    private static func append(
        _ source: URL,
        rate: Double,
        to targetRate: Double,
        channels: Int,
        into writer: FileHandle
    ) throws -> Int {
        let frameBytes = 2 * channels
        guard rate != targetRate else {
            // Same rate: stream it across in bounded chunks.
            let reader = try FileHandle(forReadingFrom: source)
            defer { try? reader.close() }
            var bytes = 0
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                try writer.write(contentsOf: chunk)
                bytes += chunk.count
            }
            return bytes / frameBytes
        }
        let resampled = try resample(Data(contentsOf: source), from: rate, to: targetRate, channels: channels)
        try writer.write(contentsOf: resampled)
        return resampled.count / frameBytes
    }

    /// Linear-interpolation resample of interleaved signed 16-bit LE PCM.
    /// Speech for transcription, not music: linear is enough, and it keeps this
    /// Foundation-only so the harness and `swift test` run it as shipped.
    static func resample(_ pcm: Data, from rate: Double, to targetRate: Double, channels: Int) -> Data {
        let input: [Int16] = pcm.withUnsafeBytes { raw in
            (0 ..< raw.count / 2).map {
                Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))
            }
        }
        let inFrames = input.count / channels
        guard inFrames > 0, rate > 0, targetRate > 0 else { return Data() }
        let outFrames = Int((Double(inFrames) * targetRate / rate).rounded())
        var output = [Int16](repeating: 0, count: outFrames * channels)
        let step = rate / targetRate
        for frame in 0 ..< outFrames {
            let position = Double(frame) * step
            let lower = min(Int(position), inFrames - 1)
            let upper = min(lower + 1, inFrames - 1)
            let fraction = position - Double(lower)
            for channel in 0 ..< channels {
                let from = Double(input[lower * channels + channel])
                let to = Double(input[upper * channels + channel])
                output[frame * channels + channel] = Int16((from + (to - from) * fraction).rounded())
            }
        }
        return output.map(\.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func writeSilence(frames: Int, channels: Int, into writer: FileHandle) throws {
        var remaining = frames * channels * 2
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
            throw SessionUploadError(statusCode: -1, code: nil, message: "Could not stage joined audio")
        }
        return url
    }
}
