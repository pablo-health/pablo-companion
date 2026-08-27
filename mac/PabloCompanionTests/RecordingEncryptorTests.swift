import CryptoKit
import Foundation
@testable import Pablo
import Testing

/// Covers the at-rest encryption for recordings, and the chunked sidecar format
/// the upload path decrypts.
///
/// This was 0% covered and untestable: constructing a `RecordingEncryptor` reads
/// the Keychain, and under an ad-hoc-signed test host that raises a system prompt
/// nobody is there to click. With the Keychain behind a protocol it mints an
/// in-memory key instead, so the real crypto path runs.
///
/// The format matters beyond this app — Windows' `PcmDecryptor.cs` reimplements
/// it, so a silent change here desynchronises the two platforms.
@Suite("RecordingEncryptor")
struct RecordingEncryptorTests {

    private static func makeEncryptor() throws -> RecordingEncryptor {
        try #require(RecordingEncryptor(userEmail: "therapist-\(UUID().uuidString)@pablo.health"))
    }

    // MARK: - Round trip

    @Test func encryptThenDecryptReturnsTheOriginal() throws {
        let encryptor = try Self.makeEncryptor()
        let plaintext = Data("clinical notes about a patient".utf8)

        let sealed = try encryptor.encrypt(plaintext)
        let opened = try encryptor.decrypt(sealed)

        #expect(opened == plaintext)
    }

    @Test func theCiphertextDoesNotContainThePlaintext() throws {
        // The whole point: this lands on a therapist's disk.
        let encryptor = try Self.makeEncryptor()
        let plaintext = Data("patient name Jane Doe".utf8)

        let sealed = try encryptor.encrypt(plaintext)

        #expect(!String(decoding: sealed, as: UTF8.self).contains("Jane Doe"))
        #expect(sealed != plaintext)
    }

    @Test func encryptingTheSameBytesTwiceGivesDifferentCiphertext() throws {
        // AES-GCM uses a fresh nonce per seal. Identical output would leak that
        // two recordings share content.
        let encryptor = try Self.makeEncryptor()
        let plaintext = Data(repeating: 0x41, count: 256)

        let a = try encryptor.encrypt(plaintext)
        let b = try encryptor.encrypt(plaintext)

        #expect(a != b)
        #expect(try encryptor.decrypt(a) == plaintext)
        #expect(try encryptor.decrypt(b) == plaintext)
    }

    @Test func anEmptyPayloadRoundTrips() throws {
        let encryptor = try Self.makeEncryptor()
        #expect(try encryptor.decrypt(encryptor.encrypt(Data())) == Data())
    }

    // MARK: - Tamper detection

