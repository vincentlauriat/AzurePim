import Foundation
import Testing
@testable import AzurePimCore

/// Fake runner returning canned outputs and recording calls.
final class FakeRunner: ProcessRunning, @unchecked Sendable {
    var outputs: [ProcessOutput]
    private(set) var calls: [[String]] = []

    init(_ outputs: [ProcessOutput]) { self.outputs = outputs }

    func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws -> ProcessOutput {
        calls.append(arguments)
        return outputs.isEmpty ? ProcessOutput(status: 1, stdout: "", stderr: "no more outputs") : outputs.removeFirst()
    }
}

/// Builds an unsigned JWT with the given claims.
func fakeJWT(_ claims: [String: Any]) -> String {
    func b64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let header = b64(Data(#"{"alg":"none"}"#.utf8))
    let body = b64((try? JSONSerialization.data(withJSONObject: claims)) ?? Data())
    return "\(header).\(body).sig"
}

struct AzureCLITokenProviderTests {
    /// `/bin/echo` stands in for `az`: it exists and is executable, the runner is faked anyway.
    let fakeAZ = "/bin/echo"

    @Test func locatesConfiguredPathFirst() {
        let provider = AzureCLITokenProvider(configuredPath: fakeAZ, runner: FakeRunner([]))
        #expect(provider.locateCLI()?.path == fakeAZ)
    }

    @Test func missingCLIThrowsCliNotFound() async {
        let provider = AzureCLITokenProvider(configuredPath: "/nonexistent/az", runner: FakeRunner([]),
                                             fileManager: NoExecutables())
        await #expect(throws: TokenError.cliNotFound) {
            try await provider.token(for: .arm, tenantId: nil, claims: nil)
        }
    }

    @Test func parsesTokenAndCachesIt() async throws {
        let json = #"{"accessToken":"abc","expires_on":4102444800,"tenant":"t1","tokenType":"Bearer"}"#
        let runner = FakeRunner([ProcessOutput(status: 0, stdout: json, stderr: "")])
        let provider = AzureCLITokenProvider(configuredPath: fakeAZ, runner: runner)
        let first = try await provider.token(for: .arm, tenantId: "t1", claims: nil)
        let second = try await provider.token(for: .arm, tenantId: "t1", claims: nil)
        #expect(first.value == "abc")
        #expect(first.expiresOn == Date(timeIntervalSince1970: 4_102_444_800))
        #expect(first == second)
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0] == ["account", "get-access-token", "--resource", "https://management.azure.com/",
                                    "--output", "json", "--tenant", "t1"])
    }

    @Test func fallsBackToJWTExpiry() throws {
        let jwt = fakeJWT(["exp": 4_102_444_800.0, "oid": "o"])
        let token = try AzureCLITokenProvider.parseToken(#"{"accessToken":"\#(jwt)","expiresOn":"2100-01-01 00:00:00.000000"}"#)
        #expect(token.expiresOn == Date(timeIntervalSince1970: 4_102_444_800))
    }

    @Test func expiredSessionMapsToLoginCommand() async {
        let stderr = "ERROR: AADSTS700082: The refresh token has expired due to inactivity. Please run 'az login'."
        let provider = AzureCLITokenProvider(configuredPath: fakeAZ,
                                             runner: FakeRunner([ProcessOutput(status: 1, stdout: "", stderr: stderr)]))
        await #expect(throws: TokenError.cliNotSignedIn(command: "az login --tenant t1")) {
            try await provider.token(for: .arm, tenantId: "t1", claims: nil)
        }
    }

    @Test func claimsChallengeNeedsInteraction() async {
        let provider = AzureCLITokenProvider(configuredPath: fakeAZ, runner: FakeRunner([]))
        await #expect(throws: TokenError.interactionRequired(claims: "{}")) {
            try await provider.token(for: .arm, tenantId: nil, claims: "{}")
        }
    }

    @Test func unknownErrorKeepsFirstLine() {
        let error = AzureCLITokenProvider.mapError("ERROR: Something odd\nTraceback…", tenantArgument: [])
        #expect(error == .failed("Something odd"))
    }

    @Test func identityComesFromTokenClaims() async throws {
        let jwt = fakeJWT(["oid": "oid-1", "tid": "tid-1", "upn": "user@contoso.com", "exp": 4_102_444_800.0])
        let tokenJSON = #"{"accessToken":"\#(jwt)","expires_on":4102444800}"#
        let listJSON = #"[{"tenantId":"tid-1","tenantDisplayName":"Contoso"},{"tenantId":"tid-1","tenantDisplayName":"Contoso"}]"#
        let runner = FakeRunner([ProcessOutput(status: 0, stdout: tokenJSON, stderr: ""),
                                 ProcessOutput(status: 0, stdout: listJSON, stderr: "")])
        let identity = try await AzureCLITokenProvider(configuredPath: fakeAZ, runner: runner).identity(tenantId: nil)
        #expect(identity == SignedInIdentity(upn: "user@contoso.com", objectId: "oid-1", tenantId: "tid-1", tenantName: "Contoso"))
    }

    @Test func realProcessRunnerHandlesLargeOutput() async throws {
        // 200 KB on stdout: would deadlock if pipes were drained only after exit.
        let output = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sh"),
                                                   arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' x; echo err >&2"],
                                                   environment: [:], timeout: .seconds(10))
        #expect(output.status == 0)
        #expect(output.stdout.count == 200_000)
        #expect(output.stderr == "err\n")
    }

    @Test func realProcessRunnerTimesOut() async {
        await #expect(throws: TokenError.timedOut) {
            try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], environment: [:],
                                          timeout: .milliseconds(300))
        }
    }

    /// Live check against the real Azure CLI session. Opt-in: AZUREPIM_LIVE=1 swift test
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AZUREPIM_LIVE"] == "1"))
    func liveAzureCLI() async throws {
        let provider = AzureCLITokenProvider()
        let identity = try await provider.identity(tenantId: nil)
        #expect(!identity.objectId.isEmpty)
        print("live identity:", identity.upn, identity.tenantId, identity.tenantName ?? "-")
    }
}

/// FileManager reporting nothing as executable (simulates a Mac without the Azure CLI).
final class NoExecutables: FileManager, @unchecked Sendable {
    override func isExecutableFile(atPath path: String) -> Bool { false }
}
