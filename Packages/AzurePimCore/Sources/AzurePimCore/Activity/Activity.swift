import Foundation

/// Activation timing (PRD success metric, T4.5).
public enum ActivationStats {
    /// Median of `timeToActivation` over provisioned activations started from the panel.
    /// Records without `panelOpenedAt` (deep links, notification actions, favorites run from Shortcuts) are excluded.
    public static func medianTimeToActivation(_ records: [ActivationRecord]) -> TimeInterval? {
        median(records.filter { $0.action == .activate && $0.status == .provisioned }.compactMap(\.timeToActivation)
            .filter { $0 >= 0 })
    }

    public static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// History retention (AppSettings.historyRetentionDays). Pending requests are kept whatever their age.
public enum Retention {
    public static func cutoff(days: Int, now: Date = .now) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    public static func expired(_ records: [ActivationRecord], days: Int, now: Date = .now) -> [ActivationRecord] {
        let limit = cutoff(days: days, now: now)
        return records.filter { $0.sentAt < limit && $0.status != .pendingApproval }
    }
}

/// CSV export of the History Window (RFC 4180 quoting).
public enum HistoryCSV {
    public static let header = ["sent_at", "account", "action", "role", "scope", "source", "duration", "status",
                                "justification", "ticket", "time_to_activation_s", "favorite", "error"]

    public static func make(_ records: [ActivationRecord]) -> String {
        let iso = ISO8601DateFormatter()
        var lines = [header.joined(separator: ",")]
        for record in records {
            let fields: [String?] = [
                iso.string(from: record.sentAt), record.account?.upn, record.action.rawValue, record.roleName,
                record.scopeName, record.sourceRaw, record.requestedDuration, record.status.rawValue, record.justification,
                record.ticketNumber, record.timeToActivation.map { String(format: "%.1f", $0) }, record.viaFavorite,
                record.errorMessage
            ]
            lines.append(fields.map { escape($0 ?? "") }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    public static func escape(_ field: String) -> String {
        // Leading = + - @ would run as a formula in Excel / Numbers.
        var value = field
        if let first = value.first, "=+-@".contains(first) { value = "'" + value }
        // Scalars, not Characters: "\r\n" is a single Character and would hide a lone "\n".
        guard value.unicodeScalars.contains(where: { ",\"\r\n".unicodeScalars.contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Result of one role of a favorite run (T4.2).
public struct FavoriteRoleResult: Sendable, Equatable {
    public let roleName: String
    public let status: RequestStatus?
    public let error: String?

    public init(roleName: String, status: RequestStatus?, error: String? = nil) {
        self.roleName = roleName
        self.status = status
        self.error = error
    }

    public var succeeded: Bool { status == .provisioned || status == .pendingApproval }
}

public enum FavoriteRun {
    /// Toast text: "2 of 2 activated", plus pending and failures per role.
    public static func summary(_ results: [FavoriteRoleResult]) -> String {
        let activated = results.filter { $0.status == .provisioned }.count
        let pending = results.filter { $0.status == .pendingApproval }.count
        var text = "\(activated) of \(results.count) activated"
        if pending > 0 { text += ", \(pending) pending approval" }
        let failures = results.filter { !$0.succeeded }
        if !failures.isEmpty {
            text += " — " + failures.map { "\($0.roleName): \($0.error ?? "failed")" }.joined(separator: "; ")
        }
        return text
    }

    /// Input for one favorite item: duration capped by policy, justification from the item or the last one used.
    public static func input(for item: FavoriteItem, policy: RolePolicy, lastJustification: String?)
        -> Result<ActivationInput, Validation.Failure> {
        if policy.requiresTicket { return .failure(.empty("ticket")) }
        let justification = (item.justification?.isEmpty == false ? item.justification : lastJustification) ?? ""
        if let error = Validation.justification(justification, required: policy.requiresJustification) {
            return .failure(error)
        }
        var duration = item.duration
        if let max = policy.maxDuration.flatMap(ISODuration.seconds), let wanted = ISODuration.seconds(duration), wanted > max {
            duration = ISODuration.string(max)
        }
        if case .failure(let error) = Validation.duration(duration, policyMax: policy.maxDuration) { return .failure(error) }
        return .success(ActivationInput(duration: duration, justification: justification))
    }
}

/// Extend activation (T4.1). PIM `SelfExtend` targets expiring *assignments* (14-day window, admin approval),
/// not activations: an activation is extended by activating again with the same parameters.
public enum ExtendPlan: Equatable, Sendable {
    case reactivate(ActivationInput)
    case blocked(String)

    public static func decide(policy: RolePolicy, lastJustification: String?, lastDuration: String?,
                              activeSince: Date, now: Date = .now) -> ExtendPlan {
        if policy.requiresApproval {
            return .blocked("This role needs approval: extending would end the current activation before the approval.")
        }
        if policy.requiresTicket { return .blocked("This role needs a ticket number: open the panel to activate it again.") }
        if policy.requiresMFA { return .blocked("This role needs MFA: open the panel to activate it again.") }
        if now.timeIntervalSince(activeSince) < 300 { return .blocked("Azure refuses changes within 5 minutes of activation.") }
        let justification = lastJustification ?? ""
        if policy.requiresJustification, Validation.justification(justification, required: true) != nil {
            return .blocked("No previous justification for this role: open the panel to activate it again.")
        }
        var duration = lastDuration ?? policy.maxDuration ?? "PT8H"
        if let max = policy.maxDuration.flatMap(ISODuration.seconds), let wanted = ISODuration.seconds(duration), wanted > max {
            duration = ISODuration.string(max)
        }
        return .reactivate(ActivationInput(duration: duration, justification: justification))
    }

    /// True when Azure / Graph refused an activation because the role is already active
    /// (then the extension deactivates first, and activates again).
    public static func isAlreadyActive(_ error: Error) -> Bool {
        guard case PIMError.http(let status, let code, let message) = error, status == 400 || status == 409 else { return false }
        let text = "\(code ?? "") \(message)".lowercased()
        return text.contains("roleassignmentexists") || text.contains("already exists") || text.contains("already active")
    }
}
