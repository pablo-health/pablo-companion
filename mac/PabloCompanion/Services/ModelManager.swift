import Foundation
import os

// MARK: - SessionType

enum SessionType: String, CaseIterable, Sendable {
    case oneToOne = "1:1"
    case couples = "Couples"

    var displayName: String { rawValue }
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
    case notImplemented

    var errorDescription: String? {
        switch self {
        case let .notFound(preset):
            "Model file not found for \(preset.displayName) preset (\(preset.modelFileName))"
        case .notImplemented:
            "Model downloading is not yet implemented"
        }
    }
}

// MARK: - ModelManager

/// Manages Whisper model files for local transcription.
/// Resolves model paths from the app's Application Support directory or the app bundle.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

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

    /// Downloads the model for the given preset from the Pablo CDN.
    /// Currently a stub that throws `ModelError.notImplemented`.
    func downloadModel(_: QualityPreset) async throws {
        throw ModelError.notImplemented
    }
}
