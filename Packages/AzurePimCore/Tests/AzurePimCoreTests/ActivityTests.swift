import Foundation
import SwiftData
import Testing
@testable import AzurePimCore

@MainActor
struct ActivityTests {
    private func record(_ context: ModelContext, account: Account, opened: Date?, completed: Date?,
                        status: RequestStatus = .provisioned, action: ActivationAction = .activate,
                        sent: Date = .now) -> ActivationRecord {
        let record = ActivationRecord(account: account, eligibleRoleId: "r", roleName: "Reader", scopeName: "Root",
                                      source: .azureResource, action: action, panelOpenedAt: opened)
        record.completedAt = completed
        record.status = status
        record.sentAt = sent
        context.insert(record)
        return record
    }

    @Test func medianIgnoresRecordsWithoutPanelOpenAndFailures() throws {
        let container = try AzurePimStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let account = Account(mode: .azureCLI, upn: "a@b", objectId: "o", tenantId: "t")
        context.insert(account)
        let start = Date(timeIntervalSince1970: 1_000)
        let records = [
            record(context, account: account, opened: start, completed: start.addingTimeInterval(4)),
            record(context, account: account, opened: start, completed: start.addingTimeInterval(8)),
            record(context, account: account, opened: start, completed: start.addingTimeInterval(12)),
            record(context, account: account, opened: nil, completed: start.addingTimeInterval(500)),       // deep link
            record(context, account: account, opened: start, completed: nil, status: .failed),
            record(context, account: account, opened: start, completed: start.addingTimeInterval(900), action: .deactivate)
        ]
        #expect(ActivationStats.medianTimeToActivation(records) == 8)
        #expect(ActivationStats.median([4, 8, 12, 20]) == 10)
        #expect(ActivationStats.median([]) == nil)
    }

    @Test func retentionKeepsRecentAndPending() throws {
        let container = try AzurePimStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let account = Account(mode: .azureCLI, upn: "a@b", objectId: "o", tenantId: "t")
        context.insert(account)
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let old = record(context, account: account, opened: nil, completed: nil, sent: now.addingTimeInterval(-91 * 86_400))
        let oldPending = record(context, account: account, opened: nil, completed: nil, status: .pendingApproval,
                                sent: now.addingTimeInterval(-200 * 86_400))
        let recent = record(context, account: account, opened: nil, completed: nil, sent: now.addingTimeInterval(-89 * 86_400))
        let expired = Retention.expired([old, oldPending, recent], days: 90, now: now)
        #expect(expired.map(\.id) == [old.id])
    }

    @Test func csvEscapesQuotesCommasAndFormulas() {
        #expect(HistoryCSV.escape("plain") == "plain")
        #expect(HistoryCSV.escape("a,b") == "\"a,b\"")
        #expect(HistoryCSV.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(HistoryCSV.escape("line\nbreak") == "\"line\nbreak\"")
        #expect(HistoryCSV.escape("=HYPERLINK(1)") == "'=HYPERLINK(1)")
        #expect(HistoryCSV.escape("\tcmd") == "'\tcmd")
    }

    @Test func csvHasOneLinePerRecord() throws {
        let container = try AzurePimStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let account = Account(mode: .azureCLI, upn: "a@b", objectId: "o", tenantId: "t")
        context.insert(account)
        let one = record(context, account: account, opened: nil, completed: nil)
        one.justification = "deploy, prod"
        let csv = HistoryCSV.make([one, record(context, account: account, opened: nil, completed: nil)])
        let lines = csv.split(separator: "\r\n")
        #expect(lines.count == 3)
        #expect(lines[1].contains("\"deploy, prod\""))
        #expect(lines[1].contains("a@b"))
    }

    @Test func favoriteSummary() {
        #expect(FavoriteRun.summary([.init(roleName: "Reader", status: .provisioned),
                                     .init(roleName: "Contributor", status: .provisioned)]) == "2 of 2 activated")
        let mixed = FavoriteRun.summary([.init(roleName: "Reader", status: .provisioned),
                                         .init(roleName: "Owner", status: .pendingApproval),
                                         .init(roleName: "Contributor", status: nil, error: "Forbidden")])
        #expect(mixed == "1 of 3 activated, 1 pending approval — Contributor: Forbidden")
    }

    @Test func favoriteInputCapsDurationAndNeedsJustification() {
        let policy = RolePolicy(maxDuration: "PT4H", requiresJustification: true)
        let item = FavoriteItem(eligibleRoleId: "r", duration: "PT8H")
        #expect(FavoriteRun.input(for: item, policy: policy, lastJustification: nil) == .failure(.empty("justification")))
        let input = try? FavoriteRun.input(for: item, policy: policy, lastJustification: "deploy").get()
        #expect(input == ActivationInput(duration: "PT4H", justification: "deploy"))
        #expect(FavoriteRun.input(for: item, policy: RolePolicy(requiresTicket: true), lastJustification: "x")
            == .failure(.empty("ticket")))
    }

    @Test func extendPlan() {
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(3600)
        let open = RolePolicy(maxDuration: "PT8H")
        #expect(ExtendPlan.decide(policy: open, lastJustification: "deploy", lastDuration: "PT2H", activeSince: start, now: now)
            == .reactivate(ActivationInput(duration: "PT2H", justification: "deploy")))
        #expect(ExtendPlan.decide(policy: RolePolicy(maxDuration: "PT1H"), lastJustification: "d", lastDuration: "PT8H",
                                  activeSince: start, now: now) == .reactivate(ActivationInput(duration: "PT1H", justification: "d")))
        for policy in [RolePolicy(requiresApproval: true), RolePolicy(requiresTicket: true), RolePolicy(requiresMFA: true)] {
            guard case .blocked = ExtendPlan.decide(policy: policy, lastJustification: "d", lastDuration: nil,
                                                    activeSince: start, now: now) else {
                Issue.record("expected blocked for \(policy)")
                continue
            }
        }
        guard case .blocked = ExtendPlan.decide(policy: open, lastJustification: nil, lastDuration: nil, activeSince: start, now: now)
        else { Issue.record("missing justification must block"); return }
        guard case .blocked = ExtendPlan.decide(policy: open, lastJustification: "d", lastDuration: nil, activeSince: start,
                                                now: start.addingTimeInterval(60))
        else { Issue.record("5-minute rule must block"); return }
    }

    @Test func approvedStatusesCountAsProvisioned() {
        #expect(RequestOutcome.status(from: "AdminApproved") == .provisioned)
        #expect(RequestOutcome.status(from: "ScheduleCreated") == .provisioned)
        #expect(RequestOutcome.status(from: "PendingApproval") == .pendingApproval)
    }

    @Test func alreadyActiveErrorDetection() {
        #expect(ExtendPlan.isAlreadyActive(PIMError.http(status: 400, code: "RoleAssignmentExists", message: "x")))
        #expect(ExtendPlan.isAlreadyActive(PIMError.http(status: 409, code: nil, message: "The Role assignment already exists.")))
        #expect(!ExtendPlan.isAlreadyActive(PIMError.http(status: 403, code: "AuthorizationFailed", message: "denied")))
        #expect(!ExtendPlan.isAlreadyActive(TokenError.consentRequired))
    }
}

