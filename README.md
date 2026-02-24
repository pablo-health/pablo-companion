# Pablo Companion

Desktop companion app for therapists — macOS and Windows.

See today's sessions, click **Start Session**, and Pablo automatically begins recording and joins your video call. Sessions sync with the Pablo backend for SOAP note generation.

## Architecture

Monorepo: shared Rust core (`core/`) with native UI on each platform.

```
core/       # Rust (pablo-core crate, UniFFI) — shared business logic
mac/        # SwiftUI macOS app
windows/    # WinUI 3 / C# (coming soon)
```

## Related

- [audiotake2](https://github.com/pablo-health/audiotake2) — AudioCaptureKit (audio recording engine)
- [pablo-health](https://pablo.health) — Pablo web app and backend
