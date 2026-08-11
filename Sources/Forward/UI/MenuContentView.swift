import ForwardKit
import SwiftUI

/// Row background that mimics a native menu item's hover highlight.
///
/// The hover state lives in a real `View` rather than in the `ButtonStyle` itself:
/// a `ButtonStyle` is not a view, so `@State` declared on it has no place in the view
/// graph and does not reliably drive updates.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRowBackground(configuration: configuration)
    }

    private struct MenuRowBackground: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovering || configuration.isPressed
                              ? Color.accentColor.opacity(0.15)
                              : Color.clear)
                )
                .onHover { hovering = $0 }
        }
    }
}

/// Reports the natural height of the host list so the popover can size to its content.
private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MenuContentView: View {
    @Environment(TunnelManager.self) private var manager
    @Environment(ConfigStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = SettingsTab.tunnels.rawValue

    @State private var copiedPort: Int?
    @State private var listHeight: CGFloat = 0

    /// One inset for every row in the popover. Rows add their own 6pt, so container
    /// padding is `inset - 6` and everything lines up on a single left edge.
    fileprivate enum Metrics {
        static let width: CGFloat = 330
        static let inset: CGFloat = 14
        static let rowInset: CGFloat = 6
        static let maxListHeight: CGFloat = 420
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if store.config.hosts.isEmpty {
                emptyState
            } else {
                hostList
            }

            Divider()
            footer
        }
        // alignment: .leading — without it the stack is centred inside the frame when its
        // natural width is under 330, which shows up as uneven left/right margins.
        .frame(width: Metrics.width, alignment: .leading)
    }

    /// A `ScrollView` inside a `.window`-style `MenuBarExtra` is not offered a height, so
    /// `maxHeight` alone does not make it fit its content. Measure the content and set a
    /// definite height, capped so a long list scrolls instead of running off screen.
    private var hostList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.config.hosts) { host in
                    hostSection(host)
                }
            }
            .padding(.horizontal, Metrics.inset - Metrics.rowInset)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .frame(height: min(max(listHeight, 1), Metrics.maxListHeight))
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(ListHeightKey.self) { height in
            Task { @MainActor in listHeight = height }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Forward").font(.headline)
            Spacer()
            if let error = store.loadError {
                Label("config error", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .help(error)
            } else {
                Text(activeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeSummary: String {
        let count = manager.activeForwardCount
        return count == 0 ? "idle" : "\(count) active"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("No tunnels configured")
                .font(.subheadline)
            Text("Add a host and the ports you want forwarded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add a Host…") { showSettings(tab: .tunnels) }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 20)
    }

    // MARK: - Hosts

    @ViewBuilder
    private func hostSection(_ host: HostGroup) -> some View {
        let state = manager.state(forHost: host.id)

        VStack(alignment: .leading, spacing: 2) {
            hostRow(host, state: state)

            if let message = statusLine(for: host, state: state) {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(state.dotLevel == .error ? .red : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
                    .padding(.trailing, 8)
                    .padding(.bottom, 2)
            }

            ForEach(host.forwards) { forward in
                forwardRow(forward, host: host)
            }
        }
        .padding(.bottom, 6)
    }

    private func hostRow(_ host: HostGroup, state: HostState) -> some View {
        HStack(spacing: 8) {
            StatusDot(level: state.dotLevel, size: 9)
            // A long host name or ssh target must truncate, not widen the popover.
            VStack(alignment: .leading, spacing: 0) {
                Text(host.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if host.name != host.sshHost {
                    Text(host.sshHost)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)

            Button {
                manager.toggleHost(host.id)
            } label: {
                Image(systemName: state.isActive ? "stop.circle" : "play.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(state.isActive ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(host.enabledForwards.isEmpty && !state.isActive)
            .help(state.isActive ? "Disconnect \(host.name)" : "Connect \(host.name)")
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.vertical, 4)
        .contextMenu {
            Button("Open in Terminal") {
                TerminalLauncher.open(command: SSHSession.interactiveCommand(for: host))
            }
            Button("Copy ssh Command") {
                Clipboard.copy(SSHSession.interactiveCommand(for: host))
            }
            Divider()
            Button("Show Log…") { showSettings(tab: .logs) }
            Button("Edit…") { showSettings(tab: .tunnels) }
        }
    }

    private func statusLine(for host: HostGroup, state: HostState) -> String? {
        switch state {
        case .failed(let reason):
            return reason
        case .reconnecting(let attempt):
            let detail = manager.hostMessages[host.id].map { " — \($0)" } ?? ""
            return "Reconnecting (attempt \(attempt))\(detail)"
        case .starting:
            return "Connecting…"
        case .up, .stopped:
            // A forward-level failure (a port clash, say) while the host itself is fine.
            return host.enabledForwards.compactMap {
                manager.state(forForward: $0.id).failureReason
            }.first
        }
    }

    private func forwardRow(_ forward: Forward, host: HostGroup) -> some View {
        let state = manager.state(forForward: forward.id)

        return HStack(spacing: 8) {
            StatusDot(level: state.dotLevel, size: 6)
                .padding(.leading, 8)

            Text(forward.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                // Yield space to the port label rather than pushing it out of the row.
                .layoutPriority(0)

            Spacer(minLength: 4)

            Button {
                Clipboard.copy("localhost:\(forward.localPort)")
                copiedPort = forward.localPort
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    if copiedPort == forward.localPort { copiedPort = nil }
                }
            } label: {
                Text(copiedPort == forward.localPort ? "copied!" : forward.displaySpec)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy localhost:\(forward.localPort)")

            Toggle("", isOn: Binding(
                get: { forward.enabled },
                set: { manager.setForward(forward.id, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.vertical, 3)
        .help(state.failureReason ?? "\(forward.localPort) → \(forward.remoteHost):\(forward.remotePort) via \(host.sshHost)")
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Button("Start All") { manager.startAll() }
                    .disabled(store.config.hosts.allSatisfy { $0.enabledForwards.isEmpty })
                Button("Stop All") { manager.stopAll() }
                    .disabled(!store.config.hosts.contains { manager.state(forHost: $0.id).isActive })
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, Metrics.inset)
            .padding(.top, 8)
            .padding(.bottom, 4)

            VStack(spacing: 0) {
                menuButton("Settings…", shortcut: "⌘,") { showSettings(tab: .tunnels) }
                menuButton("Quit Forward", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
            }
            // Rows add their own inset, so the text lines up with the header above.
            .padding(.horizontal, Metrics.inset - Metrics.rowInset)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func menuButton(_ title: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text(shortcut).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Metrics.rowInset)
            .padding(.vertical, 4)
        }
        .buttonStyle(MenuRowStyle())
        .keyboardShortcut(shortcut == "⌘," ? "," : "q", modifiers: .command)
    }

    /// LSUIElement apps have no menu bar of their own, so the Settings window needs an
    /// explicit activation to come to the front.
    private func showSettings(tab: SettingsTab) {
        settingsTab = tab.rawValue
        NSApplication.shared.activate(ignoringOtherApps: true)
        openSettings()
    }
}
