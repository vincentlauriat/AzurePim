import Foundation

/// Transport used by the ARM and Graph clients (faked in tests).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpAdditionalHeaders = ["User-Agent": "AzurePim/\(AzurePimCore.version)"]
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PIMError.decoding("non-HTTP response") }
        return (data, http)
    }
}

/// Authenticated JSON client with retries on 429 / 5xx (TRD › Reliability: 1 s, 2 s, 4 s, honoring Retry-After)
/// and claims-challenge detection.
public struct AuthorizedClient: Sendable {
    public typealias TokenSource = @Sendable (_ claims: String?) async throws -> AccessToken

    let transport: HTTPTransport
    let token: TokenSource
    let maxRetries: Int
    let sleep: @Sendable (Duration) async throws -> Void

    public init(transport: HTTPTransport = URLSessionTransport(), maxRetries: Int = 3,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                token: @escaping TokenSource) {
        self.transport = transport
        self.token = token
        self.maxRetries = maxRetries
        self.sleep = sleep
    }

    public func json(_ method: String, _ url: URL, body: [String: Any]? = nil) async throws -> [String: Any] {
        var claims: String?
        var attempt = 0
        while true {
            let access = try await token(claims)
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(access.value)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await transport.send(request)
            let status = response.statusCode

            if (200..<300).contains(status) {
                if data.isEmpty { return [:] }
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw PIMError.decoding("not a JSON object")
                }
                return object
            }
            if status == 401, claims == nil, let challenge = Self.claimsChallenge(response) {
                // One retry with the claims (MSAL answers interactively; Azure CLI mode throws).
                claims = challenge
                continue
            }
            if status == 429 || status >= 500, attempt < maxRetries {
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                try await sleep(.seconds(retryAfter ?? pow(2, Double(attempt))))
                attempt += 1
                continue
            }
            throw Self.error(status: status, data: data, response: response)
        }
    }

    /// Follows `nextLink` / `@odata.nextLink` pages and concatenates `value` arrays.
    public func list(_ url: URL) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var next: URL? = url
        while let page = next {
            let object = try await json("GET", page)
            items += (object["value"] as? [[String: Any]]) ?? []
            next = ((object["nextLink"] ?? object["@odata.nextLink"]) as? String).flatMap(URL.init(string:))
        }
        return items
    }

    static func claimsChallenge(_ response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "WWW-Authenticate"),
              header.contains("insufficient_claims") || header.contains("claims="),
              let match = header.firstMatch(of: /claims="([^"]+)"/) else { return nil }
        let raw = String(match.1)
        // ARM sends base64-encoded claims; Graph may send them as JSON.
        if raw.hasPrefix("{") { return raw }
        var base64 = raw
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64).flatMap { String(bytes: $0, encoding: .utf8) } ?? raw
    }

    static func error(status: Int, data: Data, response: HTTPURLResponse) -> Error {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let code = error?["code"] as? String
        var message = (error?["message"] as? String) ?? HTTPURLResponse.localizedString(forStatusCode: status)
        // Graph wraps PIM errors as a JSON string inside `message`.
        if let inner = message.data(using: .utf8),
           let nested = (try? JSONSerialization.jsonObject(with: inner)) as? [String: Any],
           let innerMessage = nested["message"] as? String {
            if (nested["errorCode"] as? String) == "PermissionScopeNotGranted" { return TokenError.consentRequired }
            message = innerMessage
        }
        if status == 429 {
            return PIMError.throttled(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        }
        if status == 403, message.contains("PermissionScopeNotGranted") || message.contains("AADSTS65001") {
            return TokenError.consentRequired
        }
        return PIMError.http(status: status, code: code, message: message)
    }
}
