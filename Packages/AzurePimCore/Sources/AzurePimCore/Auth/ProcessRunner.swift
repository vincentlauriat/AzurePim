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

    public func run(_ executable: URL, arguments: [String], environment: [String: String],
                    timeout: Duration) async throws -> ProcessOutput {
        let job = Job(executable: executable, arguments: arguments, environment: environment)
        return try await withThrowingTaskGroup(of: ProcessOutput?.self) { group in
            group.addTask { try await job.run() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let result = first else {
                job.terminate()
                throw TokenError.timedOut
            }
            return result
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

        func run() async throws -> ProcessOutput {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do { try process.run() } catch {
                        continuation.resume(throwing: error)
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
                    continuation.resume(returning: ProcessOutput(
                        status: process.terminationStatus,
                        stdout: String(bytes: outData, encoding: .utf8) ?? "",
                        stderr: String(bytes: errData, encoding: .utf8) ?? ""))
                }
            }
        }

        func terminate() {
            if process.isRunning { process.terminate() }
        }
    }
}
