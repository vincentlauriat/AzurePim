import Foundation
import Testing
@testable import AzurePimCore

/// Transport returning queued responses and recording requests.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var json: Any?
        var headers: [String: String] = [:]
    }

    var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let reply = replies.isEmpty ? Reply(status: 500, json: ["error": ["message": "no reply"]]) : replies.removeFirst()
        let data = try reply.json.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (data, response)
    }

    func body(_ index: Int) -> [String: Any] {
        guard let data = requests[index].httpBody else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

final class ClaimsRecorder: @unchecked Sendable {
    var seen: [String?] = []
}

func client(_ transport: FakeTransport, recorder: ClaimsRecorder = ClaimsRecorder()) -> AuthorizedClient {
    AuthorizedClient(transport: transport, sleep: { _ in }, token: { claims in
        recorder.seen.append(claims)
        return AccessToken(value: "tok", expiresOn: .distantFuture)
    })
}

let rootScope = "/providers/Microsoft.Management/managementGroups/t1"
let readerDef = "/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"

func armEligibility(_ schedule: String, scope: String = rootScope, member: String = "Direct") -> [String: Any] {
    ["name": UUID().uuidString, "properties": [
        "roleEligibilityScheduleId": "\(scope)/providers/Microsoft.Authorization/roleEligibilitySchedules/\(schedule)",
        "roleDefinitionId": readerDef, "scope": scope, "memberType": member,
        "expandedProperties": ["roleDefinition": ["displayName": "Reader"],
                               "scope": ["displayName": "Tenant Root Group", "type": "managementgroup"]]]]
}

struct ARMClientTests {
    @Test func parsesAndDeduplicatesEligibilities() async throws {
        let items = [armEligibility("s1"), armEligibility("s1"),
                     armEligibility("s2", scope: "/subscriptions/x/resourceGroups/rg", member: "Group")]
        let transport = FakeTransport([.init(status: 200, json: ["value": items])])
        let list = try await ARMClient(client: client(transport)).eligibilities()
        #expect(list.count == 2)
        #expect(list[0].roleName == "Reader")
        #expect(list[0].scopeName == "Tenant Root Group")
        #expect(list[1].memberType == .group)
        let url = try #require(transport.requests.first?.url?.absoluteString)
        #expect(url.contains("roleEligibilityScheduleInstances"))
        #expect(url.contains("api-version=2020-10-01"))
        #expect(url.contains("asTarget()"))
    }

    @Test func followsNextLink() async throws {
        let transport = FakeTransport([
            .init(status: 200, json: ["value": [armEligibility("s1")], "nextLink": "https://management.azure.com/next?page=2"]),
            .init(status: 200, json: ["value": [armEligibility("s2")]])
        ])
        #expect(try await ARMClient(client: client(transport)).eligibilities().count == 2)
        #expect(transport.requests[1].url?.absoluteString == "https://management.azure.com/next?page=2")
    }

    @Test func parsesAssignmentsWithAzureDates() async throws {
        let item: [String: Any] = ["name": "inst-1", "properties": [
            "roleDefinitionId": readerDef, "scope": rootScope, "assignmentType": "Activated",
            "startDateTime": "2026-11-03T16:47:41.6097598Z", "endDateTime": "2026-11-04T00:47:41.6097598Z",
            "linkedRoleEligibilityScheduleId": "\(rootScope)/providers/Microsoft.Authorization/roleEligibilitySchedules/s1",
            "expandedProperties": ["roleDefinition": ["displayName": "Reader"], "scope": ["displayName": "Tenant Root Group"]]]]
        let list = try await ARMClient(client: client(FakeTransport([.init(status: 200, json: ["value": [item]])]))).assignments()
        let assignment = try #require(list.first)
        #expect(assignment.type == .activated)
        let end = try #require(assignment.endAt)
        #expect(end.timeIntervalSince(assignment.startAt) == 8 * 3600)
    }

    @Test func readsPolicyRules() async throws {
        let rules: [[String: Any]] = [
            ["id": "Expiration_EndUser_Assignment", "maximumDuration": "PT8H", "isExpirationRequired": true],
            ["id": "Enablement_EndUser_Assignment", "enabledRules": ["Justification", "Ticketing", "MultiFactorAuthentication"]],
            ["id": "Approval_EndUser_Assignment", "setting": ["isApprovalRequired": true]]
        ]
        let transport = FakeTransport([.init(status: 200, json: ["value": [["properties": ["effectiveRules": rules]]]])])
        let listing = FakeTransport([.init(status: 200, json: ["value": [armEligibility("s1")]])])
        let eligibility = try #require(try await ARMClient(client: client(listing)).eligibilities().first)
        let policy = try await ARMClient(client: client(transport)).policy(for: eligibility)
        #expect(policy == RolePolicy(maxDuration: "PT8H", requiresJustification: true, requiresTicket: true,
                                     requiresMFA: true, requiresApproval: true))
        #expect(transport.requests[0].url?.absoluteString.contains("roleManagementPolicyAssignments") == true)
    }

    @Test func activationRequestBody() async throws {
        let transport = FakeTransport([.init(status: 201, json: ["name": "req-1", "properties": ["status": "Provisioned"]])])
        let eligibility = RemoteEligibility(id: "\(rootScope)/providers/Microsoft.Authorization/roleEligibilitySchedules/s1",
                                            source: .azureResource, roleDefinitionId: readerDef, roleName: "Reader",
                                            scope: rootScope, scopeName: "Tenant Root Group", scopeType: "managementgroup",
                                            memberType: .direct)
        let outcome = try await ARMClient(client: client(transport)).activate(
            eligibility, principalId: "oid", input: ActivationInput(duration: "PT4H", justification: "deploy", ticketNumber: "INC1"))
        #expect(outcome == RequestOutcome(requestId: "req-1", status: .provisioned))
        #expect(transport.requests[0].httpMethod == "PUT")
        let path = try #require(transport.requests[0].url?.path)
        #expect(path.hasPrefix("\(rootScope)/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/"))
        let props = try #require(transport.body(0)["properties"] as? [String: Any])
        #expect(props["requestType"] as? String == "SelfActivate")
        #expect(props["principalId"] as? String == "oid")
        #expect(props["linkedRoleEligibilityScheduleId"] as? String == eligibility.id)
        #expect(((props["scheduleInfo"] as? [String: Any])?["expiration"] as? [String: Any])?["duration"] as? String == "PT4H")
        #expect((props["ticketInfo"] as? [String: Any])?["ticketNumber"] as? String == "INC1")
    }

    @Test func deactivationIsSelfDeactivate() async throws {
        let transport = FakeTransport([.init(status: 201, json: ["name": "r", "properties": ["status": "Revoked"]])])
        let eligibility = RemoteEligibility(id: "e", source: .azureResource, roleDefinitionId: readerDef, roleName: "Reader",
                                            scope: rootScope, scopeName: "T", scopeType: "managementgroup", memberType: .direct)
        let outcome = try await ARMClient(client: client(transport)).deactivate(eligibility, principalId: "oid")
        #expect(outcome.status == .canceled)
        #expect((transport.body(0)["properties"] as? [String: Any])?["requestType"] as? String == "SelfDeactivate")
    }
}

