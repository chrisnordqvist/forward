import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessRunnerError: Error, LocalizedError {
    case launchFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message): "Could not launch process: \(message)"
        case .timedOut: "The command timed out."
        }
    }
}

/// Runs short-lived commands to completion. Long-running processes (the ssh masters)
/// are managed directly by `SSHSession` instead, since they need streaming stderr.
public enum ProcessRunner {
    /// Run a command and wait for it to exit.
    ///
    /// - Parameter timeout: after this many seconds the process is terminated and
    ///   `ProcessRunnerError.timedOut` is thrown. Guards against an `ssh -O check`
    ///   hanging on a wedged socket.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: Duration = .seconds(15)
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = inheritedEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Drain both pipes concurrently with the wait. Reading after waiting risks
        // deadlocking on a full pipe buffer for chatty commands.
        async let outData = readToEnd(outPipe)
        async let errData = readToEnd(errPipe)

        let timeoutTask = Task {
            try await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        defer { timeoutTask.cancel() }

        // The handler must be installed before run(): a process that exits immediately
        // would otherwise terminate before we ever attach, and the await would hang.
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                }
            }
        } catch {
            // The child never existed, so nothing will ever close the write ends and the
            // in-flight reads would block forever. Close them before unwinding.
            closeWriteEnds(outPipe, errPipe)
            _ = await outData
            _ = await errData
            throw error
        }
        // The child holds its own dup'd descriptors; releasing ours guarantees the reads
        // see EOF as soon as it exits.
        closeWriteEnds(outPipe, errPipe)

        let stdout = String(decoding: await outData, as: UTF8.self)
        let stderr = String(decoding: await errData, as: UTF8.self)
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func closeWriteEnds(_ pipes: Pipe...) {
        for pipe in pipes {
            try? pipe.fileHandleForWriting.close()
        }
    }

    private static func readToEnd(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }

    /// The app is launched by Finder/launchd, so it does not inherit a login shell's
    /// environment. `SSH_AUTH_SOCK` is the one that matters — without it ssh cannot
    /// reach the agent and every key-based connection fails.
    public static func inheritedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if env["SSH_AUTH_SOCK"] == nil, let socket = launchdSSHAuthSock() {
            env["SSH_AUTH_SOCK"] = socket
        }
        return env
    }

    /// macOS registers the per-session ssh-agent socket with launchd; ask for it directly
    /// when it is absent from our environment.
    private static func launchdSSHAuthSock() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["getenv", "SSH_AUTH_SOCK"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
