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
| `pablo-health/audiotake2` | AudioCaptureKit — audio recording engine (already has Pablo branding); auth pattern for macOS inherited from here |
| `pablo-health/pablo` | Next.js frontend + FastAPI backend |

---

## Architecture: Shared Rust Core + Native UI

**This is a monorepo.** Native UI on each platform, shared business logic in Rust. Non-negotiable architectural decision — chosen to maximize therapist UX quality (real native apps, not WebViews) while keeping core logic correct and maintained in one place.

```
pablo-health/pablo-companion/
├── core/                    # Rust crate (pablo-core) — shared business logic, UniFFI bindings
│   ├── Cargo.toml
│   ├── src/
│   └── uniffi/
│       └── pablo_core.udl   # FFI interface definition
├── mac/                     # SwiftUI macOS app
│   ├── PabloCompanion.xcodeproj
│   └── Sources/
│       ├── Models/          # Thin Swift wrappers over pablo-core UniFFI types
│       ├── ViewModels/      # @MainActor ObservableObject — thin orchestration layer
│       ├── Views/           # SwiftUI views, keep under 300 lines each
│       ├── Services/        # Platform-only: RecordingService, VideoLaunchService
│       └── Assets.xcassets/
├── windows/                 # WinUI 3 / C# — stub until needed
│   └── .gitkeep
├── docs/
├── Makefile
└── .github/workflows/
    ├── core.yml             # Triggers on core/** only
    └── mac.yml              # Triggers on mac/** only
```

### Tech Stack

| Layer | Technology |
|-------|-----------|
| Shared core | Rust (`pablo-core` crate, UniFFI) |
| macOS UI | SwiftUI (macOS 14+), MVVM |
| Windows UI | WinUI 3 / C# — TBD |
| Audio (macOS) | AudioCaptureKit (from `audiotake2`, already has Pablo branding) |
| Audio (Windows) | WASAPI — TBD |
| Auth (macOS) | Inherited from `audiotake2`; Windows auth TBD |
| Calendar | Pablo backend owns the schedule — no client-side calendar sync |
| Video launch | URL schemes (`zoommtg://`, `msteams://`), browser for Google Meet |
| Backend | Pablo FastAPI REST API |
| Build | Cargo (Rust core), Xcode + SPM (macOS) |
| Issue tracking | beads (`bd`) |

---

## The Rust Decision Rule

**Before writing business logic in Swift or C#, ask: "Will the other platform need this?"**

If yes → it belongs in `core/` (Rust). If no → native is fine.

### Belongs in core/ (Rust)

- Pablo API client (`GET /sessions`, `POST /sessions`, auth, etc.)
- Data models: `Session`, `Patient`, `Recording`, `SyncState`
- Offline sync queue and conflict resolution
- Auth token management logic (storage is platform-native; the logic is Rust)
- Audio post-processing or format conversion (if any)
- Any rule that must behave identically on macOS and Windows

### Stays native (Swift for mac/, C# for windows/)

- All UI (SwiftUI views / WinUI XAML)
- Audio capture (AudioCaptureKit on macOS, WASAPI on Windows)
- Platform credential storage (Keychain on macOS, Windows Credential Manager)
- URL scheme / `NSWorkspace` / `ShellExecute` for video launch
- System APIs: notifications, menu bar / taskbar, login items
- App lifecycle, window management

### FFI Boundary Rule

**Keep the Rust ↔ Swift interface thin and boring.**

Expose simple async functions with plain value types. No complex generics, no closures across the boundary, no shared mutable state.

```swift
// Bad — complex callback crossing the boundary
rustCore.startSession(onProgress: { ... }, onError: { ... })

// Good — simple async call, observe state in Swift
let session = await rustCore.createSession(patientId: id)
```

### Debugging Rust

**The compiler is your primary debugger.** Rust's errors catch most logic bugs before runtime.

Runtime tools:
- `rust-analyzer` in VS Code/Cursor — excellent, mature
- `CodeLLDB` extension — full breakpoints, same LLDB as Xcode
- `dbg!()` macro — prints expression + value + file/line
- `cargo test -- --nocapture` — fast feedback loop

**3am failure modes, in order of likelihood:**

1. **FFI boundary panic** — Rust panic across UniFFI = UB. Fix: always `Result<T, E>`, never panic at the boundary, `catch_unwind` on anything fallible.
2. **UniFFI type surprise** — generated Swift doesn't look like what you wrote. Fix: read the generated `.swift` file, not just the `.udl`.
3. **Borrow checker + async** — reference doesn't outlive the future. Fix: `Arc<T>` for anything crossing async boundaries.
4. **Xcode can't find the Rust dylib** — linker flags wrong in Xcode build settings. Fix: establish this in PABLO-D-004 and commit the working config immediately.
5. **tokio `block_on` inside async context** — silent deadlock. Fix: expose all async Rust via UniFFI's async support; never mix blocking and async.

---

## Brand & Design

See `docs/branding.md` for the full design system.

### Quick Reference

| Element | Value |
|---------|-------|
| Primary CTA | Honey `#E8A849` |
| Background | Warm Cream `#FDF6EC` |
| Text primary | Deep Brown `#2C1810` |
| Active / recording | Sage Green `#7A9E7E` |
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

Beads tasks: `PABLO-D-050` through `PABLO-D-057`. See `docs/repo-setup-questions.md`.

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

- **Deployment target**: macOS 14+ (Sonoma) — confirm against `audiotake2` target
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
    private let core: PabloCore  // UniFFI-generated type

    func loadSessions() async {
        sessions = try await core.fetchTodaySessions()
    }
}
```

### macOS-Specific Notes

- `NSWorkspace.shared.open(_:)` for video call URL scheme launch
- AudioCaptureKit requires `NSMicrophoneUsageDescription` in `Info.plist`
- Screen recording entitlement likely required — verify against `audiotake2`
- `@AppStorage` for lightweight user preferences
- Menu bar presence TBD — useful for session status at a glance

---

## Rust Conventions (core/)

- Expose all public API via `pablo_core.udl` (UniFFI interface file)
- `async fn` everywhere — use `tokio` runtime
- All fallible functions return `Result<T, PabloError>` — never panic at the FFI boundary
- One file per domain: `api_client.rs`, `models.rs`, `sync.rs`, `auth.rs`

---

## Definition of Done

A task is NOT complete until:

**For core/ (Rust):**
1. `cargo build` with zero warnings
2. `cargo test` — all tests green
3. All public functions return `Result<T, E>` — no unwrap at FFI boundary

**For mac/ (Swift):**
1. Xcode builds with zero warnings (warnings = errors in CI)
2. `make test-mac` passes
3. Tested in Simulator; physical Mac for audio/permission flows
4. No hardcoded UI strings

**For all:**
5. PR created and linked to the beads task
6. `make check` passes (runs both `cargo test` and `xcodebuild test`)

---

## Internal Documentation

Sensitive documents (HIPAA, BAA templates, security policies) live in `docs/internal/` — a separate private git repo, gitignored from this one.
