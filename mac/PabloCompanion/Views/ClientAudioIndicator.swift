import SwiftUI

/// Live "is the client reaching the recording?" status, replacing the old
/// "System audio" dot — which only said a system-audio source existed when
/// recording started, and stayed green while a silent tap captured nothing.
struct ClientAudioIndicator: View {
    let systemAudioActive: Bool
    let status: ClientAudioMonitor.Status

    var body: some View {
        StatusIndicator(
            isActive: systemAudioActive && status == .hearingClient,
            activeLabel: "Hearing client",
            inactiveLabel: inactiveLabel,
            // Waiting is normal (the client may not have spoken yet); only a
            // missing source or a detected problem gets the alarm colour.
            inactiveColor: systemAudioActive && status == .listening ? .pabloHoney : .pabloBlush
        )
    }

    private var inactiveLabel: String {
        guard systemAudioActive else { return "No system audio" }
        return status == .noClientAudio ? "No client audio" : "Waiting for client audio"
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        ClientAudioIndicator(systemAudioActive: true, status: .hearingClient)
        ClientAudioIndicator(systemAudioActive: true, status: .listening)
        ClientAudioIndicator(systemAudioActive: true, status: .noClientAudio)
        ClientAudioIndicator(systemAudioActive: false, status: .listening)
    }
    .padding()
}
