import CompanionSessionCore
import Foundation
@testable import Pablo
import Testing

@Suite("RecordingViewModel Bluetooth conflict")
@MainActor
struct RecordingViewModelBluetoothTests {
    @Test func noConflictWhenNoMicSelected() {
        let viewModel = RecordingViewModel()
        viewModel.selectedMicID = nil
        #expect(!viewModel.bluetoothRoutingConflict)
        #expect(viewModel.bluetoothRecommendation == nil)
    }
}

/// Session audio is PHI. When no encryption key can be had, recording must not
/// start, and the clinician must be told why.
@Suite("Recording fails closed without an encryption key")
@MainActor
struct RecordingEncryptionFailClosedTests {
    @Test func aMissingKeyStopsTheCaptureFromStarting() async {
        let viewModel = RecordingViewModel()
        viewModel.service.makeEncryptor = { _ in nil }

        await viewModel.startRecording()

        #expect(!viewModel.service.hasCaptureSession)
        #expect(viewModel.recordingState == .idle)
    }

    @Test func aMissingKeyShowsTheClinicianAnError() async {
        let viewModel = RecordingViewModel()
        viewModel.service.makeEncryptor = { _ in nil }

        await viewModel.startRecording()

        #expect(viewModel.showError)
        #expect(viewModel.errorMessage == RecordingService.encryptionUnavailableMessage)
        #expect(viewModel.persistentError == RecordingService.encryptionUnavailableMessage)
    }

    @Test func theEncryptorIsAskedForTheSignedInUsersKey() async {
        let viewModel = RecordingViewModel()
        viewModel.userEmail = "clinician@example.com"
        var askedFor: String?
        viewModel.service.makeEncryptor = { email in
            askedFor = email
            return nil
        }

        await viewModel.startRecording()

        #expect(askedFor == "clinician@example.com")
    }

    @Test func encryptionIsRequiredWhenRequested() {
        #expect(RecordingService.encryptionRequired(requested: true))
    }
}

/// A Keychain whose writes never land, as when the login keychain is locked or
/// the item can't be added.
private struct WriteRefusingKeychain: KeychainStoring {
    func string(forKey _: String) -> String? {
        nil
    }

    func setString(_: String, forKey _: String) {}
    func data(forKey _: String) -> Data? {
        nil
    }

    func setData(_: Data, forKey _: String) {}
    func removeItem(forKey _: String) {}
}

@Suite("Encryption key creation")
struct EncryptionKeyCreationTests {
    @Test func aKeyThatDidNotPersistIsNotReturned() {
        // Audio sealed with a key that never reached the Keychain could not be
        // opened again, so the caller must see no key at all.
        let key = KeychainManager.getOrCreateEncryptionKey(
            forUser: "clinician@example.com",
            in: WriteRefusingKeychain()
        )

        #expect(key == nil)
    }

    @Test func aKeyThatPersistedIsReturnedAndReadBack() {
        let store = InMemoryKeychain()

        let created = KeychainManager.getOrCreateEncryptionKey(forUser: "clinician@example.com", in: store)
        let again = KeychainManager.getOrCreateEncryptionKey(forUser: "clinician@example.com", in: store)

        #expect(created?.count == 32)
        #expect(again == created)
    }
}
