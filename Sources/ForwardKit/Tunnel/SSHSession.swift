import Foundation

public enum SSHSessionEvent: Sendable {
    /// A line of stderr from the master process.
    case log(String)
    /// The master process launched. Carries its pid so the manager can guarantee
    /// teardown at quit time without needing to talk to the actor.
    case masterStarted(pid: Int32)
    /// The master process exited. Carries the exit status.
    case masterExited(code: Int32)
}

public enum SSHError: Error, LocalizedError, Sendable {
    case masterFailedToStart(String)
    case masterExitedEarly(code: Int32, reason: String)
    case notConnected
    case forwardRejected(String)
    case portInUse(PortConflict)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .masterFailedToStart(let message):
            "Could not start ssh: \(message)"
        case .masterExitedEarly(let code, let reason):
            reason.isEmpty ? "ssh exited with status \(code)." : reason
        case .notConnected:
            "Not connected."
        case .forwardRejected(let message):
            message
        case .portInUse(let conflict):
            conflict.message
        case .timedOut:
            "Timed out waiting for the connection."
        }
    }
}

/// Owns exactly one ssh ControlMaster connection to one host.
///
/// The master is started with **no** forwards; every forward is then added over the
/// control socket with `ssh -O forward`. That keeps each forward's success or failure
/// independent — a single port clash cannot take down the host's other tunnels — and
/// lets forwards be toggled without ever dropping the connection.
public actor SSHSession {
    public static let sshPath = "/usr/bin/ssh"

    public let host: HostGroup
    public let socketURL: URL

    private var master: Process?
    /// Forward specs currently established over the control socket.
    private var established: Set<String> = []
    private let onEvent: @Sendable (SSHSessionEvent) -> Void

    public init(host: HostGroup, onEvent: @escaping @Sendable (SSHSessionEvent) -> Void) {
        self.host = host
        self.onEvent = onEvent
        self.socketURL = Self.socketURL(for: host.id)
    }

    /// ControlMaster sockets are `sockaddr_un` paths, capped at 104 bytes on Darwin.
    /// A truncated id keeps us far below that even with a long home directory; if the
    /// state directory itself is somehow long, fall back to /tmp.
    public static func socketURL(for hostID: UUID) -> URL {
        let short = hostID.uuidString.prefix(8).lowercased()
        let preferred = ConfigStore.stateDirectory().appending(path: "cm-\(short).sock")
        if preferred.path.utf8.count <= 100 { return preferred }
        return URL(fileURLWithPath: "/tmp/fwd-\(short).sock")
    }

    // MARK: - Argument construction

    /// Options shared by the master connection. Kept pure and static so tests can
    /// assert the exact command line without spawning anything.
    public static func connectionOptions(for host: HostGroup) -> [String] {
        var args: [String] = [
            "-o", "ControlPersist=no",
            // Detect a dead peer within ~45s rather than hanging on a black-holed TCP
            // connection forever.
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
        ]
        if host.batchMode {
            // No controlling TTY here: without BatchMode a passphrase or host-key prompt
            // would hang the process indefinitely instead of returning an error.
            args += ["-o", "BatchMode=yes"]
        }
        if let user = host.user, !user.isEmpty {
            args += ["-l", user]
        }
        if let port = host.port {
            args += ["-p", String(port)]
        }
        for option in host.extraOptions where !option.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["-o", option]
        }
        return args
    }

    public static func masterArguments(for host: HostGroup, socketPath: String) -> [String] {
        ["-N", "-M", "-S", socketPath] + connectionOptions(for: host) + [host.sshHost]
    }

    public static func controlArguments(
        for host: HostGroup,
        socketPath: String,
        verb: String,
        forward: Forward? = nil
    ) -> [String] {
        var args = ["-S", socketPath, "-O", verb]
        if let forward {
            args += ["-L", forward.forwardSpec]
        }
        args.append(host.sshHost)
        return args
    }

    /// The equivalent command a user could paste into a terminal. Used by
    /// "Open in Terminal" so host keys and passphrases can be dealt with interactively.
    public static func interactiveCommand(for host: HostGroup) -> String {
        var args = ["ssh"]
        if let user = host.user, !user.isEmpty { args += ["-l", user] }
        if let port = host.port { args += ["-p", String(port)] }
        for option in host.extraOptions where !option.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["-o", option]
        }
        for forward in host.enabledForwards {
            args += ["-L", forward.forwardSpec]
        }
        args.append(host.sshHost)
        return args.map(shellQuote).joined(separator: " ")
    }

    public static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-./:=@,+")
        if value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Master lifecycle

    public var isRunning: Bool { master?.isRunning ?? false }

    /// Start the master and wait until the control socket answers.
    ///
    /// Throws rather than returning a partial state: on failure the process is cleaned
    /// up and the caller can surface `error.localizedDescription` directly.
    public func start() async throws {
        guard master == nil else { return }
        await Self.reclaimSocket(host: host, socketURL: socketURL)
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sshPath)
        process.arguments = Self.masterArguments(for: host, socketPath: socketURL.path)
        process.environment = ProcessRunner.inheritedEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let errPipe = Pipe()
        process.standardError = errPipe
        let sink = onEvent
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            sink(.log(String(decoding: data, as: UTF8.self)))
        }
        process.terminationHandler = { finished in
            errPipe.fileHandleForReading.readabilityHandler = nil
            sink(.masterExited(code: finished.terminationStatus))
        }

        do {
            try process.run()
        } catch {
            throw SSHError.masterFailedToStart(error.localizedDescription)
        }
        master = process
        established.removeAll()
        onEvent(.masterStarted(pid: process.processIdentifier))

        do {
            try await waitUntilReady(process: process)
        } catch {
            await stop()
            throw error
        }
    }

    /// Poll the control socket until the master answers. Bails out early if the process
    /// dies, so an auth failure surfaces immediately instead of after the full timeout.
    private func waitUntilReady(process: Process, timeout: Duration = .seconds(25)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if !process.isRunning {
                throw SSHError.masterExitedEarly(code: process.terminationStatus, reason: "")
            }
            if await rawCheck() { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw SSHError.timedOut
    }

    /// `ssh -O check` — true when the master is alive and serving its control socket.
    /// This is a real liveness probe, unlike merely asking whether the process exists.
    public func check() async -> Bool {
        guard let master, master.isRunning else { return false }
        return await rawCheck()
    }

    private func rawCheck() async -> Bool {
        guard FileManager.default.fileExists(atPath: socketURL.path) else { return false }
        let result = try? await ProcessRunner.run(
            Self.sshPath,
            Self.controlArguments(for: host, socketPath: socketURL.path, verb: "check"),
            timeout: .seconds(8)
        )
        return result?.succeeded ?? false
    }

    /// Ask the master to exit cleanly, then make sure it is really gone.
    public func stop() async {
        if FileManager.default.fileExists(atPath: socketURL.path) {
            _ = try? await ProcessRunner.run(
                Self.sshPath,
                Self.controlArguments(for: host, socketPath: socketURL.path, verb: "exit"),
                timeout: .seconds(5)
            )
        }
        if let master, master.isRunning {
            // Give the clean exit a moment to land before escalating.
            for _ in 0..<10 where master.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if master.isRunning { master.terminate() }
            for _ in 0..<10 where master.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if master.isRunning { kill(master.processIdentifier, SIGKILL) }
        }
        master = nil
        established.removeAll()
        removeStaleSocket()
    }

    /// Deal with a control socket left behind by a previous run.
    ///
    /// Deleting the socket file is not enough: if the old master is still alive it keeps
    /// running — and keeps its local ports bound — invisibly. Ask it to exit first, then
    /// unlink, so ssh does not refuse to start with "ControlSocket already exists".
    public static func reclaimSocket(host: HostGroup, socketURL: URL) async {
        guard FileManager.default.fileExists(atPath: socketURL.path) else { return }
        _ = try? await ProcessRunner.run(
            sshPath,
            controlArguments(for: host, socketPath: socketURL.path, verb: "exit"),
            timeout: .seconds(5)
        )
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func removeStaleSocket() {
        try? FileManager.default.removeItem(at: socketURL)
    }

    // MARK: - Forwards

    public var establishedSpecs: Set<String> { established }

    /// Add a forward over the control socket. Checks the local port first so the failure
    /// names the offending process instead of surfacing a bare bind error.
    public func addForward(_ forward: Forward) async throws {
        guard master?.isRunning == true else { throw SSHError.notConnected }
        guard !established.contains(forward.forwardSpec) else { return }

        if let conflict = await PortProbe.conflict(port: forward.localPort) {
            throw SSHError.portInUse(conflict)
        }

        let result = try await ProcessRunner.run(
            Self.sshPath,
            Self.controlArguments(for: host, socketPath: socketURL.path, verb: "forward", forward: forward),
            timeout: .seconds(15)
        )
        guard result.succeeded else {
            let reason = Self.cleanError(result.stderr)
            onEvent(.log(result.stderr))
            throw SSHError.forwardRejected(reason.isEmpty ? "ssh refused the forward." : reason)
        }
        established.insert(forward.forwardSpec)
    }

    /// Remove a forward without disturbing the connection or its sibling forwards.
    public func cancelForward(_ forward: Forward) async {
        guard master?.isRunning == true else {
            established.remove(forward.forwardSpec)
            return
        }
        let result = try? await ProcessRunner.run(
            Self.sshPath,
            Self.controlArguments(for: host, socketPath: socketURL.path, verb: "cancel", forward: forward),
            timeout: .seconds(10)
        )
        if let result, !result.succeeded {
            onEvent(.log(result.stderr))
        }
        established.remove(forward.forwardSpec)
    }

    /// Forget a spec without talking to ssh — used when a forward is edited and the old
    /// spec no longer describes anything.
    public func forget(spec: String) {
        established.remove(spec)
    }

    static func cleanError(_ stderr: String) -> String {
        stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
            .last ?? ""
    }
}
