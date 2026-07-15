# CLAUDE.md — Pablo Companion

---

## Core Rules

- **Planning vs. implementing**: When asked to create a "design doc", "plan", "tasks", or "beads issues/epics", do NOT start implementing code. Focus exclusively on documentation and issue creation unless explicitly asked to implement.
- **Confirm deliverables first**: When `/work` is invoked or a task is started, always confirm the specific deliverable before beginning. Ask a single clarifying question if the intent is ambiguous.
- **No AI attribution in commits**: No "Co-Authored-By: Claude" lines. Commits are the developer's work, assisted by tools.

---

## Product: Pablo Companion

The desktop companion app for therapists — macOS and Windows. Sits on the desktop during their workday: therapists see today's sessions, click **Start Session**, and Pablo automatically starts recording and launches/joins their video call (Zoom, Teams, or Google Meet). Sessions sync with the Pablo backend for SOAP note generation.

### What This App Does

| Feature | Description |
|---------|-------------|
| Day view | List of today's scheduled sessions (schedule owned by Pablo backend) |
| Start Session | One-click: starts audio recording + launches video call |
| Session management | View past sessions, create new sessions / patients |
| Backend sync | Sessions, recordings, metadata, and schedule sync to/from Pablo API |
| Video launch | Deep links for Zoom / Teams; browser launch for Google Meet |
| Onboarding | Pablo Bear guides new therapists through first-time setup |

### Related Repos

| Repo | Role |
|------|------|
| `pablo-health/AudioCaptureKit` | Audio recording engine (already has Pablo branding); the macOS auth pattern comes from here |
| `pablo-health/pablo` | Next.js frontend + FastAPI backend |

---

## Architecture: Native Apps with Shared API Contract

**This is a monorepo.** Fully native apps on each platform — no shared Rust core, no FFI layer. Each platform uses its own idiomatic HTTP client and model types. The Pablo backend REST API is the shared contract.

> **History:** The project originally used a shared Rust core (pablo-core via UniFFI) for cross-platform business logic. This was removed because the FFI complexity wasn't justified — Whisper transcription couldn't be made to work reliably on Windows, and maintaining Rust + UniFFI bindings added friction without enough benefit. Both platforms now use native HTTP clients (URLSession on macOS, HttpClient on Windows).

```
pablo-health/pablo-companion/
├── mac/                     # SwiftUI macOS app
│   ├── PabloCompanion.xcodeproj
│   └── PabloCompanion/
│       ├── Generated/       # PabloAPITypes.swift — shared model types (Codable)
│       ├── Models/          # UI-layer model extensions
│       ├── ViewModels/      # @MainActor ObservableObject — thin orchestration layer
│       ├── Views/           # SwiftUI views, keep under 300 lines each
│       ├── Services/        # APIClient, RecordingService, VideoLaunchService
│       └── Assets.xcassets/
├── windows/                 # WinUI 3 / C# Windows app
│   ├── PabloCompanion/
│   │   ├── Models/          # PabloAPITypes.cs — shared model types
│   │   ├── ViewModels/
│   │   ├── Views/
│   │   └── Services/        # APIClient, RecordingService, etc.
│   ├── PabloCompanion.Core/ # WinUI-free classlib: audio upload wire path
│   │                        # (AudioUploadClient, WAVEncoder), DPoP + enrollment.
│   │                        # Plain net10.0-windows — no UseWinUI, no WindowsAppSDK,
│   │                        # no PasswordVault — so headless runners can use it too.
│   └── PabloCompanion.Tests/
├── docs/
├── Makefile
└── .github/workflows/
    ├── ci.yml               # macOS lint + build + test
    └── windows.yml          # Windows build + test
```

### Tech Stack

| Layer | Technology |
|-------|-----------|
| macOS UI | SwiftUI (macOS 14+), MVVM |
| macOS networking | URLSession, Codable |
| Windows UI | WinUI 3 / C# (.NET 10) |
| Windows networking | HttpClient, System.Text.Json |
| Audio (macOS) | AudioCaptureKit |
| Audio (Windows) | AudioCaptureKit C# (WASAPI) |
| Transcription (macOS) | Cloud (backend) |
| Transcription (Windows) | Cloud (backend) |
| Auth (macOS) | Pattern from AudioCaptureKit |
| Auth (Windows) | CredentialManager / loopback OAuth |
| Calendar | Pablo backend owns the schedule — no client-side calendar sync |
| Video launch | URL schemes (`zoommtg://`, `msteams://`), browser for Google Meet |
| Backend | Pablo FastAPI REST API |
| Build | Xcode + SPM (macOS), dotnet (Windows) |
| Issue tracking | beads (`bd`) |

### Cross-Platform Parity Rule

**Mac is the primary development platform. Windows features should follow.**

