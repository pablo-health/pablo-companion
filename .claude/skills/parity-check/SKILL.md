---
name: parity-check
description: Compare macOS and Windows implementations for cross-platform parity drift
user_invocable: true
---

# Cross-Platform Parity Audit — Pablo Companion

CLAUDE.md says: **"Mac is the primary development platform. Windows features should follow."** This skill finds places where Windows has drifted from macOS (or vice versa) — new features on one side, renamed fields in the shared API contract, service classes with different surfaces.

## Steps

1. **API model parity** — the Pablo backend REST API is the shared contract. Diff the generated types:
   - `mac/PabloCompanion/Generated/PabloAPITypes.swift`
   - `windows/PabloCompanion/Models/PabloAPITypes.cs`

   For each Codable/JSON type:
   - Are all property names present on both sides (modulo Swift camelCase ↔ C# PascalCase)?
   - Are the JSON serialization names (`CodingKeys` / `[JsonPropertyName]`) identical?
   - Are optional/required annotations consistent?
   - Report any field that exists on one side and not the other.

2. **Service surface parity** — for each Swift service under `mac/PabloCompanion/Services/`, look for a C# counterpart under `windows/PabloCompanion/Services/`:
   - Map Swift filename → expected C# filename (e.g., `APIClient.swift` → `APIClient.cs`, `PHISanitizer.swift` → `PhiSanitizer.cs`)
   - Flag services that exist on one platform but not the other — is this intentional, or drift?
   - Within matched pairs, compare the public method surface: methods on one side with no counterpart on the other.

3. **ViewModel parity** — same approach for `mac/PabloCompanion/ViewModels/` ↔ `windows/PabloCompanion/ViewModels/`.

4. **Known-sensitive spots** — specifically diff these:
   - Auth / OAuth flow: `AuthViewModel.swift` ↔ `AuthViewModel.cs`, `LoopbackServer.swift` ↔ `LoopbackServer.cs`
   - PHI handling: `PHISanitizer.swift` ↔ `PhiSanitizer.cs`, `SelectorValidator.swift` ↔ `SelectorValidator.cs`
   - Encryption: `RecordingEncryptor.swift` ↔ `AesGcmEncryptor` usage + `KeychainManager.swift` ↔ `CredentialManager.cs`

5. **Feature set** — check whether major features mentioned in CLAUDE.md (Day view, Start Session, Patient creation, Sparkle auto-update, etc.) have implementations on both platforms. If a feature is flagged as Mac-only or Windows-only, verify that CLAUDE.md documents that intent.

## Report format

```
## Cross-Platform Parity Audit

### API Model Drift (blocking — breaks wire compatibility)
- **Session.scheduledAt** — present in Swift, missing in C# `Session.cs`
- **Patient.firstName** — Swift camelCase `firstName`, C# maps to `first_name` (mismatch with Swift `CodingKeys`?)
- ...

### Service Drift
- **mac: FooService.swift** — no Windows counterpart
- **windows: BarService.cs** — no macOS counterpart
- **APIClient**: `fetchFoo()` on Swift, no `FetchFooAsync()` on C#
- ...

### Intentional Mac-only / Windows-only (per CLAUDE.md)
- WhisperTranscriber.cs — Windows-only; macOS is cloud-only (PABLO-D-106 tracks migration)
- ...

### Aligned
- PabloAPITypes: all N types parity-clean
- Services: APIClient, RecordingService, SessionRecordingStore, PHISanitizer — aligned
```

## Critical Rules

- **Do NOT edit files** — audit-only by default.
- Don't flag platform-idiomatic differences (e.g., Swift `async throws` ↔ C# `Task<T>` with exceptions) as drift.
- Do flag missing semantic equivalents (e.g., Swift `isValidAuthCode()` with regex `^[a-zA-Z0-9_\-\.]{10,2000}$` must have a matching regex on C#).
- Report file:line for each finding.

## Invocation

```
/parity-check
```

Takes no arguments. Runs against the whole repo.
