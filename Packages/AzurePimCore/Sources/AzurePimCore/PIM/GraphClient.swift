import Foundation

/// Entra directory roles through Microsoft Graph `roleManagement/directory` (v1.0). Needs admin-consented scopes.
public struct EntraRoleClient: PIMSource {
    public let source = RoleSource.entraRole
    static let base = "https://graph.microsoft.com/v1.0"
    let client: AuthorizedClient

    public init(client: AuthorizedClient) {
        self.client = client
    }

    public func eligibilities() async throws -> [RemoteEligibility] {
        let items = try await client.list(GraphURL.make(
            "/roleManagement/directory/roleEligibilityScheduleInstances/filterByCurrentUser(on='principal')",
            expand: "roleDefinition"))
        var seen = Set<String>()
        return items.compactMap { item -> RemoteEligibility? in
            guard let scheduleId = (item["roleEligibilityScheduleId"] as? String) ?? (item["id"] as? String),
                  seen.insert(scheduleId).inserted,
                  let roleDefinitionId = item["roleDefinitionId"] as? String else { return nil }
            let scope = item["directoryScopeId"] as? String ?? "/"
            return RemoteEligibility(id: scheduleId, source: .entraRole, roleDefinitionId: roleDefinitionId,
                                     roleName: (item["roleDefinition"] as? [String: Any])?["displayName"] as? String ?? "Entra role",
                                     scope: scope, scopeName: scope == "/" ? "Directory" : scope, scopeType: "directory",
                                     memberType: ARMClient.memberType(item["memberType"]))
        }
    }

    public func assignments() async throws -> [RemoteAssignment] {
        let items = try await client.list(GraphURL.make(
            "/roleManagement/directory/roleAssignmentScheduleInstances/filterByCurrentUser(on='principal')",
            expand: "roleDefinition"))
        return items.compactMap { item -> RemoteAssignment? in
            guard let id = item["id"] as? String, let roleDefinitionId = item["roleDefinitionId"] as? String else { return nil }
            let scope = item["directoryScopeId"] as? String ?? "/"
            return RemoteAssignment(id: id, source: .entraRole, roleDefinitionId: roleDefinitionId,
                                    roleName: (item["roleDefinition"] as? [String: Any])?["displayName"] as? String ?? "Entra role",
                                    scope: scope, scopeName: scope == "/" ? "Directory" : scope,
                                    type: (item["assignmentType"] as? String) == "Activated" ? .activated : .assigned,
                                    startAt: PIMDates.parse(item["startDateTime"]) ?? .now,
                                    endAt: PIMDates.parse(item["endDateTime"]), linkedEligibilityId: nil)
        }
    }

    public func policy(for eligibility: RemoteEligibility) async throws -> RolePolicy {
        try await GraphURL.policy(client, scopeId: "/", scopeType: "DirectoryRole", roleDefinitionId: eligibility.roleDefinitionId)
    }

    public func activate(_ eligibility: RemoteEligibility, principalId: String,
                         input: ActivationInput) async throws -> RequestOutcome {
        var body = request(eligibility, principalId: principalId, action: "selfActivate")
        body["justification"] = input.justification
        body["scheduleInfo"] = GraphURL.schedule(input.duration)
        if let ticket = input.ticketNumber, !ticket.isEmpty {
            body["ticketInfo"] = ["ticketNumber": ticket, "ticketSystem": input.ticketSystem ?? "AzurePim"]
        }
        return try await GraphURL.outcome(client.json("POST", GraphURL.make("/roleManagement/directory/roleAssignmentScheduleRequests"),
                                                      body: body))
    }

    public func deactivate(_ eligibility: RemoteEligibility, principalId: String) async throws -> RequestOutcome {
        try await GraphURL.outcome(client.json("POST", GraphURL.make("/roleManagement/directory/roleAssignmentScheduleRequests"),
                                               body: request(eligibility, principalId: principalId, action: "selfDeactivate")))
    }

    private func request(_ eligibility: RemoteEligibility, principalId: String, action: String) -> [String: Any] {
        ["action": action, "principalId": principalId, "roleDefinitionId": eligibility.roleDefinitionId,
         "directoryScopeId": eligibility.scope]
    }
}

/// PIM for Groups through Microsoft Graph `identityGovernance/privilegedAccess/group` (v1.0).
public struct PIMGroupClient: PIMSource {
    public let source = RoleSource.pimGroup
    let client: AuthorizedClient

    public init(client: AuthorizedClient) {
        self.client = client
    }

