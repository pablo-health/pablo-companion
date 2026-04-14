import Sparkle
import SwiftUI

/// Reactive wrapper around Sparkle's `SPUUpdater` for SwiftUI bindings.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    private var cancellable: Any?

    init(updater: SPUUpdater) {
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
