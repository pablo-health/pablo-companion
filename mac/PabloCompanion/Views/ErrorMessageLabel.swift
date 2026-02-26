import SwiftUI

/// Inline validation error shown below a field — exclamation icon + blush text.
struct ErrorMessageLabel: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(Color.pabloBlush)
    }
}

#Preview {
    ErrorMessageLabel(message: "URL must start with https://")
        .padding()
}
