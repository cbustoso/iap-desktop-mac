// GH-79: icono de la app dibujado por código (CoreGraphics, sin assets
// externos; ver tools/generate-app-icon.swift). Smoke test de que el .icns
// existe, es válido, y que Info.plist/el bundle lo referencian correctamente.
import Foundation
import Testing

@Suite("Icono de la app (GH-79)")
struct AppIconSmokeTests {
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    @Test func icnsFileExistsAndHasValidMagicBytes() throws {
        let icns = Self.repoRoot().appendingPathComponent("resources/AppIcon.icns")
        let data = try #require(
            FileManager.default.contents(atPath: icns.path),
            "falta resources/AppIcon.icns; ejecuta tools/generate-app-icon.sh")
        #expect(data.count > 0, "AppIcon.icns pesa 0 bytes")
        // Cabecera de un .icns real: los 4 primeros bytes son la firma "icns".
        let magic = String(data: data.prefix(4), encoding: .ascii)
        #expect(magic == "icns", "AppIcon.icns no tiene la firma esperada (encontrado: \(magic ?? "nil"))")
    }

    @Test func iconsetSourcePngsExistAtAllStandardSizes() throws {
        let iconset = Self.repoRoot().appendingPathComponent("resources/AppIcon.iconset")
        let expectedFiles = [
            "icon_16x16.png", "icon_16x16@2x.png",
            "icon_32x32.png", "icon_32x32@2x.png",
            "icon_128x128.png", "icon_128x128@2x.png",
            "icon_256x256.png", "icon_256x256@2x.png",
            "icon_512x512.png", "icon_512x512@2x.png",
        ]
        for name in expectedFiles {
            let path = iconset.appendingPathComponent(name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            #expect(size > 0, "falta o está vacío resources/AppIcon.iconset/\(name)")
        }
    }

    @Test func infoPlistDeclaresTheIconFile() throws {
        let plist = Self.repoRoot().appendingPathComponent("resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let dictionary = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let iconFile = try #require(dictionary["CFBundleIconFile"] as? String)
        #expect(iconFile == "AppIcon")
    }

    /// Si el bundle ya se generó (tools/make-app-bundle.sh), confirma que
    /// copió el .icns dentro de Contents/Resources. Si no se ha generado
    /// todavía, el test se salta sin fallar (igual que SnapshotSmokeTests
    /// con el binario suelto).
    @Test func bundledAppIncludesTheIconWhenAlreadyPackaged() throws {
        let bundleIcns = Self.repoRoot()
            .appendingPathComponent("dist/IAPDesktopMac.app/Contents/Resources/AppIcon.icns")
        guard FileManager.default.fileExists(atPath: bundleIcns.path) else {
            return  // dist/IAPDesktopMac.app no generado aún en este checkout: no es un fallo.
        }
        let size = try FileManager.default.attributesOfItem(atPath: bundleIcns.path)[.size] as? Int ?? 0
        #expect(size > 0, "dist/IAPDesktopMac.app/Contents/Resources/AppIcon.icns pesa 0 bytes")
    }
}
