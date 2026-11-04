import AzurePimCore
import Foundation
import SwiftData

/// Extend, favorites and pending requests (ImplementationPlan T4.1–T4.3).
extension RoleStore {
    // MARK: - Extend (T4.1)

    /// Extends an activation (see `ExtendPlan`): Azure keeps one activation per eligibility, so the current one is
    /// ended and the role activated again with its last parameters. Returns the text of the follow-up notification,
    /// which always says whether the role is still held.
    func extend(eligibleRoleId: String) async -> String {
        guard !extending.contains(eligibleRoleId) else { return "An extension is already running for this role." }
        extending.insert(eligibleRoleId)
        defer { extending.remove(eligibleRoleId) }
        guard let role = eligibleRole(id: eligibleRoleId) else { return "This role is no longer eligible." }
        guard let activeSince = activeActivations().first(where: { $0.eligibleRole?.id == eligibleRoleId })?.startAt else {
            return "\(role.roleName) is no longer active."
        }
        let lastDuration = role.account?.records
            .filter { $0.eligibleRoleId == eligibleRoleId && $0.action != .deactivate && $0.requestedDuration != nil }
            .max { $0.sentAt < $1.sentAt }?.requestedDuration
        // Never decide on a cached or default policy: ending the activation must be safe to undo.
        guard await refreshPolicy(for: role) else {
            return "Couldn't read the role's policy: not extended, the role is still active."
        }
        switch ExtendPlan.decide(policy: role.policy, lastJustification: role.lastJustification, lastDuration: lastDuration,
                                 activeSince: activeSince) {
        case .blocked(let reason):
            return reason + " The role is still active."
        case .reactivate(let input):
            return await reactivate(role, input: input)
        }
    }

    private func reactivate(_ role: EligibleRole, input: ActivationInput) async -> String {
        let roleId = role.id
        guard let current = activeActivations().first(where: { $0.eligibleRole?.id == roleId }) else {
            return "\(role.roleName) is no longer active."
        }
        let currentId = current.id
        guard await deactivate(current, refreshAfter: false) else {
            return "Couldn't extend: \(rowErrors[currentId] ?? "deactivation failed"). The role is still active."
        }
        // Azure may still report the old activation for a few seconds after the deactivation.
        var status: RequestStatus?
        for delay in [0, 3, 6, 12] {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            status = await activate(role, input: input, fromPanel: false, action: .extend, refreshAfter: false)
            if status != nil || lastActivationError[roleId]?.alreadyActive != true { break }
        }
        await refresh()
        switch status {
        case .provisioned?:
            let end = Date.now.addingTimeInterval(ISODuration.seconds(input.duration) ?? 0)
            return "Extended until \(end.formatted(date: .omitted, time: .shortened))."
        case .pendingApproval?:
            return "Role deactivated; the new activation is waiting for approval."
        default:
            return "Role deactivated; re-activation failed: \(rowErrors[roleId] ?? "unknown error"). Activate it from the panel."
        }
    }

