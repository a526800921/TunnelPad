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
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "TunnelPadCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio")
            ]
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
