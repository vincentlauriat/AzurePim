import Foundation

/// UI state of an error (AppFlow › Empty and blocked states, ImplementationPlan T5.1).
public enum ErrorKind: Hashable, Sendable {
    case offline
    case throttled(retryAfter: TimeInterval?)
    case cliNotFound
    case cliExpired(command: String)
    case interactionRequired
    case consentRequired
    case forbidden(String)
    case other(String)

    public static func classify(_ error: Error) -> ErrorKind {
        if let token = error as? TokenError { return classify(token) }
        if let pim = error as? PIMError {
            switch pim {
            case .throttled(let retryAfter): return .throttled(retryAfter: retryAfter)
            case .http(403, _, let message): return .forbidden(message)
            default: return .other(pim.userMessage)
            }
        }
        if let url = error as? URLError, offlineCodes.contains(url.code) { return .offline }
        return .other(error.localizedDescription)
    }

    static func classify(_ token: TokenError) -> ErrorKind {
        switch token {
        case .cliNotFound: return .cliNotFound
        case .cliNotSignedIn(let command): return .cliExpired(command: command)
        case .interactionRequired: return .interactionRequired
        case .consentRequired: return .consentRequired
        case .timedOut: return .offline
        case .notConfigured: return .other("Microsoft sign-in is not configured in this build (no client ID).")
        case .cancelled: return .other("Sign-in cancelled.")
        case .failed(let message): return .other(message)
        }
    }

    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .timedOut, .internationalRoamingOff, .dataNotAllowed
    ]

    /// Short English text for banners and rows.
    public var message: String {
        switch self {
        case .offline: "Offline."
        case .throttled(let retryAfter):
            "Microsoft is throttling requests — retrying in \(Int(retryAfter ?? 30)) s."
        case .cliNotFound: "Azure CLI not found. Install it or choose its location in Settings."
        case .cliExpired(let command): "Azure CLI session expired — run `\(command)`."
        case .interactionRequired: "Your organization requires you to sign in again (MFA)."
        case .consentRequired: "Admin consent required in this tenant."
        case .forbidden(let detail): "Not allowed by your tenant policy: \(detail)"
        case .other(let text): text
        }
    }
}
