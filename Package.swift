// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IAPDesktopMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "App", targets: ["App"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
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
        // GH-90: ARM REST (descubrimiento Azure). AuthKit solo por los modelos
        // de `az account list`; el token por tenant llega como closure.
        .target(name: "AzureClient", dependencies: ["AuthKit"]),
        .target(
            name: "TunnelKit",
            dependencies: [
                "AuthKit",  // ProxyResolver compartido (GH-70); AuthKit no depende de nada
                .product(name: "WebSocketKit", package: "websocket-kit"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]),
        .target(
            name: "SSHKit",
            dependencies: [
                "TunnelKit",  // RelayStream como transporte (SshConnector, CBU-44)
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
        // Framing SFTP v3 propio sobre la SshSession ya autenticada (GH-55,
        // specs/sftp/transport-decision.md): sin dependencia externa nueva.
        .target(name: "SFTPKit", dependencies: ["SSHKit"]),
        // GH-93/94: túnel nativo a Azure Bastion (specs/azure/design.md). SSHKit
        // por `SshByteStream`/`SshSession` (SSH in-process); RDPBridge porque el
        // forwarder es un `RdpTunnel` del conector fallback existente.
        .target(
            name: "BastionKit",
            dependencies: [
                "TunnelKit",  // ProxyConfig, TunnelError, filtro loopback de IapListener
                "SSHKit",
                "RDPBridge",
                .product(name: "WebSocketKit", package: "websocket-kit"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]),
        .target(name: "RDPBridge"),
        .target(name: "SettingsStore"),
        .target(name: "ExplorerUI", dependencies: ["GCPClient"]),
        .executableTarget(
            name: "App",
            dependencies: [
                "AuthKit", "GCPClient", "TunnelKit", "SSHKit",
                "TerminalUI", "SFTPKit", "RDPBridge", "SettingsStore",
                "ExplorerUI",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]),
        .testTarget(name: "AuthKitTests", dependencies: ["AuthKit"]),
        // Mocks compartidos por varios targets de test (relay IAP + servidor SSH).
        // Solo lo enlazan tests; nunca el producto.
        .target(
            name: "IAPTestSupport",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ],
            path: "Tests/IAPTestSupport"),
        .testTarget(name: "TunnelKitTests", dependencies: ["TunnelKit", "IAPTestSupport"]),
        .testTarget(
            name: "SSHKitTests",
            dependencies: [
                "SSHKit",
                "TunnelKit",
                "IAPTestSupport",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]),
        .testTarget(
            name: "BastionKitTests",
            dependencies: [
                "BastionKit",
                "SSHKit",
                "TunnelKit",
                "RDPBridge",
                "IAPTestSupport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]),
        .testTarget(name: "GCPClientTests", dependencies: ["GCPClient"]),
        .testTarget(name: "AzureClientTests", dependencies: ["AzureClient", "AuthKit"]),
        .testTarget(name: "SettingsStoreTests", dependencies: ["SettingsStore"]),
        .testTarget(name: "RDPBridgeTests", dependencies: ["RDPBridge"]),
        .testTarget(
            name: "SFTPKitTests",
            dependencies: [
                "SFTPKit",
                "SSHKit",
                "TunnelKit",
                "IAPTestSupport",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]),
        .testTarget(name: "ExplorerUITests", dependencies: ["ExplorerUI"]),
        .testTarget(
            name: "TerminalUITests",
            dependencies: [
                "TerminalUI",
                "ExplorerUI",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]),
        .testTarget(name: "AppTests", dependencies: ["App"]),
    ]
)
