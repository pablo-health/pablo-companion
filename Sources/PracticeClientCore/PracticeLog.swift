import Foundation

#if canImport(os)
import os
#endif

/// Lightweight logging shim for the practice client core.
///
/// On Apple platforms it is backed by `os.Logger`; elsewhere (e.g. a Linux
/// headless build) it writes to stderr. This keeps the core free of any
/// app-level constants so it compiles on both the macOS app and a portable
/// test runner.
struct PracticeLog: Sendable {
    /// Logging subsystem for the practice client. Mirrors the app bundle id
    /// default so Console grouping is unchanged when the app links this core.
    static let subsystem = "health.pablo.companion"

    private let category: String

    #if canImport(os)
    private let osLogger: os.Logger
    #endif

    init(category: String) {
        self.category = category
        #if canImport(os)
        osLogger = os.Logger(subsystem: Self.subsystem, category: category)
        #endif
    }

    func info(_ message: String) {
        #if canImport(os)
        osLogger.log("\(message)")
        #else
        emit("INFO", message)
        #endif
    }

    func warning(_ message: String) {
        #if canImport(os)
        osLogger.warning("\(message)")
        #else
        emit("WARN", message)
        #endif
    }

    func error(_ message: String) {
        #if canImport(os)
        osLogger.error("\(message)")
        #else
        emit("ERROR", message)
        #endif
    }

    #if !canImport(os)
    private func emit(_ level: String, _ message: String) {
        FileHandle.standardError.write(Data("[\(level)] [\(category)] \(message)\n".utf8))
    }
    #endif
}
