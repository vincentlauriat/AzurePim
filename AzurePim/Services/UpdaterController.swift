import Foundation
import Sparkle

/// Sparkle 2 wrapper. The updater is not started until the appcast exists (ImplementationPlan T6.4):
/// starting it without `SUFeedURL` would raise an error at launch.
@MainActor
@Observable
final class UpdaterController {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var sparkleVersion: String {
        Bundle(for: SPUUpdater.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
