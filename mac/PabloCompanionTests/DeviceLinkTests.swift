import Foundation
@testable import Pablo
import Testing

/// A device-link retry repeats the browser sign-in while the clinician is
/// already signed in. A failed or abandoned retry must not sign them out.
@Suite("Device link retry")
@MainActor
struct DeviceLinkTests {
    @Test func aFailedSignInSignsOutWhenNotRetrying() {
        let vm = AuthViewModel()
        vm.authState = .authenticating
        vm.failSignIn("Sign-in failed. Please try again.")
        #expect(vm.authState == .unauthenticated)
        #expect(vm.errorMessage == "Sign-in failed. Please try again.")
    }

    @Test func aFailedRetryKeepsTheClinicianSignedIn() {
        let vm = AuthViewModel()
        vm.authState = .authenticated(email: "clinician@example.com")
        vm.errorMessage = nil
        vm.deviceLinkFailed = true
        vm.isRelinkingDevice = true

        vm.failSignIn("Sign-in failed. Please try again.")

        #expect(vm.authState == .authenticated(email: "clinician@example.com"))
        #expect(vm.errorMessage == nil)
        #expect(vm.deviceLinkFailed)
    }
}