struct AuthorizedClientTests {
    @Test func retriesOn429ThenSucceeds() async throws {
        let transport = FakeTransport([.init(status: 429, json: nil, headers: ["Retry-After": "1"]),
                                       .init(status: 503, json: nil),
                                       .init(status: 200, json: ["ok": true])])
        let result = try await client(transport).json("GET", URL(string: "https://x.test")!)
        #expect(result["ok"] as? Bool == true)
        #expect(transport.requests.count == 3)
    }

    @Test func givesUpAfterMaxRetries() async {
        let transport = FakeTransport(Array(repeating: .init(status: 429, json: nil), count: 5))
        await #expect(throws: PIMError.throttled(retryAfter: nil)) {
            try await client(transport).json("GET", URL(string: "https://x.test")!)
        }
        #expect(transport.requests.count == 4)
    }

    @Test func retriesOnceWithClaimsChallenge() async throws {
        let claims = #"{"access_token":{"acrs":{"essential":true,"value":"c1"}}}"#
        let encoded = Data(claims.utf8).base64EncodedString()
        let transport = FakeTransport([
            .init(status: 401, json: ["error": ["code": "InvalidAuthenticationToken"]],
                  headers: ["WWW-Authenticate": #"Bearer authorization_uri="x", error="insufficient_claims", claims="\#(encoded)""#]),
            .init(status: 200, json: ["ok": true])
        ])
        let recorder = ClaimsRecorder()
        _ = try await client(transport, recorder: recorder).json("GET", URL(string: "https://x.test")!)
        #expect(recorder.seen == [nil, claims])
    }

    @Test func mapsARMErrorMessage() async {
        let transport = FakeTransport([.init(status: 400, json: ["error": ["code": "RoleAssignmentExists",
                                                                           "message": "The Role assignment already exists."]])])
        await #expect(throws: PIMError.http(status: 400, code: "RoleAssignmentExists", message: "The Role assignment already exists.")) {
            try await client(transport).json("PUT", URL(string: "https://x.test")!)
        }
    }

    @Test func mapsGraphConsentErrorToConsentRequired() async {
        let inner = #"{"errorCode":"PermissionScopeNotGranted","message":"Authorization failed due to missing permission scope"}"#
        let transport = FakeTransport([.init(status: 403, json: ["error": ["code": "UnknownError", "message": inner]])])
        await #expect(throws: TokenError.consentRequired) {
            try await client(transport).json("GET", URL(string: "https://x.test")!)
        }
    }
}

