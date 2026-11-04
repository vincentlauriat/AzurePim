import AppKit

/// The app is a menu bar agent (`LSUIElement`); the Dock icon appears only while the main window is open (TRD).
@MainActor
enum DockPolicy {
    static func mainWindowDidOpen() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func mainWindowDidClose() {
        NSApp.setActivationPolicy(.accessory)
    }
}
