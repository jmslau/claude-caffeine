// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ClaudeCaffeine",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "ClaudeCaffeine",
            targets: ["ClaudeCaffeine"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeCaffeine"
        ),
        .testTarget(
            name: "ClaudeCaffeineTests",
            dependencies: ["ClaudeCaffeine"]
        ),
    ]
)
