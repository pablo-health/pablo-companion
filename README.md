# Pablo Companion

[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/pablo-health/pablo-companion/badge)](https://scorecard.dev/viewer/?uri=github.com/pablo-health/pablo-companion)

Desktop companion app for therapists — macOS and Windows.

Sits on the desktop during the workday: therapists see today's sessions, click **Start Session**, and Pablo automatically starts recording and launches their video call (Zoom, Teams, or Google Meet). Sessions sync with the Pablo backend for SOAP note generation.

## Architecture

Monorepo: shared Rust core with native UI on each platform.

```
core/       # Rust (pablo-core crate, UniFFI) — shared business logic
mac/        # SwiftUI macOS app (macOS 14+)
windows/    # WinUI 3 / C# Windows app
docs/       # Design docs, branding, accessibility standards
scripts/    # Development utilities
```

> **Just want to use Pablo?** You don't need to build from source — sign up at [pablo.health](https://pablo.health) and download the companion app directly.

## Getting Started

### Prerequisites

- Xcode 16+ (macOS)
- Rust toolchain (`rustup`)
- SwiftLint and SwiftFormat (`brew install swiftlint swiftformat`)

### Build & Test

```bash
make check    # lint + build + test (core and mac)
```

## Related

- [AudioCaptureKit](https://github.com/pablo-health/AudioCaptureKit) — Audio recording engine (SPM dependency)
- [Pablo](https://github.com/pablo-health/pablo) — Pablo web app and backend
- [pablo.health](https://pablo.health) — Product website
