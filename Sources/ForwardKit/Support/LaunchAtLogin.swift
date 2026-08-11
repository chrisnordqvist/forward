import Foundation
import ServiceManagement

/// Login-item registration via `SMAppService`. No helper bundle or privileged install
/// is involved — the app registers itself.
public enum LaunchAtLogin {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or a message to surface if the change did not take.
    @discardableResult
    public static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                // Already-registered throws; treat that as success.
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The user can revoke login items in System Settings; the UI reads this so its
    /// toggle reflects reality rather than what we last asked for.
    public static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "Enabled"
        case .requiresApproval: "Needs approval in System Settings › General › Login Items"
        case .notFound: "Not available — run Forward from /Applications"
        case .notRegistered: "Disabled"
        @unknown default: "Unknown"
        }
    }
}
