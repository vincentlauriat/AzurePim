import AppKit
import AzurePimCore
import MSAL

/// Token provider backed by MSAL (TRD › Authentication): multi-tenant public client, interactive sign-in with MFA,
/// silent renewal from the Keychain cache, incremental directory scopes, claims challenges.
@MainActor
final class MSALTokenProvider: TokenProvider {
    nonisolated let mode = SignInMode.msal

    private let application: MSALPublicClientApplication
    /// MSAL home account id of the account this provider acts for (nil before sign-in).
    private(set) var homeAccountId: String?

    static let organizationsAuthority = "https://login.microsoftonline.com/organizations"

    /// Client id: runtime override (Settings) first, then the build setting `AZUREPIM_CLIENT_ID`.
    static func configuredClientId(override: String?) -> String? {
        if let override, Validation.clientId(override) == nil { return override.trimmingCharacters(in: .whitespaces) }
        let built = Bundle.main.object(forInfoDictionaryKey: "AzurePimClientID") as? String ?? ""
        return Validation.clientId(built) == nil ? built : nil
    }

    init(clientId: String, homeAccountId: String? = nil) throws {
        let authority = try MSALAADAuthority(url: URL(string: Self.organizationsAuthority)!)
        let redirect = "msauth.\(Bundle.main.bundleIdentifier ?? "fr.vincentlauriat.azurepim")://auth"
        let config = MSALPublicClientApplicationConfig(clientId: clientId, redirectUri: redirect, authority: authority)
        application = try MSALPublicClientApplication(configuration: config)
        self.homeAccountId = homeAccountId
    }

    // MARK: - TokenProvider

    func token(for resource: Resource, tenantId: String?, claims: String?) async throws -> AccessToken {
        let result = try await acquire(scopes: resource.baseScopes, tenantId: tenantId, claims: claims)
        return AccessToken(value: result.accessToken, expiresOn: result.expiresOn ?? .now.addingTimeInterval(3000))
    }

    func identity(tenantId: String?) async throws -> SignedInIdentity {
        let token = try await token(for: .arm, tenantId: tenantId, claims: nil)
        guard let claims = JWTClaims(token: token.value), let oid = claims.objectId, let tid = claims.tenantId else {
            throw TokenError.failed("Unreadable Microsoft token")
        }
        return SignedInIdentity(upn: claims.upn ?? oid, objectId: oid, tenantId: tid, tenantName: nil)
    }

    // MARK: - Interactive flows

    /// First sign-in (account picker). Returns the identity and stores the home account id.
    func signIn() async throws -> SignedInIdentity {
        let result = try await interactive(scopes: Resource.arm.baseScopes, extraScopes: Resource.graph.baseScopes,
                                           tenantId: nil, claims: nil, prompt: .selectAccount)
        homeAccountId = result.account.identifier
        guard let claims = JWTClaims(token: result.accessToken), let oid = claims.objectId, let tid = claims.tenantId else {
            throw TokenError.failed("Unreadable Microsoft token")
        }
        return SignedInIdentity(upn: result.account.username ?? claims.upn ?? oid, objectId: oid, tenantId: tid,
                                tenantName: nil)
    }

    /// Incremental consent for Entra roles and PIM groups. Throws `.consentRequired` when the tenant admin
    /// has not consented and the user cannot.
    func requestDirectoryAccess(tenantId: String) async throws {
        _ = try await interactive(scopes: GraphScopes.directory, extraScopes: [], tenantId: tenantId, claims: nil,
                                  prompt: .default)
    }

    func signOut() {
        guard let id = homeAccountId, let account = try? application.account(forIdentifier: id) else { return }
        try? application.remove(account)
        homeAccountId = nil
    }

    // MARK: - Internals

    private func acquire(scopes: [String], tenantId: String?, claims: String?) async throws -> MSALResult {
        if claims == nil, let id = homeAccountId, let account = try? application.account(forIdentifier: id) {
            let parameters = MSALSilentTokenParameters(scopes: scopes, account: account)
            if let tenantId {
                parameters.authority = try MSALAADAuthority(url: URL(string: "https://login.microsoftonline.com/\(tenantId)")!)
            }
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    application.acquireTokenSilent(with: parameters) { result, error in
                        Self.resume(continuation, result, error)
                    }
                }
            } catch TokenError.interactionRequired {
                // fall through to interactive
            }
        }
        return try await interactive(scopes: scopes, extraScopes: [], tenantId: tenantId, claims: claims, prompt: .default)
    }

    private func interactive(scopes: [String], extraScopes: [String], tenantId: String?, claims: String?,
                             prompt: MSALPromptType) async throws -> MSALResult {
        let anchor = Self.presentationController()
        let webview = MSALWebviewParameters(authPresentationViewController: anchor)
        let parameters = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: webview)
        parameters.promptType = prompt
        if !extraScopes.isEmpty { parameters.extraScopesToConsent = extraScopes }
        if let claims {
            var parseError: NSError?
            let request = MSALClaimsRequest(jsonString: claims, error: &parseError)
            if let parseError { throw TokenError.failed("Invalid claims challenge: \(parseError.localizedDescription)") }
            parameters.claimsRequest = request
        }
        if let tenantId {
            parameters.authority = try MSALAADAuthority(url: URL(string: "https://login.microsoftonline.com/\(tenantId)")!)
        }
        if let id = homeAccountId, let account = try? application.account(forIdentifier: id) {
            parameters.account = account
        }
        NSApp.activate(ignoringOtherApps: true)
        return try await withCheckedThrowingContinuation { continuation in
            application.acquireToken(with: parameters) { result, error in
                Self.resume(continuation, result, error)
            }
        }
    }

    private nonisolated static func resume(_ continuation: CheckedContinuation<MSALResult, Error>,
                                           _ result: MSALResult?, _ error: Error?) {
        if let result {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: map(error))
        }
    }

    nonisolated static func map(_ error: Error?) -> TokenError {
        guard let nsError = error as NSError? else { return .failed("Unknown MSAL error") }
        let description = (nsError.userInfo[MSALErrorDescriptionKey] as? String) ?? nsError.localizedDescription
        // AADSTS65001: consent missing; AADSTS90094 / 90095: admin consent required.
        if description.contains("AADSTS65001") || description.contains("AADSTS90094") || description.contains("AADSTS90095") {
            return .consentRequired
        }
        if nsError.domain == MSALErrorDomain {
            switch MSALError(rawValue: nsError.code) {
            case .userCanceled: return .cancelled
            case .interactionRequired: return .interactionRequired(claims: nil)
            default: break
            }
        }
        return .failed(description)
    }

    /// MSAL needs a view controller to present its web view; use the key window's or a transient one.
    private static func presentationController() -> NSViewController {
        if let controller = NSApp.keyWindow?.contentViewController { return controller }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Sign in — AzurePim"
        window.isReleasedWhenClosed = false
        let controller = NSViewController()
        controller.view = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentViewController = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
        return controller
    }
}
