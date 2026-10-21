// swift-tools-version: 6.0
// GH-86 (F0): spike del túnel nativo a Azure Bastion. Paquete independiente:
// no forma parte del Package.swift raíz ni del build del App.
import PackageDescription

let package = Package(
    name: "BastionSpike",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "bastion-spike", targets: ["BastionSpike"]),
    ],
    dependencies: [
        // Mismas restricciones que el Package.swift raíz.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.14.0"),
    ],
    targets: [
        .target(
            name: "BastionSpikeCore",
            dependencies: [
                .product(name: "WebSocketKit", package: "websocket-kit"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "BastionSpike",
            dependencies: ["BastionSpikeCore"]
        ),
        .testTarget(
            name: "BastionSpikeCoreTests",
            dependencies: [
                "BastionSpikeCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
    ]
)
