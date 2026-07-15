// swift-tools-version: 6.0
import PackageDescription

// Cross-platform core for the practice-mode client (WebSocket protocol + REST).
// The macOS app consumes `PracticeClientCore` as a local package; the
// `practice-harness` executable drives the same code headless (file audio in,
// captured audio out) so the real client path can be exercised on Linux CI.
//
// `CompanionAuthCore` is the device-binding stack (DPoP proofs, Secure-Enclave /
// software device key, enrollment payload) shared the same way: the app links
// it for production signing, and the harness's `dpop` scenario drives the
// identical code against a deployed backend. macOS-only (CryptoKit + Security),
// so the harness gates that scenario behind `canImport(CompanionAuthCore)`.
let package = Package(
    name: "PracticeClientCore",
    // macOS 14 floor: the `record` scenario drives AudioCaptureKit's
    // CoreAudio-tap capture graph, which requires macOS 14. Matches the app's
    // own deployment target.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PracticeClientCore", targets: ["PracticeClientCore"]),
        .library(name: "CompanionAuthCore", targets: ["CompanionAuthCore"]),
        .library(name: "CompanionSessionCore", targets: ["CompanionSessionCore"]),
        .executable(name: "practice-harness", targets: ["practice-harness"]),
    ],
    dependencies: [
        // TOTP (HMAC-SHA1) for the harness's self-contained test-user sign-in.
        // swift-crypto builds on both macOS and Linux. Range spans 3.x–4.x so
        // the version unifies with the macOS app's transitive pin (4.x via
        // AudioCaptureKit) when the app consumes this as a local package.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0"),
        // Real capture graph (mic + system mix -> WAV + PCM sidecars). The
        // `record` scenario drives it headless via a file-backed capture source,
        // so the shipping recording path is exercised without live hardware.
        .package(url: "https://github.com/pablo-health/AudioCaptureKit.git", from: "1.1.2"),
    ],
    targets: [
        .target(name: "PracticeClientCore"),
        .target(name: "CompanionAuthCore"),
        // The real session audio-upload wire path (multipart body, device-binding
        // attach, INVALID_STATUS self-heal), shared by the app and the harness so
        // neither drifts. Foundation-only; auth + binding are injected.
        .target(name: "CompanionSessionCore"),
        .executableTarget(
            name: "practice-harness",
            dependencies: [
                "PracticeClientCore",
                "CompanionSessionCore",
                .target(name: "CompanionAuthCore", condition: .when(platforms: [.macOS])),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(
                    name: "AudioCaptureKit",
                    package: "AudioCaptureKit",
                    condition: .when(platforms: [.macOS])
                ),
            ]
        ),
        .testTarget(
            name: "CompanionSessionCoreTests",
            dependencies: ["CompanionSessionCore"]
        ),
    ]
)
