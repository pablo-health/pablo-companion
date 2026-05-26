// swift-tools-version: 6.0
import PackageDescription

// Cross-platform core for the practice-mode client (WebSocket protocol + REST).
// The macOS app consumes `PracticeClientCore` as a local package; the
// `practice-harness` executable drives the same code headless (file audio in,
// captured audio out) so the real client path can be exercised on Linux CI.
let package = Package(
    name: "PracticeClientCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PracticeClientCore", targets: ["PracticeClientCore"]),
        .executable(name: "practice-harness", targets: ["practice-harness"]),
    ],
    dependencies: [
        // TOTP (HMAC-SHA1) for the harness's self-contained test-user sign-in.
        // swift-crypto builds on both macOS and Linux.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "PracticeClientCore"),
        .executableTarget(
            name: "practice-harness",
            dependencies: [
                "PracticeClientCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
    ]
)
