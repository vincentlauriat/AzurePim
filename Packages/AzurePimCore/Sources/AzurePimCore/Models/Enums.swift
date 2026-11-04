import Foundation

/// How an Account obtains its tokens (TRD › Authentication).
public enum SignInMode: String, Codable, Sendable, CaseIterable {
    case azureCLI
    case msal
}

/// Whether Entra roles / PIM groups are usable for an account (BackendSchema › Account.directoryAccess).
public enum DirectoryAccess: String, Codable, Sendable {
    case notApplicable      // Azure CLI mode: Graph PIM scopes cannot be obtained (AADSTS65002)
    case notRequested       // MSAL, directory scopes not requested yet
    case consentRequired    // MSAL, tenant admin consent missing
    case enabled
}

/// Where a PIM role comes from.
public enum RoleSource: String, Codable, Sendable, CaseIterable {
    case azureResource
    case entraRole
    case pimGroup
}

public enum MemberType: String, Codable, Sendable {
    case direct
    case group
    case inherited
}

public enum AssignmentType: String, Codable, Sendable {
    case activated   // PIM activation, can be deactivated
    case assigned    // permanent, read-only
}

public enum ActivationAction: String, Codable, Sendable {
    case activate
    case deactivate
    case extend
}

public enum RequestStatus: String, Codable, Sendable {
    case sent
    case provisioned
    case pendingApproval
    case denied
    case canceled
    case failed
}

public enum MenuBarStyle: String, Codable, Sendable, CaseIterable {
    case icon
    case iconCount
    case iconCountTime
}
