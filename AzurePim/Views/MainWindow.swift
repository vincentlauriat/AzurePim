import SwiftUI

/// Sidebar sections of the main window (AppFlow navigation rules: ⌘1–⌘3).
enum SidebarItem: String, CaseIterable, Identifiable {
    case roles = "Roles"
    case history = "History"
    case favorites = "Favorites"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .roles: "key.horizontal"
        case .history: "clock.arrow.circlepath"
        case .favorites: "star"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .roles: "1"
        case .history: "2"
        case .favorites: "3"
        }
    }
}

/// Main window: Roles Window, History Window, Favorites Window (AppFlow).
struct MainWindow: View {
    @State private var selection: SidebarItem? = .roles

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            switch selection ?? .roles {
            case .roles: RolesView()
            case .history: HistoryView()
            case .favorites: FavoritesView()
            }
        }
        .background(shortcuts)
        .onAppear { DockPolicy.mainWindowDidOpen() }
        .onDisappear { DockPolicy.mainWindowDidClose() }
    }

    /// Hidden buttons carrying the ⌘1–⌘3 shortcuts.
    private var shortcuts: some View {
        ForEach(SidebarItem.allCases) { item in
            Button("") { selection = item }
                .keyboardShortcut(item.shortcut)
                .hidden()
        }
    }
}
