// swift-tools-version: 6.0
import PackageDescription

// Panther: keep a MacBook running with the lid closed, for a set time or until a program exits.
// No third-party dependencies on purpose: the root daemon's code should be small and fully readable.
let package = Package(
    name: "Panther",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "pantherd", targets: ["pantherd"]),
        .executable(name: "panther", targets: ["panther"]),
        .executable(name: "PantherApp", targets: ["PantherApp"]),
    ],
    targets: [
        // Pure logic. No IOKit, no files, no clocks: everything risky is tested with fakes.
        .target(name: "PantherCore"),
        // macOS adapters (IOKit, libproc, notify, CoreGraphics) behind PantherCore's protocols.
        .target(name: "PantherSystem", dependencies: ["PantherCore"]),
        // XPC protocol and Codable messages shared by the daemon and its clients.
        .target(name: "PantherIPC", dependencies: ["PantherCore"]),
        .executableTarget(name: "pantherd", dependencies: ["PantherCore", "PantherSystem", "PantherIPC"]),
        .executableTarget(name: "panther", dependencies: ["PantherCore", "PantherSystem", "PantherIPC"]),
        // Menu bar UI (SwiftUI) as a library, so it can be rendered headless for design checks.
        .target(name: "PantherUI", dependencies: ["PantherCore", "PantherSystem", "PantherIPC"]),
        // Menu bar app (bundled into Panther.app by scripts/build.sh). A remote control for pantherd.
        .executableTarget(name: "PantherApp", dependencies: ["PantherUI"]),
        // Dev tool: renders the panel with sample data to PNG (no daemon needed).
        .executableTarget(name: "panther-snapshot", dependencies: ["PantherUI", "PantherCore"]),
        .testTarget(name: "PantherCoreTests", dependencies: ["PantherCore"]),
        .testTarget(name: "PantherIPCTests", dependencies: ["PantherIPC", "PantherCore"]),
    ]
)
