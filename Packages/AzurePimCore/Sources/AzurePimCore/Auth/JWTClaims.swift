import Foundation

/// Reads the payload of a JWT access token (no signature check: the token comes straight from Microsoft
/// and is only used to display who is signed in).
public struct JWTClaims: Sendable, Equatable {
    public let objectId: String?
    public let tenantId: String?
    public let upn: String?
    public let expiresOn: Date?
    public let scopes: [String]
    public let authMethods: [String]

    public init?(token: String) {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        objectId = json["oid"] as? String
        tenantId = json["tid"] as? String
        upn = (json["upn"] as? String) ?? (json["unique_name"] as? String) ?? (json["preferred_username"] as? String)
        expiresOn = (json["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        scopes = (json["scp"] as? String)?.split(separator: " ").map(String.init) ?? []
        authMethods = json["amr"] as? [String] ?? []
    }
}
