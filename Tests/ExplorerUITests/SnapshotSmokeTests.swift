// Smoke test CBU-32: lanza el binario App en modo headless (ver
// `tools/snapshot.sh` y `snapshotIfRequested()` en Sources/App/App.swift)
// en apariencia claro y oscuro, y verifica que ambos PNG se generan con
// contenido. Requiere `swift build` previo (el binario debe existir en
// `.build/<config>/App`); si no está compilado, el test se salta.
import Foundation
import Testing

@Suite("Snapshot headless (App binario)")
struct SnapshotSmokeTests {
    private static func findAppBinary() -> URL? {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for config in ["debug", "release"] {
            let candidate = root.appendingPathComponent(".build/\(config)/App")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func runSnapshot(appearance: String, outputPath: String) throws {
        let binary = try #require(
            Self.findAppBinary(),
            "No se encontró .build/{debug,release}/App; ejecuta `swift build` antes de correr este test.")
        let process = Process()
        process.executableURL = binary
        process.environment = [
            "IAP_SNAPSHOT": outputPath,
            "IAP_SNAPSHOT_APPEARANCE": appearance,
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "App terminó con código \(process.terminationStatus) (\(appearance))")
    }

    @Test func lightAndDarkSnapshotsAreWrittenWithContent() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iap-snapshot-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lightPNG = tmpDir.appendingPathComponent("explorer-light.png")
        let darkPNG = tmpDir.appendingPathComponent("explorer-dark.png")

        try runSnapshot(appearance: "light", outputPath: lightPNG.path)
        try runSnapshot(appearance: "dark", outputPath: darkPNG.path)

        for png in [lightPNG, darkPNG] {
            #expect(FileManager.default.fileExists(atPath: png.path), "falta \(png.lastPathComponent)")
            let size = try FileManager.default.attributesOfItem(atPath: png.path)[.size] as? Int ?? 0
            #expect(size > 0, "\(png.lastPathComponent) pesa 0 bytes")
        }
    }
}
