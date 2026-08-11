// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Forward",
    platforms: [.macOS(.v14)],
    targets: [
        // All logic lives here so it can be unit tested without the @main entry point.
        .target(
            name: "ForwardKit",
            path: "Sources/ForwardKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Thin app shell: @main, scenes and SwiftUI views.
        .executableTarget(
            name: "Forward",
            dependencies: ["ForwardKit"],
            path: "Sources/Forward",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ForwardTests",
            dependencies: ["ForwardKit"],
            path: "Tests/ForwardTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
