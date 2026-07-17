import AudioCaptureKit
import CryptoKit
import Foundation

/// Production AES-256-GCM encryptor using a per-user key stored in Keychain.
struct RecordingEncryptor: CaptureEncryptor {
    private let key: SymmetricKey

    /// Creates an encryptor using the encryption key for the given user.
    ///
    /// The key comes from `keyProvider`, which defaults to the Keychain. Tests
    /// inject an in-memory provider instead — without that seam, exercising a
    /// store means touching the developer's real login Keychain, and the
    /// key-unavailable branch cannot be reached at all.
    ///
    /// - Parameter userEmail: nil uses the legacy device-wide key, for
    ///   standalone recordings made before sign-in.
    init?(
        userEmail: String? = nil,
        keyProvider: EncryptionKeyProviding = KeychainEncryptionKeyProvider()
    ) {
        guard let keyData = keyProvider.key(forUser: userEmail) else { return nil }
        self.key = SymmetricKey(data: keyData)
    }

    var algorithm: String {
        "AES-256-GCM"
    }

    func encrypt(_ data: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            guard let combined = sealedBox.combined else {
                throw CaptureError.encryptionFailed("Failed to produce combined sealed box")
            }
            return combined
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.encryptionFailed(error.localizedDescription)
        }
    }

    func decrypt(_ data: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw CaptureError.encryptionFailed("Decryption failed: \(error.localizedDescription)")
        }
    }

    /// Decrypts an encrypted WAV file and returns complete in-memory WAV data.
    ///
    /// File format: 44-byte WAV header followed by encrypted chunks.
    /// Each chunk: 4-byte UInt32 length prefix (little-endian) + combined sealed box data.
    static func decryptFile(at url: URL, userEmail: String? = nil) throws -> Data {
        let fileData = try Data(contentsOf: url)
        let headerSize = 44
        guard fileData.count > headerSize else {
            throw CaptureError.encryptionFailed("File too small to contain WAV header")
        }

        let header = fileData.prefix(headerSize)
        var offset = headerSize

        guard let encryptor = Self(userEmail: userEmail) else {
            throw CaptureError.encryptionFailed("Encryption key not available")
        }

        var pcmData = Data()

        while offset + 4 <= fileData.count {
            let lengthBytes = fileData[offset ..< offset + 4]
            let chunkLength = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
            let length = Int(UInt32(littleEndian: chunkLength))
            offset += 4

            guard offset + length <= fileData.count else {
                throw CaptureError.encryptionFailed("Encrypted chunk exceeds file bounds")
            }

            let chunkData = fileData[offset ..< offset + length]
            let decrypted = try encryptor.decrypt(Data(chunkData))
            pcmData.append(decrypted)
            offset += length
        }

        // Rebuild WAV with correct data size in header
        var wav = Data(header)
        let dataSize = UInt32(pcmData.count)
        let fileSize = UInt32(36 + pcmData.count)
        // Update RIFF chunk size (bytes 4-7)
        wav.replaceSubrange(4 ..< 8, with: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        // Update data sub-chunk size (bytes 40-43)
        wav.replaceSubrange(40 ..< 44, with: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        wav.append(pcmData)

        return wav
    }

    /// Decrypts an encrypted PCM sidecar file (no WAV header) to a temp file.
    /// Returns the path to the decrypted temp file.
    ///
    /// **Important:** The caller is responsible for deleting the returned temp file
    /// after use to avoid leaving decrypted PHI on disk. Use `cleanupTempFile(_:)`.
    ///
    /// Format: sequential `[4-byte UInt32 LE length][AES-GCM sealed box]` chunks.
    static func decryptPCMToTempFile(at url: URL, userEmail: String? = nil) throws -> URL {
        let fileData = try Data(contentsOf: url)
        guard let encryptor = Self(userEmail: userEmail) else {
            throw CaptureError.encryptionFailed("Encryption key not available")
        }

        var pcmData = Data()
        var offset = 0

        while offset + 4 <= fileData.count {
            let lengthBytes = fileData[offset ..< offset + 4]
            let chunkLength = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
            let length = Int(UInt32(littleEndian: chunkLength))
            offset += 4

            guard offset + length <= fileData.count else {
                throw CaptureError.encryptionFailed("Encrypted PCM chunk exceeds file bounds")
            }

            let chunkData = fileData[offset ..< offset + length]
            let decrypted = try encryptor.decrypt(Data(chunkData))
            pcmData.append(decrypted)
            offset += length
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pablo_\(UUID().uuidString).pcm")
        try pcmData.write(to: tempURL)
        return tempURL
    }

    /// Removes a temporary decrypted file created by `decryptPCMToTempFile(at:)`.
    /// Call this in a `defer` block after processing to prevent decrypted PHI
    /// from persisting on disk.
    static func cleanupTempFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func keyMetadata() -> [String: String] {
        [
            "keyId": "device-key-v1",
            "algorithm": algorithm,
        ]
    }
}
