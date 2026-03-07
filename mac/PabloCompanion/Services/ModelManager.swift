import Foundation
import os

// MARK: - SessionType

enum SessionType: String, CaseIterable, Sendable {
    case oneToOne = "1:1"
    case couples = "Couples"

    var displayName: String {
        rawValue
    }
}

// MARK: - QualityPreset

enum QualityPreset: String, CaseIterable, Sendable {
    case fast // whisper-small (~200 MB)
    case balanced // whisper-large-v3-turbo Q5_0 (~1.0 GB) — default
    case highAccuracy // whisper-large-v3 (~1.6 GB) — on-demand download

    var modelFileName: String {
        switch self {
        case .fast: "ggml-small.bin"
        case .balanced: "ggml-large-v3-turbo-q5_0.bin"
        case .highAccuracy: "ggml-large-v3.bin"
        }
    }

    var displayName: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .highAccuracy: "High Accuracy"
        }
    }

    var diskSizeDescription: String {
        switch self {
        case .fast: "~200 MB"
        case .balanced: "~1.0 GB"
        case .highAccuracy: "~1.6 GB"
        }
    }
}

// MARK: - ModelError

enum ModelError: Error, LocalizedError {
    case notFound(QualityPreset)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case let .notFound(preset):
            "Model file not found for \(preset.displayName) preset (\(preset.modelFileName))"
        case let .downloadFailed(reason):
            "Model download failed: \(reason)"
        }
    }
}

// MARK: - ModelManager

/// Manages Whisper model files for local transcription.
/// Resolves model paths from the app's Application Support directory or the app bundle.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published var downloadProgress: [QualityPreset: Double] = [:]
    @Published var downloadingPresets: Set<QualityPreset> = []

    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: AppConstants.appBundleID, category: "ModelManager")

    private var modelsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport
            .appendingPathComponent("PabloCompanion", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns the URL to the model file for the given preset.
    /// Checks the models directory first, then the app bundle.
    func modelURL(for preset: QualityPreset) throws -> URL {
        // Check Application Support models directory first
        let cachedURL = modelsDirectory.appendingPathComponent(preset.modelFileName)
        if fileManager.fileExists(atPath: cachedURL.path) {
            logger.debug("Found model in cache: \(preset.modelFileName)")
            return cachedURL
        }

        // Fall back to app bundle
        let name = (preset.modelFileName as NSString).deletingPathExtension
        let ext = (preset.modelFileName as NSString).pathExtension
        if let bundledURL = Bundle.main.url(forResource: name, withExtension: ext) {
            logger.debug("Found model in bundle: \(preset.modelFileName)")
            return bundledURL
        }

        logger.warning("Model not found: \(preset.modelFileName)")
        throw ModelError.notFound(preset)
    }

    /// Whether the model for this preset is available (cached or bundled).
    func isAvailable(_ preset: QualityPreset) -> Bool {
        (try? modelURL(for: preset)) != nil
    }

    /// Downloads the model for the given preset from the Hugging Face whisper.cpp repository.
    /// Progress is published via `downloadProgress` and `downloadingPresets`.
    func downloadModel(_ preset: QualityPreset) async throws {
        guard !downloadingPresets.contains(preset) else { return }

        let baseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
        guard let url = URL(string: baseURL + preset.modelFileName) else { return }

        downloadingPresets.insert(preset)
        downloadProgress[preset] = 0
        defer {
            downloadingPresets.remove(preset)
            downloadProgress.removeValue(forKey: preset)
        }

        let delegate = ModelDownloadDelegate { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.downloadProgress[preset] = progress
            }
        }

        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url, delegate: delegate)
            let destination = modelsDirectory.appendingPathComponent(preset.modelFileName)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: tempURL, to: destination)
            logger.info("Model downloaded: \(preset.modelFileName)")
        } catch {
            logger.error("Model download failed for \(preset.modelFileName): \(error.localizedDescription)")
            throw ModelError.downloadFailed(error.localizedDescription)
        }
    }
}

// MARK: - ModelDownloadDelegate

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    /// Required by URLSessionDownloadDelegate.
    /// The async/await wrapper owns the temp file — this is intentionally a no-op.
    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo _: URL) {}

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}
