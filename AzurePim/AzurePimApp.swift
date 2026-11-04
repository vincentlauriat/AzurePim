import SwiftUI
import AzurePimCore

@main
struct AzurePimApp: App {
    @State private var updater = UpdaterController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("AzurePim", id: WindowID.main) {
            MainWindow()
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 980, height: 640)
        .handlesExternalEvents(matching: ["open"])
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView(updater: updater)
        }
    }
}

enum WindowID {
    static let main = "main"
}