    public func eligibilities() async throws -> [RemoteEligibility] {
        let items = try await client.list(GraphURL.make(
            "/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances/filterByCurrentUser(on='principal')",
            expand: "group"))
        var seen = Set<String>()
        return items.compactMap { item -> RemoteEligibility? in
            guard let scheduleId = (item["eligibilityScheduleId"] as? String) ?? (item["id"] as? String),
                  seen.insert(scheduleId).inserted,
                  let groupId = item["groupId"] as? String else { return nil }
            let access = item["accessId"] as? String ?? "member"
            let groupName = (item["group"] as? [String: Any])?["displayName"] as? String ?? groupId
            return RemoteEligibility(id: scheduleId, source: .pimGroup, roleDefinitionId: access,
                                     roleName: access == "owner" ? "Owner" : "Member", scope: groupId,
                                     scopeName: groupName, scopeType: "group", memberType: ARMClient.memberType(item["memberType"]))
        }
    }

    public func assignments() async throws -> [RemoteAssignment] {
        let items = try await client.list(GraphURL.make(
            "/identityGovernance/privilegedAccess/group/assignmentScheduleInstances/filterByCurrentUser(on='principal')",
            expand: "group"))
        return items.compactMap { item -> RemoteAssignment? in
            guard let id = item["id"] as? String, let groupId = item["groupId"] as? String else { return nil }
            let access = item["accessId"] as? String ?? "member"
            return RemoteAssignment(id: id, source: .pimGroup, roleDefinitionId: access,
                                    roleName: access == "owner" ? "Owner" : "Member", scope: groupId,
                                    scopeName: (item["group"] as? [String: Any])?["displayName"] as? String ?? groupId,
                                    type: (item["assignmentType"] as? String) == "Activated" ? .activated : .assigned,
                                    startAt: PIMDates.parse(item["startDateTime"]) ?? .now,
                                    endAt: PIMDates.parse(item["endDateTime"]), linkedEligibilityId: nil)
        }
    }

    public func policy(for eligibility: RemoteEligibility) async throws -> RolePolicy {
        try await GraphURL.policy(client, scopeId: eligibility.scope, scopeType: "Group",
                                  roleDefinitionId: eligibility.roleDefinitionId)
    }

    public func activate(_ eligibility: RemoteEligibility, principalId: String,
                         input: ActivationInput) async throws -> RequestOutcome {
        var body = request(eligibility, principalId: principalId, action: "selfActivate")
        body["justification"] = input.justification
        body["scheduleInfo"] = GraphURL.schedule(input.duration)
        if let ticket = input.ticketNumber, !ticket.isEmpty {
            body["ticketInfo"] = ["ticketNumber": ticket, "ticketSystem": input.ticketSystem ?? "AzurePim"]
        }
        return try await GraphURL.outcome(client.json(
            "POST", GraphURL.make("/identityGovernance/privilegedAccess/group/assignmentScheduleRequests"), body: body))
    }

    public func deactivate(_ eligibility: RemoteEligibility, principalId: String) async throws -> RequestOutcome {
        try await GraphURL.outcome(client.json(
            "POST", GraphURL.make("/identityGovernance/privilegedAccess/group/assignmentScheduleRequests"),
            body: request(eligibility, principalId: principalId, action: "selfDeactivate")))
    }

    private func request(_ eligibility: RemoteEligibility, principalId: String, action: String) -> [String: Any] {
        ["action": action, "principalId": principalId, "groupId": eligibility.scope, "accessId": eligibility.roleDefinitionId]
    }
}

enum GraphURL {
    static func make(_ path: String, expand: String? = nil, filter: String? = nil) -> URL {
        var components = URLComponents(string: EntraRoleClient.base + path)!
        var query: [URLQueryItem] = []
        if let expand { query.append(URLQueryItem(name: "$expand", value: expand)) }
        if let filter { query.append(URLQueryItem(name: "$filter", value: filter)) }
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    static func schedule(_ duration: String) -> [String: Any] {
        ["startDateTime": PIMDates.plain.string(from: .now),
         "expiration": ["type": "afterDuration", "duration": duration]]
    }

    static func outcome(_ response: [String: Any]) -> RequestOutcome {
        RequestOutcome(requestId: response["id"] as? String, status: RequestOutcome.status(from: response["status"] as? String))
    }

    static func policy(_ client: AuthorizedClient, scopeId: String, scopeType: String,
                       roleDefinitionId: String) async throws -> RolePolicy {
        let items = try await client.list(make(
            "/policies/roleManagementPolicyAssignments",
            expand: "policy($expand=rules)",
            filter: "scopeId eq '\(scopeId)' and scopeType eq '\(scopeType)' and roleDefinitionId eq '\(roleDefinitionId)'"))
        let rules = ((items.first?["policy"] as? [String: Any])?["rules"] as? [[String: Any]]) ?? []
        return RolePolicy(rules: rules)
    }
}
