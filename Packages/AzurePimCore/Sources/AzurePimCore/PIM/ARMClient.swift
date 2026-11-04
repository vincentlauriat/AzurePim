import Foundation

/// Azure resource roles through Azure Resource Manager `Microsoft.Authorization` (api-version 2020-10-01).
public struct ARMClient: PIMSource {
    public let source = RoleSource.azureResource
    static let base = "https://management.azure.com"
    static let apiVersion = "2020-10-01"

    let client: AuthorizedClient

    public init(client: AuthorizedClient) {
        self.client = client
    }

    public func eligibilities() async throws -> [RemoteEligibility] {
        let items = try await client.list(Self.url("/providers/Microsoft.Authorization/roleEligibilityScheduleInstances",
                                                   filter: "asTarget()"))
        var seen = Set<String>()
        return items.compactMap { item -> RemoteEligibility? in
            guard let props = item["properties"] as? [String: Any],
                  let scheduleId = props["roleEligibilityScheduleId"] as? String,
                  seen.insert(scheduleId.lowercased()).inserted,
                  let roleDefinitionId = props["roleDefinitionId"] as? String,
                  let scope = props["scope"] as? String else { return nil }
            let expanded = props["expandedProperties"] as? [String: Any]
            let role = expanded?["roleDefinition"] as? [String: Any]
            let scopeInfo = expanded?["scope"] as? [String: Any]
            return RemoteEligibility(id: scheduleId, source: .azureResource, roleDefinitionId: roleDefinitionId,
                                     roleName: role?["displayName"] as? String ?? "Role",
                                     scope: scope, scopeName: scopeInfo?["displayName"] as? String ?? scope,
                                     scopeType: scopeInfo?["type"] as? String ?? "resource",
                                     memberType: Self.memberType(props["memberType"]))
        }
    }

    public func assignments() async throws -> [RemoteAssignment] {
        let items = try await client.list(Self.url("/providers/Microsoft.Authorization/roleAssignmentScheduleInstances",
                                                   filter: "asTarget()"))
        var seen = Set<String>()
        return items.compactMap { item -> RemoteAssignment? in
            guard let props = item["properties"] as? [String: Any],
                  let roleDefinitionId = props["roleDefinitionId"] as? String,
                  let scope = props["scope"] as? String,
                  let start = PIMDates.parse(props["startDateTime"]) else { return nil }
            let id = (item["name"] as? String) ?? (item["id"] as? String) ?? UUID().uuidString
            guard seen.insert("\(roleDefinitionId.lowercased())|\(scope.lowercased())").inserted else { return nil }
            let expanded = props["expandedProperties"] as? [String: Any]
            let role = expanded?["roleDefinition"] as? [String: Any]
            let scopeInfo = expanded?["scope"] as? [String: Any]
            let type: AssignmentType = (props["assignmentType"] as? String) == "Activated" ? .activated : .assigned
            return RemoteAssignment(id: id, source: .azureResource, roleDefinitionId: roleDefinitionId,
                                    roleName: role?["displayName"] as? String ?? "Role", scope: scope,
                                    scopeName: scopeInfo?["displayName"] as? String ?? scope, type: type,
                                    startAt: start, endAt: PIMDates.parse(props["endDateTime"]),
                                    linkedEligibilityId: props["linkedRoleEligibilityScheduleId"] as? String)
        }
    }

    public func policy(for eligibility: RemoteEligibility) async throws -> RolePolicy {
        let items = try await client.list(Self.url(
            "\(eligibility.scope)/providers/Microsoft.Authorization/roleManagementPolicyAssignments",
            filter: "roleDefinitionId eq '\(eligibility.roleDefinitionId)'"))
        let rules = (items.first?["properties"] as? [String: Any])?["effectiveRules"] as? [[String: Any]] ?? []
        return RolePolicy(rules: rules)
    }

    public func activate(_ eligibility: RemoteEligibility, principalId: String,
                         input: ActivationInput) async throws -> RequestOutcome {
        var properties: [String: Any] = [
            "principalId": principalId,
            "roleDefinitionId": eligibility.roleDefinitionId,
            "requestType": "SelfActivate",
            "linkedRoleEligibilityScheduleId": eligibility.id,
            "justification": input.justification,
            "scheduleInfo": ["expiration": ["type": "AfterDuration", "duration": input.duration]]
        ]
        if let ticket = input.ticketNumber, !ticket.isEmpty {
            properties["ticketInfo"] = ["ticketNumber": ticket, "ticketSystem": input.ticketSystem ?? "AzurePim"]
        }
        return try await send(eligibility, properties)
    }

    public func deactivate(_ eligibility: RemoteEligibility, principalId: String) async throws -> RequestOutcome {
        try await send(eligibility, ["principalId": principalId, "roleDefinitionId": eligibility.roleDefinitionId,
                                     "requestType": "SelfDeactivate"])
    }

    private func send(_ eligibility: RemoteEligibility, _ properties: [String: Any]) async throws -> RequestOutcome {
        let name = UUID().uuidString.lowercased()
        let url = Self.url("\(eligibility.scope)/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/\(name)")
        let response = try await client.json("PUT", url, body: ["properties": properties])
        let props = response["properties"] as? [String: Any]
        return RequestOutcome(requestId: response["name"] as? String ?? name,
                              status: RequestOutcome.status(from: props?["status"] as? String))
    }

    static func url(_ path: String, filter: String? = nil) -> URL {
        var components = URLComponents(string: base)!
        components.percentEncodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var query = [URLQueryItem(name: "api-version", value: apiVersion)]
        if let filter { query.append(URLQueryItem(name: "$filter", value: filter)) }
        components.queryItems = query
        return components.url!
    }

    static func memberType(_ raw: Any?) -> MemberType {
        switch (raw as? String)?.lowercased() {
        case "group": .group
        case "inherited": .inherited
        default: .direct
        }
    }
}
