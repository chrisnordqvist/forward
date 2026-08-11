import Foundation
import Testing

@testable import ForwardKit

@Suite("ssh command construction")
struct SSHArgumentTests {
    private let minimal = HostGroup(name: "Box", sshHost: "box")

    private var elaborate: HostGroup {
        HostGroup(
            name: "Staging",
            sshHost: "staging-api",
            user: "deploy",
            port: 2222,
            batchMode: true,
            extraOptions: ["Compression=yes", "  "],
            forwards: [Forward(name: "API", localPort: 4000, remotePort: 4000, enabled: true)]
        )
    }

    @Test("The master carries no -L flags: forwards are added over the control socket")
    func masterHasNoForwards() {
        let args = SSHSession.masterArguments(for: elaborate, socketPath: "/tmp/s.sock")
        #expect(!args.contains("-L"), "a -L on the master would couple every forward's fate to the others")
        #expect(args.contains("-N"))
        #expect(args.contains("-M"))
        #expect(args.last == "staging-api", "the host must be the final argument")
    }

    @Test("Master arguments include the control socket and keepalive options")
    func masterOptions() {
        let args = SSHSession.masterArguments(for: minimal, socketPath: "/tmp/s.sock")
        #expect(args.contains("-S"))
        #expect(args.contains("/tmp/s.sock"))
        #expect(hasOption(args, "ControlPersist=no"))
        #expect(hasOption(args, "ServerAliveInterval=15"))
        #expect(hasOption(args, "ServerAliveCountMax=3"))
        #expect(hasOption(args, "ConnectTimeout=10"))
        #expect(hasOption(args, "BatchMode=yes"))
    }

    @Test("BatchMode is omitted when the host opts out")
    func batchModeOptOut() {
        var host = minimal
        host.batchMode = false
        let args = SSHSession.masterArguments(for: host, socketPath: "/tmp/s.sock")
        #expect(!hasOption(args, "BatchMode=yes"))
    }

    @Test("User, port and extra options are passed through; blank extras are dropped")
    func passesThroughConnectionDetails() {
        let args = SSHSession.masterArguments(for: elaborate, socketPath: "/tmp/s.sock")
        #expect(consecutive(args, "-l", "deploy"))
        #expect(consecutive(args, "-p", "2222"))
        #expect(hasOption(args, "Compression=yes"))
        #expect(args.filter { $0 == "-o" }.count == 6, "the whitespace-only extra option must not become a bare -o")
    }

    @Test("Control commands target the socket and name the verb")
    func controlArguments() {
        let forward = Forward(name: "API", localPort: 4000, remotePort: 4000)
        let add = SSHSession.controlArguments(
            for: minimal, socketPath: "/tmp/s.sock", verb: "forward", forward: forward
        )
        #expect(add == ["-S", "/tmp/s.sock", "-O", "forward", "-L", "127.0.0.1:4000:localhost:4000", "box"])

        let cancel = SSHSession.controlArguments(
            for: minimal, socketPath: "/tmp/s.sock", verb: "cancel", forward: forward
        )
        #expect(cancel.contains("cancel"))
        #expect(cancel.contains("-L"))

        let check = SSHSession.controlArguments(for: minimal, socketPath: "/tmp/s.sock", verb: "check")
        #expect(check == ["-S", "/tmp/s.sock", "-O", "check", "box"])
    }

    @Test("Forwards bind explicitly to 127.0.0.1 so they are never exposed on the network")
    func forwardSpecIsLoopbackBound() {
        let forward = Forward(name: "API", localPort: 4000, remoteHost: "db.internal", remotePort: 5432)
        #expect(forward.forwardSpec == "127.0.0.1:4000:db.internal:5432")
    }

    @Test("The interactive command is a pasteable equivalent including enabled forwards")
    func interactiveCommand() {
        let command = SSHSession.interactiveCommand(for: elaborate)
        #expect(command == "ssh -l deploy -p 2222 -o Compression=yes -L 127.0.0.1:4000:localhost:4000 staging-api")
    }

    @Test("Disabled forwards are left out of the interactive command")
    func interactiveCommandSkipsDisabled() {
        var host = elaborate
        host.forwards[0].enabled = false
        #expect(!SSHSession.interactiveCommand(for: host).contains("-L"))
    }

    @Test("Arguments needing quoting are quoted safely")
    func shellQuoting() {
        #expect(SSHSession.shellQuote("simple-host.example.com") == "simple-host.example.com")
        #expect(SSHSession.shellQuote("Compression=yes") == "Compression=yes")
        #expect(SSHSession.shellQuote("two words") == "'two words'")
        #expect(SSHSession.shellQuote("it's") == "'it'\\''s'")
        #expect(SSHSession.shellQuote("") == "''")
        #expect(SSHSession.shellQuote("; rm -rf /") == "'; rm -rf /'")
    }

    @Test("Control socket paths stay within the sockaddr_un length limit")
    func socketPathIsShortEnough() {
        let url = SSHSession.socketURL(for: UUID())
        #expect(url.path.utf8.count <= 104)
        #expect(url.lastPathComponent.hasSuffix(".sock"))
    }

    @Test("Each host gets its own control socket")
    func socketPathsAreDistinct() {
        #expect(SSHSession.socketURL(for: UUID()) != SSHSession.socketURL(for: UUID()))
    }

    @Test("Connection identity changes only for fields that require a reconnect")
    func connectionIdentity() {
        var host = elaborate
        let original = host.connectionIdentity

        // Renaming or changing forwards must not force the connection to be rebuilt.
        host.name = "Renamed"
        host.forwards.append(Forward(name: "Extra", localPort: 9000, remotePort: 9000))
        host.autoStart.toggle()
        #expect(host.connectionIdentity == original)

        host.user = "someone-else"
        #expect(host.connectionIdentity != original)
    }

    @Test("The most useful stderr line is picked out of ssh's noise")
    func errorExtraction() {
        let stderr = """
        Warning: Permanently added 'box' (ED25519) to the list of known hosts.
        deploy@box: Permission denied (publickey).

        """
        #expect(SSHSession.cleanError(stderr) == "deploy@box: Permission denied (publickey).")
        #expect(SSHSession.cleanError("   \n  \n") == "")
    }

    // MARK: - Helpers

    private func hasOption(_ args: [String], _ option: String) -> Bool {
        consecutive(args, "-o", option)
    }

    private func consecutive(_ args: [String], _ first: String, _ second: String) -> Bool {
        zip(args, args.dropFirst()).contains { $0 == first && $1 == second }
    }
}
