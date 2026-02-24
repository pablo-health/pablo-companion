import SwiftUI

/// Login screen shown when the user is not authenticated.
struct LoginView: View {
    let authViewModel: AuthViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("Sign in to Therapy Recorder")
                .font(.title2)
                .fontWeight(.semibold)

            serverURLField
            authStateContent
            authStatusMessages

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var serverURLField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Server URL")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("https://app.example.com", text: Bindable(authViewModel).authServerURL)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: 320)
    }

    @ViewBuilder
    private var authStateContent: some View {
        if authViewModel.authState == .authenticating {
            ProgressView("Authenticating...")
        } else {
            Button("Sign In") {
                authViewModel.signIn()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(authViewModel.authServerURL.isEmpty)
        }
    }

    @ViewBuilder
    private var authStatusMessages: some View {
        if authViewModel.authState == .tokenExpired {
            Text("Your session has expired. Please sign in again.")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        if let error = authViewModel.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}
