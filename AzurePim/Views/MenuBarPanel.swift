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

/// Menu Bar Panel (AppFlow), in the Juicy / Claude Cockpit look: a hero card with the active count and the next
/// expiry, collapsible cards (Active roles, Favorites, Eligible roles) and a settings-style action list.
struct MenuBarPanel: View {
    @Environment(RoleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \Account.sortOrder) private var accountList: [Account]
    @Query(sort: \ActiveAssignment.endAt) private var assignments: [ActiveAssignment]
    @Query(sort: \Favorite.sortOrder) private var favorites: [Favorite]
    @Query(filter: #Predicate<ActivationRecord> { $0.statusRaw == "pendingApproval" }) private var pendingRecords: [ActivationRecord]
    @State private var activating: EligibleRole?
    @State private var contentHeight: CGFloat = 0
    @AppStorage("panel.showActive") private var showActive = true
    @AppStorage("panel.showPermanent") private var showPermanent = true
    @AppStorage("panel.showFavorites") private var showFavorites = true
    @AppStorage("panel.showEligible") private var showEligible = true

    /// Accounts shown, after the account filter (T4.4).
    private var shownAccounts: [Account] {
        guard let filter = store.accountFilter, accountList.contains(where: { $0.id == filter }) else { return accountList }
        return accountList.filter { $0.id == filter }
    }
    private var activations: [ActiveAssignment] { shownAssignments(.activated) }
    /// Permanent assignments (not PIM): read-only, listed so the panel shows every role the user holds.
    private var permanents: [ActiveAssignment] {
        shownAssignments(.assigned).sorted { ($0.roleName, $0.scopeName) < ($1.roleName, $1.scopeName) }
    }
    private var eligibleCount: Int { shownAccounts.reduce(0) { $0 + $1.eligibleRoles.count } }

    private func shownAssignments(_ type: AssignmentType) -> [ActiveAssignment] {
        let shown = Set(shownAccounts.map(\.id))
        return assignments.filter { $0.assignmentType == type && $0.account.map { shown.contains($0.id) } == true }
    }

    /// The panel must fit under the menu bar; past ~640 pt the main window is the better place.
    private var maxHeight: CGFloat {
        max(320, min(640, (NSScreen.main?.visibleFrame.height ?? 800) - 24))
    }

    var body: some View {
        Group {
            if let role = activating {
                ActivationSheet(role: role) { activating = nil }
                    .frame(width: Theme.panelWidth)
            } else {
                ScrollView(.vertical) {
                    content
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
                        })
                }
                .scrollBounceBehavior(.basedOnSize)
                .onPreferenceChange(PanelHeightKey.self) { contentHeight = $0 }
                .frame(width: Theme.panelWidth, height: min(contentHeight > 0 ? contentHeight : 520, maxHeight))
            }
        }
        .background(WindowKeyObserver {
            store.panelOpenedAt = .now
            Task { await store.refreshIfStale() }
        })
    }

    private var content: some View {
        VStack(spacing: 8) {
            heroCard
            errorBanners
            activeCard
            if !favorites.isEmpty { favoritesCard }
            eligibleCard
            PanelActionList()
        }
        .padding(10)
    }

    // MARK: Hero

    /// The activation that expires first, with its fraction of time left.
    private var nextActivation: NextActivation? {
        guard let next = activations.filter({ ($0.endAt ?? .distantPast) > store.now }).min(by: {
            ($0.endAt ?? .distantFuture) < ($1.endAt ?? .distantFuture)
        }), let end = next.endAt else { return nil }
        let remaining = end.timeIntervalSince(store.now)
        let total = max(1, end.timeIntervalSince(next.startAt))
        return NextActivation(assignment: next, remaining: remaining, fraction: remaining / total)
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(activations.count)")
                            .font(.display(52))
                            .monospacedDigit()
                            .foregroundStyle(activations.isEmpty ? Color.secondary : Theme.active)
                        Text("active")
                            .font(.display(18, weight: .semibold))
                            .foregroundStyle(activations.isEmpty ? Color.secondary : Theme.active)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: activations.isEmpty ? "key.fill" : "key.horizontal.fill")
                            .foregroundStyle(activations.isEmpty ? Color.secondary : Theme.active)
                        Text(heroSubtitle).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    if let next = nextActivation {
                        SectionLabel(text: "Expires in")
                        Text(Countdown.hero(next.remaining))
                            .font(.display(20, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(next.remaining <= 900 ? Theme.remaining(next.remaining) : Color.primary)
                    } else {
                        SectionLabel(text: "Permanent")
                        Text("\(permanents.count)").font(.display(20, weight: .semibold)).monospacedDigit()
                    }
                    statusLine
                }
            }
            if let next = nextActivation {
                ProgressTrack(fraction: next.fraction, tint: Theme.remaining(next.remaining))
            }
            if accountList.count > 1 { accountPicker }
        }
        .padding(16)
        .card()
        .accessibilityElement(children: .combine)
    }

    private var heroSubtitle: String {
        if accountList.isEmpty { return "Not signed in" }
        if let next = nextActivation { return "\(next.assignment.roleName) · \(next.assignment.scopeName)" }
        return activations.isEmpty ? "No PIM activation" : "PIM roles active"
    }

    @ViewBuilder private var statusLine: some View {
        if store.isRefreshing {
            ProgressView().controlSize(.small)
        } else if store.isOffline {
            Label(offlineText, systemImage: "wifi.slash").font(.system(size: 11)).foregroundStyle(Theme.warning)
                .help("Actions are disabled until the network is back")
        } else if let last = store.lastRefresh {
            Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var accountPicker: some View {
        @Bindable var store = store
        return Picker("Account", selection: $store.accountFilter) {
            Text("All accounts (\(accountList.count))").tag(UUID?.none)
            ForEach(accountList) { Text($0.tenantName ?? $0.upn).tag(UUID?.some($0.id)) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
    }

    private var offlineText: String {
        guard let last = store.lastOnline else { return "Offline" }
        return "Offline — data from \(last.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: Banners

    private func bannerKinds(_ account: Account) -> [ErrorKind] {
        let kinds: Set<ErrorKind> = Set((store.refreshErrors[account.id] ?? [:]).values)
        return kinds.filter { $0 != .offline }.sorted { $0.message < $1.message }
    }

    /// One banner per distinct problem (Offline is shown in the hero card instead).
    @ViewBuilder private var errorBanners: some View {
        ForEach(shownAccounts) { account in
            ForEach(bannerKinds(account), id: \.message) { kind in
                ErrorBanner(kind: kind, account: accountList.count > 1 ? account.upn : nil)
            }
        }
    }

    // MARK: Cards

    private var activeCard: some View {
        DisclosureCard(title: "Active roles", icon: "bolt.fill", iconColor: Theme.active,
                       count: activations.count + permanents.count, expanded: $showActive) {
            if activations.isEmpty && permanents.isEmpty {
                EmptyLine(text: accountList.isEmpty ? "Add an account to see your roles" : "No active role")
            }
            ForEach(Array(activations.enumerated()), id: \.element.id) { index, assignment in
                if index > 0 { RowDivider() }
                ActiveRow(assignment: assignment)
            }
            if !permanents.isEmpty {
                if !activations.isEmpty { RowDivider(inset: 0) }
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showPermanent.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        SectionLabel(text: "Permanent · \(permanents.count)")
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showPermanent ? 0 : -90))
                    }
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showPermanent ? "Hide permanent roles" : "Show permanent roles")
                if showPermanent {
                    ForEach(Array(permanents.enumerated()), id: \.element.id) { index, assignment in
                        if index > 0 { RowDivider() }
                        PermanentRow(assignment: assignment, showAccount: shownAccounts.count > 1)
                    }
                }
            }
        }
    }

    private var favoritesCard: some View {
        DisclosureCard(title: "Favorites", icon: "star.fill", iconColor: Theme.violet,
                       count: favorites.count, expanded: $showFavorites) {
            FavoriteChips(favorites: favorites)
        }
    }

    private var eligibleCard: some View {
        DisclosureCard(title: "Eligible roles", icon: "key.horizontal.fill", iconColor: Theme.accent,
                       count: eligibleCount, expanded: $showEligible) {
            if accountList.isEmpty {
                Button("Add an account…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .padding(.vertical, 6)
            }
            ForEach(shownAccounts) { account in
                if shownAccounts.count > 1 {
                    HStack {
                        SectionLabel(text: account.tenantName ?? account.tenantId)
                        Spacer()
                    }
                    .padding(.top, 6)
                }
                let roles = account.eligibleRoles.sorted {
                    ($0.sourceRaw, $0.roleName, $0.scopeName) < ($1.sourceRaw, $1.roleName, $1.scopeName)
                }
                if roles.isEmpty, account.lastRefreshAt != nil {
                    EmptyLine(text: "No eligible PIM role for \(account.upn)")
                }
                ForEach(Array(roles.enumerated()), id: \.element.id) { index, role in
                    if index > 0 { RowDivider() }
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
                    .padding(.vertical, 6)
                }
            }
        }
    }

}

private struct NextActivation {
    let assignment: ActiveAssignment
    let remaining: TimeInterval
    let fraction: Double
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
