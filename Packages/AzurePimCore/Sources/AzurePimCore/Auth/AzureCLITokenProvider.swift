import Foundation

/// Token provider backed by the user's Azure CLI session (`az login`). Azure resource roles only:
/// the CLI's Graph token cannot carry PIM directory scopes (AADSTS65002, verified 2026-11-03).
public actor AzureCLITokenProvider: TokenProvider {
    public nonisolated let mode = SignInMode.azureCLI

    /// Known install locations, searched in order when no path is configured (PRD open question 8).
    public static let knownPaths = ["/opt/homebrew/bin/az", "/usr/local/bin/az", "/usr/bin/az"]

    private nonisolated let configuredPath: String?
    private let runner: ProcessRunning
    /// FileManager is thread-safe for the read-only checks used here; boxed so Swift 6.1 accepts it in nonisolated code.
    private nonisolated let files: UncheckedFileManager
    private nonisolated var fileManager: FileManager { files.value }
    private var cache: [String: AccessToken] = [:]

    public init(configuredPath: String? = nil, runner: ProcessRunning = ProcessRunner(), fileManager: FileManager = .default) {
        self.configuredPath = configuredPath
        self.runner = runner
        self.files = UncheckedFileManager(value: fileManager)
    }

    /// Path of the `az` executable, or nil when not installed.
    public nonisolated func locateCLI() -> URL? {
        // The configured path lives in a user-writable store: validated again at each use (security review L2).
        // Executes the exact resolved path that was validated, not a link that could be swapped afterwards.
        let configured = configuredPath.flatMap { Validation.trustedAZ($0, fileManager: fileManager) }
        let candidates = (configured.map { [$0] } ?? []) + Self.knownPaths
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    public func token(for resource: Resource, tenantId: String?, claims: String?) async throws -> AccessToken {
        if claims != nil {
            // The CLI cannot answer a claims challenge silently: the user must sign in again.
            throw TokenError.interactionRequired(claims: claims)
        }
        let key = "\(resource.rawValue)|\(tenantId ?? "default")"
        if let cached = cache[key], cached.isValid() { return cached }

        var args = ["account", "get-access-token", "--resource", resource.resourceURI, "--output", "json"]
        if let tenantId { args += ["--tenant", tenantId] }
        let output = try await runAZ(args)
        let token = try Self.parseToken(output.stdout)
        cache[key] = token
        return token
    }

    public func identity(tenantId: String?) async throws -> SignedInIdentity {
        let token = try await token(for: .arm, tenantId: tenantId, claims: nil)
        guard let claims = JWTClaims(token: token.value), let oid = claims.objectId, let tid = claims.tenantId else {
            throw TokenError.failed("Unreadable Azure CLI token")
        }
        let tenantName = try? await tenantDisplayName(tenantId: tid)
        return SignedInIdentity(upn: claims.upn ?? oid, objectId: oid, tenantId: tid, tenantName: tenantName)
    }

    /// Tenants of the CLI session (`az account list`), for the account picker.
    public func tenants() async throws -> [(id: String, name: String?)] {
        let output = try await runAZ(["account", "list", "--output", "json"])
        guard let list = try JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return list.compactMap { sub -> (String, String?)? in
            guard let tid = sub["tenantId"] as? String, seen.insert(tid).inserted else { return nil }
            return (tid, sub["tenantDisplayName"] as? String)
        }
    }

    public func clearCache() { cache.removeAll() }

    // MARK: - Internals

    private func tenantDisplayName(tenantId: String) async throws -> String? {
        try await tenants().first { $0.id.caseInsensitiveCompare(tenantId) == .orderedSame }?.name
    }

    private func runAZ(_ arguments: [String]) async throws -> ProcessOutput {
        guard let executable = locateCLI() else { throw TokenError.cliNotFound }
        let env = Self.environment(executable: executable, inherited: ProcessInfo.processInfo.environment)
        let output = try await runner.run(executable, arguments: arguments, environment: env, timeout: .seconds(20))
        guard output.status == 0 else { throw Self.mapError(output.stderr, tenantArgument: arguments) }
        return output
    }

    /// Allowlisted environment for `az` (security review L1): no PYTHONPATH, proxies or CA bundles injected through
    /// `launchctl setenv`. GUI apps get a minimal PATH; `az` is a script whose interpreter lives next to it.
    static func environment(executable: URL, inherited: [String: String]) -> [String: String] {
        var env = [
            "HOME": inherited["HOME"] ?? NSHomeDirectory(),
            "USER": inherited["USER"] ?? NSUserName(),
            "LANG": "en_US.UTF-8",
            "PATH": ([executable.deletingLastPathComponent().path] + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
                .joined(separator: ":"),
            "AZURE_CORE_ONLY_SHOW_ERRORS": "true",
            "AZURE_CORE_COLLECT_TELEMETRY": "false"
        ]
        // Users who keep their CLI profile elsewhere (`AZURE_CONFIG_DIR`) still get their session.
        if let dir = inherited["AZURE_CONFIG_DIR"] { env["AZURE_CONFIG_DIR"] = dir }
        return env
    }

    static func parseToken(_ json: String) throws -> AccessToken {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let value = object["accessToken"] as? String else {
            throw TokenError.failed("Unexpected Azure CLI output")
        }
        // Recent CLIs give `expires_on` (POSIX seconds); older ones only `expiresOn` (local time string).
        if let epoch = object["expires_on"] as? Double ?? (object["expires_on"] as? String).flatMap(Double.init) {
            return AccessToken(value: value, expiresOn: Date(timeIntervalSince1970: epoch))
        }
        if let exp = JWTClaims(token: value)?.expiresOn {
            return AccessToken(value: value, expiresOn: exp)
        }
        throw TokenError.failed("Azure CLI token has no expiry")
    }

    static func mapError(_ stderr: String, tenantArgument arguments: [String]) -> TokenError {
        let text = stderr.lowercased()
        var login = "az login"
        if let index = arguments.firstIndex(of: "--tenant"), index + 1 < arguments.count {
            login += " --tenant \(arguments[index + 1])"
        }
        if text.contains("aadsts50076") || text.contains("aadsts50079") || text.contains("interaction_required")
            || text.contains("claims") {
            return .cliNotSignedIn(command: login)
        }
        if text.contains("az login") || text.contains("aadsts700082") || text.contains("aadsts70043")
            || text.contains("no subscription found") || text.contains("refresh token") || text.contains("not logged in") {
            return .cliNotSignedIn(command: login)
        }
        let firstLine = stderr.split(separator: "\n").first.map(String.init) ?? "Azure CLI error"
        return .failed(firstLine.replacingOccurrences(of: "ERROR: ", with: ""))
    }
}

/// FileManager is documented as thread-safe for the read-only queries made here.
struct UncheckedFileManager: @unchecked Sendable {
    let value: FileManager
}
