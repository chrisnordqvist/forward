import Darwin
import Foundation

public struct PortConflict: Sendable, Hashable {
    public let port: Int
    /// Process name and pid holding the port, when `lsof` could identify it.
    public let holder: String?

    public var message: String {
        if let holder {
            "Local port \(port) is already in use by \(holder)."
        } else {
            "Local port \(port) is already in use."
        }
    }
}

/// Checks whether a local port can be bound before handing it to ssh.
///
/// Without this, a port clash surfaces as an opaque ssh failure; with
/// `ExitOnForwardFailure=yes` set on the master it would also take down the host's
/// other forwards.
public enum PortProbe {
    /// True when nothing is listening on 127.0.0.1:port.
    ///
    /// `SO_REUSEADDR` is set because ssh sets it on its own forward listeners, and the
    /// probe must answer the question "will ssh be able to bind this?" rather than
    /// "could a socket with different options bind it?".
    ///
    /// Without it, sockets left in `TIME_WAIT` by a tunnel that has just carried traffic
    /// make `bind` fail with `EADDRINUSE` for up to a minute — so restarting a tunnel, or
    /// reconnecting a dropped one, would be refused with a bogus "port in use" error.
    /// `SO_REUSEADDR` does not weaken the check: on Darwin it still refuses a port that
    /// another socket is actively `LISTEN`ing on.
    public static func isAvailable(port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Nil when the port is free, otherwise a conflict annotated with whoever holds it.
    public static func conflict(port: Int) async -> PortConflict? {
        guard !isAvailable(port: port) else { return nil }
        return PortConflict(port: port, holder: await holder(port: port))
    }

    /// Ask `lsof` which process is listening. Best-effort — a port held by another
    /// user's process is reported as unknown rather than failing the check.
    public static func holder(port: Int) async -> String? {
        guard let result = try? await ProcessRunner.run(
            "/usr/sbin/lsof",
            ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "cp"],
            timeout: .seconds(5)
        ) else { return nil }

        // -F cp emits records like "p12345\ncnode\n" — one field per line, tagged by
        // its first character.
        var pid: String?
        var command: String?
        for line in result.stdout.split(separator: "\n") {
            switch line.first {
            case "p": pid = String(line.dropFirst())
            case "c": command = String(line.dropFirst())
            default: break
            }
            if let pid, let command { return "\(command) (pid \(pid))" }
        }
        if let command { return command }
        return nil
    }
}