struct GraphClientTests {
    @Test func entraEligibilitiesAndActivation() async throws {
        let transport = FakeTransport([
            .init(status: 200, json: ["value": [["id": "i1", "roleEligibilityScheduleId": "sch1", "roleDefinitionId": "def1",
                                                 "directoryScopeId": "/", "memberType": "Direct",
                                                 "roleDefinition": ["displayName": "Application Administrator"]]]]),
            .init(status: 201, json: ["id": "req1", "status": "PendingApproval"])
        ])
        let entra = EntraRoleClient(client: client(transport))
        let eligibility = try #require(try await entra.eligibilities().first)
        #expect(eligibility.roleName == "Application Administrator")
        #expect(eligibility.scopeName == "Directory")
        let input = ActivationInput(duration: "PT1H", justification: "j")
        let outcome = try await entra.activate(eligibility, principalId: "oid", input: input)
        #expect(outcome.status == .pendingApproval)
        let body = transport.body(1)
        #expect(body["action"] as? String == "selfActivate")
        #expect(body["directoryScopeId"] as? String == "/")
        #expect(transport.requests[0].url?.absoluteString.contains("filterByCurrentUser(on='principal')") == true)
    }

    @Test func groupActivationUsesGroupAndAccessId() async throws {
        let transport = FakeTransport([
            .init(status: 200, json: ["value": [["id": "i", "eligibilityScheduleId": "g-sch", "groupId": "g1", "accessId": "member",
                                                 "group": ["displayName": "SG-RBAC-PAGES"]]]]),
            .init(status: 201, json: ["id": "r", "status": "Provisioned"])
        ])
        let groups = PIMGroupClient(client: client(transport))
        let eligibility = try #require(try await groups.eligibilities().first)
        #expect(eligibility.scopeName == "SG-RBAC-PAGES")
        _ = try await groups.activate(eligibility, principalId: "oid", input: ActivationInput(duration: "PT2H", justification: "j"))
        #expect(transport.body(1)["groupId"] as? String == "g1")
        #expect(transport.body(1)["accessId"] as? String == "member")
    }
}

struct PIMServiceTests {
    struct StubSource: PIMSource {
        let source: RoleSource
        var eligible: [RemoteEligibility] = []
        var active: [RemoteAssignment] = []
        var failure: PIMError?

        func eligibilities() async throws -> [RemoteEligibility] {
            if let failure { throw failure }
            return eligible
        }
        func assignments() async throws -> [RemoteAssignment] { active }
        func policy(for eligibility: RemoteEligibility) async throws -> RolePolicy { RolePolicy() }
        func activate(_ eligibility: RemoteEligibility, principalId: String, input: ActivationInput) async throws -> RequestOutcome {
            RequestOutcome(requestId: nil, status: .provisioned)
        }
        func deactivate(_ eligibility: RemoteEligibility, principalId: String) async throws -> RequestOutcome {
            RequestOutcome(requestId: nil, status: .canceled)
        }
    }

    @Test func oneFailingSourceDoesNotHideOthers() async {
        let eligibility = RemoteEligibility(id: "E1", source: .azureResource, roleDefinitionId: "d", roleName: "Reader",
                                            scope: "/s", scopeName: "S", scopeType: "subscription", memberType: .direct)
        let active = RemoteAssignment(id: "a", source: .azureResource, roleDefinitionId: "D", roleName: "Reader", scope: "/S",
                                      scopeName: "S", type: .activated, startAt: .now, endAt: nil, linkedEligibilityId: nil)
        let service = PIMService(sources: [
            StubSource(source: .azureResource, eligible: [eligibility], active: [active]),
            StubSource(source: .entraRole, failure: .http(status: 403, code: nil, message: "denied"))
        ])
        let snapshot = await service.refresh()
        #expect(snapshot.eligibilities.count == 1)
        #expect(snapshot.errors[.entraRole] != nil)
        #expect(snapshot.eligibility(for: active)?.id == "E1")  // matched case-insensitively on role + scope
    }
}

/// Live read-only check against Azure with the Azure CLI session. Opt-in: AZUREPIM_LIVE=1
struct LiveARMTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AZUREPIM_LIVE"] == "1"))
    func liveEligibilitiesAndPolicy() async throws {
        let provider = AzureCLITokenProvider()
        let sources = PIMService.sources(token: { resource, claims in
            try await provider.token(for: resource, tenantId: nil, claims: claims)
        }, directory: false)
        let snapshot = await PIMService(sources: sources).refresh()
        #expect(snapshot.errors.isEmpty)
        for eligibility in snapshot.eligibilities {
            let policy = try await sources[0].policy(for: eligibility)
            print("live:", eligibility.roleName, "@", eligibility.scopeName, eligibility.memberType, policy)
        }
        print("live active:", snapshot.assignments.map { "\($0.roleName) @ \($0.scopeName) \($0.type)" })
        #expect(!snapshot.eligibilities.isEmpty)
    }
}
