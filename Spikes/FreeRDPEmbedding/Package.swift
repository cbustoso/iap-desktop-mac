// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FreeRDPEmbeddingSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CFreeRDPProbe",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "FreeRDPEmbeddingSpike",
            dependencies: ["CFreeRDPProbe"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
    ]
)
