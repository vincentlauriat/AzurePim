import Foundation

/// An eligible PIM assignment as returned by Azure or Graph, normalized across the three sources.
public struct RemoteEligibility: Sendable, Equatable, Identifiable {
    /// Eligibility schedule id (stable across instances).
    public let id: String
    public let source: RoleSource
    public let roleDefinitionId: String
    public let roleName: String
    /// ARM scope path, Entra directory scope id (`/` or `/administrativeUnits/…`), or group id.
    public let scope: String
    public let scopeName: String
    public let scopeType: String
    public let memberType: MemberType

    public init(id: String, source: RoleSource, roleDefinitionId: String, roleName: String, scope: String,
                scopeName: String, scopeType: String, memberType: MemberType) {
        self.id = id
        self.source = source
        self.roleDefinitionId = roleDefinitionId
        self.roleName = roleName
        self.scope = scope
        self.scopeName = scopeName
        self.scopeType = scopeType
        self.memberType = memberType
    }

    /// Key used to match an active assignment to its eligibility when no link id is returned.
    public var matchKey: String { "\(source.rawValue)|\(roleDefinitionId.lowercased())|\(scope.lowercased())" }
}

/// An active assignment (PIM activation or permanent assignment).
public struct RemoteAssignment: Sendable, Equatable, Identifiable {
    public let id: String
    public let source: RoleSource
    public let roleDefinitionId: String
    public let roleName: String
    public let scope: String
    public let scopeName: String
    public let type: AssignmentType
    public let startAt: Date
    public let endAt: Date?
    public let linkedEligibilityId: String?

    public init(id: String, source: RoleSource, roleDefinitionId: String, roleName: String, scope: String,
                scopeName: String, type: AssignmentType, startAt: Date, endAt: Date?, linkedEligibilityId: String?) {
        self.id = id
        self.source = source
        self.roleDefinitionId = roleDefinitionId
        self.roleName = roleName
        self.scope = scope
        self.scopeName = scopeName
        self.type = type
        self.startAt = startAt
        self.endAt = endAt
        self.linkedEligibilityId = linkedEligibilityId
    }

    public var matchKey: String { "\(source.rawValue)|\(roleDefinitionId.lowercased())|\(scope.lowercased())" }
}

/// End-user activation rules of a role (from its PIM policy).
public struct RolePolicy: Sendable, Equatable {
    public var maxDuration: String?
    public var requiresJustification: Bool
    public var requiresTicket: Bool
    public var requiresMFA: Bool
    public var requiresApproval: Bool

    public init(maxDuration: String? = nil, requiresJustification: Bool = true, requiresTicket: Bool = false,
                requiresMFA: Bool = false, requiresApproval: Bool = false) {
        self.maxDuration = maxDuration
        self.requiresJustification = requiresJustification
        self.requiresTicket = requiresTicket
        self.requiresMFA = requiresMFA
        self.requiresApproval = requiresApproval
    }

    /// Reads the `*_EndUser_Assignment` rules shared by ARM `effectiveRules` and Graph `policy.rules`.
    public init(rules: [[String: Any]]) {
        self.init()
        for rule in rules {
            switch rule["id"] as? String {
            case "Expiration_EndUser_Assignment":
                maxDuration = rule["maximumDuration"] as? String
            case "Enablement_EndUser_Assignment":
                let enabled = (rule["enabledRules"] as? [String]) ?? []
                requiresJustification = enabled.contains("Justification")
                requiresTicket = enabled.contains("Ticketing")
                requiresMFA = requiresMFA || enabled.contains("MultiFactorAuthentication")
            case "Approval_EndUser_Assignment":
                let setting = rule["setting"] as? [String: Any]
                requiresApproval = (setting?["isApprovalRequired"] as? Bool) ?? false
            case "AuthenticationContext_EndUser_Assignment":
                requiresMFA = requiresMFA || ((rule["isEnabled"] as? Bool) ?? false)
            default:
                break
            }
        }
    }
}

/// What the user typed in the Activation Sheet.
public struct ActivationInput: Sendable, Equatable {
    public var duration: String
    public var justification: String
    public var ticketNumber: String?
    public var ticketSystem: String?

    public init(duration: String, justification: String, ticketNumber: String? = nil, ticketSystem: String? = nil) {
        self.duration = duration
        self.justification = justification
        self.ticketNumber = ticketNumber
        self.ticketSystem = ticketSystem
    }
}

/// Result of an activation / deactivation request.
public struct RequestOutcome: Sendable, Equatable {
    public let requestId: String?
    public let status: RequestStatus
    public let message: String?

    public init(requestId: String?, status: RequestStatus, message: String? = nil) {
        self.requestId = requestId
        self.status = status
        self.message = message
    }

    /// Maps ARM / Graph request status strings.
    public static func status(from raw: String?) -> RequestStatus {
        switch raw?.lowercased() {
        case "provisioned", "granted", "scheduled", "provisioningstarted", "pendingprovisioning", "accepted":
            return .provisioned
        case "pendingapproval", "pendingapprovalprovisioning", "pendingadmindecision", "pendingevaluation":
            return .pendingApproval
        case "denied", "admindenied": return .denied
        case "canceled", "revoked": return .canceled
        case "failed", "failedasresourceislocked", "invalid", "timedout": return .failed
        default: return .sent
        }
    }
}

/// Errors from ARM / Graph (beyond token errors).
public enum PIMError: Error, Equatable, Sendable {
    case http(status: Int, code: String?, message: String)
    case throttled(retryAfter: TimeInterval?)
    case decoding(String)

    public var userMessage: String {
        switch self {
        case .http(_, _, let message): message
        case .throttled: "Microsoft is throttling requests — retrying shortly."
        case .decoding(let detail): "Unexpected response from Microsoft (\(detail))."
        }
    }
}

/// One PIM source (Azure resources, Entra roles, PIM groups) for one signed-in principal.
public protocol PIMSource: Sendable {
    var source: RoleSource { get }
    func eligibilities() async throws -> [RemoteEligibility]
    func assignments() async throws -> [RemoteAssignment]
    func policy(for eligibility: RemoteEligibility) async throws -> RolePolicy
    func activate(_ eligibility: RemoteEligibility, principalId: String, input: ActivationInput) async throws -> RequestOutcome
    func deactivate(_ eligibility: RemoteEligibility, principalId: String) async throws -> RequestOutcome
    /// Requests sent by the signed-in user that wait for an approver (History Window).
    func pendingRequests() async throws -> [RemoteRequest]
    /// Current status of a request sent earlier (`RequestOutcome.requestId`).
    func status(ofRequest id: String) async throws -> RequestStatus
    /// Cancels a pending request.
    func cancel(request id: String) async throws
}

enum PIMDates {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) static let plain = ISO8601DateFormatter()

    static func parse(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        // Azure returns 7 fractional digits; ISO8601DateFormatter accepts at most 3.
        let trimmed = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        return fractional.date(from: trimmed) ?? plain.date(from: trimmed)
    }
}
