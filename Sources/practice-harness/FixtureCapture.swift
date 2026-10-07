#if canImport(CompanionAuthCore)

import AudioCaptureKit
import AVFoundation
import Foundation

/// Records through the real AudioCaptureKit graph with the exact
/// `RecordingService` config (`.separated`, 48 kHz, raw-PCM sidecars), feeding
/// the mic and system fixtures in through `FilePlayerCaptureSource`.
///
/// Shared by the `record` and `visit` scenarios so both gate the same capture.
struct FixtureCapture {
    let micFixture: URL
    let systemFixture: URL
    let seconds: Double

    struct Outcome {
        /// Where the capture wrote everything; a decline must leave no audio here.
        let directory: URL
        let mixedURL: URL
        let micURL: URL
        let systemURL: URL?
        let mixCycles: Int
        let bytesWritten: Int
        let micRMS: Double
        let systemRMS: Double
        let overflow: Int

        /// The capture gate. The graph mixes one second of frames per cycle, so
        /// a capture that ran for `seconds` has close to that many cycles; two
        /// short allows for the partial first and last second. A graph that
        /// stalled after one cycle used to pass here.
        func checks(seconds: Double) -> [GateCheck] {
            let minCycles = max(1, Int(seconds) - 2)
            return [
                GateCheck(
                    name: "capture completed",
                    ok: mixCycles >= minCycles && bytesWritten > 0,
                    detail: "mixCycles \(mixCycles) (min \(minCycles)), bytes \(bytesWritten)"
                ),
                GateCheck(
                    name: "per-channel audio liveness",
                    ok: micRMS > 1 && systemRMS > 1,
                    detail: String(format: "mic RMS %.0f, system RMS %.0f", micRMS, systemRMS)
                ),
                GateCheck(name: "no dropped samples", ok: overflow == 0, detail: "overflow samples \(overflow)"),
            ]
        }
    }

    /// Captures for `seconds`, running `midway` halfway through while the graph
    /// is still capturing (the `visit` scenario records the client's answer
    /// there, as the clinician does).
    ///
    /// During capture the app makes no other backend calls, so on a long
    /// session the server's idle session would lapse before the stop-time
    /// upload. `touch` is the heartbeat, called on the same 240 s cadence the
    /// shipping app uses (`SessionViewModel.keepSessionAliveWhileRecording`).
    func record(
        touch: @escaping @Sendable () async -> Void,
        midway: () async throws -> Void = {}
    ) async throws -> Outcome {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let micFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false
        ), let systemFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false
        ) else {
            throw GateFailure(message: "could not build capture formats")
        }

        let config = CaptureConfiguration(
            sampleRate: 48000,
            bitDepth: 16,
            channels: 2,
            outputDirectory: directory,
            enableMicCapture: true,
            enableSystemCapture: true,
            mixingStrategy: .separated,
            exportRawPCM: true,
            sidecarFormat: .aacADTS
        )

        let session = CompositeCaptureSession(
            configuration: config,
            micSource: FilePlayerCaptureSource(fileURL: micFixture, format: micFormat, loop: true),
            systemSource: FilePlayerCaptureSource(fileURL: systemFixture, format: systemFormat, loop: true)
        )

        let keepAlive = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 240 * 1_000_000_000)
                if Task.isCancelled { break }
                await touch()
            }
        }
        defer { keepAlive.cancel() }

        try session.configure(config)
        try await session.startCapture()
        let half = UInt64(seconds / 2 * 1_000_000_000)
        try await Task.sleep(nanoseconds: half)
        do {
            try await midway()
        } catch {
            _ = try? await session.stopCapture()
            throw error
        }
        try await Task.sleep(nanoseconds: half)
        let result = try await session.stopCapture()

        let diag = session.diagnostics
        guard let micURL = result.rawPCMFileURLs.first else {
            throw GateFailure(message: "no mic PCM sidecar produced")
        }
        let systemURL = result.rawPCMFileURLs.indices.contains(1) ? result.rawPCMFileURLs[1] : nil
        return Outcome(
            directory: directory,
            mixedURL: result.fileURL,
            micURL: micURL,
            systemURL: systemURL,
            mixCycles: diag.mixCycles,
            bytesWritten: diag.bytesWritten,
            micRMS: Self.pcmRMS(micURL),
            systemRMS: systemURL.map(Self.pcmRMS) ?? 0,
            overflow: diag.micOverflowSamples + diag.systemOverflowSamples
        )
    }

    /// RMS of a raw signed-16-bit-LE PCM sidecar — a cheap "is this speech, not
    /// silence" liveness check on each captured channel.
    static func pcmRMS(_ url: URL) -> Double {
        guard let data = try? Data(contentsOf: url), data.count >= 2 else { return 0 }
        let sampleCount = data.count / 2
        var sumSquares = 0.0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0 ..< sampleCount {
                let value = Double(Int16(littleEndian: samples[i]))
                sumSquares += value * value
            }
        }
        return (sumSquares / Double(sampleCount)).squareRoot()
    }

    /// Audio files a capture left under `directory` (the mixed file and its
    /// sidecars, encrypted or not). Keep the upload queue and the recording
    /// map out of `directory`: their files end in `.enc` too.
    static func audioFiles(under directory: URL) -> [String] {
        let audio: Set = ["wav", "pcm", "aac", "m4a", "enc"]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }
            .filter { audio.contains($0.pathExtension.lowercased()) }
            .map(\.lastPathComponent)
    }
}

#endif
