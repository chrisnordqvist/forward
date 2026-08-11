import Foundation

/// A single local port forward: `-L <localPort>:<remoteHost>:<remotePort>`.
public struct Forward: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var localPort: Int
    /// Host to connect to *from the remote side*. Usually "localhost".
    public var remoteHost: String
    public var remotePort: Int
    /// Whether this forward should be active when its host is running.
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        localPort: Int,
        remoteHost: String = "localhost",
        remotePort: Int,
        enabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.enabled = enabled
    }

    /// The argument to `-L`. Bound to 127.0.0.1 explicitly so the forward is never
    /// exposed on the local network regardless of the user's GatewayPorts setting.
    public var forwardSpec: String {
        "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)"
    }

    public var displaySpec: String {
        remoteHost == "localhost" || remoteHost == "127.0.0.1"
            ? "\(localPort) → \(remotePort)"
            : "\(localPort) → \(remoteHost):\(remotePort)"
    }

    // Tolerate configs written by older/newer versions: missing keys fall back to defaults
    // rather than failing the whole file to parse.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Forward"
        localPort = try c.decode(Int.self, forKey: .localPort)
        remoteHost = try c.decodeIfPresent(String.self, forKey: .remoteHost) ?? "localhost"
        remotePort = try c.decodeIfPresent(Int.self, forKey: .remotePort) ?? localPort
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

/// A remote host and the set of forwards tunnelled through it.
/// One host == one ssh master connection == one group in the UI.
public struct HostGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Display name for the group.
    public var name: String
    /// Passed verbatim to ssh — may be a `~/.ssh/config` Host alias.
    public var sshHost: String
    /// Optional `-l <user>`; nil defers to ssh config.
    public var user: String?
    /// Optional `-p <port>`; nil defers to ssh config.
    public var port: Int?
    /// `-o BatchMode=yes` — fail fast instead of hanging on a passphrase prompt.
    public var batchMode: Bool
    /// Start this host's enabled forwards when the app launches.
    public var autoStart: Bool
    /// Extra raw ssh options, each appended as `-o <option>`.
    public var extraOptions: [String]
    public var forwards: [Forward]

    public init(
        id: UUID = UUID(),
        name: String,
        sshHost: String,
        user: String? = nil,
        port: Int? = nil,
        batchMode: Bool = true,
        autoStart: Bool = false,
        extraOptions: [String] = [],
        forwards: [Forward] = []
    ) {
        self.id = id
        self.name = name
        self.sshHost = sshHost
        self.user = user
        self.port = port
        self.batchMode = batchMode
        self.autoStart = autoStart
        self.extraOptions = extraOptions
        self.forwards = forwards
    }

    public var enabledForwards: [Forward] { forwards.filter(\.enabled) }

    /// Fields that, when changed, require tearing down and respawning the master
    /// connection rather than adjusting forwards over the control socket.
    public var connectionIdentity: String {
        "\(sshHost)|\(user ?? "")|\(port.map(String.init) ?? "")|\(batchMode)|\(extraOptions.joined(separator: ","))"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sshHost = try c.decode(String.self, forKey: .sshHost)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? sshHost
        user = try c.decodeIfPresent(String.self, forKey: .user)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        batchMode = try c.decodeIfPresent(Bool.self, forKey: .batchMode) ?? true
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        extraOptions = try c.decodeIfPresent([String].self, forKey: .extraOptions) ?? []
        forwards = try c.decodeIfPresent([Forward].self, forKey: .forwards) ?? []
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var launchAtLogin: Bool
    public var healthIntervalSeconds: Int
    public var maxReconnectAttempts: Int

    public init(
        launchAtLogin: Bool = false,
        healthIntervalSeconds: Int = 10,
        maxReconnectAttempts: Int = 6
    ) {
        self.launchAtLogin = launchAtLogin
        self.healthIntervalSeconds = healthIntervalSeconds
        self.maxReconnectAttempts = maxReconnectAttempts
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        healthIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .healthIntervalSeconds) ?? 10
        maxReconnectAttempts = try c.decodeIfPresent(Int.self, forKey: .maxReconnectAttempts) ?? 6
    }
}

public struct Config: Codable, Hashable, Sendable {
    public var version: Int
    public var hosts: [HostGroup]
    public var settings: AppSettings

    public init(version: Int = 1, hosts: [HostGroup] = [], settings: AppSettings = AppSettings()) {
        self.version = version
        self.hosts = hosts
        self.settings = settings
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        hosts = try c.decodeIfPresent([HostGroup].self, forKey: .hosts) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    }

    public func host(id: UUID) -> HostGroup? { hosts.first { $0.id == id } }

    /// Local ports claimed by more than one *enabled* forward. Two disabled forwards
    /// sharing a port is harmless; two enabled ones cannot both bind.
    public func duplicateLocalPorts() -> [Int] {
        var counts: [Int: Int] = [:]
        for host in hosts {
            for forward in host.enabledForwards {
                counts[forward.localPort, default: 0] += 1
            }
        }
        return counts.filter { $0.value > 1 }.keys.sorted()
    }

    /// Human-readable problems that should block starting, surfaced in Settings.
    public func validationIssues() -> [String] {
        var issues: [String] = []
        for port in duplicateLocalPorts() {
            issues.append("Local port \(port) is used by more than one enabled forward.")
        }
        for host in hosts {
            if host.sshHost.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append("Host “\(host.name)” has no SSH host set.")
            }
            for forward in host.forwards {
                if !(1...65535).contains(forward.localPort) {
                    issues.append("\(host.name) / \(forward.name): local port \(forward.localPort) is out of range.")
                }
                if !(1...65535).contains(forward.remotePort) {
                    issues.append("\(host.name) / \(forward.name): remote port \(forward.remotePort) is out of range.")
                }
            }
        }
        return issues
    }
}
