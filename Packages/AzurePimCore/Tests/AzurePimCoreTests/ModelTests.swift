import Foundation
import SwiftData
import Testing
@testable import AzurePimCore

@MainActor
struct ModelTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try AzurePimStore.makeContainer(inMemory: true)
    }

    @Test func seedCreatesSingleSettingsRow() throws {
        let first = try AzurePimStore.settings(in: context)
        let second = try AzurePimStore.settings(in: context)
        #expect(first === second)
        #expect(try context.fetchCount(FetchDescriptor<AppSettings>()) == 1)
        #expect(first.refreshIntervalMinutes == 5)
        #expect(first.notificationLeadMinutes == 15)
        #expect(first.historyRetentionDays == 90)
        #expect(first.menuBarStyle == .iconCountTime)
    }

    @Test func accountDefaultsDependOnMode() {
        let cli = Account(mode: .azureCLI, upn: "a@x.com", objectId: "o1", tenantId: "t1")
        let msal = Account(mode: .msal, upn: "a@x.com", objectId: "o1", tenantId: "t1")
        #expect(cli.directoryAccess == .notApplicable)
        #expect(msal.directoryAccess == .notRequested)
        #expect(cli.identityKey != msal.identityKey)
    }

    @Test func everyEntityRoundTrips() throws {
        let account = Account(mode: .azureCLI, upn: "a@x.com", objectId: "o1", tenantId: "t1", tenantName: "Contoso")
        context.insert(account)
        let role = EligibleRole(id: "sched-1", account: account, source: .azureResource,
                                roleDefinitionId: "/providers/Microsoft.Authorization/roleDefinitions/r",
                                roleName: "Reader", scope: "/providers/Microsoft.Management/managementGroups/t1",
                                scopeName: "Tenant Root Group", scopeType: "managementgroup")
        context.insert(role)
        let active = ActiveAssignment(id: "inst-1", account: account, source: .azureResource, roleName: "Reader",
                                      scope: role.scope, scopeName: role.scopeName, assignmentType: .activated,
                                      startAt: .now, endAt: .now.addingTimeInterval(3600), eligibleRole: role)
        context.insert(active)
        context.insert(Favorite(name: "Morning", items: [FavoriteItem(eligibleRoleId: "sched-1", duration: "PT4H")]))
        let record = ActivationRecord(account: account, eligibleRoleId: "sched-1", roleName: "Reader",
                                      scopeName: "Tenant Root Group", source: .azureResource, action: .activate,
                                      requestedDuration: "PT4H", panelOpenedAt: .now.addingTimeInterval(-8))
        record.status = .provisioned
        record.completedAt = .now
        context.insert(record)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<Account>()).first)
        #expect(fetched.eligibleRoles.count == 1)
        #expect(fetched.activeAssignments.first?.eligibleRole?.roleName == "Reader")
        #expect(try context.fetch(FetchDescriptor<Favorite>()).first?.items.first?.duration == "PT4H")
        let time = try #require(fetched.records.first?.timeToActivation)
        #expect(time > 7 && time < 10)
    }

    @Test func deletingAccountCascades() throws {
        let account = Account(mode: .msal, upn: "a@x.com", objectId: "o1", tenantId: "t1")
        context.insert(account)
        context.insert(EligibleRole(id: "s", account: account, source: .entraRole, roleDefinitionId: "d",
                                    roleName: "Application Administrator", scope: "/", scopeName: "Directory",
                                    scopeType: "directory"))
        try context.save()
        context.delete(account)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<EligibleRole>()) == 0)
    }
}
