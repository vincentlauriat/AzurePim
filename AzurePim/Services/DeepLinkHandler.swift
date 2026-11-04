import AppKit
import AzurePimCore

/// Handles `azurepim://activate?favorite=<name>` (AppFlow › Deep links). SwiftUI routes `open` and `activate` URLs to
/// the main window (`handlesExternalEvents`), whose `onOpenURL` calls `handle`. An `NSApplicationDelegate`
/// `application(_:open:)` is not called under the SwiftUI lifecycle (verified 2026-11-04).
@MainActor
enum DeepLinkHandler {
    /// Set by `AzurePimApp.init`, before any URL can arrive.
    static var store: RoleStore?

    static func handle(_ url: URL) {
        guard url.scheme == "azurepim" else { return }
        switch url.host() {
        case "activate":
            let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "favorite" }?.value ?? ""
            Task { await runFavorite(named: name) }
        case "open":
            NSApp.activate(ignoringOtherApps: true)
        default:
            break
        }
    }

    /// Any local process can open a URL: activating privileged roles always asks the user first.
    private static func runFavorite(named name: String) async {
        guard let store = Self.store else { return }
        guard let favorite = store.favorite(named: name) else {
            NSApp.activate(ignoringOtherApps: true)
            alert("No favorite named “\(name)”.", info: "Create it in AzurePim › Favorites.")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let confirm = NSAlert()
        confirm.messageText = "Activate “\(favorite.name)”?"
        confirm.informativeText = "A link asked AzurePim to activate \(favorite.items.count) role(s)."
        confirm.addButton(withTitle: "Activate")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let text = await store.run(favorite, fromPanel: false)
        alert(favorite.name, info: text)
    }

    private static func alert(_ message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }
}
