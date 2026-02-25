import AudioCaptureKit
import CryptoKit
import Foundation

/// Production AES-256-GCM encryptor using a per-device key stored in Keychain.
struct RecordingEncryptor: CaptureEncryptor {
    private let key: SymmetricKey

    init?() {
        guard let keyData = KeychainManager.deviceEncryptionKey()
            ?? KeychainManager.getOrCreateDeviceEncryptionKey()
        else {
            return nil
        }
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
    static func decryptFile(at url: URL) throws -> Data {
        let fileData = try Data(contentsOf: url)
        let headerSize = 44
        guard fileData.count > headerSize else {
            throw CaptureError.encryptionFailed("File too small to contain WAV header")
        }

        let header = fileData.prefix(headerSize)
        var offset = headerSize

        guard let encryptor = Self() else {
            throw CaptureError.encryptionFailed("Device encryption key not available")
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

    func keyMetadata() -> [String: String] {
        [
            "keyId": "device-key-v1",
            "algorithm": algorithm,
        ]
    }
}
