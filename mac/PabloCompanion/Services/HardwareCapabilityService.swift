import Foundation

/// Detects CPU architecture and physical RAM for transcription guardrails.
/// Results are computed once at init and cached — hardware doesn't change at runtime.
struct HardwareCapabilityService {
    let isAppleSilicon: Bool
    let physicalMemoryGB: Int

    init() {
        isAppleSilicon = Self.detectAppleSilicon()
        physicalMemoryGB = Self.detectPhysicalMemoryGB()
    }

    /// True if the machine has ≥ 16 GB physical RAM.
    var meetsHighAccuracyRequirement: Bool { physicalMemoryGB >= 16 }

    /// True if this machine is likely to be slow at local transcription.
    /// Intel Mac with < 16 GB — recommend Cloud mode.
    var isLowSpec: Bool { !isAppleSilicon && physicalMemoryGB < 16 }

    // MARK: - Private

    private static func detectAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value != 0
    }

    private static func detectPhysicalMemoryGB() -> Int {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &value, &size, nil, 0)
        // Round down to nearest GB
        return Int(value / (1024 * 1024 * 1024))
    }
}
