---
name: check-docs
description: Scan docs and CLAUDE.md for stale references, broken links, and drift against the codebase
user_invocable: true
---

# Doc Freshness Audit — Pablo Companion

You are auditing the repository's documentation for drift against the current codebase. Cross-platform apps with rapid architectural changes accumulate stale references quickly, and those drifted docs mislead future contributors (and Claude).

## Steps

1. **Scan for references to removed architecture.** Use Grep across `*.md`, `.github/`, and `.claude/`:
   - `\b[Rr]ust\b`, `UniFFI`, `pablo-core`, `cargo`, `\.toml\b`, `Cargo\.toml`
   - Windows-specific: `transcribe_session_1on1`, `preprocess_pcm`, `CaptureRecordingResult` — these were Rust/UniFFI symbols
   - Any `core/` directory references (Rust was removed in commit `5f05c87`)

2. **Scan for references to removed files.** For each doc in `docs/` and root `.md` files, extract backtick-quoted file paths and verify each one exists on disk (ignoring external repos like `pablo-health/pablo`).

3. **Check CLAUDE.md claims against reality:**
   - For every `PABLO-D-*` issue ID mentioned, confirm it exists in `.beads/issues.jsonl`
   - For every file path mentioned, confirm it exists
   - For every tech-stack claim (e.g., "Whisper.net", "Apple Speech"), confirm the service actually exists on that platform

4. **Check SECURITY.md for platform drift:**
   - If it references "Rust" but `/core` doesn't exist → flag
   - If it lists a platform that no longer builds (no `windows/` directory, etc.) → flag

5. **Check `.github/dependabot.yml`:** every `directory:` must correspond to a real directory in the repo.

6. **Check AGENTS.md and skill docs** for references to non-existent slash commands or agents.

## Report format

```
## Doc Freshness Audit

### Critical (references to removed code)
- **path/to/doc.md:NN** — mentions `foo`; last seen in commit `abc123`, removed in `def456`
- ...

### Broken internal links
- **path/to/doc.md:NN** — references `relative/path/to/missing.md`
- ...

### Drift against code
- **CLAUDE.md:NN** — claims "X" but code says "Y" (`path/to/file.ext:NN`)
- ...

### Likely-stale docs (no fix proposed, just flagging)
- docs/foo.md — last touched 2025-XX; references removed subsystem
- ...

### Clean
- All docs free of stale refs: list them here
```

## Critical Rules

- **Do NOT edit any files** — this is audit-only by default. If the user asks to fix, make minimal surgical edits to each affected doc.
- When in doubt, **flag rather than rewrite**. The doc author may have intentionally kept historical context.
- Report file:line locations so the user can jump directly to each finding.
- Keep the report under 1000 words; group strictly by severity.

## Invocation

```
/check-docs
```

Takes no arguments. Runs against the whole repo.
