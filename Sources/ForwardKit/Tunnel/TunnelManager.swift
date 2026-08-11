import Foundation
import Observation

public enum HostState: Sendable, Equatable {
    case stopped
    case starting
    case up
    case reconnecting(attempt: Int)
    case failed(reason: String)

    public var isActive: Bool {
        switch self {
        case .up, .starting, .reconnecting: true
        case .stopped, .failed: false
        }
    }

    public var isBusy: Bool {
        switch self {
        case .starting, .reconnecting: true
        default: false
        }
    }
}

public enum ForwardState: Sendable, Equatable {
    case inactive
    case pending
    case active
    case failed(reason: String)

    public var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

/// Orchestrates one `SSHSession` per host: start/stop, health polling, reconnect
/// backoff, and reconciling running tunnels against edits to the config.
@MainActor
@Observable
public final class TunnelManager {
    public private(set) var hostStates: [UUID: HostState] = [:]
    public private(set) var forwardStates: [UUID: ForwardState] = [:]
    public private(set) var logs: [UUID: LogBuffer] = [:]
    /// Last transient error worth showing in the UI, keyed by host.
    public private(set) var hostMessages: [UUID: String] = [:]

    private let store: ConfigStore
    private var sessions: [UUID: SSHSession] = [:]
    /// Connection identity each live session was created with, so we know when a config
    /// edit requires a full reconnect rather than a forward-level adjustment.
    private var sessionIdentities: [UUID: String] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    /// Serialises operations per host so rapid toggling cannot interleave start and stop.
    private var hostQueue: [UUID: Task<Void, Never>] = [:]
    /// Hosts we are deliberately stopping — their master exiting is expected, not a drop.
    private var stoppingHosts: Set<UUID> = []
    private var healthTask: Task<Void, Never>?
    /// Everything needed to kill a master without touching the actor or the config —
    /// the only thing `shutdownSynchronously` can rely on.
    private var masterRecords: [UUID: MasterRecord] = [:]

    private struct MasterRecord {
        let pid: Int32
        let sshHost: String
        let socketPath: String
    }

    public init(store: ConfigStore) {
        self.store = store
        store.onExternalChange = { [weak self] config in
            self?.reconcile(with: config)
        }
    }

    public var config: Config { store.config }

    // MARK: - Lookup

    public func state(forHost id: UUID) -> HostState { hostStates[id] ?? .stopped }
    public func state(forForward id: UUID) -> ForwardState { forwardStates[id] ?? .inactive }
    public func log(forHost id: UUID) -> LogBuffer { logs[id] ?? LogBuffer() }

    public var anyActive: Bool { hostStates.values.contains { $0 == .up } }
    public var anyTrouble: Bool {
        hostStates.values.contains {
            if case .failed = $0 { return true }
            if case .reconnecting = $0 { return true }
            return false
        }
    }

    public var activeForwardCount: Int {
        forwardStates.values.filter { $0 == .active }.count
    }

    // MARK: - Lifecycle

    public func start() {
        store.startWatching()
        startHealthMonitor()
        Task { @MainActor in
            // A previous run that was force-quit or crashed leaves masters alive and
            // holding their local ports. Clear them before anything tries to bind.
            await reclaimOrphanedMasters()
            for host in store.config.hosts where host.autoStart && !host.enabledForwards.isEmpty {
                startHost(host.id)
            }
        }
    }

    /// Terminate ssh masters left over from an earlier launch of the app.
    private func reclaimOrphanedMasters() async {
        for host in store.config.hosts {
            await SSHSession.reclaimSocket(host: host, socketURL: SSHSession.socketURL(for: host.id))
        }
    }

    /// Synchronous teardown for app termination.
    ///
    /// Must be synchronous: `applicationWillTerminate` does not wait for async work, so
    /// anything awaited here would simply not run before the process dies.
    ///
    /// Driven by `masterRecords` rather than the current config, so a host deleted from
    /// config while its tunnel was still running is torn down too. Escalates rather than
    /// trusting any single mechanism: a clean `-O exit`, then SIGTERM, then SIGKILL.
    /// Leaving an ssh master behind would silently hold its local ports after we exit.
    public func shutdownSynchronously() {
        healthTask?.cancel()
        for task in reconnectTasks.values { task.cancel() }
        for task in hostQueue.values { task.cancel() }
        store.stopWatching()

        for record in masterRecords.values {
            requestCleanExit(record)
        }
        // Give the clean exits a moment to land before escalating.
        for record in masterRecords.values where isAlive(record.pid) {
            kill(record.pid, SIGTERM)
        }
        for record in masterRecords.values {
            waitForExit(record.pid, timeout: 1.5)
            if isAlive(record.pid) { kill(record.pid, SIGKILL) }
            try? FileManager.default.removeItem(atPath: record.socketPath)
        }
        masterRecords.removeAll()
    }

