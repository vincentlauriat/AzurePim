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
