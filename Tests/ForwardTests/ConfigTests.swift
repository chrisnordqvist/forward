import Foundation
import Testing

@testable import ForwardKit

@Suite("Config coding")
struct ConfigCodingTests {
    @Test("A config survives an encode/decode round trip")
    func roundTrip() throws {
        let config = Config(
            hosts: [
                HostGroup(
                    name: "Staging",
                    sshHost: "staging-api",
                    user: "deploy",
                    port: 2222,
                    autoStart: true,
                    extraOptions: ["Compression=yes"],
                    forwards: [
                        Forward(name: "API", localPort: 4000, remotePort: 4000, enabled: true),
                        Forward(name: "PG", localPort: 5432, remoteHost: "db.internal", remotePort: 5432),
                    ]
                )
            ],
            settings: AppSettings(launchAtLogin: true, healthIntervalSeconds: 20, maxReconnectAttempts: 3)
        )

        let decoded = try ConfigStore.decode(ConfigStore.encode(config))
        #expect(decoded == config)
    }

    @Test("Missing optional keys fall back to defaults instead of failing the file")
    func toleratesMissingKeys() throws {
        let json = """
        { "hosts": [ { "sshHost": "box", "forwards": [ { "localPort": 8080 } ] } ] }
        """
        let config = try ConfigStore.decode(Data(json.utf8))

        #expect(config.version == 1)
        #expect(config.hosts.count == 1)
        // name defaults to the ssh host so the UI always has something to show.
        #expect(config.hosts[0].name == "box")
        #expect(config.hosts[0].batchMode == true)
        #expect(config.hosts[0].autoStart == false)

        let forward = try #require(config.hosts[0].forwards.first)
        #expect(forward.localPort == 8080)
        // remotePort mirrors localPort, matching the common `-L 8080:localhost:8080` case.
        #expect(forward.remotePort == 8080)
        #expect(forward.remoteHost == "localhost")
        #expect(forward.enabled == false)
        #expect(config.settings.healthIntervalSeconds == 10)
    }

    @Test("Unknown keys from a newer version are ignored rather than rejected")
    func toleratesUnknownKeys() throws {
        let json = """
        {
          "version": 99,
          "somethingNew": true,
          "hosts": [ { "sshHost": "box", "kind": "socks", "forwards": [] } ],
          "settings": { "futureFlag": 1 }
        }
        """
        let config = try ConfigStore.decode(Data(json.utf8))
        #expect(config.hosts.count == 1)
        #expect(config.version == 99)
    }

    @Test("Hand-editing conveniences are accepted: comments and trailing commas")
    func acceptsJSON5() throws {
        let json = """
        {
          // the staging box
          "hosts": [
            { "sshHost": "box", "forwards": [ { "localPort": 3000, } ], },
          ],
        }
        """
        let config = try ConfigStore.decode(Data(json.utf8))
        #expect(config.hosts.first?.forwards.first?.localPort == 3000)
    }

    @Test("A malformed file throws rather than silently yielding an empty config")
    func rejectsGarbage() {
        #expect(throws: (any Error).self) {
            try ConfigStore.decode(Data("not json at all".utf8))
        }
    }
}

@Suite("Config validation")
struct ConfigValidationTests {
    private func config(_ forwards: [Forward]) -> Config {
        Config(hosts: [HostGroup(name: "H", sshHost: "h", forwards: forwards)])
    }

    @Test("Two enabled forwards on one local port are reported as a duplicate")
    func detectsDuplicates() {
        let subject = config([
            Forward(name: "a", localPort: 4000, remotePort: 1, enabled: true),
            Forward(name: "b", localPort: 4000, remotePort: 2, enabled: true),
        ])
        #expect(subject.duplicateLocalPorts() == [4000])
        #expect(subject.validationIssues().count == 1)
    }

    @Test("Disabled forwards may share a port — only one can ever bind")
    func ignoresDisabledDuplicates() {
        let subject = config([
            Forward(name: "a", localPort: 4000, remotePort: 1, enabled: true),
            Forward(name: "b", localPort: 4000, remotePort: 2, enabled: false),
        ])
        #expect(subject.duplicateLocalPorts().isEmpty)
        #expect(subject.validationIssues().isEmpty)
    }

    @Test("Ports outside 1–65535 are flagged")
    func flagsOutOfRangePorts() {
        let subject = config([Forward(name: "a", localPort: 70000, remotePort: 0)])
        #expect(subject.validationIssues().count == 2)
    }

    @Test("A host with no ssh host set is flagged")
    func flagsMissingHost() {
        let subject = Config(hosts: [HostGroup(name: "Empty", sshHost: "  ")])
        #expect(subject.validationIssues().contains { $0.contains("no SSH host") })
    }
}

@Suite("ConfigStore persistence")
struct ConfigStorePersistenceTests {
    @Test("Saving writes the file, and a fresh store reads it back")
    @MainActor
    func writesAndReloads() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "forward-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")

        let store = ConfigStore(configURL: url)
        // A brand-new store seeds an empty config file rather than leaving nothing behind.
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(store.config.hosts.isEmpty)

        store.update { $0.hosts.append(HostGroup(name: "Box", sshHost: "box")) }

        let reloaded = ConfigStore(configURL: url)
        #expect(reloaded.config.hosts.map(\.name) == ["Box"])
        #expect(reloaded.loadError == nil)
    }

    @Test("A corrupt file keeps the loaded config and surfaces an error")
    @MainActor
    func survivesCorruptFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "forward-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")

        let store = ConfigStore(configURL: url)
        store.update { $0.hosts.append(HostGroup(name: "Box", sshHost: "box")) }

        // Simulate an editor mid-save writing a truncated file.
        try Data("{ \"hosts\": [".utf8).write(to: url)
        store.reloadFromDisk(notify: false)

        #expect(store.loadError != nil)
        #expect(store.config.hosts.map(\.name) == ["Box"], "running state must not be wiped by a bad parse")
    }
}