    private func requestCleanExit(_ record: MasterRecord) {
        guard FileManager.default.fileExists(atPath: record.socketPath) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHSession.sshPath)
        process.arguments = ["-S", record.socketPath, "-O", "exit", record.sshHost]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    private func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // Signal 0 tests for existence without delivering anything.
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func waitForExit(_ pid: Int32, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while isAlive(pid), Date() < deadline {
            usleep(50_000)
        }
    }

    // MARK: - Host operations

    public func startHost(_ hostID: UUID) {
        enqueue(hostID) { [weak self] in
            await self?.performStart(hostID, isReconnect: false)
        }
    }

    public func stopHost(_ hostID: UUID) {
        cancelReconnect(hostID)
        enqueue(hostID) { [weak self] in
            await self?.performStop(hostID)
        }
    }

    public func toggleHost(_ hostID: UUID) {
        state(forHost: hostID).isActive ? stopHost(hostID) : startHost(hostID)
    }

    public func startAll() {
        for host in store.config.hosts where !host.enabledForwards.isEmpty {
            startHost(host.id)
        }
    }

    public func stopAll() {
        for host in store.config.hosts {
            stopHost(host.id)
        }
    }

    private func performStart(_ hostID: UUID, isReconnect: Bool) async {
        guard let host = store.config.host(id: hostID) else { return }
        guard !host.enabledForwards.isEmpty else {
            hostMessages[hostID] = "No forwards are enabled for this host."
            return
        }
        if case .up = state(forHost: hostID), sessions[hostID] != nil { return }

        hostStates[hostID] = isReconnect ? .reconnecting(attempt: reconnectAttempts[hostID] ?? 1) : .starting
        hostMessages[hostID] = nil
        for forward in host.enabledForwards {
            forwardStates[forward.id] = .pending
        }

        // Any previous session for this host is finished with; make sure it is gone
        // before a new master claims the same control socket.
        if let existing = sessions[hostID] {
            stoppingHosts.insert(hostID)
            await existing.stop()
            stoppingHosts.remove(hostID)
            sessions[hostID] = nil
        }

        let session = SSHSession(host: host) { [weak self] event in
            Task { @MainActor in self?.handle(event, from: hostID) }
        }
        sessions[hostID] = session
        sessionIdentities[hostID] = host.connectionIdentity

        do {
            try await session.start()
        } catch {
            sessions[hostID] = nil
            let reason = describe(error, hostID: hostID)
            for forward in host.enabledForwards {
                forwardStates[forward.id] = .inactive
            }
            failOrRetry(hostID, reason: reason)
            return
        }

        hostStates[hostID] = .up
        reconnectAttempts[hostID] = 0
        await applyForwards(hostID)
    }

    private func performStop(_ hostID: UUID) async {
        stoppingHosts.insert(hostID)
        if let session = sessions[hostID] {
            await session.stop()
        }
        sessions[hostID] = nil
        sessionIdentities[hostID] = nil
        masterRecords[hostID] = nil
        stoppingHosts.remove(hostID)
        hostStates[hostID] = .stopped
        hostMessages[hostID] = nil
        reconnectAttempts[hostID] = 0
        if let host = store.config.host(id: hostID) {
            for forward in host.forwards {
                forwardStates[forward.id] = .inactive
            }
        }
    }

    // MARK: - Forward operations

