import Foundation

/// Validation rules of BackendSchema › Data validation.
public enum Validation {
    public enum Failure: Error, Equatable, Sendable {
        case empty(String)
        case tooLong(String, max: Int)
        case outOfRange(String, ClosedRange<Int>)
        case invalidFormat(String)
        case duplicate(String)
        case exceedsPolicy(max: TimeInterval)
    }

    public static func favoriteName(_ raw: String, existing: [String]) -> Result<String, Failure> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.empty("name")) }
        guard name.count <= 40 else { return .failure(.tooLong("name", max: 40)) }
        if existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return .failure(.duplicate("name"))
        }
        return .success(name)
    }

    public static func justification(_ text: String, required: Bool) -> Failure? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if required && trimmed.isEmpty { return .empty("justification") }
        if trimmed.count > 500 { return .tooLong("justification", max: 500) }
        return nil
    }

    public static func ticketNumber(_ text: String, required: Bool) -> Failure? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if required && trimmed.isEmpty { return .empty("ticket") }
        if trimmed.count > 100 { return .tooLong("ticket", max: 100) }
        return nil
    }

    /// Validates an activation duration: 5 min ≤ d ≤ policy max (default cap 24 h).
    public static func duration(_ iso: String, policyMax: String?) -> Result<TimeInterval, Failure> {
        guard let seconds = ISODuration.seconds(iso) else { return .failure(.invalidFormat("duration")) }
        let cap = policyMax.flatMap(ISODuration.seconds) ?? 24 * 3600
        guard seconds >= 5 * 60 else { return .failure(.outOfRange("duration", 5...Int(cap / 60))) }
        guard seconds <= cap else { return .failure(.exceedsPolicy(max: cap)) }
        return .success(seconds)
    }

    public static func setting(_ name: String, _ value: Int) -> Failure? {
        let range: ClosedRange<Int>
        switch name {
        case "refreshIntervalMinutes": range = 1...30
        case "notificationLeadMinutes": range = 5...60
        case "historyRetentionDays": range = 7...365
        default: return nil
        }
        return range.contains(value) ? nil : .outOfRange(name, range)
    }

    public static func clientId(_ text: String) -> Failure? {
        UUID(uuidString: text.trimmingCharacters(in: .whitespaces)) == nil ? .invalidFormat("clientId") : nil
    }

    /// `azCLIPath` must be an executable file named `az`.
    public static func azPath(_ path: String, fileManager: FileManager = .default) -> Failure? {
        let url = URL(fileURLWithPath: path)
        guard url.lastPathComponent == "az", fileManager.isExecutableFile(atPath: path) else {
            return .invalidFormat("azCLIPath")
        }
        // Both the link and its resolved target, with every ancestor folder, must be owned by root or the user and not
        // writable by others (security review L2). The resolved target is what gets executed (`locateCLI`).
        let target = url.resolvingSymlinksInPath()
        for start in [url, target] where !isTrustedChain(start, fileManager: fileManager) {
            return .invalidFormat("azCLIPath")
        }
        return nil
    }

    /// The item and all its ancestors: readable attributes, owner root or current user, not world-writable
    /// (except root-owned sticky folders such as /tmp, where others cannot replace the user's file).
    static func isTrustedChain(_ url: URL, fileManager: FileManager) -> Bool {
        var item = url.standardizedFileURL
        while true {
            guard let attributes = try? fileManager.attributesOfItem(atPath: item.path),
                  let mode = attributes[.posixPermissions] as? Int,
                  let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value else { return false }
            guard owner == 0 || owner == getuid() else { return false }
            let stickyRoot = mode & 0o1000 != 0 && owner == 0
            if mode & 0o002 != 0 && !stickyRoot { return false }
            if item.path == "/" { return true }
            item = item.deletingLastPathComponent()
        }
    }
}

/// Minimal ISO 8601 duration support for PIM: `PT<n>H<n>M<n>S` and `P<n>D`.
public enum ISODuration {
    public static func seconds(_ iso: String) -> TimeInterval? {
        let pattern = /^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/
        guard iso != "P", iso != "PT", let match = iso.wholeMatch(of: pattern) else { return nil }
        let days = Double(match.1 ?? "0") ?? 0
        let hours = Double(match.2 ?? "0") ?? 0
        let minutes = Double(match.3 ?? "0") ?? 0
        let secs = Double(match.4 ?? "0") ?? 0
        let total = days * 86400 + hours * 3600 + minutes * 60 + secs
        return total > 0 ? total : nil
    }

    public static func string(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60
        switch (hours, minutes) {
        case (0, let mins): return "PT\(mins)M"
        case (let hrs, 0): return "PT\(hrs)H"
        case (let hrs, let mins): return "PT\(hrs)H\(mins)M"
        }
    }
}

extension Validation.Failure {
    /// Short English message for inline errors and toasts.
    public var userMessage: String {
        switch self {
        case .empty(let field): field == "ticket" ? "Ticket number required by policy" : "\(field.capitalized) required"
        case .tooLong(let field, let max): "\(field.capitalized) is limited to \(max) characters"
        case .outOfRange(let field, let range): "\(field.capitalized) must be between \(range.lowerBound) and \(range.upperBound)"
        case .invalidFormat(let field): "Invalid \(field)"
        case .duplicate(let field): "This \(field) is already used"
        case .exceedsPolicy(let max): "Longer than the policy maximum (\(Int(max / 3600)) h)"
        }
    }
}
