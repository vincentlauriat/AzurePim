import Foundation
import Testing
@testable import AzurePimCore

struct ValidationTests {
    @Test func favoriteNameRules() throws {
        #expect(try Validation.favoriteName("  Morning  ", existing: []).get() == "Morning")
        #expect(Validation.favoriteName("   ", existing: []) == .failure(.empty("name")))
        #expect(Validation.favoriteName(String(repeating: "x", count: 41), existing: []) == .failure(.tooLong("name", max: 40)))
        #expect(Validation.favoriteName("morning", existing: ["Morning"]) == .failure(.duplicate("name")))
    }

    @Test func justificationAndTicket() {
        #expect(Validation.justification("", required: true) == .empty("justification"))
        #expect(Validation.justification("", required: false) == nil)
        #expect(Validation.justification(String(repeating: "x", count: 501), required: false) == .tooLong("justification", max: 500))
        #expect(Validation.ticketNumber("", required: true) == .empty("ticket"))
        #expect(Validation.ticketNumber("INC123", required: true) == nil)
    }

    @Test(arguments: [("PT8H", 28_800.0), ("PT30M", 1_800.0), ("PT1H30M", 5_400.0), ("P1D", 86_400.0), ("PT45S", 45.0)])
    func isoDurationParsing(iso: String, seconds: Double) {
        #expect(ISODuration.seconds(iso) == seconds)
    }

    @Test(arguments: ["", "P", "PT", "8H", "PT8X", "PTH"])
    func isoDurationRejects(iso: String) {
        #expect(ISODuration.seconds(iso) == nil)
    }

    @Test func isoDurationFormatting() {
        #expect(ISODuration.string(28_800) == "PT8H")
        #expect(ISODuration.string(5_400) == "PT1H30M")
        #expect(ISODuration.string(600) == "PT10M")
    }

    @Test func durationAgainstPolicy() throws {
        #expect(try Validation.duration("PT4H", policyMax: "PT8H").get() == 14_400)
        #expect(Validation.duration("PT9H", policyMax: "PT8H") == .failure(.exceedsPolicy(max: 28_800)))
        if case .failure(.outOfRange) = Validation.duration("PT2M", policyMax: nil) {} else { Issue.record("2 min accepted") }
        #expect(Validation.duration("PT25H", policyMax: nil) == .failure(.exceedsPolicy(max: 86_400)))
        #expect(Validation.duration("nope", policyMax: nil) == .failure(.invalidFormat("duration")))
    }

    @Test func settingsRanges() {
        #expect(Validation.setting("refreshIntervalMinutes", 5) == nil)
        #expect(Validation.setting("refreshIntervalMinutes", 0) == .outOfRange("refreshIntervalMinutes", 1...30))
        #expect(Validation.setting("notificationLeadMinutes", 61) == .outOfRange("notificationLeadMinutes", 5...60))
        #expect(Validation.setting("historyRetentionDays", 6) == .outOfRange("historyRetentionDays", 7...365))
    }

    @Test func clientIdAndAzPath() {
        #expect(Validation.clientId("6404be9a-5db5-4476-8310-ffabea4f9439") == nil)
        #expect(Validation.clientId("not-a-guid") == .invalidFormat("clientId"))
        #expect(Validation.azPath("/bin/ls") == .invalidFormat("azCLIPath"))
        #expect(Validation.azPath("/nonexistent/az") == .invalidFormat("azCLIPath"))
    }
}