    public func setForward(_ forwardID: UUID, enabled: Bool) {
        guard let hostID = hostID(owning: forwardID) else { return }
        store.update { config in
            guard let hostIndex = config.hosts.firstIndex(where: { $0.id == hostID }),
                  let index = config.hosts[hostIndex].forwards.firstIndex(where: { $0.id == forwardID })
            else { return }
            config.hosts[hostIndex].forwards[index].enabled = enabled
        }

        guard let forward = forward(id: forwardID) else { return }

        if enabled {
            // Enabling a forward on a stopped host is the common way to start a tunnel,
            // so bring the host up rather than making the user do it in two steps.
            if state(forHost: hostID).isActive {
                enqueue(hostID) { [weak self] in
                    await self?.establish(forward, on: hostID)
                }
            } else {
                startHost(hostID)
            }
        } else {
            enqueue(hostID) { [weak self] in
                guard let self else { return }
                if let session = self.sessions[hostID] {
                    await session.cancelForward(forward)
                }
                self.forwardStates[forwardID] = .inactive
                // A host with nothing left to forward has no reason to hold a connection.
                if let host = self.store.config.host(id: hostID), host.enabledForwards.isEmpty {
                    await self.performStop(hostID)
                }
            }
        }
    }

    public func toggleForward(_ forwardID: UUID) {
        guard let forward = forward(id: forwardID) else { return }
        setForward(forwardID, enabled: !forward.enabled)
    }

    /// Bring the session's live forwards in line with the config's enabled set.
    private func applyForwards(_ hostID: UUID) async {
        guard let session = sessions[hostID], let host = store.config.host(id: hostID) else { return }
        let desired = host.enabledForwards
        let desiredSpecs = Set(desired.map(\.forwardSpec))
        let live = await session.establishedSpecs

        for spec in live.subtracting(desiredSpecs) {
            if let stale = host.forwards.first(where: { $0.forwardSpec == spec }) {
                await session.cancelForward(stale)
            } else {
                await session.forget(spec: spec)
            }
        }
        for forward in desired where !live.contains(forward.forwardSpec) {
            await establish(forward, on: hostID)
        }
        for forward in host.forwards where !forward.enabled {
            forwardStates[forward.id] = .inactive
        }
    }

    private func establish(_ forward: Forward, on hostID: UUID) async {
        guard let session = sessions[hostID] else {
            forwardStates[forward.id] = .inactive
            return
        }
        forwardStates[forward.id] = .pending
        do {
            try await session.addForward(forward)
            forwardStates[forward.id] = .active
        } catch {
            // One rejected forward does not invalidate the connection or its siblings.
            forwardStates[forward.id] = .failed(reason: error.localizedDescription)
            hostMessages[hostID] = error.localizedDescription
        }
    }

    // MARK: - Health and reconnect

