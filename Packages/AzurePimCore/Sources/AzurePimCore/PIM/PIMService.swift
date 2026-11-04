import Foundation

/// Result of refreshing one account: per-source data or error (one failing source never hides the others).
public struct AccountSnapshot: Sendable {
    public var eligibilities: [RemoteEligibility] = []
    public var assignments: [RemoteAssignment] = []
    public var errors: [RoleSource: Error] = [:]
    public var fetchedAt = Date.now

    public init() {}

    /// Active PIM activations linked to their eligibility (link id first, then role + scope).
    public func eligibility(for assignment: RemoteAssignment) -> RemoteEligibility? {
        if let link = assignment.linkedEligibilityId?.lowercased(),
           let match = eligibilities.first(where: { $0.id.lowercased() == link }) {
            return match
        }
        return eligibilities.first { $0.matchKey == assignment.matchKey }
    }
}

/// Fetches the three sources of one account concurrently (TRD › Architecture).
public struct PIMService: Sendable {
    public let sources: [any PIMSource]

    public init(sources: [any PIMSource]) {
        self.sources = sources
    }

    /// Builds the sources available for a token provider. Directory sources only when `directory` is true
    /// (MSAL account with consent): the Azure CLI cannot obtain Graph PIM scopes.
    public static func sources(token: @escaping @Sendable (Resource, String?) async throws -> AccessToken,
                               directory: Bool, transport: HTTPTransport = URLSessionTransport()) -> [any PIMSource] {
        let arm = AuthorizedClient(transport: transport) { claims in try await token(.arm, claims) }
        var list: [any PIMSource] = [ARMClient(client: arm)]
        if directory {
            let graph = AuthorizedClient(transport: transport) { claims in try await token(.graph, claims) }
            list += [EntraRoleClient(client: graph), PIMGroupClient(client: graph)] as [any PIMSource]
        }
        return list
    }

    public func refresh() async -> AccountSnapshot {
        await withTaskGroup(of: (RoleSource, Result<([RemoteEligibility], [RemoteAssignment]), Error>).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        async let eligible = source.eligibilities()
                        async let active = source.assignments()
                        return (source.source, .success(try await (eligible, active)))
                    } catch {
                        return (source.source, .failure(error))
                    }
                }
            }
            var snapshot = AccountSnapshot()
            for await (kind, result) in group {
                switch result {
                case .success(let (eligible, active)):
                    snapshot.eligibilities += eligible
                    snapshot.assignments += active
                case .failure(let error):
                    snapshot.errors[kind] = error
                }
            }
            snapshot.eligibilities.sort {
                ($0.source.rawValue, $0.roleName, $0.scopeName) < ($1.source.rawValue, $1.roleName, $1.scopeName)
            }
            snapshot.assignments.sort { ($0.endAt ?? .distantFuture) < ($1.endAt ?? .distantFuture) }
            return snapshot
        }
    }

    public func source(for kind: RoleSource) -> (any PIMSource)? {
        sources.first { $0.source == kind }
    }
}
