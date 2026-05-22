// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Important: Use these settings for most targets.
let swiftSettings: [SwiftSetting]? = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "TerminalDashboard",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "tuidash", targets: ["TerminalDashboard"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/rensbreur/SwiftTUI.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "TerminalDashboard",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftTUI", package: "SwiftTUI"),
            ],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
