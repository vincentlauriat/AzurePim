import AppKit
import SwiftUI

/// Settings-style action list at the bottom of the panel (Juicy look).
struct PanelActionList: View {
    @Environment(RoleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        actionList
    }

    private var actionList: some View {
        VStack(spacing: 0) {
            Button {
                openWindow(id: WindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                ActionRow(icon: "macwindow", iconColor: Theme.accent, title: "Open AzurePim…",
                          subtitle: "Roles, history and favorites") { Chevron() }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("0")
            RowDivider(inset: 48)
            Button {
                Task { await store.refresh() }
            } label: {
                ActionRow(icon: "arrow.clockwise", iconColor: Theme.accent,
                          title: store.isRefreshing ? "Refreshing…" : "Refresh", subtitle: refreshSubtitle) {
                    if store.isRefreshing { ProgressView().controlSize(.small) } else { KeyHint(text: "⌘R") }
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r")
            .disabled(store.isRefreshing)
            RowDivider(inset: 48)
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                ActionRow(icon: "gearshape.fill", iconColor: .secondary, title: "Settings…") { Chevron() }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",")
            RowDivider(inset: 48)
            Button {
                NSApp.terminate(nil)
            } label: {
                ActionRow(icon: "power", iconColor: Theme.danger, title: "Quit AzurePim") {
                    Text("v\(Self.version)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
        .card()
    }

    private var refreshSubtitle: String {
        guard let last = store.lastRefresh else { return "Never updated" }
        return "Updated \(last.formatted(date: .omitted, time: .shortened))"
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
}

private struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
    }
}

private struct KeyHint: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, design: .rounded)).foregroundStyle(.tertiary)
    }
}

struct EmptyLine: View {
    let text: String
    var body: some View {
        HStack {
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}
