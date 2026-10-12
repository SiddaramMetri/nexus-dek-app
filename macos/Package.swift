// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NexusConsole",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The only third-party dependency: a native (AppKit) terminal emulator.
        // Pinned: 1.12+ adds Metal shaders, which need full Xcode to compile.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.11.2"),
    ],
    targets: [
        // Pure logic: process runner, brew, parsers, doctor probes, archiver.
        // No UI imports — everything here is unit-testable.
        .target(
            name: "NexusCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "NexusConsole",
            dependencies: [
                "NexusCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NexusCoreTests",
            dependencies: ["NexusCore"],
            exclude: ["Fixtures"]
        ),
    ]
)
