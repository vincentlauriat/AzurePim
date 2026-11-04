import AzurePimCore
import SwiftData
import SwiftUI

/// Roles Window (AppFlow, T4.6): every eligible and active role of every account, searchable, with a detail pane.
struct RolesView: View {
    @Environment(RoleStore.self) private var store
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query(sort: \EligibleRole.roleName) private var roles: [EligibleRole]
    @Query(sort: \ActiveAssignment.roleName) private var assignments: [ActiveAssignment]
    @State private var search = ""
    @State private var source: RoleSource?
    @State private var accountId: UUID?
    @State private var state: StateFilter = .all
    @State private var selection: RoleRow.ID?

    enum StateFilter: String, CaseIterable, Identifiable {
        case all = "All", eligible = "Eligible", active = "Active", permanent = "Permanent"
        var id: String { rawValue }
    }

    private var rows: [RoleRow] {
        var list = roles.map { role in
            RoleRow(role: role, assignment: assignments.first { $0.eligibleRole?.id == role.id && $0.assignmentType == .activated })
        }
        list += assignments.filter { $0.assignmentType == .assigned }.map { RoleRow(permanent: $0) }
        return list.filter { row in
            (source == nil || row.source == source)
                && (accountId == nil || row.account?.id == accountId)
                && state.matches(row)
                && (search.isEmpty || row.searchText.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        HSplitView {
            Table(rows, selection: $selection) {
                TableColumn("Role") { row in
                    Label(row.roleName, systemImage: SourceIcon.name(row.source))
                }
                TableColumn("Scope") { row in Text(row.scopeName).truncationMode(.middle) }
                TableColumn("State") { row in StateBadge(row: row, now: store.now) }
                    .width(min: 90, ideal: 110)
                // Always present: conditional table columns need macOS 14.4.
                TableColumn("Account") { row in Text(row.account?.tenantName ?? row.account?.upn ?? "") }
            }
            .contextMenu(forSelectionType: RoleRow.ID.self) { ids in
                if let id = ids.first, let role = rows.first(where: { $0.id == id })?.role {
                    AddToFavoriteMenu(role: role)
                }
            }
            .frame(minWidth: 420)

            Group {
                if let row = rows.first(where: { $0.id == selection }) {
                    RoleDetail(row: row)
                } else {
                    ContentUnavailableView(roles.isEmpty ? "No eligible role" : "Select a role", systemImage: "key.horizontal",
                                           description: Text(accounts.isEmpty ? "Add an account to get started." : ""))
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380, maxHeight: .infinity)
        }
        .searchable(text: $search, prompt: "Search roles and scopes")
        .toolbar {
            Picker("Source", selection: $source) {
                Text("All sources").tag(RoleSource?.none)
                Text("Azure resources").tag(RoleSource?.some(.azureResource))
                Text("Entra roles").tag(RoleSource?.some(.entraRole))
                Text("PIM groups").tag(RoleSource?.some(.pimGroup))
            }
            Picker("State", selection: $state) {
                ForEach(StateFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            if accounts.count > 1 {
                Picker("Account", selection: $accountId) {
                    Text("All accounts").tag(UUID?.none)
                    ForEach(accounts) { Text($0.tenantName ?? $0.upn).tag(UUID?.some($0.id)) }
                }
            }
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
        }
        .navigationTitle("Roles")
    }
}

/// One line of the Roles table: an eligible role (maybe active) or a permanent assignment.
struct RoleRow: Identifiable {
    let id: String
    let role: EligibleRole?
    let assignment: ActiveAssignment?

    init(role: EligibleRole, assignment: ActiveAssignment?) {
        id = role.id
        self.role = role
        self.assignment = assignment
    }

    init(permanent: ActiveAssignment) {
        id = permanent.id
        role = nil
        assignment = permanent
    }

    var source: RoleSource { role?.source ?? assignment?.source ?? .azureResource }
    var roleName: String { role?.roleName ?? assignment?.roleName ?? "" }
    var scopeName: String { role?.scopeName ?? assignment?.scopeName ?? "" }
    var scope: String { role?.scope ?? assignment?.scope ?? "" }
    var account: Account? { role?.account ?? assignment?.account }
    var isPermanent: Bool { role == nil }
    var searchText: String { "\(roleName) \(scopeName) \(account?.upn ?? "")" }
}

extension RolesView.StateFilter {
    func matches(_ row: RoleRow) -> Bool {
        switch self {
        case .all: true
        case .eligible: !row.isPermanent && row.assignment == nil
        case .active: !row.isPermanent && row.assignment != nil
        case .permanent: row.isPermanent
        }
    }
}

private struct StateBadge: View {
    let row: RoleRow
    let now: Date

    var body: some View {
        if row.isPermanent {
            Text("Permanent").foregroundStyle(.secondary)
        } else if let end = row.assignment?.endAt {
            Text(Countdown.long(end.timeIntervalSince(now))).foregroundStyle(.green).monospacedDigit()
        } else {
            Text("Eligible").foregroundStyle(.secondary)
        }
    }
}

private struct RoleDetail: View {
    @Environment(RoleStore.self) private var store
    let row: RoleRow
    @State private var activating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.roleName).font(.title3.weight(.semibold))
                    Text(row.scopeName).foregroundStyle(.secondary)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    detail("Source", sourceName(row.source))
                    detail("Account", row.account?.upn ?? "—")
                    if let role = row.role {
                        detail("Assignment", role.memberType == .group ? "Via group" : role.memberType.rawValue.capitalized)
                    }
                    detail("Scope path", row.scope)
                    if let end = row.assignment?.endAt {
                        detail("Ends", end.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.callout)
                if let role = row.role {
                    policy(role)
                    actions(role)
                } else {
                    Text("Permanent assignment: managed by your administrator, not through PIM.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = store.rowErrors[row.id] ?? row.assignment.flatMap({ store.rowErrors[$0.id] }) {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: row.id) {
            if let role = row.role { await store.ensurePolicy(for: role) }
        }
        .sheet(isPresented: $activating) {
            if let role = row.role {
                ActivationSheet(role: role) { activating = false }.frame(width: 360)
            }
        }
    }

    @ViewBuilder private func policy(_ role: EligibleRole) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("POLICY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if role.policyFetchedAt == nil {
                Text("Policy unavailable").font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    detail("Maximum", role.maxDuration.flatMap(ISODuration.seconds).map { "\(Int($0 / 3600)) h" } ?? "—")
                    detail("Justification", role.requiresJustification ? "Required" : "Optional")
                    detail("Ticket", role.requiresTicket ? "Required" : "No")
                    detail("MFA", role.requiresMFA ? "Required" : "No")
                    detail("Approval", role.requiresApproval ? "Required" : "No")
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder private func actions(_ role: EligibleRole) -> some View {
        HStack {
            if store.busy.contains(role.id) || row.assignment.map({ store.busy.contains($0.id) }) == true {
                ProgressView().controlSize(.small)
            } else if let assignment = row.assignment {
                Button("Deactivate", role: .destructive) { Task { await store.deactivate(assignment) } }
                    .disabled(Date.now.timeIntervalSince(assignment.startAt) < 300)
                    .help("Azure refuses deactivation within 5 minutes of activation")
            } else {
                Button("Activate…") { activating = true }.buttonStyle(.borderedProminent)
            }
            Menu("Add to favorite") { AddToFavoriteMenu(role: role) }.fixedSize()
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
        }
    }

    private func sourceName(_ source: RoleSource) -> String {
        switch source {
        case .azureResource: "Azure resource"
        case .entraRole: "Entra role"
        case .pimGroup: "PIM group"
        }
    }
}

/// Menu items adding a role to an existing favorite or to a new one.
struct AddToFavoriteMenu: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Favorite.sortOrder) private var favorites: [Favorite]
    let role: EligibleRole

    var body: some View {
        ForEach(favorites) { favorite in
            Button(favorite.name) {
                guard !favorite.items.contains(where: { $0.eligibleRoleId == role.id }) else { return }
                favorite.items.append(FavoriteItem(eligibleRoleId: role.id, duration: role.maxDuration ?? "PT8H"))
                try? context.save()
            }
            .disabled(favorite.items.contains { $0.eligibleRoleId == role.id })
        }
        if !favorites.isEmpty { Divider() }
        Button("New favorite with this role") {
            let names = favorites.map(\.name)
            let base = String(role.roleName.prefix(34))   // room for " 99" under the 40-char limit
            var name = base
            var index = 2
            while case .failure = Validation.favoriteName(name, existing: names), index < 1000 {
                name = "\(base) \(index)"
                index += 1
            }
            context.insert(Favorite(name: name, items: [FavoriteItem(eligibleRoleId: role.id, duration: role.maxDuration ?? "PT8H")],
                                    sortOrder: (favorites.map(\.sortOrder).max() ?? -1) + 1))
            try? context.save()
        }
    }
}
