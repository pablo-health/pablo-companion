import Foundation
import Testing
@testable import PabloCompanion

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
