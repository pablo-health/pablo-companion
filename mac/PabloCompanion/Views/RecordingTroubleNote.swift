import SwiftUI

/// Shown inside the session card when audio isn't being recorded: capture has
/// stalled, or has stopped while the session is still open. Offers one fix,
/// restarting capture, which keeps what was already recorded and adds to it.
struct RecordingTroubleNote: View {
    let trouble: RecordingTrouble
    let onRestart: () -> Void

    private var message: String {
        switch trouble {
        case .stalled: RecordingTrouble.stalledMessage
        case let .stopped(reason): reason
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(Color.pabloError)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.pabloBody(13).weight(.semibold))
                    .foregroundStyle(Color.pabloBrownDeep)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Restart Recording", action: onRestart)
                    .buttonStyle(.link)
                    .accessibilityLabel("Restart recording")
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.pabloError.opacity(0.1))
        )
        .accessibilityElement(children: .contain)
        .onAppear {
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

#Preview("Stalled") {
    RecordingTroubleNote(trouble: .stalled, onRestart: {})
        .padding()
        .frame(width: 456)
        .background(Color.pabloCream)
}

#Preview("Mic disconnected") {
    RecordingTroubleNote(trouble: .stopped(RecordingViewModel.micDisconnectedMessage), onRestart: {})
        .padding()
        .frame(width: 456)
        .background(Color.pabloCream)
}
