# Security Policy

## Supported Versions

| Platform | Version | Supported |
|----------|---------|-----------|
| macOS (Swift) | latest main | ✅ |
| Windows (C#) | latest main | ✅ |

## Reporting a Vulnerability

If you discover a security vulnerability in Pablo Companion, **please do not open a public issue.**

Instead, please report it through [GitHub's private vulnerability reporting](https://github.com/pablo-health/pablo-companion/security/advisories/new):

1. Go to the [Security Advisories](https://github.com/pablo-health/pablo-companion/security/advisories) page
2. Click **"Report a vulnerability"**
3. Fill in the details and submit

If you are unable to use GitHub's reporting, you may email [kurtn@pablo.health](mailto:kurtn@pablo.health) with the subject line "Pablo Companion Vulnerability Disclosure".

### Response Timeline

- A maintainer will **acknowledge** the report within **3 business days**
- A detailed response with next steps will follow within **7 business days**
- A fix or mitigation will be developed within **90 days** of the initial report, depending on severity and complexity

### Disclosure Policy

We follow a [coordinated vulnerability disclosure](https://en.wikipedia.org/wiki/Coordinated_vulnerability_disclosure) process:

- Reporters are asked to keep vulnerability details confidential until a fix is released
- We will coordinate a disclosure timeline with the reporter
- Security advisories will be published via [GitHub Security Advisories](https://github.com/pablo-health/pablo-companion/security/advisories) once a fix is available
- Credit will be given to reporters unless they prefer to remain anonymous

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Affected platform(s) and version(s)
- Potential impact (e.g., data exposure, privilege escalation)
- Any suggested fix or mitigation (optional)

## Security Practices

This project handles sensitive audio data and follows these security practices:

### Encryption at rest

- All captured audio is encrypted with **AES-256-GCM** before reaching disk — no plaintext audio is stored.
- Each file uses a fresh random 96-bit nonce (via `AES.GCM.seal()` on macOS, `AesGcm` on Windows).
- The 32-byte master key is **per-user**, keyed by the signed-in account's email (`encryptionKey_<email>` in Keychain / Credential Manager). Signing out does not delete the key so pending uploads can resume; explicit "purge" removes it.
- Keychain access uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

### Authentication

- OAuth 2.0 authorization code flow with **PKCE (RFC 7636, S256)** and **loopback redirect (RFC 8252 §7.3)**.
- The loopback server binds to `127.0.0.1` IPv4 only on an OS-assigned ephemeral port; port is bound before the browser opens to prevent hijack races.
- A cryptographically random `state` parameter is generated per flow and verified on callback to protect against CSRF / cross-flow contamination.
- The backend is the authority for JWT signature verification on every API call. The client decodes the ID token only for UI (email display, local expiry check) and never grants trust on decoded claims beyond local session scoping.

### PHI handling

- `print()` / `Console.WriteLine` are forbidden in production code; logging uses `os.Logger` (Swift) and structured logging (C#).
- SwiftLint enforces this via a custom `no_print_statements` rule with severity `error`.
- All DOM / prompt content sent to the backend LLM is run through `PHISanitizer` (Swift) / `PhiSanitizer` (C#) to strip names, phones, emails, DOBs, SSNs, MRNs, and ICD-10 codes.
- CSS selectors driven by the LLM are validated by `SelectorValidator` before being executed in a browser context.
- 15-minute inactivity timer (+ screen-lock hook) signs the user out when not actively recording.

### Dependency & supply chain

- Dependabot — weekly SPM (macOS), weekly NuGet/audit (Windows), weekly GitHub Actions.
- Trivy — vulnerability, misconfiguration, and secret scanning.
- `dotnet restore /p:NuGetAudit=true /p:NuGetAuditLevel=moderate` on every Windows build.
- GitHub Actions: SHA-pinned (not tag-pinned); least-privilege `permissions:` declared per job.

### Static analysis & CI gates

- SwiftLint `--strict` (force-unwrap/cast/try treated as error), SwiftFormat `--lint`, `dotnet format --verify-no-changes`.
- CodeQL (Swift + C#), OpenSSF Scorecard (weekly), weekly security workflow.
- Pre-commit: `detect-secrets` with a maintained baseline, trailing whitespace, large-file rejection.
