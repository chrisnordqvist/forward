import ForwardKit
import SwiftUI

/// Small coloured indicator used for both hosts and forwards. Amber states pulse so a
/// connection that is retrying is distinguishable from one that is simply up.
struct StatusDot: View {
    enum Level {
        case off, working, on, error

        var color: Color {
            switch self {
            case .off: .secondary.opacity(0.4)
            case .working: .orange
            case .on: .green
            case .error: .red
            }
        }
    }

    let level: Level
    var size: CGFloat = 8

    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(level.color)
            .frame(width: size, height: size)
            .opacity(level == .working && pulsing ? 0.35 : 1)
            .animation(
                level == .working
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default,
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}

extension HostState {
    var dotLevel: StatusDot.Level {
        switch self {
        case .stopped: .off
        case .starting, .reconnecting: .working
        case .up: .on
        case .failed: .error
        }
    }

    var shortLabel: String? {
        switch self {
        case .stopped: nil
        case .starting: "connecting…"
        case .reconnecting(let attempt): "reconnecting (attempt \(attempt))…"
        case .up: nil
        case .failed: "failed"
        }
    }
}

extension ForwardState {
    var dotLevel: StatusDot.Level {
        switch self {
        case .inactive: .off
        case .pending: .working
        case .active: .on
        case .failed: .error
        }
    }
}
