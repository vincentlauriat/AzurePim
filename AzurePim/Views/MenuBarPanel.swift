import SwiftUI

/// Menu bar label (DesignBrief: `key.fill` when no role is active). Count and countdown arrive in T3.5.
struct MenuBarLabel: View {
    var body: some View {
        Image(systemName: "key.fill")
            .accessibilityLabel("AzurePim")
    }
}

/// Menu Bar Panel (AppFlow). Step 1 shell: sections and footer only; data arrives in T3.4.
struct MenuBarPanel: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                section("Active") { placeholder("No active role") }
                section("Eligible") { placeholder("Add an account to get started") }
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
            Text("Not signed in").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
