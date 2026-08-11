import AppKit
import ForwardKit
import SwiftUI

@main
struct ForwardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(delegate.manager)
                .environment(delegate.store)
        } label: {
            MenuBarLabel(manager: delegate.manager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(delegate.manager)
                .environment(delegate.store)
        }
    }
}

/// The menu bar item itself. Monochrome symbols do the work here — the menu bar renders
/// label images as templates, so state is conveyed by shape and an active count rather
/// than by colour.
private struct MenuBarLabel: View {
    let manager: TunnelManager

    var body: some View {
        let count = manager.activeForwardCount
        HStack(spacing: 3) {
            Image(systemName: symbolName(count: count))
            if count > 0 {
                Text("\(count)").font(.system(size: 11, weight: .medium))
            }
        }
        .accessibilityLabel(accessibilityText(count: count))
    }

    private func symbolName(count: Int) -> String {
        if manager.anyTrouble { return "exclamationmark.triangle.fill" }
        return count > 0 ? "arrow.left.arrow.right.circle.fill" : "arrow.left.arrow.right.circle"
    }

    private func accessibilityText(count: Int) -> String {
        if manager.anyTrouble { return "Forward — attention needed" }
        return count > 0 ? "Forward — \(count) tunnels active" : "Forward — no tunnels active"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ConfigStore()
    lazy var manager = TunnelManager(store: store)
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationHandler()
        manager.start()
    }

    /// AppKit only runs `applicationWillTerminate` for a Quit; a plain SIGTERM (from
    /// `pkill`, a script, or a logout race) would otherwise kill us outright and leave
    /// ssh masters running with their ports still bound.
    private func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSApplication.shared.terminate(nil)
        }
        source.resume()
        sigtermSource = source
    }

    /// Leave no orphaned ssh processes or stale control sockets behind.
    func applicationWillTerminate(_ notification: Notification) {
        manager.shutdownSynchronously()
    }
}
