import SwiftUI

/// Blocking full-screen view shown when a version incompatibility is detected.
///
/// Two modes:
/// - **clientUpdate**: the server says this app version is too old.
/// - **serverUpdate**: this app requires a newer server version.
struct UpdateRequiredView: View {
    let reason: Reason

    enum Reason {
        case clientUpdate(currentVersion: String, minVersion: String)
        case serverUpdate(serverVersion: String, minRequired: String)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("PabloBear")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Text(title)
                .font(.pabloDisplay(22))
                .foregroundStyle(Color.pabloBrownDeep)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.pabloBody(14))
                .foregroundStyle(Color.pabloBrownSoft)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if case .clientUpdate = reason {
                Text("Please download the latest version to continue.")
                    .font(.pabloBody(14))
                    .foregroundStyle(Color.pabloBrownSoft)
            } else {
                Text("Please contact your administrator.")
                    .font(.pabloBody(14))
                    .foregroundStyle(Color.pabloBrownSoft)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color.pabloCream)
    }

    private var title: String {
        switch reason {
        case .clientUpdate:
            "Update Required"
        case .serverUpdate:
            "Server Update Needed"
        }
    }

    private var subtitle: String {
        switch reason {
        case let .clientUpdate(current, min):
            "Your app (v\(current)) is no longer supported. Version \(min) or later is required."
        case let .serverUpdate(server, min):
            "The server (v\(server)) is not compatible with this app. Server v\(min) or later is required."
        }
    }
}

#Preview("Client Update") {
    UpdateRequiredView(reason: .clientUpdate(currentVersion: "1.0.0", minVersion: "2.0.0"))
}

#Preview("Server Update") {
    UpdateRequiredView(reason: .serverUpdate(serverVersion: "0.9.0", minRequired: "1.0.0"))
}