    private func startHealthMonitor() {
        healthTask?.cancel()
        let interval = max(3, store.config.settings.healthIntervalSeconds)
        healthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.runHealthCheck()
            }
        }
    }

    private func runHealthCheck() async {
        for (hostID, state) in hostStates where state == .up {
            guard let session = sessions[hostID] else { continue }
            let alive = await session.check()
            guard !alive, hostStates[hostID] == .up, !stoppingHosts.contains(hostID) else { continue }
            let reason = logs[hostID]?.mostRelevantError ?? "The connection dropped."
            failOrRetry(hostID, reason: reason)
        }
    }

    private func handle(_ event: SSHSessionEvent, from hostID: UUID) {
        switch event {
        case .log(let chunk):
            var buffer = logs[hostID] ?? LogBuffer()
            buffer.append(chunk: chunk)
            logs[hostID] = buffer

        case .masterStarted(let pid):
            if let host = store.config.host(id: hostID) {
                masterRecords[hostID] = MasterRecord(
                    pid: pid,
                    sshHost: host.sshHost,
                    socketPath: SSHSession.socketURL(for: hostID).path
                )
            }

        case .masterExited:
            masterRecords[hostID] = nil
            guard !stoppingHosts.contains(hostID) else { return }
            guard hostStates[hostID] == .up else { return }
            let reason = logs[hostID]?.mostRelevantError ?? "The connection dropped."
            failOrRetry(hostID, reason: reason)
        }
    }

    /// Decide between retrying and giving up. Errors that will never fix themselves on a
    /// retry (bad credentials, unknown host, config mistakes) go straight to failed —
    /// hammering them for six rounds just delays the real message.
    private func failOrRetry(_ hostID: UUID, reason: String) {
        for forward in store.config.host(id: hostID)?.forwards ?? [] {
            forwardStates[forward.id] = .inactive
        }
        sessions[hostID] = nil

        let attempts = (reconnectAttempts[hostID] ?? 0) + 1
        let limit = max(0, store.config.settings.maxReconnectAttempts)

        if Self.isFatal(reason) || attempts > limit {
            reconnectAttempts[hostID] = 0
            hostStates[hostID] = .failed(reason: reason)
            hostMessages[hostID] = reason
            return
        }

        reconnectAttempts[hostID] = attempts
        hostStates[hostID] = .reconnecting(attempt: attempts)
        hostMessages[hostID] = reason

        let delay = Self.backoffDelay(attempt: attempts)
        reconnectTasks[hostID]?.cancel()
        reconnectTasks[hostID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.enqueue(hostID) { [weak self] in
                await self?.performStart(hostID, isReconnect: true)
            }
        }
    }

    private func cancelReconnect(_ hostID: UUID) {
        reconnectTasks[hostID]?.cancel()
        reconnectTasks[hostID] = nil
        reconnectAttempts[hostID] = 0
    }

    /// 1, 2, 4, 8, 16, 32, capped at 60 seconds.
    public nonisolated static func backoffDelay(attempt: Int) -> Int {
        guard attempt > 0 else { return 1 }
        let exponent = min(attempt - 1, 16)
        return min(60, 1 << exponent)
    }

    /// Failures where retrying cannot help.
    public nonisolated static func isFatal(_ reason: String) -> Bool {
        let fatalMarkers = [
            "Permission denied",
            "Could not resolve hostname",
            "Host key verification failed",
            "REMOTE HOST IDENTIFICATION HAS CHANGED",
            "Bad configuration option",
            "no such identity",
            "Too many authentication failures",
            "not a valid",
        ]
        return fatalMarkers.contains { reason.localizedCaseInsensitiveContains($0) }
    }

    private func describe(_ error: any Error, hostID: UUID) -> String {
        // ssh writes the interesting part to stderr; the thrown error is often just
        // "exited with status 255".
        if case SSHError.masterExitedEarly = error, let logged = logs[hostID]?.mostRelevantError {
            return annotate(logged)
        }
        if case SSHError.timedOut = error, let logged = logs[hostID]?.mostRelevantError {
            return annotate(logged)
        }
        return annotate(error.localizedDescription)
    }

    /// Turn ssh's terser failures into something actionable in a menu bar popover.
    private func annotate(_ reason: String) -> String {
        if reason.localizedCaseInsensitiveContains("Permission denied") {
            return "\(reason) — check that your key is loaded (ssh-add -l), or use Open in Terminal."
        }
        if reason.localizedCaseInsensitiveContains("Host key verification failed") {
            return "\(reason) — connect once with Open in Terminal to accept the host key."
        }
        return reason
    }

    // MARK: - Config reconciliation

    /// Apply an external edit to `config.json` without disturbing tunnels that did not
    /// change: hosts whose connection parameters changed reconnect, hosts whose forwards
    /// changed get added/cancelled deltas, and removed hosts are torn down.
    public func reconcile(with config: Config) {
        startHealthMonitor()

        let knownIDs = Set(config.hosts.map(\.id))
        for hostID in sessions.keys where !knownIDs.contains(hostID) {
            enqueue(hostID) { [weak self] in
                await self?.performStop(hostID)
            }
        }
        for state in hostStates.keys where !knownIDs.contains(state) {
            hostStates[state] = nil
            hostMessages[state] = nil
        }

        for host in config.hosts {
            guard sessions[host.id] != nil else { continue }
            if sessionIdentities[host.id] != host.connectionIdentity {
                enqueue(host.id) { [weak self] in
                    await self?.performStop(host.id)
                    await self?.performStart(host.id, isReconnect: false)
                }
            } else {
                enqueue(host.id) { [weak self] in
                    await self?.applyForwards(host.id)
                }
            }
        }
    }

    /// Called after in-app edits so running tunnels track the change immediately.
    public func reconcileWithCurrentConfig() {
        reconcile(with: store.config)
    }

    // MARK: - Helpers

    private func hostID(owning forwardID: UUID) -> UUID? {
        store.config.hosts.first { $0.forwards.contains { $0.id == forwardID } }?.id
    }

    private func forward(id: UUID) -> Forward? {
        for host in store.config.hosts {
            if let match = host.forwards.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    /// Chain work per host so two operations on the same connection never overlap.
    private func enqueue(_ hostID: UUID, _ body: @escaping @Sendable @MainActor () async -> Void) {
        let previous = hostQueue[hostID]
        hostQueue[hostID] = Task { @MainActor in
            _ = await previous?.result
            await body()
        }
    }
}