struct PendingRequestTests {
    @Test func armListsOnlyPendingRequestsAsTarget() async throws {
        let id = "\(rootScope)/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/req-1"
        let items: [[String: Any]] = [
            ["id": id, "properties": ["status": "PendingApproval", "scope": rootScope, "createdOn": "2026-11-04T08:00:00.1234567Z",
                                      "justification": "deploy",
                                      "expandedProperties": ["roleDefinition": ["displayName": "Owner"],
                                                             "scope": ["displayName": "Tenant Root Group"]]]],
            ["id": "\(id)-done", "properties": ["status": "Provisioned"]]
        ]
        let transport = FakeTransport([.init(status: 200, json: ["value": items])])
        let list = try await ARMClient(client: client(transport)).pendingRequests()
        #expect(list.count == 1)
        #expect(list[0] == RemoteRequest(id: id, source: .azureResource, roleName: "Owner", scopeName: "Tenant Root Group",
                                         status: .pendingApproval, createdAt: PIMDates.parse("2026-11-04T08:00:00.123Z"),
                                         justification: "deploy"))
        #expect(transport.requests[0].url?.absoluteString.contains("asTarget()") == true)
    }

    @Test func armCancelAndStatusUseFullId() async throws {
        let id = "\(rootScope)/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/req-1"
        let transport = FakeTransport([.init(status: 200, json: [:]),
                                       .init(status: 200, json: ["properties": ["status": "Canceled"]])])
        let arm = ARMClient(client: client(transport))
        try await arm.cancel(request: id)
        #expect(try await arm.status(ofRequest: id) == .canceled)
        #expect(transport.requests[0].httpMethod == "POST")
        #expect(transport.requests[0].url?.path == "\(id)/cancel")
        #expect(transport.requests[1].httpMethod == "GET")
        #expect(transport.requests[1].url?.path == id)
    }

    @Test func graphPendingAndCancel() async throws {
        let transport = FakeTransport([
            .init(status: 200, json: ["value": [["id": "g1", "status": "PendingApproval", "directoryScopeId": "/",
                                                 "roleDefinition": ["displayName": "User Administrator"]]]]),
            .init(status: 204, json: nil)
        ])
        let entra = EntraRoleClient(client: client(transport))
        let list = try await entra.pendingRequests()
        #expect(list.first?.roleName == "User Administrator")
        #expect(list.first?.scopeName == "Directory")
        let url = try #require(transport.requests[0].url?.absoluteString.removingPercentEncoding)
        #expect(url.contains("roleAssignmentScheduleRequests/filterByCurrentUser(on='principal')"))
        #expect(url.contains("status eq 'PendingApproval'"))
        try await entra.cancel(request: "g1")
        #expect(transport.requests[1].url?.path == "/v1.0/roleManagement/directory/roleAssignmentScheduleRequests/g1/cancel")
    }

    @Test func groupCancelPath() async throws {
        let transport = FakeTransport([.init(status: 204, json: nil)])
        try await PIMGroupClient(client: client(transport)).cancel(request: "x1")
        #expect(transport.requests[0].url?.path
            == "/v1.0/identityGovernance/privilegedAccess/group/assignmentScheduleRequests/x1/cancel")
    }
}

@MainActor
struct FavoritePersistenceTests {
    /// The Favorites editor mutates `items[i]` in place: SwiftData must persist it.
    @Test func inPlaceItemEditIsPersisted() throws {
        let container = try AzurePimStore.makeContainer(inMemory: true)
        let favorite = Favorite(name: "Morning", items: [FavoriteItem(eligibleRoleId: "r1", duration: "PT8H")])
        container.mainContext.insert(favorite)
        try container.mainContext.save()
        favorite.items[0].duration = "PT2H"
        favorite.items[0].justification = "deploy"
        try container.mainContext.save()
        let fresh = ModelContext(container)
        let stored = try #require(try fresh.fetch(FetchDescriptor<Favorite>()).first)
        #expect(stored.items == [FavoriteItem(eligibleRoleId: "r1", duration: "PT2H", justification: "deploy")])
    }
}
