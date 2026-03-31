import SwiftUI

/// Shown after a practice session ends — confirms completion and duration.
struct PracticeEndedView: View {
    let topicName: String
    let durationSeconds: Int
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.pabloSage)
                .accessibilityHidden(true)

            Text("Practice Session Complete")
                .font(.pabloDisplay(20))
                .foregroundStyle(Color.pabloBrownDeep)

            VStack(spacing: 6) {
                Text(topicName)
                    .font(.pabloBody(14).weight(.medium))
                    .foregroundStyle(Color.pabloBrownDeep)

                Text(formattedDuration)
                    .font(.pabloBody(13))
                    .foregroundStyle(Color.pabloBrownSoft)
            }

            Text("Your SOAP note is being generated and will appear in session history.")
                .font(.pabloBody(13))
                .foregroundStyle(Color.pabloBrownSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button("Done") { onDismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Close practice session summary")
                .padding(.bottom, 16)
        }
        .padding(32)
        .frame(width: 400, height: 360)
        .background(Color.pabloCream)
    }

    private var formattedDuration: String {
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        return "Duration: \(minutes)m \(seconds)s"
    }
}
