import AppKit
import ForwardKit
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case tunnels, general, logs

    var title: String {
        switch self {
        case .tunnels: "Tunnels"
        case .general: "General"
        case .logs: "Logs"
        }
    }

    var symbol: String {
        switch self {
        case .tunnels: "arrow.left.arrow.right"
        case .general: "gearshape"
        case .logs: "text.alignleft"
        }
    }
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var rawTab = SettingsTab.tunnels.rawValue

    private var selection: Binding<SettingsTab> {
        Binding(
            get: { SettingsTab(rawValue: rawTab) ?? .tunnels },
            set: { rawTab = $0.rawValue }
        )
    }

    var body: some View {
        TabView(selection: selection) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Group {
                    switch tab {
                    case .tunnels: TunnelsSettingsView()
                    case .general: GeneralSettingsView()
                    case .logs: LogsSettingsView()
                    }
                }
                // Size each tab's content, not the TabView. Framing the TabView sizes the
                // window including its tab bar and leaves the content a smaller, unclipped
                // area — which is how content ends up spilling outside the window.
                .frame(width: Self.contentWidth, height: Self.contentHeight)
                .tabItem { Label(tab.title, systemImage: tab.symbol) }
                .tag(tab)
            }
        }
    }

    static let contentWidth: CGFloat = 780
    static let contentHeight: CGFloat = 520
}

// MARK: - Tunnels

