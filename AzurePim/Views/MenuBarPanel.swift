import AzurePimCore
import SwiftData
import SwiftUI

/// Menu bar label (DesignBrief: `key.fill` when no role is active). Count and countdown arrive in T3.5.
/// The label is rendered at launch, so its task also opens Onboarding on first run.
struct MenuBarLabel: View {
    @Environment(AccountService.self) private var accounts
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "key.fill")
            .accessibilityLabel("AzurePim")
            .task {
                if !accounts.settings.onboardingCompleted {
                    openWindow(id: WindowID.onboarding)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

/// Menu Bar Panel (AppFlow). Data arrives in T3.4; Step 2 shows the signed-in accounts.
struct MenuBarPanel: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \Account.sortOrder) private var accountList: [Account]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                section("Active") { placeholder("No active role") }
                section("Eligible") {
                    placeholder(accountList.isEmpty ? "Add an account to get started" : "Role list arrives in step 3")
                }
            }
            .padding(12)
            Divider()
            footer
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Text("AzurePim").font(.headline)
            Spacer()
            Text(accountSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var accountSummary: String {
        switch accountList.count {
        case 0: "Not signed in"
        case 1: accountList[0].upn
        default: "\(accountList.count) accounts"
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Open AzurePim…") { showMainWindow() }
                .keyboardShortcut("0")
            Spacer()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .keyboardShortcut(",")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit AzurePim")
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func showMainWindow() {
        openWindow(id: WindowID.main)
        NSApp.activate(ignoringOtherApps: true)
    }
}
