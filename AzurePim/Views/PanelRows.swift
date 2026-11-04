import AppKit
import AzurePimCore
import SwiftUI

enum Countdown {
    static func short(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 300 { return String(format: "%d:%02d", total / 60, total % 60) }
        return String(format: "%d:%02d", total / 3600, (total % 3600) / 60)
    }

    static func long(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60
        if total < 300 { return String(format: "%d:%02d left", total / 60, total % 60) }
        return hours > 0 ? "\(hours) h \(String(format: "%02d", minutes)) left" : "\(minutes) min left"
    }

    /// Hero card value: « 5h 16m », « 42m », « 3:12 » in the last 5 minutes.
    static func hero(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 300 { return String(format: "%d:%02d", total / 60, total % 60) }
        let hours = total / 3600, minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(String(format: "%02d", minutes))m" : "\(minutes)m"
    }

    static func spoken(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "unknown" }
        let minutes = max(0, Int(seconds) / 60)
        return minutes >= 60 ? "\(minutes / 60) hours \(minutes % 60) minutes" : "\(minutes) minutes"
    }

    static func color(_ seconds: TimeInterval?) -> Color {
        guard let seconds else { return .primary }
        if seconds <= 300 { return .red }
        if seconds <= 900 { return .orange }
        return .primary
    }
}

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

enum SourceIcon {
    static func name(_ source: RoleSource) -> String {
        switch source {
        case .azureResource: "cloud"
        case .entraRole: "person.badge.key"
        case .pimGroup: "person.3"
        }
    }
}

struct EligibleRow: View {
    @Environment(RoleStore.self) private var store
    let role: EligibleRole
    let isActive: Bool
    let isPending: Bool
    let activate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: SourceIcon.name(role.source)).frame(width: 22).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(role.roleName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(role.scopeName + (role.memberType == .group ? " · via group" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if store.busy.contains(role.id) {
                    ProgressView().controlSize(.small)
                } else if isActive {
                    Text("Active").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.active)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.active.opacity(0.14), in: Capsule())
                } else if isPending {
                    Label("Pending", systemImage: "clock").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warning)
                        .help("Waiting for approval — see History")
                } else {
                    Button("Activate", action: activate)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .controlSize(.small)
                        .disabled(store.isOffline)
                }
            }
            .frame(minHeight: 40)
            if let error = store.rowErrors[role.id] {
                Text(error).font(.caption).foregroundStyle(Theme.danger).textSelection(.enabled).padding(.leading, 30).padding(.bottom, 4)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ActiveRow: View {
    @Environment(RoleStore.self) private var store
    let assignment: ActiveAssignment
    @State private var confirming = false

    /// Azure refuses deactivation within 5 minutes of activation (BackendSchema › business rules).
    private var tooRecent: Bool { Date.now.timeIntervalSince(assignment.startAt) < 300 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: SourceIcon.name(assignment.source)).frame(width: 22).foregroundStyle(Theme.active)
                VStack(alignment: .leading, spacing: 1) {
                    Text(assignment.roleName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(assignment.scopeName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let end = assignment.endAt {
                    let remaining = end.timeIntervalSince(store.now)
                    Text(Countdown.hero(remaining))
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.remaining(remaining))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.remaining(remaining).opacity(0.14), in: Capsule())
                        .help(Countdown.long(remaining))
                }
                if store.busy.contains(assignment.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        confirming = true
                    } label: {
                        Label("Deactivate \(assignment.roleName)", systemImage: "stop.circle.fill").labelStyle(.iconOnly)
                            .font(.system(size: 16))
                            .foregroundStyle(tooRecent ? Color.secondary : Theme.danger)
                    }
                    .buttonStyle(.borderless)
                    .disabled(tooRecent || store.isOffline)
                    .help(tooRecent ? "Can't deactivate within 5 minutes of activation" : "Deactivate")
                    .popover(isPresented: $confirming) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Deactivate \(assignment.roleName)?").font(.headline)
                            Text(assignment.scopeName).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Spacer()
                                Button("Cancel") { confirming = false }
                                Button("Deactivate", role: .destructive) {
                                    confirming = false
                                    Task { await store.deactivate(assignment) }
                                }
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(14)
                        .frame(width: 260)
                    }
                }
            }
            .frame(minHeight: 40)
            if let error = store.rowErrors[assignment.id] {
                Text(error).font(.caption).foregroundStyle(Theme.danger).textSelection(.enabled).padding(.leading, 30).padding(.bottom, 4)
            }
        }
    }
}

/// A permanent (non-PIM) role assignment: read-only, no countdown, no action.
struct PermanentRow: View {
    let assignment: ActiveAssignment
    let showAccount: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: SourceIcon.name(assignment.source)).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(assignment.roleName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(showAccount ? "\(assignment.scopeName) · \(assignment.account?.upn ?? "")" : assignment.scopeName)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Image(systemName: "lock").imageScale(.small).foregroundStyle(.tertiary)
                .help("Permanent assignment, managed by your administrator")
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(assignment.roleName), \(assignment.scopeName), permanent")
    }
}

/// Panel banner for a refresh problem (AppFlow › Empty and blocked states).
struct ErrorBanner: View {
    let kind: ErrorKind
    let account: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(account.map { "\($0): \(kind.message)" } ?? kind.message).font(.system(size: 12))
            } icon: {
                Image(systemName: icon).foregroundStyle(Theme.warning)
            }
            .textSelection(.enabled)
            if case .cliExpired(let command) = kind {
                Button(copied ? "Copied" : "Copy “\(command)”") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var icon: String {
        switch kind {
        case .throttled: "hourglass"
        case .cliExpired, .cliNotFound, .interactionRequired: "person.crop.circle.badge.exclamationmark"
        case .forbidden: "hand.raised.fill"
        default: "exclamationmark.triangle.fill"
        }
    }
}

/// Favorite chips and the last run result (T4.2).
struct FavoriteChips: View {
    @Environment(RoleStore.self) private var store
    let favorites: [Favorite]

    var body: some View {
        if !favorites.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(favorites) { favorite in
                            Button {
                                Task { await store.run(favorite) }
                            } label: {
                                HStack(spacing: 4) {
                                    if store.runningFavorites.contains(favorite.id) {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "star.fill").imageScale(.small)
                                    }
                                    Text(favorite.name).lineLimit(1)
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.violet)
                            .controlSize(.regular)
                            .disabled(favorite.items.isEmpty || store.runningFavorites.contains(favorite.id) || store.isOffline)
                            .help("Activate \(favorite.items.count) role(s)")
                        }
                    }
                }
                if let toast = store.favoriteToast {
                    let name = favorites.first { $0.id == toast.favoriteId }?.name ?? "Favorite"
                    HStack(alignment: .top) {
                        Text("\(name): \(toast.text)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                        Button {
                            store.favoriteToast = nil
                        } label: {
                            Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly).imageScale(.small)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}
