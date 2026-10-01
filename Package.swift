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
        // T-SSH-1 (CBU-37): stack SSH. 0.x: los minors pueden romper API, se fija
        // hasta el siguiente minor (resuelto 0.15.0, ver specs/ssh/transport-decision.md).
        .package(url: "https://github.com/apple/swift-nio-ssh.git", .upToNextMinor(from: "0.15.0")),
        // T-SSH-5 (CBU-41): emulador VT. Major 1 fijado y además < 1.12: desde
        // 1.12.0 SwiftTerm incluye shaders Metal que exigen el compilador `metal`
        // (solo Xcode completo, no Command Line Tools). Subir al tener Xcode en CI.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.11.2")),
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
        .target(
            name: "SSHKit",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]),
        .target(
            name: "TerminalUI",
            dependencies: [
                "ExplorerUI",  // SessionTabHosting (área central de pestañas)
                "SSHKit",  // SshChannel como backend del terminal
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]),
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
        .testTarget(
            name: "SSHKitTests",
            dependencies: [
                "SSHKit",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]),
        .testTarget(name: "GCPClientTests", dependencies: ["GCPClient"]),
        .testTarget(name: "SettingsStoreTests", dependencies: ["SettingsStore"]),
        .testTarget(name: "ExplorerUITests", dependencies: ["ExplorerUI"]),
        .testTarget(
            name: "TerminalUITests",
            dependencies: [
                "TerminalUI",
                "ExplorerUI",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]),
    ]
)
