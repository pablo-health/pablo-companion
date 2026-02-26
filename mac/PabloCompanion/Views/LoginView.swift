import SwiftUI

/// Login screen shown when the user is not authenticated.
struct LoginView: View {
    let authViewModel: AuthViewModel
    @State private var authURLValidationError: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("PabloBear")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)

            Text("Sign in to Pablo")
                .font(.pabloDisplay(22))

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
                .onChange(of: authViewModel.authServerURL) { _, newValue in
                    authURLValidationError = URLValidator.validateScheme(newValue)
                }
            if let error = authURLValidationError {
                ErrorMessageLabel(message: error)
            }
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
                .foregroundStyle(Color.pabloHoney)
        }

        if let error = authViewModel.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(Color.pabloBlush)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

#Preview {
    LoginView(authViewModel: AuthViewModel())
        .frame(width: 500, height: 600)
}
