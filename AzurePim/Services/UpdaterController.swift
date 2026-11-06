import Foundation
import Sparkle

/// Sparkle 2 wrapper. Debug builds are unsigned and share the release feed, so only
/// release builds start the updater and offer update checks.
@MainActor
@Observable
final class UpdaterController {
    #if DEBUG
    let isEnabled = false
    #else
    let isEnabled = true
    #endif

    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: isEnabled,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var sparkleVersion: String {
        Bundle(for: SPUUpdater.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
