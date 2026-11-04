import AzurePimCore
import SwiftData
import SwiftUI

/// Menu bar label (DesignBrief › Components): `key.fill` when nothing is active; otherwise count + next expiry,
/// orange at ≤ 15 min, red at ≤ 5 min. Rendered at launch: also opens Onboarding on first run.
struct MenuBarLabel: View {
    @Environment(AccountService.self) private var accounts
    @Environment(RoleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \ActiveAssignment.endAt) private var assignments: [ActiveAssignment]

    private var activations: [ActiveAssignment] { assignments.filter { $0.assignmentType == .activated } }
    private var nextEnd: Date? { activations.compactMap(\.endAt).filter { $0 > .now }.min() }

    var body: some View {
        label(at: store.now)
            .task {
                if !accounts.settings.onboardingCompleted {
                    openWindow(id: WindowID.onboarding)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }

    @ViewBuilder private func label(at now: Date) -> some View {
        let style = accounts.settings.menuBarStyle
        if activations.isEmpty || style == .icon {
            Image(systemName: activations.isEmpty ? "key.fill" : "key.horizontal.fill")
                .accessibilityLabel(activations.isEmpty ? "AzurePim, no active role" : "AzurePim, \(activations.count) active")
        } else {
            let remaining = nextEnd.map { $0.timeIntervalSince(now) }
            HStack(spacing: 3) {
                Image(systemName: "key.horizontal.fill")
                Text(text(count: activations.count, remaining: style == .iconCountTime ? remaining : nil))
                    .monospacedDigit()
            }
            .foregroundStyle(Countdown.color(remaining))
            .accessibilityLabel("AzurePim, \(activations.count) active, next expiry in \(Countdown.spoken(remaining))")
        }
    }

    private func text(count: Int, remaining: TimeInterval?) -> String {
        guard let remaining else { return "\(count)" }
        return "\(count) · \(Countdown.short(remaining))"
    }
}

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

/// Menu Bar Panel (AppFlow): Active, Eligible (grouped by account), header with refresh, footer.
struct MenuBarPanel: View {
    @Environment(RoleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \Account.sortOrder) private var accountList: [Account]
    @Query(sort: \ActiveAssignment.endAt) private var assignments: [ActiveAssignment]
    @State private var activating: EligibleRole?

    private var activations: [ActiveAssignment] { assignments.filter { $0.assignmentType == .activated } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let role = activating {
                ActivationSheet(role: role) { activating = nil }
            } else {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        errorBanners
                        activeSection
                        eligibleSection
                    }
                    .padding(12)
                }
                .frame(maxHeight: 460)
                Divider()
                footer
            }
        }
        .frame(width: 360)
        .onAppear {
            store.panelOpenedAt = .now
            Task { await store.refreshIfStale() }
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("AzurePim").font(.headline)
                Text(accountSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let last = store.lastRefresh {
                Text(last, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                    .help("Last updated")
            }
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .disabled(store.isRefreshing)
            .help("Refresh (⌘R)")
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

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Open AzurePim…") {
                openWindow(id: WindowID.main)
                NSApp.activate(ignoringOtherApps: true)
            }
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

    // MARK: Sections

    @ViewBuilder private var errorBanners: some View {
        ForEach(accountList) { account in
            ForEach(Array((store.refreshErrors[account.id] ?? [:]).sorted { $0.key.rawValue < $1.key.rawValue }), id: \.key) { _, message in
                Label {
                    Text(accountList.count > 1 ? "\(account.upn): \(message)" : message).font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .textSelection(.enabled)
            }
        }
    }

    private var activeSection: some View {
        PanelSection(title: "Active") {
            if activations.isEmpty {
                Text("No active role").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(activations) { assignment in
                ActiveRow(assignment: assignment)
            }
        }
    }

    private var eligibleSection: some View {
        PanelSection(title: "Eligible") {
            if accountList.isEmpty {
                Text("Add an account to get started").font(.callout).foregroundStyle(.secondary)
                Button("Add an account…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
            ForEach(accountList) { account in
                if accountList.count > 1 {
                    Text(account.tenantName ?? account.tenantId).font(.caption.weight(.semibold)).padding(.top, 4)
                }
                let roles = account.eligibleRoles.sorted {
                    ($0.sourceRaw, $0.roleName, $0.scopeName) < ($1.sourceRaw, $1.roleName, $1.scopeName)
                }
                if roles.isEmpty, account.lastRefreshAt != nil {
                    Text("No eligible PIM role for \(account.upn)").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(roles) { role in
                    EligibleRow(role: role, isActive: activations.contains { $0.eligibleRole?.id == role.id }) {
                        activating = role
                    }
                }
                if account.directoryAccess == .consentRequired {
                    Button {
                        openWindow(id: WindowID.consent, value: account.id)
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label("Entra roles: admin consent required", systemImage: "info.circle")
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
        }
    }
}

private struct PanelSection<Content: View>: View {
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

private struct EligibleRow: View {
    @Environment(RoleStore.self) private var store
    let role: EligibleRole
    let isActive: Bool
    let activate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: SourceIcon.name(role.source)).frame(width: 18).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(role.roleName).lineLimit(1)
                    Text(role.scopeName + (role.memberType == .group ? " · via group" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if store.busy.contains(role.id) {
                    ProgressView().controlSize(.small)
                } else if isActive {
                    Text("Active").font(.caption).foregroundStyle(.green)
                } else {
                    Button("Activate", action: activate).controlSize(.small)
                }
            }
            .frame(minHeight: 32)
            if let error = store.rowErrors[role.id] {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ActiveRow: View {
    @Environment(RoleStore.self) private var store
    let assignment: ActiveAssignment
    @State private var confirming = false

    /// Azure refuses deactivation within 5 minutes of activation (BackendSchema › business rules).
    private var tooRecent: Bool { Date.now.timeIntervalSince(assignment.startAt) < 300 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: SourceIcon.name(assignment.source)).frame(width: 18).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(assignment.roleName).lineLimit(1)
                    Text(assignment.scopeName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let end = assignment.endAt {
                    let remaining = end.timeIntervalSince(store.now)
                    Text(Countdown.long(remaining))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(remaining <= 900 ? Countdown.color(remaining) : .secondary)
                }
                if store.busy.contains(assignment.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        confirming = true
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(tooRecent)
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
            .frame(minHeight: 32)
            if let error = store.rowErrors[assignment.id] {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }
}
