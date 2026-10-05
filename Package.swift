// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexBridge",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "codexbridge", targets: ["BridgeCLI"])],
    targets: [
        .target(name: "BridgeCore"),
        .executableTarget(name: "BridgeCLI", dependencies: ["BridgeCore"]),
        .executableTarget(name: "BridgeTests", dependencies: ["BridgeCore"], path: "Tests/BridgeCoreTests"),
    ]
)
