import CryptoKit
import Foundation
import os
import Security

/// Manages the per-install device keypair used for device-bound proofs (DPoP).
///
/// The key is a P-256 (ES256) keypair generated once per install and persisted
/// across sign-outs — same survive-sign-out treatment as the install identifier
/// and the encryption key. The backend stores the **public** JWK at enrollment
/// (`device_public_key_jwk`) and computes the RFC 7638 thumbprint server-side;
/// the private key never leaves this device.
///
/// Storage is hardware-backed via the Secure Enclave when available
/// (`keyStorage == .hardware`); on hardware without a Secure Enclave (CI hosts,
/// VMs, older Macs) it falls back to a software key persisted in the Keychain
/// (`keyStorage == .software`). Either way the enrollment payload carries a full,
/// schema-valid `device_public_key_jwk` + `key_storage` so the OAuth code
/// exchange is never rejected for a partial enrollment object.
public enum DeviceKey {
    /// Where the private key material lives. Mirrors the backend `KeyStorage`
    /// enum (`hardware | software`).
    public enum Storage: String {
        case hardware
        case software
    }

    /// The public key in JWK form plus the storage class that produced it.
    public struct PublicKey {
        /// Full public JWK: `{kty:"EC", crv:"P-256", x, y}` (base64url, no padding).
        public let jwk: [String: String]
        /// `"hardware"` for a Secure-Enclave key, `"software"` for the fallback.
        public let storage: Storage
    }

    private static let logger = Logger(subsystem: AuthCoreConfig.bundleID, category: "DeviceKey")

    /// Keychain account for the persisted software-fallback private key (raw
    /// P-256 representation).
    private static let softwareKeyAccount = "device_signing_key"
    /// Keychain account for the persisted Secure-Enclave key blob. The SE key is
    /// stored as its opaque `dataRepresentation` — an SE-wrapped blob that only
    /// this device's Secure Enclave can unwrap; no private bytes leave the SE.
    ///
    /// It lives in a `kSecClassGenericPassword` item, NOT `kSecClassKey`.
    /// Storing the opaque blob under `kSecClassKey` makes `SecItemAdd` report
    /// success but the item is not retrievable by tag (`errSecItemNotFound` on
    /// read-back), which silently breaks proof signing on every SE-equipped Mac.
    private static let secureEnclaveKeyAccount = "secure_enclave_device_key"

    /// Adds `kSecAttrAccessGroup` only when the process configured one — an
    /// unentitled process (the harness CLI) must not send the attribute at all.
    private static func withAccessGroup(_ query: [String: Any]) -> [String: Any] {
        guard let group = AuthCoreConfig.keychainAccessGroup else { return query }
        var query = query
        query[kSecAttrAccessGroup as String] = group
        return query
    }

    /// Returns the public JWK + storage class for this install's device key,
    /// creating and persisting the keypair on first call. Returns `nil` only if
    /// neither a Secure-Enclave nor a software key can be created (extremely
    /// unusual); callers then omit the enrollment object entirely rather than
    /// sending a partial one.
    public static func publicKey() -> PublicKey? {
        if let hardware = secureEnclavePublicKey() {
            return PublicKey(jwk: hardware, storage: .hardware)
        }
        if let software = softwarePublicKey() {
            return PublicKey(jwk: software, storage: .software)
        }
        logger.error("Unable to provision a device key (hardware or software)")
        return nil
    }

    // MARK: - Secure Enclave (hardware)

