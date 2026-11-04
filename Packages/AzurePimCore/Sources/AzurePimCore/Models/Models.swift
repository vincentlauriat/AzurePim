import Foundation
import SwiftData

// Entities of BackendSchema.md. Enums are stored as raw strings (stable on disk, usable in #Predicate)
// and exposed through typed computed properties.

@Model
public final class Account {
    @Attribute(.unique) public var id: UUID
    public var modeRaw: String
    public var upn: String
    public var objectId: String
    public var tenantId: String
    public var tenantName: String?
    public var msalHomeAccountId: String?
    /// Client id used at sign-in: removal must purge the token cache of that same app (MSAL only).
    public var msalClientId: String?
    public var directoryAccessRaw: String
    public var sortOrder: Int
    public var lastRefreshAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \EligibleRole.account) public var eligibleRoles: [EligibleRole] = []
    @Relationship(deleteRule: .cascade, inverse: \ActiveAssignment.account) public var activeAssignments: [ActiveAssignment] = []
    @Relationship(deleteRule: .cascade, inverse: \ActivationRecord.account) public var records: [ActivationRecord] = []

    public init(mode: SignInMode, upn: String, objectId: String, tenantId: String, tenantName: String? = nil,
                msalHomeAccountId: String? = nil, msalClientId: String? = nil, sortOrder: Int = 0) {
        self.id = UUID()
        self.modeRaw = mode.rawValue
        self.upn = upn
        self.objectId = objectId
        self.tenantId = tenantId
        self.tenantName = tenantName
        self.msalHomeAccountId = msalHomeAccountId
        self.msalClientId = msalClientId
        self.directoryAccessRaw = (mode == .azureCLI ? DirectoryAccess.notApplicable : .notRequested).rawValue
        self.sortOrder = sortOrder
    }

    public var mode: SignInMode { SignInMode(rawValue: modeRaw) ?? .azureCLI }
    public var directoryAccess: DirectoryAccess {
        get { DirectoryAccess(rawValue: directoryAccessRaw) ?? .notApplicable }
        set { directoryAccessRaw = newValue.rawValue }
    }
    /// Unique key (BackendSchema index: tenantId + objectId + mode).
    public var identityKey: String { "\(tenantId.lowercased())|\(objectId.lowercased())|\(modeRaw)" }
}

@Model
public final class EligibleRole {
    /// Remote eligibility schedule id.
    @Attribute(.unique) public var id: String
    public var account: Account?
    public var sourceRaw: String
    public var roleDefinitionId: String
    public var roleName: String
    public var scope: String
    public var scopeName: String
    public var scopeType: String
    public var memberTypeRaw: String
    public var maxDuration: String?
    public var requiresJustification: Bool
    public var requiresTicket: Bool
    public var requiresMFA: Bool
    public var requiresApproval: Bool
    public var policyFetchedAt: Date?
    public var lastJustification: String?
    public var fetchedAt: Date

    public init(id: String, account: Account, source: RoleSource, roleDefinitionId: String, roleName: String,
                scope: String, scopeName: String, scopeType: String, memberType: MemberType = .direct) {
        self.id = id
        self.account = account
        self.sourceRaw = source.rawValue
        self.roleDefinitionId = roleDefinitionId
        self.roleName = roleName
        self.scope = scope
        self.scopeName = scopeName
        self.scopeType = scopeType
        self.memberTypeRaw = memberType.rawValue
        self.requiresJustification = true
        self.requiresTicket = false
        self.requiresMFA = false
        self.requiresApproval = false
        self.fetchedAt = .now
    }

    public var source: RoleSource { RoleSource(rawValue: sourceRaw) ?? .azureResource }
    public var memberType: MemberType { MemberType(rawValue: memberTypeRaw) ?? .direct }
}

@Model
public final class ActiveAssignment {
    @Attribute(.unique) public var id: String
    public var account: Account?
    public var eligibleRole: EligibleRole?
    public var sourceRaw: String
    public var roleName: String
    public var scope: String
    public var scopeName: String
    public var assignmentTypeRaw: String
    public var startAt: Date
    public var endAt: Date?
    public var notifiedAt: Date?
    public var fetchedAt: Date