struct TunnelsSettingsView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(TunnelManager.self) private var manager
    @State private var selectedHost: UUID?

    var body: some View {
        HStack(spacing: 0) {
            hostSidebar
            Divider()
            detail
        }
        .onAppear {
            if selectedHost == nil { selectedHost = store.config.hosts.first?.id }
        }
    }

    private var hostSidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedHost) {
                ForEach(store.config.hosts) { host in
                    HStack(spacing: 6) {
                        StatusDot(level: manager.state(forHost: host.id).dotLevel, size: 7)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(host.name)
                            Text("\(host.forwards.count) forward\(host.forwards.count == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(host.id)
                }
                .onMove { indices, destination in
                    store.update { $0.hosts.move(fromOffsets: indices, toOffset: destination) }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 4) {
                Button { addHost() } label: { Image(systemName: "plus") }
                    .help("Add a host")
                Button { removeSelectedHost() } label: { Image(systemName: "minus") }
                    .disabled(selectedHost == nil)
                    .help("Remove the selected host")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 200)
    }

    @ViewBuilder
    private var detail: some View {
        if let hostID = selectedHost, store.config.host(id: hostID) != nil {
            HostEditorView(hostID: hostID)
                .id(hostID)
        } else {
            VStack(spacing: 8) {
                Text("No host selected").foregroundStyle(.secondary)
                Button("Add a Host") { addHost() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func addHost() {
        let host = HostGroup(name: "New Host", sshHost: "")
        store.update { $0.hosts.append(host) }
        selectedHost = host.id
    }

    private func removeSelectedHost() {
        guard let hostID = selectedHost else { return }
        manager.stopHost(hostID)
        store.update { $0.hosts.removeAll { $0.id == hostID } }
        selectedHost = store.config.hosts.first?.id
    }
}

struct HostEditorView: View {
    let hostID: UUID
    @Environment(ConfigStore.self) private var store
    @Environment(TunnelManager.self) private var manager
    @State private var showingAdvanced = false

    private var host: HostGroup? { store.config.host(id: hostID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let host {
                    connectionSection(host)
                    forwardsSection(host)
                    advancedSection(host)
                    issuesSection(host)
                }
            }
            .padding(16)
        }
    }

    private func connectionSection(_ host: HostGroup) -> some View {
        GroupBox("Connection") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("Staging", text: store.bind(host: hostID, \.name, fallback: ""))
                }
                GridRow {
                    Text("SSH host")
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("staging.example.com or a ~/.ssh/config alias",
                                  text: store.bind(host: hostID, \.sshHost, fallback: ""))
                        Text("Passed straight to ssh — aliases, ProxyJump and keys from your ssh config all apply.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("User")
                    HStack {
                        TextField("(from ssh config)", text: store.bindOptionalText(host: hostID, \.user))
                            .frame(maxWidth: 180)
                        Text("Port").foregroundStyle(.secondary)
                        TextField("22", text: store.bindOptionalPort(host: hostID))
                            .frame(width: 70)
                        Spacer()
                    }
                }
                GridRow {
                    // An empty label cell, sized out of the layout so it cannot widen
                    // the label column.
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Toggle("Connect automatically when Forward launches",
                           isOn: store.bind(host: hostID, \.autoStart, fallback: false))
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Column widths. The two text columns flex between a min and max so the table
    /// adapts to the pane instead of demanding a fixed total that can exceed it.
    private enum Column {
        static let nameMin: CGFloat = 90
        static let nameMax: CGFloat = 150
        static let hostMin: CGFloat = 100
        static let hostMax: CGFloat = 170
        static let port: CGFloat = 62
        static let status: CGFloat = 12
        static let toggle: CGFloat = 30
        static let trash: CGFloat = 22
    }

    private func forwardsSection(_ host: HostGroup) -> some View {
        GroupBox("Port forwards") {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Name").frame(minWidth: Column.nameMin, alignment: .leading)
                    Text("Local").frame(width: Column.port, alignment: .leading)
                    Text("Remote host").frame(minWidth: Column.hostMin, alignment: .leading)
                    Text("Port").frame(width: Column.port, alignment: .leading)
                    Color.clear.frame(width: Column.status, height: 1)
                    Text("On").frame(width: Column.toggle, alignment: .center)
                    Color.clear.frame(width: Column.trash, height: 1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(host.forwards) { forward in
                    forwardRow(forward)
                }
            }
            .padding(.vertical, 4)

            if host.forwards.isEmpty {
                Text("No forwards yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }

            HStack {
                Button("Add Forward") { addForward() }
                    .controlSize(.small)
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    private func forwardRow(_ forward: Forward) -> some View {
        GridRow {
            TextField("API", text: store.bind(host: hostID, forward: forward.id, \.name, fallback: ""))
                .frame(minWidth: Column.nameMin, maxWidth: Column.nameMax)
            TextField("4000", value: store.bind(host: hostID, forward: forward.id, \.localPort, fallback: 0),
                      format: .number.grouping(.never))
                .frame(width: Column.port)
            TextField("localhost", text: store.bind(host: hostID, forward: forward.id, \.remoteHost, fallback: "localhost"))
                .frame(minWidth: Column.hostMin, maxWidth: Column.hostMax)
            TextField("4000", value: store.bind(host: hostID, forward: forward.id, \.remotePort, fallback: 0),
                      format: .number.grouping(.never))
                .frame(width: Column.port)

            StatusDot(level: manager.state(forForward: forward.id).dotLevel, size: 7)
                .frame(width: Column.status)
                .help(manager.state(forForward: forward.id).failureReason ?? "")

            Toggle("", isOn: Binding(
                get: { forward.enabled },
                set: { manager.setForward(forward.id, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .frame(width: Column.toggle)

            Button { removeForward(forward.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .frame(width: Column.trash)
                .help("Remove this forward")
        }
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private func advancedSection(_ host: HostGroup) -> some View {
        DisclosureGroup("Advanced", isExpanded: $showingAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Fail immediately instead of waiting for a password prompt (BatchMode)",
                       isOn: store.bind(host: hostID, \.batchMode, fallback: true))
                Text("Forward has no terminal, so an interactive prompt would hang. Leave this on unless you use an askpass helper — for one-off passphrases or host keys, use Open in Terminal.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text("Extra ssh options (one per line, as you would write them after -o)")
                    .font(.caption)
                TextEditor(text: store.bindExtraOptions(host: hostID))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 60)
                    .border(Color.secondary.opacity(0.3))

                HStack {
                    Button("Open in Terminal") {
                        TerminalLauncher.open(command: SSHSession.interactiveCommand(for: host))
                    }
                    Button("Copy ssh Command") {
                        Clipboard.copy(SSHSession.interactiveCommand(for: host))
                    }
                    Spacer()
                }
                .controlSize(.small)

                // A long ssh command line would otherwise set the width of the whole
                // pane. Let it wrap, and never let it grow the layout.
                Text(SSHSession.interactiveCommand(for: host))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func issuesSection(_ host: HostGroup) -> some View {
        let issues = store.config.validationIssues()
        if !issues.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
    }

    private func addForward() {
        let forward = Forward(name: "New", localPort: 8080, remotePort: 8080)
        store.update { config in
            guard let index = config.hosts.firstIndex(where: { $0.id == hostID }) else { return }
            config.hosts[index].forwards.append(forward)
        }
    }

    private func removeForward(_ forwardID: UUID) {
        manager.setForward(forwardID, enabled: false)
        store.update { config in
            guard let index = config.hosts.firstIndex(where: { $0.id == hostID }) else { return }
            config.hosts[index].forwards.removeAll { $0.id == forwardID }
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(ConfigStore.self) private var store
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch Forward at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        launchError = LaunchAtLogin.set(newValue)
                        // The registration can be refused or need approval; show what
                        // actually happened rather than what we asked for.
                        launchAtLogin = LaunchAtLogin.isEnabled
                        store.update { $0.settings.launchAtLogin = launchAtLogin }
                    }
                Text(launchError ?? LaunchAtLogin.statusDescription)
                    .font(.caption)
                    .foregroundStyle(launchError == nil ? Color.secondary : Color.red)
            }

            Section("Health") {
                Stepper(
                    "Check connections every \(store.config.settings.healthIntervalSeconds)s",
                    value: store.bind(settings: \.healthIntervalSeconds),
                    in: 3...120,
                    step: 1
                )
                Stepper(
                    "Give up after \(store.config.settings.maxReconnectAttempts) reconnect attempts",
                    value: store.bind(settings: \.maxReconnectAttempts),
                    in: 0...20
                )
                Text("Backoff doubles each attempt up to 60s. Failures that a retry cannot fix — bad credentials, unknown hosts — stop immediately regardless.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Configuration file") {
                HStack {
                    Text(store.configURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.configURL])
                    }
                    .controlSize(.small)
                }
                if let error = store.loadError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Edits made outside Forward are picked up automatically. Saving from the app rewrites the file as plain JSON, so comments are not preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Logs

struct LogsSettingsView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(TunnelManager.self) private var manager
    @State private var selectedHost: UUID?

    private var currentHost: HostGroup? {
        if let selectedHost, let host = store.config.host(id: selectedHost) { return host }
        return store.config.hosts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Host", selection: Binding(
                    get: { currentHost?.id },
                    set: { selectedHost = $0 }
                )) {
                    ForEach(store.config.hosts) { host in
                        Text(host.name).tag(Optional(host.id))
                    }
                }
                .frame(maxWidth: 260)

                Spacer()

                Button("Copy") {
                    if let host = currentHost { Clipboard.copy(manager.log(forHost: host.id).text) }
                }
                .disabled(currentHost.map { manager.log(forHost: $0.id).isEmpty } ?? true)
            }
            .controlSize(.small)

            if let host = currentHost {
                let buffer = manager.log(forHost: host.id)
                ScrollView {
                    Text(buffer.isEmpty ? "No output yet." : buffer.text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .border(Color.secondary.opacity(0.3))
            } else {
                Text("No hosts configured.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
    }
}
