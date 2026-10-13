// GH-60 (T-SFTP-5): FileBrowserViewModel contra el servidor SFTP en memoria:
// navegación + breadcrumb, columnas formateadas, subida/descarga con progreso.
import Foundation
import Testing
@testable import SFTPKit

@MainActor
private func browser(_ fs: MemoryFileSystem, home: String = "/home/ada") async throws -> (FileBrowserViewModel, MemorySftpServer) {
    let server = MemorySftpServer(fs: fs)
    server.homeDirectory = home
    let model = FileBrowserViewModel(channel: try await connect(server), timeZone: TimeZone(identifier: "UTC")!)
    return (model, server)
}

private func sampleTree() -> MemoryFileSystem {
    let fs = MemoryFileSystem()
    fs.directories.formUnion(["/home", "/home/ada", "/home/ada/src", "/home/ada/src/lib"])
    fs.files["/home/ada/notes.txt"] = Data("hola".utf8)
    fs.files["/home/ada/Zeta.log"] = Data(count: 1536)
    fs.files["/home/ada/src/main.swift"] = Data("print(1)".utf8)
    return fs
}

private func temporaryURL(_ name: String) -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-browser-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(name)
}

@Suite("FileBrowserViewModel navegación (GH-60)", .timeLimit(.minutes(1)))
@MainActor
struct FileBrowserNavigationTests {
    @Test func startsAtHomeWithDirectoriesFirst() async throws {
        let (model, _) = try await browser(sampleTree())
        await model.start()
        #expect(model.path == "/home/ada")
        #expect(model.entries.map(\.name) == ["src", "notes.txt", "Zeta.log"])  // dirs primero, orden natural
        #expect(model.entries.first?.isDirectory == true)
        #expect(model.breadcrumb.map(\.title) == ["/", "home", "ada"])
        #expect(model.breadcrumb.map(\.path) == ["/", "/home", "/home/ada"])
        #expect(model.lastError == nil)
    }

    @Test func navigatesIntoSubdirectoriesAndBack() async throws {
        let (model, _) = try await browser(sampleTree())
        await model.start()
        let src = try #require(model.entries.first { $0.name == "src" })
        await model.open(src)
        #expect(model.path == "/home/ada/src")
        #expect(model.entries.map(\.name) == ["lib", "main.swift"])
        #expect(model.entries.first { $0.name == "main.swift" }?.path == "/home/ada/src/main.swift")

        // Abrir un fichero no navega.
        await model.open(try #require(model.entries.last))
        #expect(model.path == "/home/ada/src")

        await model.goUp()
        #expect(model.path == "/home/ada")
        await model.navigate(to: model.breadcrumb[1].path)  // clic en "home"
        #expect(model.path == "/home")
        #expect(model.entries.map(\.name) == ["ada"])
        await model.goUp()
        await model.goUp()  // la raíz no tiene padre
        #expect(model.path == "/")
    }

    @Test func missingDirectoryKeepsPathAndReportsBaseNameOnly() async throws {
        let (model, _) = try await browser(sampleTree())
        await model.start()
        await model.navigate(to: "/home/ada/secret/nope")
        #expect(model.path == "/home/ada")
        #expect(model.lastError == "nope: no existe.")  // sin ruta completa
        await model.refresh()
        #expect(model.lastError == nil)
    }

    @Test func pathsAreNormalizedAndHostileNamesRejected() {
        #expect(FileBrowserViewModel.normalized("/a/./b/../c//") == "/a/c")
        #expect(FileBrowserViewModel.normalized("/../..") == "/")
        #expect(FileBrowserViewModel.parent(of: "/a/b") == "/a")
        #expect(FileBrowserViewModel.join("/", "x") == "/x")
        for bad in ["", ".", "..", "a/b", "../etc", "x\0y"] {
            #expect(!FileBrowserViewModel.isSafeName(bad), "\(bad)")
        }
        #expect(FileBrowserViewModel.isSafeName(".bashrc"))
    }

    @Test func fallsBackToRootWithoutRealPath() async throws {
        let fs = sampleTree()
        let (model, _) = try await browser(fs, home: "/nowhere")
        await model.start()
        #expect(model.lastError == "nowhere: no existe.")
    }
}

@Suite("FileBrowserViewModel columnas (GH-60)")
@MainActor
struct FileBrowserFormattingTests {
    private func entry(_ mode: UInt32, size: UInt64? = nil, modified: Date? = nil) -> FileBrowserViewModel.Entry {
        FileBrowserViewModel.Entry(
            info: SftpFileInfo(name: "x", attributes: SftpAttributes(
                size: size, permissions: mode, accessTime: modified, modificationTime: modified)),
            path: "/x")
    }

