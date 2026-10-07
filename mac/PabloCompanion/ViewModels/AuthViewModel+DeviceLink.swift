import Foundation

// MARK: - Device Link

/// Sign-in also registers this Mac with the server (the enrollment payload on
/// the code exchange). Until it is registered the web dashboard cannot tell
/// the app is installed and keeps offering the download, so a failed
/// registration is surfaced in the main window with a retry.
extension AuthViewModel {
    /// Registers this Mac again by repeating the browser sign-in. Enrollment
    /// only happens in the code exchange; the server has no separate endpoint
    /// for it. The clinician stays signed in here whatever happens: a failed
    /// or abandoned retry leaves the note up rather than signing them out.
    func retryDeviceLink() async {
        guard !isRelinkingDevice else { return }
        isRelinkingDevice = true
        defer { isRelinkingDevice = false }
        await signIn()
    }

    /// Records a failed sign-in step. During a device-link retry the
    /// clinician is already signed in, so nothing changes.
    func failSignIn(_ message: String?) {
        guard !isRelinkingDevice else { return }
        errorMessage = message
        authState = .unauthenticated
    }
}
