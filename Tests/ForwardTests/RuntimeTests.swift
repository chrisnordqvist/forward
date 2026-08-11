import Darwin
import Foundation
import Testing

@testable import ForwardKit

/// Serialized: these tests bind and release kernel-assigned ephemeral ports. Run in
/// parallel, one test's just-released port can be handed straight to another, which
/// then looks like a spurious conflict.
@Suite("Port probing", .serialized)
struct PortProbeTests {
    /// Binds a real loopback port for the duration of a test so the probe has something
    /// genuine to collide with.
    private final class BoundPort {
        private var descriptor: Int32
        let port: Int

        init?() {
            let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { return nil }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0  // let the kernel choose a free port
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let bound = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 1) == 0 else { close(fd); return nil }

            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &actual) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &length)
                }
            }
            guard named == 0 else { close(fd); return nil }

            descriptor = fd
            port = Int(UInt16(bigEndian: actual.sin_port))
        }

        var descriptorForTesting: Int32 { descriptor }

        func release() {
            guard descriptor >= 0 else { return }
            close(descriptor)
            descriptor = -1
        }

        deinit { release() }
    }

    @Test("A port held by a listening socket reads as unavailable")
    func detectsBoundPort() throws {
        let held = try #require(BoundPort())
        #expect(PortProbe.isAvailable(port: held.port) == false)
    }

    @Test("Releasing the port makes it available again")
    func detectsReleasedPort() throws {
        let held = try #require(BoundPort())
        #expect(PortProbe.isAvailable(port: held.port) == false)
        held.release()
        #expect(PortProbe.isAvailable(port: held.port) == true)
    }

    @Test("A conflict names the port, and identifies the holder when lsof can see it")
    func conflictDescribesPort() async throws {
        let held = try #require(BoundPort())
        let conflict = try #require(await PortProbe.conflict(port: held.port))
        #expect(conflict.port == held.port)
        #expect(conflict.message.contains("\(held.port)"))
        // The holder is this test process; lsof should be able to name it.
        #expect(conflict.holder?.isEmpty == false)
    }

    @Test("No conflict is reported for a free port")
    func freePortHasNoConflict() async throws {
        // Bind then release, so we know for certain nothing else is on this port.
        let held = try #require(BoundPort())
        held.release()
        #expect(await PortProbe.conflict(port: held.port) == nil)
    }

    /// Regression: a tunnel that has carried traffic leaves sockets in TIME_WAIT. A probe
    /// without SO_REUSEADDR reports those as "in use", which made restarting a tunnel —
    /// or reconnecting a dropped one — fail with a bogus port conflict for up to a minute.
    /// ssh sets SO_REUSEADDR on its forward listeners, so the probe must too.
    @Test("A port with connections in TIME_WAIT still reads as available")
    func ignoresTimeWait() throws {
        let listener = try #require(BoundPort())
        let port = listener.port

        // Connect a client so there is a real connection to leave behind.
        let client = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        #expect(client >= 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connected == 0)

        let accepted = accept(listener.descriptorForTesting, nil, nil)
        #expect(accepted >= 0)

        // Closing the server side first puts *this* end into TIME_WAIT on `port`.
        close(accepted)
        close(client)
        listener.release()

        // The teardown passes briefly through FIN_WAIT_2/LAST_ACK, where *no* bind
        // succeeds — SO_REUSEADDR only bypasses TIME_WAIT. So wait for the moment the
        // probe first reports the port free, and check right then that a plain bind is
        // still refused. That pins the property exactly: TIME_WAIT is present, and
        // SO_REUSEADDR is the only reason the probe can see past it.
        var probeSucceeded = false
        var plainBindStillRefused = false
        for _ in 0..<200 {
            if PortProbe.isAvailable(port: port) {
                probeSucceeded = true
                plainBindStillRefused = !bindWithoutReuse(port: port)
                break
            }
            usleep(50_000)
        }

        #expect(probeSucceeded, "TIME_WAIT must not be mistaken for a port conflict")
        #expect(
            plainBindStillRefused,
            "the connection had already left TIME_WAIT, so this run proved nothing"
        )
    }

    /// A bind with the default options — what the probe used to do, and what fails while
    /// sockets linger in TIME_WAIT.
    private func bindWithoutReuse(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    @Test("Ports outside the valid range are never considered available")
    func rejectsInvalidPorts() {
        #expect(PortProbe.isAvailable(port: 0) == false)
        #expect(PortProbe.isAvailable(port: -1) == false)
        #expect(PortProbe.isAvailable(port: 70000) == false)
    }
}

