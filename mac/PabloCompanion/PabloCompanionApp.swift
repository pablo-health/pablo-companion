import CoreText
import ScreenCaptureKit
import Sparkle
import SwiftUI

@main
struct PabloCompanionApp: App {
    @State private var authVM = AuthViewModel()
    @State private var deepLinks = DeepLinkRouter()

    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        registerFonts()
    }

    var body: some Scene {
        Window("Pablo", id: "main") {
            ContentView(authVM: authVM, deepLinks: deepLinks)
                .task {
                    await requestScreenCapturePermission()
                }
                .onOpenURL { url in
                    // Legacy custom scheme (pablohealth://…) and OAuth callback.
                    DeepLinkRouter.logger.info("Received deep link: \(url.absoluteString, privacy: .public)")
                    deepLinks.pendingURL = url
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    // Domain-verified Universal Link (https://<host>/launch/<id>).
                    guard let url = activity.webpageURL else { return }
                    DeepLinkRouter.logger.info("Received universal link: \(url.absoluteString, privacy: .public)")
                    deepLinks.pendingURL = url
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
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
