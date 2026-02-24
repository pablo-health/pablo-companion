# Pablo Desktop — Repo Setup & Brainstorm

_Created: 2026-02-24_

---

## 1. Repo Name

**Current folder:** `PabloDesktop`

### Options Considered

| Name | Pros | Cons |
|------|------|------|
| `pablo-desktop` | Lowercase kebab matches GitHub conventions; clear platform scope | Doesn't highlight that it's the companion to the web app |
| `PabloCompanion` | User-friendly, warm — matches brand voice ("Pablo's got it"); implies "alongside your sessions" | Less explicit about macOS/desktop |
| `PabloCompanionApp` | User's initial suggestion; explicit it's an app | "App" is redundant in repo names; verbose |
| `PabloDesktop` | Already the local folder name; unambiguous platform signal | PascalCase is unusual for GitHub repo names |
| `pablo-companion` | Kebab version of PabloCompanion | Same as above minus the case issue |

### Recommendation

**`pablo-companion`** under the `pablo-health` org → `github.com/pablo-health/pablo-companion`

Reasoning:
- Aligns with brand voice — a "companion" is warm, reliable, present with you in the session
- Distinguishes it from the web dashboard (`pablo-health/pablo` or similar)
- Lowercase kebab is standard GitHub practice
- "One Pablo. Your whole workflow." — the companion app is _that_ companion

**Decision needed:** Confirm `pablo-companion` or pick an alternative above.

---

## 2. What We're Building

**Pablo Companion** is a native macOS app for therapists — the "session launcher" that lives on their desktop.

### Core Flows

1. **Day view** — therapist opens the app and sees today's scheduled sessions
2. **Session start** — one click on "Start Session":
   - Automatically begins audio recording via `AudioCaptureKit`
   - Launches / joins the video call (Google Meet, Zoom, or Microsoft Teams)
3. **Session management** — view past sessions, create new sessions / new patients (less frequent)
4. **Backend sync** — all session data syncs with the Pablo backend (FastAPI)

### What It Is NOT

