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

/// Menu Bar Panel (AppFlow): Active, Eligible (grouped by account), header with refresh, footer.
struct MenuBarPanel: View {
    @Environment(RoleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \Account.sortOrder) private var accountList: [Account]
    @Query(sort: \ActiveAssignment.endAt) private var assignments: [ActiveAssignment]
    @Query(sort: \Favorite.sortOrder) private var favorites: [Favorite]
    @Query(filter: #Predicate<ActivationRecord> { $0.statusRaw == "pendingApproval" }) private var pendingRecords: [ActivationRecord]
    @State private var activating: EligibleRole?

    /// Accounts shown, after the header account filter (T4.4).
    private var shownAccounts: [Account] {
        guard let filter = store.accountFilter, accountList.contains(where: { $0.id == filter }) else { return accountList }
        return accountList.filter { $0.id == filter }
    }
    private var activations: [ActiveAssignment] {
        let shown = Set(shownAccounts.map(\.id))
        return assignments.filter { $0.assignmentType == .activated && $0.account.map { shown.contains($0.id) } == true }
    }

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
                        favoritesSection
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
                if accountList.count > 1 {
                    @Bindable var store = store
                    Picker("Account", selection: $store.accountFilter) {
                        Text("All accounts (\(accountList.count))").tag(UUID?.none)
                        ForEach(accountList) { Text($0.tenantName ?? $0.upn).tag(UUID?.some($0.id)) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                } else {
                    Text(accountSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
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

    @ViewBuilder private var favoritesSection: some View {
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
                            .controlSize(.small)
                            .disabled(favorite.items.isEmpty || store.runningFavorites.contains(favorite.id))
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
                            Image(systemName: "xmark").imageScale(.small)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    @ViewBuilder private var errorBanners: some View {
        ForEach(shownAccounts) { account in
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
            ForEach(shownAccounts) { account in
                if shownAccounts.count > 1 {
                    Text(account.tenantName ?? account.tenantId).font(.caption.weight(.semibold)).padding(.top, 4)
                }
                let roles = account.eligibleRoles.sorted {
                    ($0.sourceRaw, $0.roleName, $0.scopeName) < ($1.sourceRaw, $1.roleName, $1.scopeName)
                }
                if roles.isEmpty, account.lastRefreshAt != nil {
                    Text("No eligible PIM role for \(account.upn)").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(roles) { role in
                    EligibleRow(role: role, isActive: activations.contains { $0.eligibleRole?.id == role.id },
                                isPending: pendingRecords.contains { $0.eligibleRoleId == role.id }) {
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
