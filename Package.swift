// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "grokbot-tunnel",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "GrokBotTunnelCore", targets: ["GrokBotTunnelCore"]),
        .executable(name: "grokbot-tunnel", targets: ["grokbot-tunnel"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "GrokBotTunnelCore",
            path: "Sources/GrokBotTunnelCore"
        ),
        .executableTarget(
            name: "grokbot-tunnel",
            dependencies: [
                "GrokBotTunnelCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/grokbot-tunnel"
        ),
        .testTarget(
            name: "GrokBotTunnelCoreTests",
            dependencies: ["GrokBotTunnelCore"],
            path: "Tests/GrokBotTunnelCoreTests"
        ),
    ]
)