- Not a standalone transcription tool (that's `audiotake2` / `AudioCaptureKit`)
- Not the web dashboard (that's the Next.js frontend)
- Not a video conferencing tool (it _launches_ them)

---

## 3. Cross-Platform Strategy — Analysis & Trade-offs

**There is also a Windows companion app.** This is the most consequential architectural decision before writing any code.

AudioCaptureKit is macOS-only. Windows audio capture uses WASAPI (Windows Audio Session API) or PortAudio. The recording layer will always be platform-specific regardless of which approach is chosen.

The question is: how much else can be shared, and at what cost?

---

### Option A: Fully Separate Native Apps (Two Repos)

- `pablo-health/pablo-companion-mac` — SwiftUI + AudioCaptureKit
- `pablo-health/pablo-companion-win` — WinUI 3 / .NET MAUI + WASAPI

**Pros:**
- Each app is idiomatic for its platform — feels right to users
- AudioCaptureKit + Swift stays exactly as-is (already has Pablo branding)
- macOS: perfect system integration (Keychain, notifications, menu bar, Accessibility APIs)
- Windows: proper Win32 notifications, Windows Credential Manager, taskbar integration
- Teams can specialize — one person owns the mac app, one owns Windows
- No build complexity from bridging two ecosystems
- Simpler repos — any dev can jump in without knowing both platforms

**Cons:**
- Business logic duplicated: API client, session models, sync, auth token handling
- UI diverges over time (subtle UX differences accumulate)
- Two separate bug surfaces for the same logical features
- If you add a feature, you ship it twice

**Verdict:** Low complexity, high maintenance cost as the product grows. Fine for v1. Gets painful at v3+.

---

### Option B: Tauri (Rust + WebView)

- One repo: `pablo-health/pablo-companion`
- Rust backend + React/Svelte/Vue web frontend rendered in OS WebView
- Platform-specific Tauri plugins for audio capture

**Pros:**
- Shared frontend — Pablo web dashboard and the companion app can share React components
- True single codebase for UI logic
- Rust core handles all platform-agnostic work (API client, models, sync)
- Already in the existing tech stack (CLAUDE-otherproject.md lists Tauri)
- Strong ecosystem, actively maintained by Crabnebula

**Cons:**
- WebView UI — looks good, but not quite native (especially on macOS: scroll physics, font rendering, context menus feel slightly off)
- AudioCaptureKit is Swift — wrapping it as a Tauri plugin means writing Rust ↔ Swift FFI, or reimplementing capture in Rust
- Abandons the existing AudioCaptureKit + Pablo branding work
- Therapists on macOS will notice it doesn't feel like a "real Mac app"
- `NSUserNotifications`, Keychain access, and menu bar require custom Tauri plugins

**Verdict:** Best choice if UI consistency between web and desktop is the priority, or if the team is primarily JS/TS. But sacrifices native feel and throws away existing AudioCaptureKit work.

---

### Option C: Shared Rust Core + Native UI (Recommended)

- `pablo-health/pablo-core` — pure Rust library (UniFFI)
- `pablo-health/pablo-companion-mac` — SwiftUI UI + AudioCaptureKit, calls pablo-core
- `pablo-health/pablo-companion-win` — WinUI 3 / C# UI + WASAPI, calls pablo-core

**The idea:** The heavy business logic lives in Rust once. The UI layers are thin and native.

**What goes in pablo-core (Rust):**
- Pablo API client (session CRUD, upload, auth)
- Data models (`Session`, `Patient`, `Recording`)
- Sync logic (offline queue, conflict resolution)
- Audio processing utilities (if any post-capture work happens)
- The "Pablo style" at the data/logic level

**What stays native:**
- SwiftUI day view, session list, onboarding (macOS)
- WinUI 3 equivalent (Windows)
- AudioCaptureKit (macOS) / WASAPI (Windows) — platform audio engines
- System integration: Keychain, notifications, URL scheme launch

**The bridge: UniFFI (Mozilla)**
UniFFI generates Swift bindings from a `.udl` interface definition file. The Swift app calls Rust code as if it were a native Swift library. Firefox Desktop and 1Password use this pattern. On Windows, C# calls Rust via P/Invoke (also well-established).

**Pros:**
- Native UI on both platforms — looks and feels exactly right
- Shared core logic — fix the API client once, both apps benefit
- AudioCaptureKit stays untouched (it already works and has Pablo branding)
- Strong long-term maintainability
- "Pablo style" in the core means consistent behavior, even if pixels differ
- Rust core is independently testable

**Cons:**
- Most complex initial setup (UniFFI + FFI boundary requires discipline)
- Need to define the Rust/Swift/C# interface boundary carefully upfront
- Rust compilation adds to Xcode build time
- Smaller team = more context-switching between Rust + Swift + C#
- More repos to manage (though pablo-core could be a subdirectory or git submodule)

**Verdict:** The most architecturally sound option for a product with longevity. High upfront investment, pays off quickly if Windows parity matters. This is how serious cross-platform native apps are built in 2026.

---

### Simplified Option C (Pragmatic Middle Ground)

If Option C feels too heavy for v1, a lighter version:
- Don't create pablo-core yet
- Write the macOS app fully in Swift
- When building the Windows app, extract shared logic into a Rust crate at that point
- Use UniFFI from day one on macOS so the pattern is established

This means you're not doing Rust FFI until you actually need it, but you're building toward it.

---

### Summary Matrix

| | Separate Native | Tauri | Rust Core + Native UI |
|---|---|---|---|
| **Native feel** | ✅ Best | ⚠️ Good | ✅ Best |
| **Shared logic** | ❌ Duplicated | ✅ Yes | ✅ Yes (Rust) |
| **AudioCaptureKit** | ✅ Unchanged | ⚠️ Needs Tauri plugin | ✅ Unchanged |
| **UI consistency** | ⚠️ Manual effort | ✅ Same web code | ⚠️ Manual effort |
| **Setup complexity** | ✅ Low | ✅ Medium | ⚠️ High |
| **Long-term maint.** | ⚠️ Two bug surfaces | ✅ One frontend | ✅ One core |
| **v1 speed** | ✅ Fastest | ✅ Fast | ⚠️ Slower |
| **Rust involvement** | ❌ None | ✅ Core + plugins | ✅ Core only |

---

---

### Can We Get Pablo Style Natively?

**Yes — with intentional effort.** Pablo's visual identity is fonts + colors + spacing + personality copy. In SwiftUI you implement those same design tokens: bundle DM Sans + Fraunces, define `Color.pabloHoney`, write custom `ButtonStyle`s with amber CTAs and warm shadows. The result _looks_ like Pablo.

**What you can't share is code.** Every design system update (new color, spacing change, new component) must be applied twice — once in CSS/Tailwind, once in Swift. This is the drift risk: web evolves, desktop lags.

**Does "different from boring SaaS" require Tauri?**

No — that feeling comes from _default styling_, not the technology. A SwiftUI app with Pablo's cream/amber/sage palette, Fraunces headings, and Pablo Bear mascot will look _more_ premium than most Tauri apps. Native scroll physics, native window chrome, proper macOS animations read as quality.

_However_ — there is a real case for Tauri given your stack:
- Web dashboard is already Next.js + Tailwind + shadcn/ui with Pablo design tokens
- Tauri lets the desktop app import those same React components
- Design system update ships to web AND desktop in one commit
- Windows parity comes for free with the same frontend codebase
- Tauri is already listed in the existing Pablo tech stack

**Honest summary by goal:**

| What you want | SwiftUI native | Tauri |
|---|---|---|
| Feels like a real Mac app | ✅ Best | ⚠️ WebView seams show |
| Looks exactly like web dashboard | ⚠️ Requires discipline | ✅ Shared components |
| Pablo Bear + warm design | ✅ Achievable | ✅ Achievable |
| AudioCaptureKit stays as-is | ✅ Yes | ⚠️ Needs Swift↔Tauri plugin |
| One design system to maintain | ❌ Two impls | ✅ One |
| Windows parity | ❌ Separate work | ✅ Same frontend |
| Offline/system integration | ✅ Best | ✅ Good (via plugins) |

**The AudioCaptureKit bridge question:**
If going Tauri, AudioCaptureKit doesn't disappear — it becomes a Tauri plugin. The Swift code that does the actual audio capture stays. The Tauri app calls it via Rust FFI → Swift. This is real work (~2–3 days to set up correctly) but it's a one-time cost, and AudioCaptureKit's Pablo branding (UI components) would need to be replicated in React anyway since Tauri renders a WebView, not native Swift views.

---

### Updated Recommendation

Given that Tauri is already in the Pablo tech stack, you have a Windows app to support, and visual consistency with the web dashboard is a stated goal:

**Lean toward Tauri** for the companion app — one repo, one design system, React components shared with the web dashboard, Windows covered.

The one trade-off to consciously accept: on macOS, a Tauri app will never feel as "native" as SwiftUI. For a therapy app used in focused sessions (not casual consumer use), this is an acceptable trade-off IF the UI is polished. The WebView seams are most visible in things like: scroll physics, text selection behavior, drag and drop, context menus. All of these can be handled with Tauri plugins and careful CSS.

If native macOS _feel_ is non-negotiable (and you're willing to maintain two UI codebases), go SwiftUI + WinUI with a shared Rust core.

**Decision needed:** Tauri (one repo, shared web design system) or Native (two repos, native feel, two UI codebases)?

---

## 4. Tech Stack Decisions

| Layer | Technology | Notes |
|-------|-----------|-------|
| UI | SwiftUI (macOS) | Native; MVVM pattern |
| Recording | AudioCaptureKit (from `audiotake2`) | Already has Pablo branding; pull as Swift package |
| Video launch | URL schemes / AppleScript | `zoommtg://`, `msteams://`, Google Meet browser |
| Backend | Pablo FastAPI API | REST / WebSocket sync |
| Auth | TBD — likely same auth as web dashboard | |
| Build | Xcode + Swift Package Manager | |

### Note: AudioCaptureKit Already Has Pablo Branding

The `audiotake2` repo already includes Pablo branding. When we pull it in, we get that branding "for free" — no need to re-theme the recording UI layer. Audit what's already branded before adding new brand assets.

### Open Questions

- [x] Cross-platform strategy — **monorepo, Option C (Rust core + native UI)**
- [x] Auth — **inherited from audiotake2 macOS app; Windows auth TBD when Windows app is built**
- [x] Calendar source — **comes from Pablo backend** (backend owns the schedule, not iCal/Google Calendar sync — that integration, if ever needed, lives server-side)
- [ ] AudioCaptureKit integration — Swift package vs. submodule? (audiotake2 already has Pablo branding — audit before duplicating assets)
- [ ] Video call joining — automatic deep link launch or show-link-then-click? (UX decision)
- [ ] macOS minimum version target — check audiotake2 deployment target; companion app should match
- [ ] "entire" — user handling this

---

## 4. Repo Structure: Monorepo ✅

**Decision: monorepo.** One repo (`pablo-health/pablo-companion`) containing the Rust core and both native apps.

**Why not separate repos:**
- Changing a function signature in `pablo-core` breaks Swift bindings AND C# bindings simultaneously — in a monorepo, one commit fixes all three and CI validates everything at once. In separate repos, that's 3 coordinated PRs that must land in order.
- `pablo-core` is not a general library — it's tightly coupled to these two apps. No reason to treat it like a versioned crate.
- Git submodules are painful (detached HEAD, `--recurse-submodules`, CI bloat) — not worth it.
- One developer + Claude Code — no org-scale reason to silo repos.

**Structure:**

```
pablo-health/pablo-companion/
├── core/                          # Rust pablo-core crate
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs
│   │   ├── api_client.rs
│   │   ├── models.rs
│   │   └── sync.rs
│   └── uniffi/
│       └── pablo_core.udl         # FFI interface definition
├── mac/                           # SwiftUI macOS app
│   ├── PabloCompanion.xcodeproj
│   └── Sources/
├── windows/                       # WinUI 3 — stub for now
│   └── .gitkeep
├── docs/
├── CLAUDE.md
├── Makefile                       # make build-core / make build-mac / make test-all
└── .github/
    └── workflows/
        ├── core.yml               # triggers on core/** changes only
        └── mac.yml                # triggers on mac/** changes only
```

---

## 5. GitHub Setup

- **Org:** `pablo-health`
- **Repo:** `pablo-companion` (pending name confirmation)
- **Visibility:** Private (HIPAA context)
- **Git identity for this machine:**
  - Name: `Kurt Niemi`
  - Email: `kurtn@pablo.health`

### Commands to run after repo creation

```bash
# Set local git identity for this repo
git config user.name "Kurt Niemi"
git config user.email "kurtn@pablo.health"

# Create repo under pablo-health org
gh repo create pablo-health/pablo-companion --private --description "Pablo macOS companion app for therapist session management"

# Push initial commit
git remote add origin git@github.com:pablo-health/pablo-companion.git
git push -u origin main
```

---

## 5. Onboarding — Pablo-Guided Setup

Therapists should be able to onboard themselves with zero hand-holding from support. Pablo (the bear) walks them through setup in a warm, guided flow.

### Onboarding Scope

1. **Account connection** — enter their Pablo API credentials or log in via browser OAuth
2. **Microphone permission** — request + verify mic access (required for AudioCaptureKit)
3. **Screen recording permission** (if needed by AudioCaptureKit)
4. **Video platform detection** — detect installed apps (Zoom, Teams) and configure launch behavior
5. **Calendar connection** (future) — connect iCal or Google Calendar for auto-populated session list
6. **Test recording** — do a 5-second test capture to confirm audio is working
7. **"You're ready" screen** — Pablo Bear celebration moment, land on the day view

### Onboarding Design Principles

- Every step should be completable in under 30 seconds
- Never leave the therapist on a blank screen
- Pablo Bear mascot guides each step ("Pablo needs mic access to listen in sessions")
- Show progress (e.g., "Step 2 of 5")
- Allow skipping non-essential steps with clear re-access from Settings
- Resume-able — if they close mid-onboarding, pick up where they left off

---

## 6. Beads Tasks (Initial Backlog)

These are the seed tasks to get the audiotake2 code integrated and the initial app skeleton running.

### Epic 1: Project Foundation

- `PABLO-D-001` — Initialize Xcode project (SwiftUI, macOS target, SPM)
- `PABLO-D-002` — Set up MVVM folder structure (Models/ViewModels/Views/Services)
- `PABLO-D-003` — Configure beads for this repo
- `PABLO-D-004` — Set up CI (GitHub Actions — build + test on push)

### Epic 2: AudioCaptureKit Integration

- `PABLO-D-010` — Audit audiotake2 repo — identify public API surface
- `PABLO-D-011` — Add AudioCaptureKit as Swift package dependency (or submodule)
- `PABLO-D-012` — Implement `RecordingService` wrapper around AudioCaptureKit
- `PABLO-D-013` — Verify recording start/stop in a sandbox view (no UI polish yet)

### Epic 3: Core Session UI

- `PABLO-D-020` — Day-view screen (list of today's sessions)
- `PABLO-D-021` — Session row component with status badge
- `PABLO-D-022` — "Start Session" button — triggers recording + video launch
- `PABLO-D-023` — New session / new patient creation flow
- `PABLO-D-024` — Empty state (no sessions today)

### Epic 4: Backend Sync

- `PABLO-D-030` — `APIClient` service (auth + base request handling)
- `PABLO-D-031` — Fetch sessions for today from Pablo backend
- `PABLO-D-032` — POST new session / patient to backend
- `PABLO-D-033` — Upload recording on session end

### Epic 5: Video Conferencing Launch

- `PABLO-D-040` — Zoom deep link launch (`zoommtg://`)
- `PABLO-D-041` — Microsoft Teams deep link launch (`msteams://`)
- `PABLO-D-042` — Google Meet browser launch (no native scheme — open in default browser)
- `PABLO-D-043` — Detect installed apps and show only relevant launch options

### Epic 6: Therapist Onboarding (Pablo-Guided Setup)

- `PABLO-D-050` — Onboarding flow architecture (step machine, resume-able state)
- `PABLO-D-051` — Step 1: Account connection / login screen
- `PABLO-D-052` — Step 2: Microphone permission request + verification
- `PABLO-D-053` — Step 3: Screen recording / system audio permission (if required)
- `PABLO-D-054` — Step 4: Video platform detection + configuration
- `PABLO-D-055` — Step 5: Test recording (5-second capture + playback)
- `PABLO-D-056` — Step 6: "You're ready" Pablo Bear celebration + day view hand-off
- `PABLO-D-057` — Settings screen: re-access any onboarding step after setup

---

## 7. Files to Create in This Repo

- [x] `docs/repo-setup-questions.md` (this file)
- [x] `CLAUDE.md` — project instructions for Claude Code
- [x] `docs/branding.md` — Pablo design system reference for macOS
- [ ] `README.md` — once repo is initialized
- [ ] `.gitignore` — Xcode + Rust + macOS standard
- [ ] `Makefile` — `build-core` / `build-mac` / `test-all`
- [ ] `core/Cargo.toml` — Rust crate skeleton
- [ ] `mac/` — Xcode project skeleton
- [ ] `windows/.gitkeep` — stub for future Windows app
- [ ] `.github/workflows/core.yml` — CI on `core/**`
- [ ] `.github/workflows/mac.yml` — CI on `mac/**`

---

## 8. Decisions Log

| Decision | Status | Answer |
|---|---|---|
| Repo name | ✅ | `pablo-health/pablo-companion` (monorepo) |
| Cross-platform strategy | ✅ | Option C — Rust core (`core/`) + SwiftUI (`mac/`) + WinUI (`windows/`) |
| Repo structure | ✅ | Monorepo |
| Auth (macOS) | ✅ | Inherited from `audiotake2` |
| Auth (Windows) | 🔜 | TBD when Windows app is built |
| Calendar source | ✅ | Pablo backend owns the schedule |
| "entire" toolchain | 🔜 | User handling |
| AudioCaptureKit integration | ❓ | Swift Package or submodule? Audit audiotake2 first |
| Video call joining UX | ❓ | Auto deep link or show-then-click? |
| macOS minimum version | ❓ | Check audiotake2 target |

**Ready to initialize the repo** once "entire" is resolved. Everything else can be answered during implementation.