When adding a new feature:
1. Implement on macOS first (Swift)
2. Port the same API models and service logic to Windows (C#)
3. Keep model types in sync: `mac/PabloCompanion/Generated/PabloAPITypes.swift` ↔ `windows/PabloCompanion/Models/PabloAPITypes.cs`
4. The Pablo backend REST API is the shared contract — both platforms must serialize/deserialize identically

---

## Brand & Design

See `docs/branding.md` for the full design system.

### Quick Reference

| Element | Value |
|---------|-------|
| Primary CTA | Honey `#D4922E` (adjusted from `#E8A849` for WCAG AA) |
| Background | Warm Cream `#FDF6EC` |
| Text primary | Deep Brown `#2C1810` |
| Active / recording | Sage Green `#7A9E7E` |
| Error / destructive | Terracotta Red `#C45B4A` |
| Mascot | Pablo Bear |
| Tagline | "Pablo's got it." |
| Body font | DM Sans |
| Display font | Fraunces |
| Design feel | "Therapist's favorite chair" — warm, grounded, trustworthy |

### Design Principles

1. Warm, not sterile — cream/brown tones, not clinical gray
2. Spacious and breathable — generous padding, clear hierarchy
3. Professional but human — rounded corners (8pt), subtle shadows
4. Session-first — today's sessions are always the hero UI element

---

## Onboarding Flow

Pablo Bear guides new therapists through first-time setup before reaching the day view. The flow is resume-able and skippable for non-essential steps.

Steps: account login → mic permission → screen recording permission → video platform detection → test recording → "You're ready" celebration

Beads epic: `PABLO-D-112` (`bd show PABLO-D-112`).

---

## Beads Workflow

```bash
bd ready                                          # check available work
bd update <issue-id> --status=in_progress         # claim a task
bd close <issue-id>                               # complete a task
bd create --title="..." --type=task --priority=2  # create discovered work
```

- ALWAYS check `bd ready` before asking "what should I work on?"
- ALWAYS update status when starting work
- ALWAYS close issues when done
- NEVER use markdown TODO lists for tracking work

---

## Agent Team Workflow

For non-trivial features, follow this phased approach:

### Phase 1: Research (no code changes)
Spin up a 3-agent team:
- **code-reviewer** — investigates current implementation
- **researcher** — searches web for best practices (Apple APIs, Rust crates, etc.)
- **manager** — synthesizes gap analysis and recommendations

Present findings for user review. No code changes until approved.

### Phase 2: Planning
1. Create beads tasks from approved recommendations
2. Set task dependencies
3. Suggest fresh session for implementation (clean context)

### Phase 3: Implementation
Spin up a 2-agent team:
- **coder** — implements changes, writes tests
- **reviewer** — runs `make check`, reviews code quality, gates PR readiness

Nothing goes to PR until reviewer confirms `make check` passes.

### Rules
- Always research before implementing non-trivial changes
- User reviews findings before any code is written
- Beads tasks carry context between sessions
- Fresh sessions for implementation
- **Keep agents alive during review** — don't shut down until user confirms they're done
- **Research agent permissions** — spawn with `mode: "dontAsk"` so they can fetch URLs and read files freely

---

## Git Workflow

```bash
git checkout -b PABLO-D-001-short-description
# ... do work ...
git add <specific files>
git commit -m "feat: Add session day view"
git push -u origin PABLO-D-001-short-description
gh pr create --title "feat: Add session day view" --body "Implements PABLO-D-001..."
bd close PABLO-D-001 --reason="Done. See PR #N"
```

- Always create a PR before closing an issue
- Branch name: `<issue-id>-short-description`
- Commit messages: conventional commits (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`)

### Git Identity

```bash
git config user.name "Kurt Niemi"
git config user.email "kurtn@pablo.health"
```

---

## Swift / Xcode Conventions (mac/)

- **Deployment target**: macOS 14+ (Sonoma) — confirm against `AudioCaptureKit` target
- **Swift version**: 6.0
- **Concurrency**: `async/await` throughout — no completion handlers in new code
- **@MainActor**: All ViewModels that update `@Published` properties
- **Asset catalogs**: ALL images via `Assets.xcassets` — never file path references
- **Previews**: Every view needs a `#Preview` macro

```swift
// ViewModel pattern
@MainActor
final class SessionListViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    private let apiClient: APIClient

    func loadSessions() async {
        sessions = try await apiClient.fetchTodaySessions(timezone: TimeZone.current.identifier)
    }
}
```

### macOS-Specific Notes

- `NSWorkspace.shared.open(_:)` for video call URL scheme launch
- AudioCaptureKit requires `NSMicrophoneUsageDescription` in `Info.plist`
- Screen recording entitlement likely required — verify against `AudioCaptureKit`
- `@AppStorage` for lightweight user preferences
- Menu bar presence TBD — useful for session status at a glance

### Accessibility (non-negotiable)

- Every `Button` must have `.accessibilityLabel()` — use context like patient name
- Every decorative `Image` must have `.accessibilityHidden(true)`
- Custom controls: `.accessibilityElement(children: .ignore)` + `.accessibilityLabel()` + `.accessibilityValue()`
- Animations must check `@Environment(\.accessibilityReduceMotion)` before animating
- `.help()` is for tooltips, NOT accessibility — always pair with `.accessibilityLabel()`
- Never use color alone to convey meaning — always pair with text, icon, or shape
- See `docs/accessibility.md` for full standards and high-contrast palette

---

## Definition of Done

A task is NOT complete until:

**For mac/ (Swift):**
1. Xcode builds with zero warnings (warnings = errors in CI)
2. `make test-mac` passes
3. Tested in Simulator; physical Mac for audio/permission flows
4. No hardcoded UI strings

**For windows/ (C#):**
1. `dotnet build` succeeds
2. `make test-windows` passes
3. Tested on Windows (VM or physical)

**For all:**
5. PR created and linked to the beads task
6. `make check` passes (lint + xcodebuild) or `make check-windows` (dotnet build + test)

**Accessibility (macOS):**
7. Every `Button` has an explicit `.accessibilityLabel()` (not only `.help()`)
8. Every decorative `Image` has `.accessibilityHidden(true)`
9. Run `/a11y` before opening the PR — any Critical findings must be fixed or explicitly waived in the PR description

**Docs:**
10. If your change removes or materially alters a feature (architecture shift, removed subsystem, new cross-cutting dependency), update `CLAUDE.md`, `SECURITY.md`, and relevant `docs/*.md` in the same PR. Run `/check-docs` to catch stale references.

---

## Internal Documentation

Sensitive documents (HIPAA, BAA templates, security policies) live in `docs/internal/` — a separate private git repo, gitignored from this one.
