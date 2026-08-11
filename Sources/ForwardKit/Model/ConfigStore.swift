import Foundation
import Observation

/// Owns `~/.config/forward/config.json`: loads it, writes it back atomically, and
/// watches for external edits.
///
/// The file is the single source of truth. In-app edits go through `update(_:)`,
/// which writes the file; external edits arrive via the directory watch and are
/// published on `config`.
@MainActor
@Observable
public final class ConfigStore {
    public private(set) var config: Config
    /// Set when the file on disk could not be parsed. The last good config stays loaded.
    public private(set) var loadError: String?

    public let configURL: URL
    private let directoryURL: URL

    /// Serialised bytes of the last write we performed, so the directory watch can
    /// ignore the event our own save just generated.
    private var lastWrittenData: Data?
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?
    private var rearmTask: Task<Void, Never>?

    /// Called after an *external* edit changes the config, so the tunnel manager can
    /// reconcile running sessions. Not called for in-app saves.
    public var onExternalChange: ((Config) -> Void)?

    public init(configURL: URL? = nil) {
        let url = configURL ?? Self.defaultConfigURL()
        self.configURL = url
        self.directoryURL = url.deletingLastPathComponent()
        self.config = Config()
        seedIfNeeded()
        reloadFromDisk(notify: false)
    }

    // MARK: - Paths
    // nonisolated: these are pure path arithmetic, needed from `SSHSession` off the main actor.

    public nonisolated static func defaultConfigURL() -> URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        return base.appending(path: "forward/config.json")
    }

    /// Where ssh ControlMaster sockets live. Unix socket paths are capped at ~104
    /// bytes, so this stays short and the filename uses a truncated id.
    public nonisolated static func stateDirectory() -> URL {
        let base = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/state")
        return base.appending(path: "forward")
    }

    // MARK: - Loading

    private func seedIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: configURL.path) else { return }
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.stateDirectory(), withIntermediateDirectories: true)
        if let data = try? Self.encode(Config()) {
            try? data.write(to: configURL, options: .atomic)
            lastWrittenData = data
        }
    }

    /// Re-read the file. Parse failures keep the in-memory config and surface `loadError`,
    /// so a half-saved file in an editor never wipes running state.
    public func reloadFromDisk(notify: Bool) {
        guard let data = try? Data(contentsOf: configURL) else {
            loadError = nil
            return
        }
        do {
            let decoded = try Self.decode(data)
            loadError = nil
            guard decoded != config else { return }
            config = decoded
            if notify { onExternalChange?(decoded) }
        } catch {
            loadError = "config.json could not be parsed: \(error.localizedDescription)"
        }
    }

    // MARK: - Saving

    /// Mutate and persist. Used by every in-app edit.
    public func update(_ mutate: (inout Config) -> Void) {
        var copy = config
        mutate(&copy)
        guard copy != config else { return }
        config = copy
        save()
    }

    public func save() {
        do {
            let data = try Self.encode(config)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: configURL, options: .atomic)
            lastWrittenData = data
            loadError = nil
        } catch {
            loadError = "Could not write config.json: \(error.localizedDescription)"
        }
    }

    // MARK: - Coding

    // nonisolated: pure serialisation, no shared state.
    public nonisolated static func encode(_ config: Config) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(config)
    }

    public nonisolated static func decode(_ data: Data) throws -> Config {
        let decoder = JSONDecoder()
        // Tolerate hand-editing conveniences: comments and trailing commas.
        decoder.allowsJSON5 = true
        return try decoder.decode(Config.self, from: data)
    }

    // MARK: - External change watching

    /// Watch the file *and* its containing directory. Neither alone is sufficient:
    ///
    /// - Editors that save atomically replace the file by rename, which leaves a
    ///   file-level watch pointing at an orphaned inode — only the directory sees it.
    /// - Writers that truncate in place (`>` redirection, most scripts) never touch the
    ///   directory entry at all — only the file watch sees it.
    public func startWatching() {
        stopWatching()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        watchDirectory()
        watchFile()
    }

    private func watchDirectory() {
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // A replaced file means our file-level watch is now following a dead inode.
            self?.rearmFileWatch()
            self?.scheduleReload()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil

        let fd = open(configURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
                self.rearmFileWatch()
            }
            self.scheduleReload()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    /// Re-open the file watch on a later turn, so we never cancel a source from inside
    /// its own event handler.
    private func rearmFileWatch() {
        rearmTask?.cancel()
        rearmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            self.watchFile()
        }
    }

    public func stopWatching() {
        debounceTask?.cancel()
        debounceTask = nil
        rearmTask?.cancel()
        rearmTask = nil
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
    }

    /// Coalesce the burst of events a single save produces, and skip reloading when the
    /// bytes on disk are exactly what we last wrote.
    private func scheduleReload() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            if let current = try? Data(contentsOf: self.configURL), current == self.lastWrittenData {
                return  // our own write
            }
            self.lastWrittenData = nil
            self.reloadFromDisk(notify: true)
        }
    }
}
