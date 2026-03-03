import CoreText
import ScreenCaptureKit
import SwiftUI

@main
struct PabloCompanionApp: App {
    init() {
        registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await requestScreenCapturePermission()
                }
        }
        .windowResizability(.contentMinSize)
    }

    /// Registers bundled variable fonts (DM Sans, Fraunces) so SwiftUI
    /// Font.custom() can resolve them by family name.
    private func registerFonts() {
        let fontNames = ["DMSans.ttf", "Fraunces.ttf"]
        for name in fontNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: nil) else {
                assertionFailure("Font not found in bundle: \(name)")
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Triggers the ScreenCaptureKit permission prompt, which reliably
    /// registers the app in System Settings > Privacy & Security >
    /// Screen & System Audio Recording.
    private func requestScreenCapturePermission() async {
        do {
            // This call triggers the system permission prompt on first launch.
            // It will throw if permission is denied, which is fine — we handle
            // that gracefully in the capture layer.
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            // Expected on first launch before permission is granted
        }
    }
}
