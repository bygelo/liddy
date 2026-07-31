// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode for v0: the runtime is deliberately built on DispatchQueue +
// BSD sockets (the layers that talk to IOKit and launchd are callback-shaped), and
// full Swift 6 sendability annotation is a follow-up rather than a v0 blocker.
let mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "liddy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LiddyKit", targets: ["LiddyKit"]),
        // Named "LiddyApp", not "Liddy": macOS filesystems are case-insensitive by
        // default, so a "Liddy" product and the "liddy" CLI resolve to the same file
        // in .build and silently clobber each other. Script/build-app.sh renames the
        // binary to Liddy inside the .app bundle, where nothing else competes for it.
        .executable(name: "LiddyApp", targets: ["LiddyApp"]),
        .executable(name: "liddy", targets: ["LiddyCli"]),
        .executable(name: "liddy-helper", targets: ["LiddyHelper"]),
    ],
    targets: [
        .target(name: "LiddyKit", swiftSettings: mode),
        .executableTarget(name: "LiddyApp", dependencies: ["LiddyKit"], swiftSettings: mode),
        .executableTarget(name: "LiddyCli", dependencies: ["LiddyKit"], swiftSettings: mode),
        .executableTarget(name: "LiddyHelper", dependencies: ["LiddyKit"], swiftSettings: mode),
        .testTarget(name: "LiddyKitTest", dependencies: ["LiddyKit"], swiftSettings: mode),
    ]
)
