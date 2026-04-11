# Pablo Companion

[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/pablo-health/pablo-companion/badge)](https://scorecard.dev/viewer/?uri=github.com/pablo-health/pablo-companion)

Desktop companion app for therapists — macOS and Windows.

Sits on the desktop during the workday: therapists see today's sessions, click **Start Session**, and Pablo automatically starts recording and launches their video call (Zoom, Teams, or Google Meet). Sessions sync with the Pablo backend for SOAP note generation.

## Architecture

Monorepo: fully native apps on each platform, shared API contract via the Pablo backend.

```
mac/        # SwiftUI macOS app (macOS 14+)
windows/    # WinUI 3 / C# Windows app (.NET 10)
docs/       # Design docs, branding, accessibility standards
scripts/    # Development utilities
```

> **Just want to use Pablo?** You don't need to build from source — sign up at [pablo.health](https://pablo.health) and download the companion app directly.

## Getting Started

### Prerequisites (macOS)

- Xcode 16+
- SwiftLint and SwiftFormat (`brew install swiftlint swiftformat`)

### Prerequisites (Windows)

- .NET 10 SDK
- Visual Studio 2022+ with WinUI workload

### Build & Test

```bash
make check          # lint + build (macOS)
make check-windows  # build + test (Windows)
```

## Related

- [AudioCaptureKit](https://github.com/pablo-health/AudioCaptureKit) — Audio recording engine (SPM dependency)
- [Pablo](https://github.com/pablo-health/pablo) — Pablo web app and backend
- [pablo.health](https://pablo.health) — Product website
