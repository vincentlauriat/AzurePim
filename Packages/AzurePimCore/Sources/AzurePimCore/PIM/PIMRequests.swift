import Foundation

/// A PIM request as listed by Azure / Graph (History Window › pending requests).
public struct RemoteRequest: Sendable, Equatable, Identifiable {
    /// ARM full resource id, or Graph request id. Also what `status(ofRequest:)` and `cancel(request:)` take.
    public let id: String
    public let source: RoleSource
    public let roleName: String
    public let scopeName: String
    public let status: RequestStatus
    public let createdAt: Date?
    public let justification: String?

    public init(id: String, source: RoleSource, roleName: String, scopeName: String, status: RequestStatus,
                createdAt: Date?, justification: String?) {
        self.id = id
        self.source = source
        self.roleName = roleName
        self.scopeName = scopeName
        self.status = status
        self.createdAt = createdAt
        self.justification = justification
    }
}

// MARK: - Azure resources

extension ARMClient {
    public func pendingRequests() async throws -> [RemoteRequest] {
        // At the root scope ARM refuses `asRequestor()` (400 InsufficientPermissions, verified live 2026-11-04):
        // `asTarget()` lists the requests made for the signed-in user, which includes self-activations.
        let items = try await client.list(Self.url("/providers/Microsoft.Authorization/roleAssignmentScheduleRequests",
                                                   filter: "asTarget()"))
        return items.compactMap { item -> RemoteRequest? in
            guard let id = item["id"] as? String, let props = item["properties"] as? [String: Any] else { return nil }
            let status = RequestOutcome.status(from: props["status"] as? String)
            guard status == .pendingApproval else { return nil }
            let expanded = props["expandedProperties"] as? [String: Any]
            let scope = props["scope"] as? String ?? ""
            return RemoteRequest(id: id, source: .azureResource,
                                 roleName: (expanded?["roleDefinition"] as? [String: Any])?["displayName"] as? String ?? "Role",
                                 scopeName: (expanded?["scope"] as? [String: Any])?["displayName"] as? String ?? scope,
                                 status: status, createdAt: PIMDates.parse(props["createdOn"]),
                                 justification: props["justification"] as? String)
        }
    }

    public func status(ofRequest id: String) async throws -> RequestStatus {
        let response = try await client.json("GET", Self.url(id))
        return RequestOutcome.status(from: (response["properties"] as? [String: Any])?["status"] as? String)
    }

    public func cancel(request id: String) async throws {
        _ = try await client.json("POST", Self.url("\(id)/cancel"))
    }
}

// MARK: - Entra roles

extension EntraRoleClient {
    static let requests = "/roleManagement/directory/roleAssignmentScheduleRequests"

    public func pendingRequests() async throws -> [RemoteRequest] {
        let items = try await client.list(GraphURL.make("\(Self.requests)/filterByCurrentUser(on='principal')",
                                                        expand: "roleDefinition", filter: "status eq 'PendingApproval'"))
        return items.compactMap { item in
            GraphURL.request(item, source: .entraRole,
                             roleName: (item["roleDefinition"] as? [String: Any])?["displayName"] as? String ?? "Entra role",
                             scopeName: (item["directoryScopeId"] as? String ?? "/") == "/" ? "Directory"
                                : item["directoryScopeId"] as? String ?? "")
        }
    }

    public func status(ofRequest id: String) async throws -> RequestStatus {
        RequestOutcome.status(from: try await client.json("GET", GraphURL.make("\(Self.requests)/\(id)"))["status"] as? String)
    }

    public func cancel(request id: String) async throws {
        _ = try await client.json("POST", GraphURL.make("\(Self.requests)/\(id)/cancel"))
    }
}

// MARK: - PIM groups

extension PIMGroupClient {
    static let requests = "/identityGovernance/privilegedAccess/group/assignmentScheduleRequests"

    public func pendingRequests() async throws -> [RemoteRequest] {
        let items = try await client.list(GraphURL.make("\(Self.requests)/filterByCurrentUser(on='principal')",
                                                        expand: "group", filter: "status eq 'PendingApproval'"))
        return items.compactMap { item in
            GraphURL.request(item, source: .pimGroup,
                             roleName: (item["accessId"] as? String) == "owner" ? "Owner" : "Member",
                             scopeName: (item["group"] as? [String: Any])?["displayName"] as? String
                                ?? item["groupId"] as? String ?? "Group")
        }
    }

    public func status(ofRequest id: String) async throws -> RequestStatus {
        RequestOutcome.status(from: try await client.json("GET", GraphURL.make("\(Self.requests)/\(id)"))["status"] as? String)
    }

    public func cancel(request id: String) async throws {
        _ = try await client.json("POST", GraphURL.make("\(Self.requests)/\(id)/cancel"))
    }
}

extension GraphURL {
    static func request(_ item: [String: Any], source: RoleSource, roleName: String, scopeName: String) -> RemoteRequest? {
        guard let id = item["id"] as? String else { return nil }
        return RemoteRequest(id: id, source: source, roleName: roleName, scopeName: scopeName,
                             status: RequestOutcome.status(from: item["status"] as? String),
                             createdAt: PIMDates.parse(item["createdDateTime"]), justification: item["justification"] as? String)
    }
}