    @Test func permissionsLikeLs() {
        #expect(FileBrowserViewModel.permissionsText(entry(0o040755)) == "drwxr-xr-x")
        #expect(FileBrowserViewModel.permissionsText(entry(0o100644)) == "-rw-r--r--")
        #expect(FileBrowserViewModel.permissionsText(entry(0o120777)) == "lrwxrwxrwx")
        #expect(FileBrowserViewModel.permissionsText(entry(0o104755)) == "-rwsr-xr-x")
        #expect(FileBrowserViewModel.permissionsText(entry(0o010600)) == "prw-------")
        #expect(FileBrowserViewModel.permissionsText(entry(0o140755)) == "srwxr-xr-x")
        #expect(FileBrowserViewModel.permissionsText(entry(0o000644)) == "?rw-r--r--")
    }

    @Test func sizesAreLocaleIndependent() {
        #expect(FileBrowserViewModel.sizeText(entry(0o100644, size: 0)) == "0 B")
        #expect(FileBrowserViewModel.sizeText(entry(0o100644, size: 1023)) == "1023 B")
        #expect(FileBrowserViewModel.sizeText(entry(0o100644, size: 1536)) == "1.5 KB")
        #expect(FileBrowserViewModel.sizeText(entry(0o100644, size: 5 * 1024 * 1024)) == "5.0 MB")
        #expect(FileBrowserViewModel.sizeText(entry(0o040755, size: 4096)) == "—")  // directorio
        #expect(FileBrowserViewModel.sizeText(entry(0o100644)) == "—")  // sin SIZE
    }

    @Test func modifiedUsesInjectedTimeZone() async throws {
        let (model, _) = try await browser(MemoryFileSystem())
        #expect(model.modifiedText(entry(0o100644, modified: Date(timeIntervalSince1970: 1_700_000_000))) == "2023-11-14 22:13")
        #expect(model.modifiedText(entry(0o100644)) == "—")
    }
}

@Suite("FileBrowserViewModel transferencias (GH-60)", .timeLimit(.minutes(1)))
@MainActor
struct FileBrowserTransferTests {
    @Test func uploadReportsProgressAndRefreshesListing() async throws {
        let fs = sampleTree()
        let (model, _) = try await browser(fs)
        await model.start()
        let payload = sampleData(count: 700_000)  // 3 bloques de copia
        let local = temporaryURL("upload.bin")
        try payload.write(to: local)

        var fractions: [Double] = []
        model.onChange = { if let f = model.transfers.last?.fraction, model.transfers.last?.state == .transferring { fractions.append(f) } }
        #expect(model.conflictingNames(for: [local]).isEmpty)
        let transfer = await model.upload(local)

        #expect(transfer.state == .completed)
        #expect(transfer.direction == .upload)
        #expect(transfer.bytesDone == UInt64(payload.count))
        #expect(transfer.fraction == 1)
        #expect(fs.file("/home/ada/upload.bin") == payload)
        #expect(fractions == fractions.sorted() && fractions.count >= 3)  // progreso creciente por bloque
        #expect(model.entries.contains { $0.name == "upload.bin" })  // listado refrescado
        #expect(model.conflictingNames(for: [local]) == ["upload.bin"])
    }

    @Test func downloadWritesLocalFile() async throws {
        let fs = sampleTree()
        let payload = sampleData(count: 300_000)
        fs.files["/home/ada/big.dat"] = payload
        let (model, _) = try await browser(fs)
        await model.start()
        let entry = try #require(model.entries.first { $0.name == "big.dat" })
        let local = temporaryURL("big.dat")

        let transfer = await model.download(entry, to: local)
        #expect(transfer.state == .completed)
        #expect(transfer.bytesTotal == UInt64(payload.count))
        #expect(try Data(contentsOf: local) == payload)
    }

    @Test func failedDownloadRemovesPartialFile() async throws {
        let fs = sampleTree()
        fs.files["/home/ada/big.dat"] = sampleData(count: 2_000_000)
        let (model, server) = try await browser(fs)
        await model.start()
        let entry = try #require(model.entries.first { $0.name == "big.dat" })
        server.cutAfterReads = 10  // la conexión cae a mitad
        let local = temporaryURL("big.dat")

        let transfer = await model.download(entry, to: local)
        #expect(transfer.state == .failed("Conexión SFTP perdida."))
        #expect(!FileManager.default.fileExists(atPath: local.path))  // sin parcial engañoso
    }

    @Test func directoriesAreNotDownloadable() async throws {
        let (model, _) = try await browser(sampleTree())
        await model.start()
        let src = try #require(model.entries.first { $0.name == "src" })
        #expect(!src.isDownloadable)
        let transfer = await model.download(src, to: temporaryURL("src"))
        #expect(transfer.state == .failed("src: no se pudo completar la operación."))
    }

    @Test func cancelStopsBetweenChunks() async throws {
        let fs = sampleTree()
        let (model, _) = try await browser(fs)
        await model.start()
        let local = temporaryURL("huge.bin")
        try sampleData(count: 2_000_000).write(to: local)
        model.onChange = {
            if let transfer = model.transfers.last, transfer.state == .transferring, transfer.bytesDone > 0 {
                model.cancel(transfer.id)
            }
        }
        let transfer = await model.upload(local)
        #expect(transfer.state == .cancelled)
        #expect(transfer.bytesDone < 2_000_000)
    }
}
