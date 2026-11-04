import Foundation
import Testing
@testable import AzurePimCore

struct JWTClaimsTests {
    @Test func readsStandardClaims() throws {
        let token = fakeJWT(["oid": "o", "tid": "t", "upn": "u@x.com", "exp": 1_000.0, "scp": "a b", "amr": ["pwd", "mfa"]])
        let claims = try #require(JWTClaims(token: token))
        #expect(claims.objectId == "o")
        #expect(claims.tenantId == "t")
        #expect(claims.upn == "u@x.com")
        #expect(claims.expiresOn == Date(timeIntervalSince1970: 1_000))
        #expect(claims.scopes == ["a", "b"])
        #expect(claims.authMethods == ["pwd", "mfa"])
    }

    @Test func fallsBackToPreferredUsername() throws {
        let claims = try #require(JWTClaims(token: fakeJWT(["preferred_username": "p@x.com"])))
        #expect(claims.upn == "p@x.com")
    }

    @Test func rejectsGarbage() {
        #expect(JWTClaims(token: "nope") == nil)
        #expect(JWTClaims(token: "a.%%%.c") == nil)
    }
}
