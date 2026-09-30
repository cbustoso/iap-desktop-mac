// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IAPDesktopMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "App", targets: ["App"])
    ],
    targets: [
        .target(name: "AuthKit"),
        .target(name: "GCPClient"),
        .target(name: "TunnelKit"),
        .target(name: "SSHKit"),
        .target(name: "TerminalUI"),
        .target(name: "SFTPKit"),
        .target(name: "RDPBridge"),
        .target(name: "SettingsStore"),
        .executableTarget(name: "App", dependencies: [
            "AuthKit", "GCPClient", "TunnelKit", "SSHKit",
            "TerminalUI", "SFTPKit", "RDPBridge", "SettingsStore"
        ]),
        .testTarget(name: "AuthKitTests", dependencies: ["AuthKit"]),
        .testTarget(name: "TunnelKitTests", dependencies: ["TunnelKit"]),
        .testTarget(name: "GCPClientTests", dependencies: ["GCPClient"]),
        .testTarget(name: "SettingsStoreTests", dependencies: ["SettingsStore"])
    ]
)