    func eligibleRole(id: String) -> EligibleRole? {
        var descriptor = FetchDescriptor<EligibleRole>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Favorites (T4.2)

    /// Activates every role of a favorite without a sheet. Returns the toast text.
    @discardableResult
    func run(_ favorite: Favorite, fromPanel: Bool = true) async -> String {
        // Value copies: the model may be deleted while requests are in flight.
        let favoriteId = favorite.id, favoriteName = favorite.name, items = favorite.items
        guard !runningFavorites.contains(favoriteId) else { return "\(favoriteName) is already running." }
        runningFavorites.insert(favoriteId)
        defer { runningFavorites.remove(favoriteId) }
        let active = Set(activeActivations().compactMap { $0.eligibleRole?.id })
        var results: [FavoriteRoleResult] = []
        for item in items {
            guard let role = eligibleRole(id: item.eligibleRoleId) else {
                results.append(.init(roleName: "Unknown role", status: nil, error: "no longer eligible"))
                continue
            }
            if active.contains(role.id) {
                results.append(.init(roleName: role.roleName, status: .provisioned))
                continue
            }
            await ensurePolicy(for: role)
            switch FavoriteRun.input(for: item, policy: role.policy, lastJustification: role.lastJustification) {
            case .failure(let failure):
                results.append(.init(roleName: role.roleName, status: nil, error: failure.userMessage))
            case .success(let input):
                let status = await activate(role, input: input, viaFavorite: favoriteName, fromPanel: fromPanel,
                                            refreshAfter: false)
                results.append(.init(roleName: role.roleName, status: status, error: rowErrors[role.id]))
            }
        }
        await refresh()
        let text = FavoriteRun.summary(results)
        favoriteToast = (favoriteId, text)
        return text
    }

    func favorite(named name: String) -> Favorite? {
        let all = (try? context.fetch(FetchDescriptor<Favorite>())) ?? []
        return all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - History (T4.3)

    /// Cancels a pending request (local record or request made elsewhere).
    func cancel(requestId: String, source: RoleSource, account: Account) async -> String? {
        do {
            guard let pim = try PIMService(sources: sources(for: account)).source(for: source) else {
                throw TokenError.consentRequired
            }
            try await pim.cancel(request: requestId)
            for record in account.records where record.remoteRequestId?.lowercased() == requestId.lowercased() {
                record.status = .canceled
                record.completedAt = .now
            }
            pending[account.id]?.removeAll { $0.id.lowercased() == requestId.lowercased() }
            try? context.save()
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    // MARK: - Pending requests and retention

    /// Pending approvals: lists them, and updates local records whose request was decided meanwhile (T4.3).
    /// ARM has no status filter on requests, so the full listing only runs while History is open or when local
    /// requests are still undecided.
    func refreshPending(of account: Account, service: PIMService, failedSources: Set<RoleSource>) async {
        let undecided = account.records.filter(Self.needsPolling)
        guard historyVisible || !undecided.isEmpty else {
            pending[account.id] = []
            pendingErrors[account.id] = nil
            return
        }
        var list: [RemoteRequest] = []
        var failure: String?
        for source in service.sources where !failedSources.contains(source.source) {
            do {
                list += try await source.pendingRequests()
            } catch {
                failure = Self.message(for: error)
            }
        }
        pending[account.id] = list.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        pendingErrors[account.id] = failure
        let open = Set(list.map { $0.id.lowercased() })
        for record in undecided {
            guard let requestId = record.remoteRequestId, !open.contains(requestId.lowercased()),
                  let source = service.source(for: record.source),
                  let status = try? await source.status(ofRequest: requestId),
                  status != .pendingApproval, status != .sent else { continue }
            let wasPending = record.status == .pendingApproval
            record.status = status
            if status == .provisioned {
                record.completedAt = .now
                // The approver's delay is not app speed: keep it out of the time-to-activation median.
                if wasPending { record.panelOpenedAt = nil }
            }
            guard wasPending, Date.now.timeIntervalSince(record.sentAt) < 86_400 else { continue }
            await notifications.notify(title: "\(record.roleName) — \(record.scopeName)",
                                       body: status == .provisioned ? "Request approved: the role is active."
                                           : "Request \(status.rawValue).")
        }
    }

    /// Requests still waiting for a decision, polled for 7 days at most (older ones may hold a name-only ARM id).
    static func needsPolling(_ record: ActivationRecord) -> Bool {
        (record.status == .pendingApproval || record.status == .sent) && record.remoteRequestId != nil
            && Date.now.timeIntervalSince(record.sentAt) < 7 * 86_400
    }

    /// Deletes history older than the retention setting (pending requests are kept).
    func purgeHistory() {
        let records = (try? context.fetch(FetchDescriptor<ActivationRecord>())) ?? []
        for record in Retention.expired(records, days: accounts.settings.historyRetentionDays) {
            context.delete(record)
        }
    }
}
