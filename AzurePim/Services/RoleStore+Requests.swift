import AzurePimCore
import Foundation
import SwiftData

/// Extend, favorites and pending requests (ImplementationPlan T4.1–T4.3).
extension RoleStore {
    // MARK: - Extend (T4.1)

    /// Extends an activation by activating it again with its last parameters (see `ExtendPlan`).
    /// Returns the text of the follow-up notification.
    func extend(eligibleRoleId: String) async -> String {
        guard let role = eligibleRole(id: eligibleRoleId) else { return "This role is no longer eligible." }
        guard let assignment = activeActivations().first(where: { $0.eligibleRole?.id == role.id }) else {
            return "\(role.roleName) is no longer active."
        }
        let lastDuration = role.account?.records
            .filter { $0.eligibleRoleId == role.id && $0.action != .deactivate && $0.requestedDuration != nil }
            .max { $0.sentAt < $1.sentAt }?.requestedDuration
        await ensurePolicy(for: role)
        switch ExtendPlan.decide(policy: role.policy, lastJustification: role.lastJustification, lastDuration: lastDuration,
                                 activeSince: assignment.startAt) {
        case .blocked(let reason):
            return reason
        case .reactivate(let input):
            var status = await activate(role, input: input, fromPanel: false, action: .extend)
            if status == nil, lastActivationError[role.id]?.alreadyActive == true {
                // Azure keeps one activation per eligibility: end the current one, then activate again.
                rowErrors[role.id] = nil
                guard let current = activeActivations().first(where: { $0.eligibleRole?.id == role.id }),
                      await deactivate(current, refreshAfter: false) else {
                    return "Couldn't extend: \(rowErrors.values.first ?? "deactivation failed")."
                }
                status = await activate(role, input: input, fromPanel: false, action: .extend)
            }
            switch status {
            case .provisioned?:
                let end = Date.now.addingTimeInterval(ISODuration.seconds(input.duration) ?? 0)
                return "Extended until \(end.formatted(date: .omitted, time: .shortened))."
            case .pendingApproval?: return "Extension pending approval."
            default: return "Couldn't extend: \(rowErrors[role.id] ?? "unknown error")."
            }
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
        guard !runningFavorites.contains(favorite.id) else { return "\(favorite.name) is already running." }
        runningFavorites.insert(favorite.id)
        defer { runningFavorites.remove(favorite.id) }
        let active = Set(activeActivations().compactMap { $0.eligibleRole?.id })
        var results: [FavoriteRoleResult] = []
        for item in favorite.items {
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
                let status = await activate(role, input: input, viaFavorite: favorite.name, fromPanel: fromPanel,
                                            refreshAfter: false)
                results.append(.init(roleName: role.roleName, status: status, error: rowErrors[role.id]))
            }
        }
        await refresh()
        let text = FavoriteRun.summary(results)
        favoriteToast = (favorite.name, text)
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
            pending[account.id]?.removeAll { $0.id == requestId }
            try? context.save()
            return nil
        } catch {
            return Self.message(for: error)
        }
    }
}
