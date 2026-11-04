#if DEBUG
import AppKit
import AzurePimCore
import SwiftData
import SwiftUI

/// Debug only: `AZUREPIM_SNAPSHOT=<dir>` renders the panel and the main window sections to PNG files
/// once the first refresh is done, so the look can be checked without clicking the status item.
@MainActor
enum SnapshotRunner {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["AZUREPIM_SNAPSHOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(container: ModelContainer, accounts: AccountService, store: RoleStore) {
        guard let directory else { return }
        let env = Env(container: container, accounts: accounts, store: store)
        Task { @MainActor in
            while store.lastRefresh == nil { try? await Task.sleep(for: .milliseconds(300)) }
            try? await Task.sleep(for: .seconds(1))
            for scheme in [ColorScheme.dark, .light] {
                let suffix = scheme == .dark ? "dark" : "light"
                render(MenuBarPanel(), size: NSSize(width: Theme.panelWidth, height: 900), scheme: scheme,
                       to: directory.appending(path: "panel-\(suffix).png"), env: env)
                for item in SidebarItem.allCases {
                    render(MainWindow(initial: item), size: NSSize(width: 1100, height: 720), scheme: scheme,
                           to: directory.appending(path: "window-\(item.rawValue.lowercased())-\(suffix).png"),
                           env: env)
                }
            }
            renderDemo(to: directory)
            NSApp.terminate(nil)
        }
    }

    /// Panel with fake activations (in-memory store): hero countdown, progress and active rows.
    private static func renderDemo(to directory: URL) {
        guard let demo = try? AzurePimStore.makeContainer(inMemory: true) else { return }
        let context = demo.mainContext
        let account = Account(mode: .azureCLI, upn: "demo@contoso.com", objectId: "o", tenantId: "t", tenantName: "Contoso")
        context.insert(account)
        let reader = EligibleRole(id: "e1", account: account, source: .azureResource, roleDefinitionId: "r1", roleName: "Reader",
                                  scope: "/", scopeName: "Tenant Root Group", scopeType: "managementgroup")
        let contributor = EligibleRole(id: "e2", account: account, source: .azureResource, roleDefinitionId: "r2",
                                       roleName: "Contributor", scope: "/s", scopeName: "rg-app-prod-weu001", scopeType: "resourcegroup")
        context.insert(reader)
        context.insert(contributor)
        context.insert(ActiveAssignment(id: "a1", account: account, source: .azureResource, roleName: "Reader", scope: "/",
                                        scopeName: "Tenant Root Group", assignmentType: .activated,
                                        startAt: .now - 18 * 60, endAt: .now + 42 * 60, eligibleRole: reader))
        context.insert(ActiveAssignment(id: "a2", account: account, source: .azureResource, roleName: "Contributor", scope: "/s",
                                        scopeName: "rg-app-prod-weu001", assignmentType: .activated,
                                        startAt: .now - 7 * 3600, endAt: .now + 3 * 3600 + 16 * 60, eligibleRole: contributor))
        context.insert(ActiveAssignment(id: "a3", account: account, source: .azureResource, roleName: "Key Vault Secrets Officer",
                                        scope: "/k", scopeName: "kv-app-dev-weu001", assignmentType: .assigned,
                                        startAt: .now - 86_400, endAt: nil))
        try? context.save()
        let accounts = AccountService(context: context)
        let store = RoleStore(context: context, accounts: accounts, notifications: NotificationScheduler())
        for scheme in [ColorScheme.dark, .light] {
            render(MenuBarPanel(), size: NSSize(width: Theme.panelWidth, height: 900), scheme: scheme,
                   to: directory.appending(path: "panel-demo-\(scheme == .dark ? "dark" : "light").png"),
                   env: Env(container: demo, accounts: accounts, store: store))
        }
    }

    private struct Env {
        let container: ModelContainer
        let accounts: AccountService
        let store: RoleStore
    }

    private static func render(_ view: some View, size: NSSize, scheme: ColorScheme, to url: URL, env: Env) {
        let container = env.container, accounts = env.accounts, store = env.store
        let root = view
            .environment(accounts)
            .environment(store)
            .modelContainer(container)
            .environment(\.colorScheme, scheme)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now + 0.6)
        let fitting = hosting.fittingSize
        if fitting.height > 0, fitting.height < size.height, size.width == Theme.panelWidth {
            window.setContentSize(NSSize(width: size.width, height: fitting.height))
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: .now + 0.3)
        }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
#endif
