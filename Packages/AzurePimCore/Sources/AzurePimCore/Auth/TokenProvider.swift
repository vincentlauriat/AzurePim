import Foundation

/// Microsoft API a token is requested for.
public enum Resource: String, Sendable, CaseIterable {
    case arm
    case graph

    /// Resource URI for `az account get-access-token --resource`.
    public var resourceURI: String {
        switch self {
        case .arm: "https://management.azure.com/"
        case .graph: "https://graph.microsoft.com/"
        }
    }

    /// Base delegated scopes for MSAL (directory scopes are requested incrementally, see `GraphScopes`).
    public var baseScopes: [String] {
        switch self {
        case .arm: ["https://management.azure.com/user_impersonation"]
        case .graph: ["User.Read"]
        }
    }
}

/// Graph scopes needing admin consent (TRD › MSAL scopes).
public enum GraphScopes {
    public static let directory = [
        "https://graph.microsoft.com/RoleEligibilitySchedule.Read.Directory",
        "https://graph.microsoft.com/RoleAssignmentSchedule.ReadWrite.Directory",
        "https://graph.microsoft.com/RoleManagementPolicy.Read.Directory",
        "https://graph.microsoft.com/PrivilegedEligibilitySchedule.Read.AzureADGroup",
        "https://graph.microsoft.com/PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup",
        "https://graph.microsoft.com/RoleManagementPolicy.Read.AzureADGroup"
    ]
}

public struct AccessToken: Sendable, Equatable {
    public let value: String
    public let expiresOn: Date

    public init(value: String, expiresOn: Date) {
        self.value = value
        self.expiresOn = expiresOn
    }

    /// Considered expired 5 minutes early to avoid using a token that dies in flight.
    public func isValid(at date: Date = .now) -> Bool { expiresOn.timeIntervalSince(date) > 300 }
}

/// Who is signed in, read from the token claims.
public struct SignedInIdentity: Sendable, Equatable {
    public let upn: String
    public let objectId: String
    public let tenantId: String
    public let tenantName: String?

    public init(upn: String, objectId: String, tenantId: String, tenantName: String?) {
        self.upn = upn
        self.objectId = objectId
        self.tenantId = tenantId
        self.tenantName = tenantName
    }
}

public enum TokenError: Error, Equatable, Sendable {
    /// The Azure CLI binary was not found (Open question 8: GUI apps do not inherit PATH).
    case cliNotFound
    /// `az login` is needed (no session, or expired refresh token). Carries the command to show.
    case cliNotSignedIn(command: String)
    /// MFA / authentication context needed (claims challenge). Carries the claims JSON when known.
    case interactionRequired(claims: String?)
    /// Directory scopes not consented in this tenant (Admin consent helper).
    case consentRequired
    /// MSAL is not configured (no client id in this build or in Settings).
    case notConfigured
    case cancelled
    case timedOut
    case failed(String)
}

/// Source of access tokens for one account (TRD › Authentication). Implemented by
/// `AzureCLITokenProvider` (core) and `MSALTokenProvider` (app target, depends on MSAL).
public protocol TokenProvider: Sendable {
    var mode: SignInMode { get }
    func token(for resource: Resource, tenantId: String?, claims: String?) async throws -> AccessToken
    func identity(tenantId: String?) async throws -> SignedInIdentity
}
