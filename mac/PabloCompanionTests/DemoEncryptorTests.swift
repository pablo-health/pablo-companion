import Foundation
import Testing
@testable import PabloCompanion

@Suite("DemoEncryptor")
struct DemoEncryptorTests {
    let encryptor = DemoEncryptor()

    @Test func roundTripEncryption() throws {
        let original = Data("Hello, Pablo!".utf8)
        let encrypted = try encryptor.encrypt(original)
        let decrypted = try encryptor.decrypt(encrypted)
        #expect(decrypted == original)
    }

    @Test func encryptedDataDiffersFromPlaintext() throws {
        let data = Data("test".utf8)
        let encrypted = try encryptor.encrypt(data)
        #expect(encrypted != data)
    }

    @Test func decryptCorruptDataThrows() {
        let garbage = Data(repeating: 0xFF, count: 64)
        #expect(throws: (any Error).self) {
            try encryptor.decrypt(garbage)
        }
    }

    @Test func decryptFileTooSmallThrows() {
        let tinyData = Data(repeating: 0, count: 10)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tiny_\(UUID()).wav")
        try? tinyData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) {
            try DemoEncryptor.decryptFile(at: url)
        }
    }

    @Test func algorithmIdentifier() {
        #expect(encryptor.algorithm == "AES-256-GCM")
    }
}
