import Foundation
import Testing

@testable import ForwardKit

/// External edits must be noticed however they were written. The two cases below are
/// genuinely different at the filesystem level and each needs its own watch:
/// a truncating write never touches the directory entry, and an atomic replace
/// orphans the inode a file-level watch is holding.
@Suite("External config edits", .serialized)
@MainActor
struct ConfigWatchTests {
    private func makeStore() -> (ConfigStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "forward-watch-\(UUID().uuidString)")
        let url = directory.appending(path: "config.json")
        return (ConfigStore(configURL: url), url)
    }

    private func hostsJSON(_ name: String) -> Data {
        Data("""
        { "hosts": [ { "id": "AAAAAAAA-0000-0000-0000-000000000001",
                       "name": "\(name)", "sshHost": "box", "forwards": [] } ] }
        """.utf8)
    }

    /// Waits for the watcher rather than sleeping a fixed amount, so the test is not
    /// timing-fragile on a loaded machine.
    private func waitForChange(_ store: ConfigStore, to name: String) async -> Bool {
        for _ in 0..<60 {
            if store.config.hosts.first?.name == name { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test("An in-place truncating write is picked up")
    func detectsInPlaceWrite() async throws {
        let (store, url) = makeStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        store.startWatching()

        var notified: Config?
        store.onExternalChange = { notified = $0 }

        // Mimics `>` redirection and most scripts: same inode, contents replaced.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: hostsJSON("InPlace"))
        try handle.close()

        #expect(await waitForChange(store, to: "InPlace"))
        #expect(notified?.hosts.first?.name == "InPlace")
    }

    @Test("An atomic replace-by-rename is picked up")
    func detectsAtomicReplace() async throws {
        let (store, url) = makeStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        store.startWatching()

        // Mimics how most editors save: write a temp file, rename it over the original.
        try hostsJSON("Replaced").write(to: url, options: .atomic)

        #expect(await waitForChange(store, to: "Replaced"))
    }

    @Test("Two successive external edits are both seen")
    func detectsRepeatedEdits() async throws {
        let (store, url) = makeStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        store.startWatching()

        // The second edit is the one that regresses if the watch is not re-armed after
        // the first replace orphans its inode.
        try hostsJSON("First").write(to: url, options: .atomic)
        #expect(await waitForChange(store, to: "First"))

        try hostsJSON("Second").write(to: url, options: .atomic)
        #expect(await waitForChange(store, to: "Second"))
    }

    @Test("The app's own saves do not report themselves as external changes")
    func ignoresOwnWrites() async throws {
        let (store, url) = makeStore()
        defer {
            store.stopWatching()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        store.startWatching()

        var externalNotifications = 0
        store.onExternalChange = { _ in externalNotifications += 1 }

        store.update { $0.hosts.append(HostGroup(name: "FromApp", sshHost: "box")) }
        try? await Task.sleep(for: .milliseconds(800))

        #expect(externalNotifications == 0, "a self-save must not round-trip back through reconcile")
        #expect(store.config.hosts.first?.name == "FromApp")
    }
}
