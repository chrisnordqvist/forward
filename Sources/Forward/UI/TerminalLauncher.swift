import AppKit
import ForwardKit
import Foundation

/// Opens a command in Terminal.app.
///
/// Uses a temporary `.command` script rather than AppleScript so it needs no Automation
/// permission prompt — the point of this feature is to unblock a user whose connection
/// already failed, so it should not itself require granting anything.
enum TerminalLauncher {
    static func open(command: String) {
        let directory = ConfigStore.stateDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appending(path: "open-in-terminal.command")

        let contents = """
        #!/bin/zsh
        echo "\(command.replacingOccurrences(of: "\"", with: "\\\""))"
        \(command)
        """

        do {
            try contents.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            NSSound.beep()
        }
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