    @Test func aTamperedCiphertextFailsToDecrypt() throws {
        // AES-GCM authenticates. A flipped bit must throw, not return garbage —
        // silently decrypting corrupted PHI would be worse than failing.
        let encryptor = try Self.makeEncryptor()
        var sealed = try encryptor.encrypt(Data("sensitive".utf8))
        sealed[sealed.count - 1] ^= 0xFF

        #expect(throws: (any Error).self) {
            try encryptor.decrypt(sealed)
        }
    }

    @Test func anotherUsersKeyCannotDecryptIt() throws {
        // Keys are scoped per user. A second therapist on the same Mac must not
        // be able to read the first one's recordings.
        let mine = try Self.makeEncryptor()
        let theirs = try Self.makeEncryptor()
        let sealed = try mine.encrypt(Data("my session".utf8))

        #expect(throws: (any Error).self) {
            try theirs.decrypt(sealed)
        }
    }

    @Test func garbageIsRejectedRatherThanReturned() throws {
        let encryptor = try Self.makeEncryptor()
        #expect(throws: (any Error).self) {
            try encryptor.decrypt(Data("not a sealed box at all".utf8))
        }
    }

    // MARK: - The chunked PCM sidecar format

    @Test func aChunkedPCMSidecarDecryptsToTheOriginalBytes() throws {
        // Format: sequential [4-byte UInt32 LE length][AES-GCM sealed box].
        // Windows' PcmDecryptor.cs reimplements this; the two must agree.
        let encryptor = try Self.makeEncryptor()
        let email = "therapist-\(UUID().uuidString)@pablo.health"
        let keyed = try #require(RecordingEncryptor(userEmail: email))

        let chunk1 = Data(repeating: 0x01, count: 512)
        let chunk2 = Data(repeating: 0x02, count: 256)
        var file = Data()
        for chunk in [chunk1, chunk2] {
            let sealed = try keyed.encrypt(chunk)
            withUnsafeBytes(of: UInt32(sealed.count).littleEndian) { file.append(contentsOf: $0) }
            file.append(sealed)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcm-\(UUID().uuidString).enc.pcm")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let tempURL = try RecordingEncryptor.decryptPCMToTempFile(at: url, userEmail: email)
        defer { RecordingEncryptor.cleanupTempFile(tempURL) }

        #expect(try Data(contentsOf: tempURL) == chunk1 + chunk2)
        _ = encryptor
    }

    @Test func aTruncatedChunkIsRejectedRatherThanTruncatingTheAudio() throws {
        // A length prefix claiming more bytes than remain means the file is
        // damaged. Returning the partial audio would silently upload a truncated
        // session; the therapist would never know.
        let email = "therapist-\(UUID().uuidString)@pablo.health"
        let keyed = try #require(RecordingEncryptor(userEmail: email))
        let sealed = try keyed.encrypt(Data(repeating: 0x07, count: 128))

        var file = Data()
        // Claim a chunk far longer than what follows.
        withUnsafeBytes(of: UInt32(sealed.count + 999).littleEndian) { file.append(contentsOf: $0) }
        file.append(sealed)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcm-\(UUID().uuidString).enc.pcm")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try RecordingEncryptor.decryptPCMToTempFile(at: url, userEmail: email)
        }
    }

    @Test func cleanupRemovesTheDecryptedTempFile() throws {
        // The temp file is decrypted PHI. Leaving it behind defeats encrypting
        // the sidecar in the first place.
        let email = "therapist-\(UUID().uuidString)@pablo.health"
        let keyed = try #require(RecordingEncryptor(userEmail: email))
        let sealed = try keyed.encrypt(Data(repeating: 0x03, count: 64))
        var file = Data()
        withUnsafeBytes(of: UInt32(sealed.count).littleEndian) { file.append(contentsOf: $0) }
        file.append(sealed)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcm-\(UUID().uuidString).enc.pcm")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let tempURL = try RecordingEncryptor.decryptPCMToTempFile(at: url, userEmail: email)
        #expect(FileManager.default.fileExists(atPath: tempURL.path))

        RecordingEncryptor.cleanupTempFile(tempURL)

        #expect(!FileManager.default.fileExists(atPath: tempURL.path))
    }

    @Test func cleanupOfAnAlreadyGoneFileIsNotAnError() {
        RecordingCleanerProbe.expectNoThrow {
            RecordingEncryptor.cleanupTempFile(
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("never-existed-\(UUID().uuidString).pcm")
            )
        }
    }

    // MARK: - Metadata

    @Test func keyMetadataNamesTheAlgorithmTheBackendExpects() throws {
        let encryptor = try Self.makeEncryptor()
        #expect(encryptor.algorithm == "AES-256-GCM")
        #expect(encryptor.keyMetadata()["algorithm"] == "AES-256-GCM")
        #expect(encryptor.keyMetadata()["keyId"] != nil)
    }
}

/// Tiny helper so "this must not trap" reads as an assertion rather than a bare
/// call that happens to be in a test.
private enum RecordingCleanerProbe {
    static func expectNoThrow(_ body: () -> Void) {
        body()
    }
}
