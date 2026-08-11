import Foundation

/// Fixed-size ring of recent log lines. One per host, fed from the ssh master's stderr,
/// so a chatty or flapping connection cannot grow memory without bound.
public struct LogBuffer: Sendable {
    public private(set) var lines: [String] = []
    public let capacity: Int

    public init(capacity: Int = 200) {
        self.capacity = capacity
        lines.reserveCapacity(capacity)
    }

    public mutating func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append(trimmed)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    public mutating func append(chunk: String) {
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
            append(String(line))
        }
    }

    public mutating func clear() { lines.removeAll(keepingCapacity: true) }

    public var text: String { lines.joined(separator: "\n") }
    public var isEmpty: Bool { lines.isEmpty }
    public var last: String? { lines.last }

    /// The line most worth showing next to a failed host. ssh's final message is often
    /// generic ("exited"), while the useful cause appears a line or two earlier.
    public var mostRelevantError: String? {
        let markers = [
            "Permission denied",
            "Could not resolve hostname",
            "Connection refused",
            "Connection timed out",
            "Operation timed out",
            "No route to host",
            "Host key verification failed",
            "REMOTE HOST IDENTIFICATION HAS CHANGED",
            "bind: Address already in use",
            "cannot listen to port",
            "open failed",
            "Bad configuration option",
            "Bad local forwarding specification",
            "not a valid",
        ]
        for line in lines.reversed() {
            if markers.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
                return line
            }
        }
        return lines.last
    }
}
