import SwiftUI

/// Offers "Say hello to Pablo" once, the first time a signed-in therapist
/// reaches the main window. Skippable; Settings → Check audio reruns it.
///
/// Never while recording or mid-start: the check runs its own capture, and two
/// captures can't share the devices.
private struct AudioCheckOnFirstUse: ViewModifier {
    @AppStorage("audioCheckOffered") private var offered = false
    @State private var showing = false

    let isBusy: Bool
    let micDeviceID: String?

    func body(content: Content) -> some View {
        content
            .task(id: isBusy) {
                guard !offered, !isBusy else { return }
                // Let the window settle before a sheet lands on it.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, !isBusy else { return }
                offered = true
                showing = true
            }
            .sheet(isPresented: $showing) {
                AudioCheckView(micDeviceID: micDeviceID) { showing = false }
            }
    }
}

extension View {
    func audioCheckOnFirstUse(isBusy: Bool, micDeviceID: String?) -> some View {
        modifier(AudioCheckOnFirstUse(isBusy: isBusy, micDeviceID: micDeviceID))
    }
}