@Suite("Reconnect policy")
struct ReconnectPolicyTests {
    @Test("Backoff doubles and then holds at 60 seconds")
    func backoffSequence() {
        let delays = (1...10).map(TunnelManager.backoffDelay)
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60, 60, 60])
    }

    @Test("Backoff is defensive about a zero or negative attempt count")
    func backoffFloor() {
        #expect(TunnelManager.backoffDelay(attempt: 0) == 1)
        #expect(TunnelManager.backoffDelay(attempt: -5) == 1)
        #expect(TunnelManager.backoffDelay(attempt: 1000) == 60)
    }

    @Test("Errors a retry cannot fix stop the loop immediately")
    func fatalErrorsAreNotRetried() {
        #expect(TunnelManager.isFatal("deploy@box: Permission denied (publickey)."))
        #expect(TunnelManager.isFatal("ssh: Could not resolve hostname nope: nodename nor servname provided"))
        #expect(TunnelManager.isFatal("Host key verification failed."))
        #expect(TunnelManager.isFatal("command-line: line 0: Bad configuration option: frobnicate"))
    }

    @Test("Transient network errors are retried")
    func transientErrorsAreRetried() {
        #expect(!TunnelManager.isFatal("ssh: connect to host box port 22: Connection refused"))
        #expect(!TunnelManager.isFatal("ssh: connect to host box port 22: Operation timed out"))
        #expect(!TunnelManager.isFatal("Timeout, server box not responding."))
        #expect(!TunnelManager.isFatal("The connection dropped."))
    }
}

@Suite("Log buffer")
struct LogBufferTests {
    @Test("The buffer keeps only the most recent lines")
    func ringBufferEvicts() {
        var buffer = LogBuffer(capacity: 3)
        for index in 1...5 { buffer.append("line \(index)") }
        #expect(buffer.lines == ["line 3", "line 4", "line 5"])
    }

    @Test("A chunk of output is split into lines and blanks are dropped")
    func splitsChunks() {
        var buffer = LogBuffer(capacity: 10)
        buffer.append(chunk: "first\n\n  second  \n")
        #expect(buffer.lines == ["first", "second"])
    }

    @Test("The relevant error is preferred over ssh's last, less useful line")
    func picksRelevantError() {
        var buffer = LogBuffer(capacity: 10)
        buffer.append("Warning: Permanently added 'box' to the list of known hosts.")
        buffer.append("deploy@box: Permission denied (publickey).")
        buffer.append("Killed by signal 1.")
        #expect(buffer.mostRelevantError == "deploy@box: Permission denied (publickey).")
    }

    @Test("With nothing recognisable, the last line is used")
    func fallsBackToLastLine() {
        var buffer = LogBuffer(capacity: 10)
        buffer.append("something unexpected")
        #expect(buffer.mostRelevantError == "something unexpected")

        let empty = LogBuffer()
        #expect(empty.mostRelevantError == nil)
    }
}

@Suite("Process runner")
struct ProcessRunnerTests {
    @Test("Captures stdout, stderr and the exit code")
    func capturesOutput() async throws {
        let result = try await ProcessRunner.run(
            "/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"]
        )
        #expect(result.exitCode == 3)
        #expect(result.succeeded == false)
        #expect(result.stdout.contains("out"))
        #expect(result.stderr.contains("err"))
    }

    @Test("A process that exits instantly does not hang the caller")
    func handlesImmediateExit() async throws {
        let result = try await ProcessRunner.run("/usr/bin/true", [])
        #expect(result.succeeded)
    }

    @Test("Output larger than a pipe buffer is read without deadlocking")
    func handlesLargeOutput() async throws {
        let result = try await ProcessRunner.run(
            "/bin/sh", ["-c", "for i in $(seq 1 5000); do echo 'a line of output padding'; done"],
            timeout: .seconds(30)
        )
        #expect(result.succeeded)
        #expect(result.stdout.split(separator: "\n").count == 5000)
    }

    @Test("A hung process is terminated at the timeout")
    func enforcesTimeout() async throws {
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "sleep 30"], timeout: .seconds(1))
        #expect(result.succeeded == false)
    }

    @Test("Launching a missing executable throws instead of hanging")
    func reportsLaunchFailure() async {
        await #expect(throws: ProcessRunnerError.self) {
            try await ProcessRunner.run("/nonexistent/binary", [])
        }
    }

    @Test("The spawn environment preserves the process environment")
    func preservesEnvironment() {
        let base = ProcessInfo.processInfo.environment
        let env = ProcessRunner.inheritedEnvironment()
        // ssh needs HOME to find ~/.ssh/config; dropping it would break host aliases.
        for (key, value) in base {
            #expect(env[key] == value, "\(key) must be passed through to ssh")
        }
    }

    @Test("An agent socket is filled in when one exists, and its absence is not fatal")
    func resolvesAgentSocketWhenAvailable() {
        // Launched from Finder the app inherits no shell environment, so the agent socket
        // is looked up via launchctl. Machines using unencrypted IdentityFile keys have no
        // agent at all and work fine without one — so this asserts consistency, not presence.
        let env = ProcessRunner.inheritedEnvironment()
        if let inherited = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            #expect(env["SSH_AUTH_SOCK"] == inherited, "an inherited socket must not be overwritten")
        }
        if let resolved = env["SSH_AUTH_SOCK"] {
            #expect(!resolved.isEmpty, "an empty socket path is worse than none — ssh would fail on it")
        }
    }
}
