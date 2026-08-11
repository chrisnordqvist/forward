import Foundation
import Testing

@testable import ForwardKit

/// End-to-end tests against a real ssh server.
///
/// These are skipped unless a test sshd is running and its details are exported. See
/// `Scripts/test-sshd.sh`, which sets up a throwaway sshd on a high port with its own
/// host key and authorized_keys, and exports:
///
///   FORWARD_TEST_SSH_PORT   port the test sshd listens on
///   FORWARD_TEST_SSH_KEY    path to the client private key
///   FORWARD_TEST_KNOWN      path to a known_hosts file
///   FORWARD_TEST_HTTP_PORT  port of an HTTP server on the far side to forward to
@Suite("Live ssh integration", .serialized, .enabled(if: LiveEnvironment.isConfigured))
@MainActor
struct IntegrationTests {
    /// A local port very unlikely to collide with anything else on the machine.
    private func freeLocalPort() -> Int {
        for candidate in 34_000...34_200 where PortProbe.isAvailable(port: candidate) {
            return candidate
        }
        return 34_999
    }

    private func makeStore() -> (ConfigStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "forward-live-\(UUID().uuidString)")
        let url = directory.appending(path: "config.json")
        return (ConfigStore(configURL: url), url)
    }

    private func testHost(localPort: Int, id: UUID = UUID()) -> HostGroup {
        let environment = LiveEnvironment.self
        return HostGroup(
            id: id,
            name: "Live",
            sshHost: "127.0.0.1",
            port: environment.sshPort,
            batchMode: true,
            extraOptions: [
                "IdentityFile=\(environment.keyPath)",
                "IdentitiesOnly=yes",
                "StrictHostKeyChecking=no",
                "UserKnownHostsFile=\(environment.knownHostsPath)",
            ],
            forwards: [
                Forward(
                    name: "Web",
                    localPort: localPort,
                    remoteHost: "localhost",
                    remotePort: environment.httpPort,
                    enabled: true
                )
            ]
        )
    }

    private func waitFor(
        _ description: String,
        timeout: Duration = .seconds(30),
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// Fetches through the tunnel, proving the forward carries real traffic rather than
    /// merely holding the port open.
    private func fetchThroughTunnel(port: Int) async -> String? {
        guard let result = try? await ProcessRunner.run(
            "/usr/bin/curl", ["-s", "--max-time", "5", "http://127.0.0.1:\(port)/probe.txt"]
        ), result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("A host starts, forwards traffic, and stops cleanly")
    func startsAndForwards() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let port = freeLocalPort()
        let host = testHost(localPort: port)
        store.update { $0.hosts = [host] }

        let manager = TunnelManager(store: store)
        manager.startHost(host.id)

        #expect(await waitFor("host up") { manager.state(forHost: host.id) == .up },
                "host never reached .up — \(manager.log(forHost: host.id).text)")

        let forwardID = try #require(host.forwards.first?.id)
        #expect(await waitFor("forward active") { manager.state(forForward: forwardID) == .active },
                "forward never became active — \(manager.log(forHost: host.id).text)")

        #expect(await fetchThroughTunnel(port: port) == "HELLO_FROM_TUNNEL")

        manager.stopHost(host.id)
        #expect(await waitFor("host stopped") { manager.state(forHost: host.id) == .stopped })
        #expect(await waitFor("port released") { PortProbe.isAvailable(port: port) },
                "the local port must be released when the tunnel stops")
    }

    @Test("A dropped connection reconnects and re-establishes its forwards")
    func reconnectsAndRestoresForwards() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let port = freeLocalPort()
        let host = testHost(localPort: port)
        store.update {
            $0.hosts = [host]
            $0.settings.healthIntervalSeconds = 3
        }

        let manager = TunnelManager(store: store)
        manager.startHost(host.id)
        #expect(await waitFor("host up") { manager.state(forHost: host.id) == .up })

        let forwardID = try #require(host.forwards.first?.id)
        #expect(await waitFor("forward active") { manager.state(forForward: forwardID) == .active })
        #expect(await fetchThroughTunnel(port: port) == "HELLO_FROM_TUNNEL")

        // Kill the master out from under the app, the way a dropped network would.
        let socket = SSHSession.socketURL(for: host.id)
        _ = try? await ProcessRunner.run("/usr/bin/pkill", ["-9", "-f", "ssh -N -M -S \(socket.path)"])

        #expect(await waitFor("noticed the drop", timeout: .seconds(30)) {
            manager.state(forHost: host.id) != .up
        }, "the health check never noticed the master had died")

        #expect(await waitFor("reconnected", timeout: .seconds(60)) {
            manager.state(forHost: host.id) == .up
        }, "never reconnected — \(manager.log(forHost: host.id).text)")

        // The real regression risk: reconnecting but forgetting to re-add the forwards.
        #expect(await waitFor("forward restored", timeout: .seconds(30)) {
            manager.state(forForward: forwardID) == .active
        }, "reconnected but the forward was not restored — \(manager.log(forHost: host.id).text)")

        #expect(await fetchThroughTunnel(port: port) == "HELLO_FROM_TUNNEL",
                "the restored forward must actually carry traffic")

        manager.stopHost(host.id)
        #expect(await waitFor("stopped") { manager.state(forHost: host.id) == .stopped })
    }

    @Test("A local port already in use is reported instead of silently failing")
    func reportsPortConflict() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let port = freeLocalPort()
        // Hold the port with a listener before the tunnel tries to bind it.
        let blocker = Process()
        blocker.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        blocker.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
        blocker.standardOutput = FileHandle.nullDevice
        blocker.standardError = FileHandle.nullDevice
        try blocker.run()
        defer { blocker.terminate() }
        #expect(await waitFor("blocker bound") { !PortProbe.isAvailable(port: port) })

        let host = testHost(localPort: port)
        store.update { $0.hosts = [host] }

        let manager = TunnelManager(store: store)
        manager.startHost(host.id)

        let forwardID = try #require(host.forwards.first?.id)
        #expect(await waitFor("conflict reported") {
            manager.state(forForward: forwardID).failureReason != nil
        }, "a port clash must surface as a forward failure")

        let reason = try #require(manager.state(forForward: forwardID).failureReason)
        #expect(reason.contains("\(port)"))
        #expect(reason.localizedCaseInsensitiveContains("in use"))
        // The connection itself is fine — only the one forward failed.
        #expect(manager.state(forHost: host.id) == .up)

        manager.stopHost(host.id)
        #expect(await waitFor("stopped") { manager.state(forHost: host.id) == .stopped })
    }

    @Test("Enabling a second forward reuses the existing connection")
    func addsForwardWithoutReconnecting() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = freeLocalPort()
        let second = first + 1
        var host = testHost(localPort: first)
        let extra = Forward(
            name: "Second",
            localPort: second,
            remoteHost: "localhost",
            remotePort: LiveEnvironment.httpPort,
            enabled: false
        )
        host.forwards.append(extra)
        store.update { $0.hosts = [host] }

        let manager = TunnelManager(store: store)
        manager.startHost(host.id)
        #expect(await waitFor("host up") { manager.state(forHost: host.id) == .up })

        let masterPID = await masterProcessID(for: host.id)
        #expect(masterPID != nil)

        manager.setForward(extra.id, enabled: true)
        #expect(await waitFor("second forward active") {
            manager.state(forForward: extra.id) == .active
        }, "second forward never came up — \(manager.log(forHost: host.id).text)")

        #expect(await fetchThroughTunnel(port: second) == "HELLO_FROM_TUNNEL")
        // The point of ControlMaster: no new connection, no reauthentication.
        #expect(await masterProcessID(for: host.id) == masterPID,
                "adding a forward must not respawn ssh")
        // ...and the original forward is undisturbed.
        #expect(await fetchThroughTunnel(port: first) == "HELLO_FROM_TUNNEL")

        // Always await the teardown: returning early would leave an ssh master running
        // past the end of the test process, still holding these ports.
        manager.stopHost(host.id)
        #expect(await waitFor("stopped") { manager.state(forHost: host.id) == .stopped })
    }

    private func masterProcessID(for hostID: UUID) async -> String? {
        let socket = SSHSession.socketURL(for: hostID)
        guard let result = try? await ProcessRunner.run(
            "/usr/bin/pgrep", ["-f", "ssh -N -M -S \(socket.path)"]
        ), result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LiveEnvironment {
    static var sshPort: Int? {
        ProcessInfo.processInfo.environment["FORWARD_TEST_SSH_PORT"].flatMap(Int.init)
    }
    static var httpPort: Int {
        ProcessInfo.processInfo.environment["FORWARD_TEST_HTTP_PORT"].flatMap(Int.init) ?? 0
    }
    static var keyPath: String {
        ProcessInfo.processInfo.environment["FORWARD_TEST_SSH_KEY"] ?? ""
    }
    static var knownHostsPath: String {
        ProcessInfo.processInfo.environment["FORWARD_TEST_KNOWN"] ?? ""
    }
    static var isConfigured: Bool {
        sshPort != nil && httpPort != 0 && !keyPath.isEmpty && FileManager.default.fileExists(atPath: keyPath)
    }
}
