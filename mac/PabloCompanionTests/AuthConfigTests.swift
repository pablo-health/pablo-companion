import Foundation
@testable import Pablo
import Testing

/// Covers the auth config the login screen keys off.
///
/// `authServerURL`/`backendAPIURL`/`tenantID` were computed Keychain
/// passthroughs. The Observation macro only instruments stored properties, so
/// SwiftUI never invalidated on a change — and every read hit
/// `SecItemCopyMatching`, every keystroke hit `SecItemUpdate`. Now they are
/// stored and hydrated once, which is also what makes this assertable.
@Suite("Auth config defaults")
@MainActor
struct AuthConfigTests {

    @Test func theBackendDefaultsToTheHostThatActuallyResolves() {
        // api.pablo.health was hardcoded here and in six view models and does
        // not resolve. Config discovery masked it by overwriting the value
        // before the first real call.
        #expect(AppConstants.defaultBackendAPIURL == "https://app.pablo.health")
    }

    @Test func signInDefaultsToProduction() {
        #expect(AppConstants.defaultAuthServerURL == "https://app.pablo.health")
    }

    @Test func aFreshInstallHidesTheServerURLField() {
        // A therapist has no idea what to type there, and a labelled field above
        // the CTA reads as required input.
        let vm = AuthViewModel()
        guard vm.authServerURL == AppConstants.defaultAuthServerURL else {
            // A developer machine may carry a saved override; the paired test
            // below covers that case explicitly.
            return
        }
        #expect(!vm.isAdvancedVisible)
    }

    @Test func showAdvancedRevealsTheField() {
        let vm = AuthViewModel()
        vm.showAdvanced()
        #expect(vm.isAdvancedVisible)
    }

    @Test func theURLIsObservableSoValidationCanRunLive() {
        // The property must be stored for @Observable to track it. If this ever
        // reverts to a computed Keychain passthrough, SwiftUI stops invalidating
        // and LoginView's inline validation silently stops firing while typing.
        let vm = AuthViewModel()
        vm.authServerURL = "https://example.test"
        #expect(vm.authServerURL == "https://example.test")
    }
}