    public init(id: String, account: Account, source: RoleSource, roleName: String, scope: String, scopeName: String,
                assignmentType: AssignmentType, startAt: Date, endAt: Date?, eligibleRole: EligibleRole? = nil) {
        self.id = id
        self.account = account
        self.eligibleRole = eligibleRole
        self.sourceRaw = source.rawValue
        self.roleName = roleName
        self.scope = scope
        self.scopeName = scopeName
        self.assignmentTypeRaw = assignmentType.rawValue
        self.startAt = startAt
        self.endAt = endAt
        self.fetchedAt = .now
    }

    public var source: RoleSource { RoleSource(rawValue: sourceRaw) ?? .azureResource }
    public var assignmentType: AssignmentType { AssignmentType(rawValue: assignmentTypeRaw) ?? .assigned }
}

/// One role inside a Favorite (embedded value, soft reference to EligibleRole.id).
public struct FavoriteItem: Codable, Hashable, Sendable {
    public var eligibleRoleId: String
    public var duration: String
    public var justification: String?

    public init(eligibleRoleId: String, duration: String = "PT8H", justification: String? = nil) {
        self.eligibleRoleId = eligibleRoleId
        self.duration = duration
        self.justification = justification
    }
}

@Model
public final class Favorite {
    @Attribute(.unique) public var id: UUID
    @Attribute(.unique) public var name: String
    public var sortOrder: Int
    public var items: [FavoriteItem]

    public init(name: String, items: [FavoriteItem], sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.items = items
        self.sortOrder = sortOrder
    }
}

@Model
public final class ActivationRecord {
    @Attribute(.unique) public var id: UUID
    public var account: Account?
    public var eligibleRoleId: String
    public var roleName: String
    public var scopeName: String
    public var sourceRaw: String
    public var actionRaw: String
    public var requestedDuration: String?
    public var justification: String?
    public var ticketNumber: String?
    public var remoteRequestId: String?
    public var statusRaw: String
    public var errorMessage: String?
    public var panelOpenedAt: Date?
    public var sentAt: Date
    public var completedAt: Date?
    public var viaFavorite: String?

    public init(account: Account, eligibleRoleId: String, roleName: String, scopeName: String, source: RoleSource,
                action: ActivationAction, requestedDuration: String? = nil, justification: String? = nil,
                ticketNumber: String? = nil, panelOpenedAt: Date? = nil, viaFavorite: String? = nil) {
        self.id = UUID()
        self.account = account
        self.eligibleRoleId = eligibleRoleId
        self.roleName = roleName
        self.scopeName = scopeName
        self.sourceRaw = source.rawValue
        self.actionRaw = action.rawValue
        self.requestedDuration = requestedDuration
        self.justification = justification
        self.ticketNumber = ticketNumber
        self.statusRaw = RequestStatus.sent.rawValue
        self.panelOpenedAt = panelOpenedAt
        self.sentAt = .now
        self.viaFavorite = viaFavorite
    }

    public var status: RequestStatus {
        get { RequestStatus(rawValue: statusRaw) ?? .sent }
        set { statusRaw = newValue.rawValue }
    }
    public var action: ActivationAction { ActivationAction(rawValue: actionRaw) ?? .activate }
    /// Activation timing (PRD success metric): panel opened → provisioned.
    public var timeToActivation: TimeInterval? {
        guard let start = panelOpenedAt, let end = completedAt else { return nil }
        return end.timeIntervalSince(start)
    }
}

@Model
public final class AppSettings {
    public var refreshIntervalMinutes: Int
    public var notificationLeadMinutes: Int
    public var historyRetentionDays: Int
    public var menuBarStyleRaw: String
    public var azCLIPath: String?
    public var customClientId: String?
    public var launchAtLogin: Bool
    public var onboardingCompleted: Bool

    public init() {
        refreshIntervalMinutes = 5
        notificationLeadMinutes = 15
        historyRetentionDays = 90
        menuBarStyleRaw = MenuBarStyle.iconCountTime.rawValue
        launchAtLogin = true
        onboardingCompleted = false
    }

    public var menuBarStyle: MenuBarStyle {
        get { MenuBarStyle(rawValue: menuBarStyleRaw) ?? .iconCountTime }
        set { menuBarStyleRaw = newValue.rawValue }
    }
}
