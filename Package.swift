// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IAPDesktopMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "App", targets: ["App"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.14.0"),
    ],
    targets: [
        .target(name: "AuthKit"),
        .target(name: "GCPClient"),
        .target(
            name: "TunnelKit",
            dependencies: [
                .product(name: "WebSocketKit", package: "websocket-kit"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]),
        .target(name: "SSHKit"),
        .target(name: "TerminalUI"),
        .target(name: "SFTPKit"),
        .target(name: "RDPBridge"),
        .target(name: "SettingsStore"),
        .target(name: "ExplorerUI", dependencies: ["GCPClient"]),
        .executableTarget(name: "App", dependencies: [
            "AuthKit", "GCPClient", "TunnelKit", "SSHKit",
            "TerminalUI", "SFTPKit", "RDPBridge", "SettingsStore",
            "ExplorerUI",
        ]),
        .testTarget(name: "AuthKitTests", dependencies: ["AuthKit"]),
        .testTarget(name: "TunnelKitTests", dependencies: ["TunnelKit"]),
        .testTarget(name: "GCPClientTests", dependencies: ["GCPClient"]),
        .testTarget(name: "SettingsStoreTests", dependencies: ["SettingsStore"]),
        .testTarget(name: "ExplorerUITests", dependencies: ["ExplorerUI"]),
    ]
)
