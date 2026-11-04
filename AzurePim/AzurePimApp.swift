import AzurePimCore
import SwiftData
import SwiftUI

@main
struct AzurePimApp: App {
    @State private var updater = UpdaterController()
    private let container: ModelContainer
    @State private var accounts: AccountService

    init() {
        do {
            container = try AzurePimStore.makeContainer()
        } catch {
            // The local store is required; failing silently to memory would lose favorites and history.
            fatalError("AzurePim could not open its local store at \(AzurePimStore.defaultURL.path): \(error)")
        }
        _accounts = State(initialValue: AccountService(context: container.mainContext))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environment(accounts)
                .modelContainer(container)
        } label: {
            MenuBarLabel()
                .environment(accounts)
        }
        .menuBarExtraStyle(.window)

        Window("AzurePim", id: WindowID.main) {
            MainWindow()
                .frame(minWidth: 760, minHeight: 480)
                .environment(accounts)
                .modelContainer(container)
        }
        .defaultSize(width: 980, height: 640)
        .handlesExternalEvents(matching: ["open"])
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window("Welcome to AzurePim", id: WindowID.onboarding) {
            OnboardingView()
                .environment(accounts)
                .modelContainer(container)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["onboarding"])

        Settings {
            SettingsView(updater: updater)
                .environment(accounts)
                .modelContainer(container)
        }
    }
}

enum WindowID {
    static let main = "main"
    static let onboarding = "onboarding"
}
