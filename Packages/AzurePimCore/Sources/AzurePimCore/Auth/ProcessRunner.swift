import Foundation

public struct ProcessOutput: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs an executable with an explicit argument array (never through a shell — TRD › Security).
public protocol ProcessRunning: Sendable {
    func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws -> ProcessOutput
}

public struct ProcessRunner: ProcessRunning {
    public init() {}

    /// The timeout resumes the caller itself: it never waits for the child, which may ignore SIGTERM or leave a
    /// grandchild holding the pipes open. The child gets SIGTERM, then SIGKILL one second later.
    public func run(_ executable: URL, arguments: [String], environment: [String: String],
                    timeout: Duration) async throws -> ProcessOutput {
        let job = Job(executable: executable, arguments: arguments, environment: environment)
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            job.start { once.resume(with: $0) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                if once.resume(with: .failure(TokenError.timedOut)) { job.kill() }
            }
        }
    }

    /// Resumes a continuation exactly once (process completion and timeout race).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ProcessOutput, Error>?

        init(_ continuation: CheckedContinuation<ProcessOutput, Error>) {
            self.continuation = continuation
        }

        @discardableResult
        func resume(with result: Result<ProcessOutput, Error>) -> Bool {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
            return pending != nil
        }
    }

    /// Owns the Process and its pipes. Both pipes are drained while the process runs, so outputs larger
    /// than the pipe buffer (64 KB) cannot block the child.
    private final class Job: @unchecked Sendable {
        private let process = Process()
        private let out = Pipe()
        private let err = Pipe()
        private var errData = Data()

        init(executable: URL, arguments: [String], environment: [String: String]) {
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
        }

        func start(_ completion: @escaping @Sendable (Result<ProcessOutput, Error>) -> Void) {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do { try process.run() } catch {
                    completion(.failure(error))
                    return
                }
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                completion(.success(ProcessOutput(
                    status: process.terminationStatus,
                    stdout: String(bytes: outData, encoding: .utf8) ?? "",
                    stderr: String(bytes: errData, encoding: .utf8) ?? "")))
            }
        }

        func kill() {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                if process.isRunning { Darwin.kill(pid, SIGKILL) }
            }
        }
    }
}