    /// Loads the persisted Secure-Enclave key, generating it on first call.
    /// Returns the public JWK, or `nil` if the Secure Enclave is unavailable.
    private static func secureEnclavePublicKey() -> [String: String]? {
        guard SecureEnclave.isAvailable else { return nil }

        if let stored = loadSecureEnclaveKey() {
            return jwk(from: stored.publicKey)
        }

        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey()
            guard storeSecureEnclaveKey(key.dataRepresentation) else {
                logger.error("Failed to persist Secure-Enclave device key")
                return nil
            }
            logger.info("Generated new Secure-Enclave device key")
            return jwk(from: key.publicKey)
        } catch {
            logger.error("Secure-Enclave key generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func loadSecureEnclaveKey() -> SecureEnclave.P256.Signing.PrivateKey? {
        guard let data = readSecureEnclaveKeyData() else { return nil }
        return try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
    }

    private static func readSecureEnclaveKeyData() -> Data? {
        let query: [String: Any] = withAccessGroup([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AuthCoreConfig.bundleID,
            kSecAttrAccount as String: secureEnclaveKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    @discardableResult
    private static func storeSecureEnclaveKey(_ data: Data) -> Bool {
        let query: [String: Any] = withAccessGroup([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AuthCoreConfig.bundleID,
            kSecAttrAccount as String: secureEnclaveKeyAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ])
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Software fallback

    /// Loads the persisted software P-256 key, generating it on first call.
    private static func softwarePublicKey() -> [String: String]? {
        if let key = loadSoftwareKey() {
            return jwk(from: key.publicKey)
        }

        let key = P256.Signing.PrivateKey()
        guard storeSoftwareKey(key.rawRepresentation) else {
            logger.error("Failed to persist software device key")
            return nil
        }
        logger.info("Generated new software device key")
        return jwk(from: key.publicKey)
    }

    private static func loadSoftwareKey() -> P256.Signing.PrivateKey? {
        guard let data = readSoftwareKeyData() else { return nil }
        return try? P256.Signing.PrivateKey(rawRepresentation: data)
    }

    private static func readSoftwareKeyData() -> Data? {
        let query: [String: Any] = withAccessGroup([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AuthCoreConfig.bundleID,
            kSecAttrAccount as String: softwareKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    @discardableResult
    private static func storeSoftwareKey(_ data: Data) -> Bool {
        let query: [String: Any] = withAccessGroup([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AuthCoreConfig.bundleID,
            kSecAttrAccount as String: softwareKeyAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ])
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Proof signing (DPoP)

    /// Signs `message` with this install's device private key and returns the
    /// signature in JOSE raw `r || s` form (64 bytes for P-256), ready to be
    /// base64url-encoded into a compact JWS.
    ///
    /// `SecKey` / CryptoKit P-256 signatures are ASN.1 DER (`ECDSASig ::=
    /// SEQUENCE { r INTEGER, s INTEGER }`); RFC 7515 §3.4 / RFC 7518 requires the
    /// fixed-width `r || s` concatenation instead. CryptoKit's
    /// `ECDSASignature.rawRepresentation` already emits that JOSE form, so we go
    /// through CryptoKit rather than `SecKeyCreateSignature` and hand-rolling the
    /// DER→raw conversion. The Secure-Enclave key signs in hardware; the bytes it
    /// returns are still the standard DER which CryptoKit re-expresses as raw.
    ///
    /// Returns `nil` when no device key is available (the caller then sends
    /// neither the `DPoP` nor the `X-Install-ID` header — never one alone).
    public static func sign(_ message: Data) -> Data? {
        if SecureEnclave.isAvailable, let key = loadSecureEnclaveKey() {
            guard let signature = try? key.signature(for: message) else {
                logger.error("Secure-Enclave proof signing failed")
                return nil
            }
            return signature.rawRepresentation
        }
        if let key = loadSoftwareKey() {
            guard let signature = try? key.signature(for: message) else {
                logger.error("Software-key proof signing failed")
                return nil
            }
            return signature.rawRepresentation
        }
        logger.error("No device key available to sign a proof")
        return nil
    }

    // MARK: - JWK encoding

    /// Builds a public EC JWK from a P-256 public key. The uncompressed point is
    /// `0x04 || X(32) || Y(32)`; `x` and `y` are the two 32-byte coordinates
    /// encoded base64url without padding (RFC 7518 §6.2.1).
    public static func jwk(from publicKey: P256.Signing.PublicKey) -> [String: String]? {
        let raw = publicKey.rawRepresentation // 64 bytes: X(32) || Y(32)
        guard raw.count == 64 else { return nil }
        let x = raw.prefix(32)
        let y = raw.suffix(32)
        return [
            "kty": "EC",
            "crv": "P-256",
            "x": base64URLNoPadding(x),
            "y": base64URLNoPadding(y),
        ]
    }

    public static func base64URLNoPadding(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
