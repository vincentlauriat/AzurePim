import AzurePimCore
import Foundation
import SwiftData

/// Keeps the SwiftData cache in sync with Azure / Graph and runs activation requests (ImplementationPlan T3.3, T3.6, T3.7).
@MainActor
@Observable
final class RoleStore {
    private let context: ModelContext
    private let accounts: AccountService
    private let notifications: NotificationScheduler
    private var autoRefresh: Task<Void, Never>?

    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// Errors of the last refresh, per account and source, as user messages.
    private(set) var refreshErrors: [UUID: [RoleSource: String]] = [:]
    /// Rows with a request in flight, and the last error per row (local EligibleRole / ActiveAssignment id).
    private(set) var busy: Set<String> = []
    private(set) var rowErrors: [String: String] = [:]
    /// When the panel was last opened (Activation timing).
    var panelOpenedAt: Date?
    /// Clock for countdowns: ticks every 30 s, every second in the last 5 minutes before an expiry (TRD › Performance).
    private(set) var now = Date.now
    private var clock: Task<Void, Never>?

    init(context: ModelContext, accounts: AccountService, notifications: NotificationScheduler) {
        self.context = context
        self.accounts = accounts
        self.notifications = notifications
    }

    // MARK: - Refresh

    /// Starts the refresh loop and the countdown clock (once, at launch).
    func start() {
        startAutoRefresh()
        guard clock == nil else { return }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.now = .now
                let next = self.activeActivations().compactMap(\.endAt).filter { $0 > .now }.min()
                let interval: Double = next.map { $0.timeIntervalSinceNow <= 300 ? 1 : 30 } ?? 30
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func startAutoRefresh() {
        guard autoRefresh == nil else { return }
        autoRefresh = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let minutes = self?.accounts.settings.refreshIntervalMinutes ?? 5
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
    }

    /// Refresh when the panel opens and the data is older than 60 s (PRD open question 10).
    func refreshIfStale() async {
        if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < 60 { return }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let list = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        for account in list {
            await refresh(account)
        }
        lastRefresh = .now
        try? context.save()
        await notifications.reschedule(activations: activeActivations(), leadMinutes: accounts.settings.notificationLeadMinutes)
    }

    private func refresh(_ account: Account) async {
        let service: PIMService
        do {
            service = PIMService(sources: try sources(for: account))
        } catch {
            refreshErrors[account.id] = [.azureResource: AccountService.message(for: error)]
            return
        }
        let snapshot = await service.refresh()
        var errors: [RoleSource: String] = [:]
        for (source, error) in snapshot.errors {
            if case TokenError.consentRequired = error {
                account.directoryAccess = .consentRequired
            } else {
                errors[source] = Self.message(for: error)
            }
        }
        refreshErrors[account.id] = errors
        apply(snapshot, to: account, failedSources: Set(snapshot.errors.keys))
        account.lastRefreshAt = snapshot.fetchedAt
        await refreshPolicies(of: account, service: service)
    }

    /// Replaces the cache of one account. Sources that failed keep their previous rows (offline / throttled).
    private func apply(_ snapshot: AccountSnapshot, to account: Account, failedSources: Set<RoleSource>) {
        var existing = Dictionary(uniqueKeysWithValues: account.eligibleRoles.map { ($0.remoteId, $0) })
        var kept: [String: EligibleRole] = [:]
        for remote in snapshot.eligibilities {
            let role = existing.removeValue(forKey: remote.id)
                ?? EligibleRole(id: remote.id, account: account, source: remote.source, roleDefinitionId: remote.roleDefinitionId,
                                roleName: remote.roleName, scope: remote.scope, scopeName: remote.scopeName,
                                scopeType: remote.scopeType, memberType: remote.memberType)
            if role.modelContext == nil { context.insert(role) }
            role.roleName = remote.roleName
            role.scopeName = remote.scopeName
            role.fetchedAt = snapshot.fetchedAt
            kept[remote.matchKey] = role
        }
        for stale in existing.values where !failedSources.contains(stale.source) {
            context.delete(stale)
        }

        for old in account.activeAssignments where !failedSources.contains(old.source) {
            context.delete(old)
        }
        for remote in snapshot.assignments {
            let eligible = snapshot.eligibility(for: remote).flatMap { kept[$0.matchKey] }
            let assignment = ActiveAssignment(id: remote.id, account: account, source: remote.source, roleName: remote.roleName,
                                              scope: remote.scope, scopeName: remote.scopeName, assignmentType: remote.type,
                                              startAt: remote.startAt, endAt: remote.endAt, eligibleRole: eligible)
            context.insert(assignment)
        }
    }

    /// Policies are cached 24 h (BackendSchema › EligibleRole.policyFetchedAt).
    private func refreshPolicies(of account: Account, service: PIMService) async {
        for role in account.eligibleRoles {
            if let fetched = role.policyFetchedAt, Date.now.timeIntervalSince(fetched) < 86_400 { continue }
            guard let source = service.source(for: role.source) else { continue }
            if let policy = try? await source.policy(for: role.remote) { role.policy = policy }
        }
    }

    private func sources(for account: Account) throws -> [any PIMSource] {
        let provider = try accounts.provider(for: account)
        let tenantId = account.tenantId
        return PIMService.sources(token: { resource, claims in
            try await provider.token(for: resource, tenantId: tenantId, claims: claims)
        }, directory: account.directoryAccess == .enabled)
    }

    // MARK: - Actions

    /// Sends an activation request; returns the outcome status, or nil on failure (error stored per row).
    @discardableResult
    func activate(_ role: EligibleRole, input: ActivationInput, viaFavorite: String? = nil) async -> RequestStatus? {
        guard let account = role.account else { return nil }
        busy.insert(role.id)
        rowErrors[role.id] = nil
        defer { busy.remove(role.id) }
        let record = ActivationRecord(account: account, eligibleRoleId: role.id, roleName: role.roleName,
                                      scopeName: role.scopeName, source: role.source, action: .activate,
                                      requestedDuration: input.duration, justification: input.justification,
                                      ticketNumber: input.ticketNumber, panelOpenedAt: panelOpenedAt, viaFavorite: viaFavorite)
        context.insert(record)
        do {
            guard let source = try PIMService(sources: sources(for: account)).source(for: role.source) else {
                throw TokenError.consentRequired
            }
            let outcome = try await source.activate(role.remote, principalId: account.objectId, input: input)
            record.remoteRequestId = outcome.requestId
            record.status = outcome.status
            if outcome.status == .provisioned { record.completedAt = .now }
            role.lastJustification = input.justification
            try? context.save()
            await refresh()
            return outcome.status
        } catch {
            record.status = .failed
            record.errorMessage = Self.message(for: error)
            rowErrors[role.id] = record.errorMessage
            try? context.save()
            return nil
        }
    }

    func deactivate(_ assignment: ActiveAssignment) async {
        guard let account = assignment.account, let role = assignment.eligibleRole else {
            rowErrors[assignment.id] = "This assignment is permanent and cannot be deactivated."
            return
        }
        busy.insert(assignment.id)
        rowErrors[assignment.id] = nil
        defer { busy.remove(assignment.id) }
        let record = ActivationRecord(account: account, eligibleRoleId: role.id, roleName: role.roleName,
                                      scopeName: role.scopeName, source: role.source, action: .deactivate)
        context.insert(record)
        do {
            guard let source = try PIMService(sources: sources(for: account)).source(for: role.source) else {
                throw TokenError.consentRequired
            }
            let outcome = try await source.deactivate(role.remote, principalId: account.objectId)
            record.remoteRequestId = outcome.requestId
            record.status = outcome.status == .failed ? .failed : .provisioned
            record.completedAt = .now
            try? context.save()
            await refresh()
        } catch {
            record.status = .failed
            record.errorMessage = Self.message(for: error)
            rowErrors[assignment.id] = record.errorMessage
            try? context.save()
        }
    }

    /// Fetches the policy now if it was never read (Activation Sheet needs it before validating).
    func ensurePolicy(for role: EligibleRole) async {
        guard role.policyFetchedAt == nil, let account = role.account,
              let source = try? PIMService(sources: sources(for: account)).source(for: role.source),
              let policy = try? await source.policy(for: role.remote) else { return }
        role.policy = policy
        try? context.save()
    }

    // MARK: - Queries

    func activeActivations() -> [ActiveAssignment] {
        let all = (try? context.fetch(FetchDescriptor<ActiveAssignment>(sortBy: [SortDescriptor(\.endAt)]))) ?? []
        return all.filter { $0.assignmentType == .activated }
    }

    static func message(for error: Error) -> String {
        if let pim = error as? PIMError { return pim.userMessage }
        if error is TokenError { return AccountService.message(for: error) }
        if let url = error as? URLError, url.code == .notConnectedToInternet { return "Offline." }
        return error.localizedDescription
    }
}
