import Foundation
import os

/// Process-wide configuration for the device-auth core.
///
/// The same code signs DPoP proofs inside the sandboxed, signed app *and*
/// inside the headless e2e harness (`practice-harness`), and the two run with
/// different keychain identities:
///
/// - The app sets `keychainAccessGroup` to its `keychain-access-groups`
///   entitlement (`L8KG4FA2R9.health.pablo.companion`) so the device key is
///   shared across its own binaries and survives reinstalls.
/// - The harness leaves it `nil` — an unsigned CLI has no keychain
///   entitlements, and passing an access group it isn't entitled to fails
///   every `SecItem` call with `errSecMissingEntitlement`. With no group the
///   items land in the caller's default (login) keychain, which is exactly
///   right for a test process.
///
/// Set both values once at process start, before the first `DeviceKey` use.
public enum AuthCoreConfig {
    private struct State {
        var bundleID = "health.pablo.companion"
        var keychainAccessGroup: String?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Logger subsystem + keychain service/tag namespace. The app sets its
    /// bundle id; the harness uses a distinct namespace so its software test
    /// key can never collide with a real install's key on a developer Mac.
    public static var bundleID: String {
        get { state.withLock { $0.bundleID } }
        set { state.withLock { $0.bundleID = newValue } }
    }

    /// Keychain access group for the persisted device key, or `nil` to use
    /// the process's default keychain (no `kSecAttrAccessGroup` attribute).
    public static var keychainAccessGroup: String? {
        get { state.withLock { $0.keychainAccessGroup } }
        set { state.withLock { $0.keychainAccessGroup = newValue } }
    }
}
