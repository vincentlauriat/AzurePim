import Foundation
import Testing
@testable import AzurePimCore

struct ErrorKindTests {
    @Test func mapsEachBlockedState() {
        #expect(ErrorKind.classify(URLError(.notConnectedToInternet)) == .offline)
        #expect(ErrorKind.classify(URLError(.cannotFindHost)) == .offline)
        #expect(ErrorKind.classify(PIMError.throttled(retryAfter: 12)) == .throttled(retryAfter: 12))
        #expect(ErrorKind.classify(TokenError.cliNotSignedIn(command: "az login")) == .cliExpired(command: "az login"))
        #expect(ErrorKind.classify(TokenError.interactionRequired(claims: nil)) == .interactionRequired)
        #expect(ErrorKind.classify(TokenError.consentRequired) == .consentRequired)
        #expect(ErrorKind.classify(PIMError.http(status: 403, code: "AuthorizationFailed", message: "denied"))
            == .forbidden("denied"))
        #expect(ErrorKind.classify(PIMError.http(status: 400, code: nil, message: "bad")) == .other("bad"))
    }

    @Test func messages() {
        #expect(ErrorKind.throttled(retryAfter: nil).message == "Microsoft is throttling requests — retrying in 30 s.")
        #expect(ErrorKind.forbidden("x").message == "Not allowed by your tenant policy: x")
        #expect(ErrorKind.cliExpired(command: "az login").message.contains("az login"))
    }
}

struct SecurityHardeningTests {
    @Test func odataLiteralDoublesQuotes() {
        #expect(OData.literal("a'b") == "'a''b'")
        #expect(OData.segment("x/y?z#w") == "x%2Fy%3Fz%23w")
    }

    @Test func nextLinkToAnotherHostIsRefused() async {
        let transport = FakeTransport([.init(status: 200, json: ["value": [], "nextLink": "https://evil.example.com/steal"])])
        await #expect(throws: PIMError.decoding("unexpected nextLink host")) {
            _ = try await client(transport).list(URL(string: "https://management.azure.com/x")!)
        }
        #expect(transport.requests.count == 1)
    }

    @Test func retryAfterIsCapped() async throws {
        let recorder = SleepRecorder()
        let transport = FakeTransport([.init(status: 429, json: nil, headers: ["Retry-After": "86400"]),
                                       .init(status: 200, json: [:])])
        let authorized = AuthorizedClient(transport: transport, sleep: { recorder.add($0) },
                                          token: { _ in AccessToken(value: "t", expiresOn: .distantFuture) })
        _ = try await authorized.json("GET", URL(string: "https://management.azure.com/x")!)
        #expect(recorder.durations == [.seconds(30)])
    }

    @Test func azEnvironmentIsAllowlisted() {
        let env = AzureCLITokenProvider.environment(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/az"),
            inherited: ["HOME": "/Users/x", "PYTHONPATH": "/tmp/evil", "HTTPS_PROXY": "http://evil", "AZURE_CONFIG_DIR": "/c"])
        #expect(env["PYTHONPATH"] == nil)
        #expect(env["HTTPS_PROXY"] == nil)
        #expect(env["AZURE_CONFIG_DIR"] == "/c")
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
    }
}

final class SleepRecorder: @unchecked Sendable {
    private(set) var durations: [Duration] = []
    func add(_ duration: Duration) { durations.append(duration) }
}
