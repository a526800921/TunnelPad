// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TunnelPad",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "TunnelPadCore",
            targets: ["TunnelPadCore"]
        ),
        .executable(
            name: "tunnelpad",
            targets: ["tunnelpad"]
        )
    ],
    targets: [
        .target(
            name: "TunnelPadCore"
        ),
        .executableTarget(
            name: "tunnelpad",
            dependencies: ["TunnelPadCore"],
            path: "Sources/tunnelpad"
        ),
        .testTarget(
            name: "TunnelPadCoreTests",
            dependencies: ["TunnelPadCore", "tunnelpad"]
        )
    ]
)
