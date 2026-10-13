// GH-57 (T-SFTP-3/4): FileType por máscara, listado paginado, operaciones de
// directorio, flags de apertura, corte + reanudación sin duplicar bytes y
// `seek` sin tráfico.
import Foundation
import Testing
@testable import SFTPKit

@Suite("PosixFileMode (GH-57)")
struct PosixFileModeTests {
    @Test(arguments: [
        (UInt32(0o010644), PosixFileMode.FileType.fifo),
        (0o020620, .characterDevice),
        (0o040755, .directory),
        (0o060660, .blockSpecial),
        (0o100644, .regular),
        (0o120777, .symbolicLink),
        (0o140755, .socket),
    ])
    func fileTypeForEachMask(mode: UInt32, expected: PosixFileMode.FileType) {
        #expect(PosixFileMode(rawValue: mode).fileType == expected)
        // Los bits de permiso no influyen en el tipo.
        #expect(PosixFileMode(rawValue: mode | 0o7777).fileType == expected)
        #expect(PosixFileMode(rawValue: mode & PosixFileMode.fileTypeMask).fileType == expected)
    }

    @Test func unmappedMasksAreExplicitlyUnknown() {
        for mode: UInt32 in [0, 0o000644, 0o030000, 0o050000, 0o070000, 0o110000, 0o130000, 0o150000, 0o160000, 0o170000] {
            #expect(PosixFileMode(rawValue: mode).fileType == .unknown, "\(String(mode, radix: 8))")
        }
    }

    @Test func everyTypeHasDistinctFrozenMask() {
        let masks = PosixFileMode.FileType.allCases.compactMap(\.mask)
        #expect(masks.count == 7)
        #expect(Set(masks).count == 7)
        #expect(PosixFileMode.FileType.unknown.mask == nil)
        for type in PosixFileMode.FileType.allCases {
            if let mask = type.mask { #expect(PosixFileMode(rawValue: mask).fileType == type) }
        }
        // Valores POSIX congelados.
        #expect(PosixFileMode.ownerRead.rawValue == 0o400)
        #expect(PosixFileMode.otherExecute.rawValue == 0o001)
        #expect(PosixFileMode.sticky.rawValue == 0o1000)
    }

    @Test func symbolicLikeLs() {
        #expect(PosixFileMode(rawValue: 0o100644).symbolic == "rw-r--r--")
        #expect(PosixFileMode(rawValue: 0o040755).symbolic == "rwxr-xr-x")
        #expect(PosixFileMode(rawValue: 0o104755).symbolic == "rwsr-xr-x")
        #expect(PosixFileMode(rawValue: 0o041777).symbolic == "rwxrwxrwt")
        #expect(PosixFileMode(rawValue: 0o102644).symbolic == "rw-r-Sr--")
        #expect(PosixFileMode(rawValue: 0o100644).permissionBits.rawValue == 0o644)
    }

    @Test func fileInfoFromAttributes() {
        let info = SftpFileInfo(name: "a", attributes: SftpAttributes(size: 3, permissions: 0o120777))
        #expect(info.isSymbolicLink)
        #expect(!info.isDirectory)
        #expect(info.size == 3)
        #expect(info.userID == nil)  // no enviado → nil
        #expect(SftpFileInfo(name: "x", attributes: SftpAttributes()).permissions.fileType == .unknown)
    }
}

@Suite("SftpChannel operaciones (GH-57)", .timeLimit(.minutes(1)))
struct SftpOperationTests {
    @Test func listFilesPaginatesUntilEOFAndClosesHandle() async throws {
        let fs = MemoryFileSystem()
        fs.directories.insert("/data")
        fs.directories.insert("/data/sub")
        for index in 0..<24 { fs.files[String(format: "/data/f%02d.txt", index)] = Data(count: index) }
        let server = MemorySftpServer(fs: fs)
        server.pageSize = 7
        let channel = try await connect(server)

        let files = try await channel.listFiles(atPath: "/data")
        #expect(files.count == 25)  // 24 ficheros + "sub"; sin "." ni ".."
        #expect(!files.contains { $0.name == "." || $0.name == ".." })
        #expect(files.first { $0.name == "sub" }?.isDirectory == true)
        let f05 = try #require(files.first { $0.name == "f05.txt" })
        #expect(f05.isRegular)
        #expect(f05.size == 5)
        #expect(f05.permissions.symbolic == "rw-r--r--")
        #expect(f05.lastModifiedDate == Date(timeIntervalSince1970: 1_700_000_100))

        // 27 entradas (con . y ..) en páginas de 7 → 4 NAME + EOF, y CLOSE al final.
        let types = server.receivedTypes.filter { $0 != .initialize }
        #expect(types == [.opendir] + Array(repeating: .readdir, count: 5) + [.close])
        await channel.close()
    }

    @Test func listingMissingDirectoryIsTyped() async throws {
        let channel = try await connect(MemorySftpServer(fs: MemoryFileSystem()))
        await #expect(throws: SftpError.fileNotFound) { try await channel.listFiles(atPath: "/nope") }
        await channel.close()
    }

    @Test func directoryAndFileOperations() async throws {
        let fs = MemoryFileSystem()
        fs.files["/a.txt"] = Data("hola".utf8)
        let channel = try await connect(MemorySftpServer(fs: fs))

        try await channel.makeDirectory(atPath: "/docs")
        #expect(try await channel.attributes(atPath: "/docs").isDirectory)
        await #expect(throws: SftpError.protocolError(code: SftpStatus.failure, message: "Failure")) {
            try await channel.makeDirectory(atPath: "/docs")
        }

        try await channel.rename(fromPath: "/a.txt", toPath: "/docs/a.txt")
        #expect(fs.file("/a.txt") == nil)
        let moved = try await channel.attributes(atPath: "/docs/a.txt")
        #expect(moved.name == "a.txt")
        #expect(moved.size == 4)

        // RMDIR de un directorio no vacío falla; vaciado, funciona.
        await #expect(throws: SftpError.protocolError(code: SftpStatus.failure, message: "Failure")) {
            try await channel.removeDirectory(atPath: "/docs")
        }
        try await channel.remove(atPath: "/docs/a.txt")
        try await channel.removeDirectory(atPath: "/docs")
        await #expect(throws: SftpError.fileNotFound) { try await channel.attributes(atPath: "/docs") }
        await #expect(throws: SftpError.fileNotFound) { try await channel.remove(atPath: "/docs/a.txt") }
        await channel.close()
    }

    @Test func openModesMapToProtocolFlags() {
        #expect(SftpOpenMode.readOnly.flags == 0x01)
        #expect(SftpOpenMode.writeCreateTruncate.flags == 0x1a)  // WRITE|CREAT|TRUNC
        #expect(SftpOpenMode.writeCreateOrAppend.flags == 0x0a)  // WRITE|CREAT, sin TRUNC ni APPEND
    }

    @Test func truncateVersusResumableOpen() async throws {
        let fs = MemoryFileSystem()
        fs.files["/f"] = Data("0123456789".utf8)
        let channel = try await connect(MemorySftpServer(fs: fs))

        let keep = try await channel.openFile(atPath: "/f", mode: .writeCreateOrAppend)
        #expect(fs.file("/f") == Data("0123456789".utf8))  // no trunca
        await keep.seek(to: 10)
        try await keep.write(Data("AB".utf8))
        await keep.close()
        #expect(fs.file("/f") == Data("0123456789AB".utf8))

        let fresh = try await channel.openFile(atPath: "/f", mode: .writeCreateTruncate)
        #expect(fs.file("/f") == Data())
        await fresh.close()
        await #expect(throws: SftpError.fileNotFound) { try await channel.openFile(atPath: "/missing", mode: .readOnly) }
        await channel.close()
    }
}

@Suite("SftpFileHandle transferencia (GH-57)", .timeLimit(.minutes(1)))
struct SftpFileHandleTests {
    @Test func seekGeneratesNoTraffic() async throws {
        let fs = MemoryFileSystem()
        fs.files["/f"] = sampleData(count: 100_000)
        let server = MemorySftpServer(fs: fs)
        let channel = try await connect(server)
        let file = try await channel.openFile(atPath: "/f", mode: .readOnly)

        let before = server.receivedTypes.count
        await file.seek(to: 70_000)
        await file.seek(to: 12_345)
        #expect(server.receivedTypes.count == before)  // cero paquetes
        #expect(await file.offset == 12_345)

        // La siguiente lectura lleva el offset en el propio READ.
        let chunk = try await file.read(upTo: 10)
        #expect(chunk == fs.file("/f")?.subdata(in: 12_345..<12_355))
        #expect(server.readRequestOffsets == [12_345])
        #expect(await file.offset == 12_355)
        await file.close()
        await channel.close()
    }

    @Test func roundTripLargeFileWithPipelinedChunks() async throws {
        let fs = MemoryFileSystem()
        let server = MemorySftpServer(fs: fs)
        let channel = try await connect(server)
        let payload = sampleData(count: 1_000_003)  // no múltiplo del bloque

        let upload = try await channel.openFile(atPath: "/big.bin", mode: .writeCreateTruncate)
        try await upload.write(payload)
        #expect(await upload.offset == UInt64(payload.count))
        await upload.close()
        #expect(fs.file("/big.bin") == payload)
        #expect(server.receivedTypes.filter { $0 == .write }.count == (payload.count + SftpFileHandle.chunkSize - 1) / SftpFileHandle.chunkSize)

        let download = try await channel.openFile(atPath: "/big.bin", mode: .readOnly)
        var received = Data()
        while true {
            let chunk = try await download.read(upTo: 300_000)
            if chunk.isEmpty { break }
            received.append(chunk)
        }
        #expect(received == payload)
        await download.close()
        await channel.close()
    }

    @Test func shortReadsNeverLeaveGaps() async throws {
        let fs = MemoryFileSystem()
        let payload = sampleData(count: 50_000)
        fs.files["/f"] = payload
        let server = MemorySftpServer(fs: fs)
        server.maxReadLength = 1_000  // el servidor acorta cada READ
        let channel = try await connect(server)
        let file = try await channel.openFile(atPath: "/f", mode: .readOnly)

        let first = try await file.read(upTo: 200_000)
        #expect(first == payload.prefix(1_000))  // lo contiguo; el resto se descarta
        #expect(await file.offset == 1_000)
        var received = first
        while true {
            let chunk = try await file.read(upTo: 200_000)
            if chunk.isEmpty { break }
            received.append(chunk)
        }
        #expect(received == payload)
        await file.close()
        await channel.close()
    }

    @Test func uploadCutMidwayResumesFromRemoteSizeWithoutDuplicates() async throws {
        let fs = MemoryFileSystem()
        let payload = sampleData(count: 300_000)  // 10 bloques
        let first = MemorySftpServer(fs: fs)
        first.cutAfterWrites = 4  // el 4.º se aplica pero su ACK se pierde
        let channel = try await connect(first)
        let upload = try await channel.openFile(atPath: "/up.bin", mode: .writeCreateTruncate)

        await #expect(throws: SftpError.channelClosed) { try await upload.write(payload) }
        let confirmed = await upload.offset
        #expect(confirmed == 3 * UInt64(SftpFileHandle.chunkSize))  // solo lo confirmado
        await channel.close()

        // Reconexión: el tamaño remoto (4 bloques) manda sobre lo confirmado.
        let second = try await connect(MemorySftpServer(fs: fs))
        let remoteSize = try #require(try await second.attributes(atPath: "/up.bin").size)
        #expect(remoteSize == 4 * UInt64(SftpFileHandle.chunkSize))
        let resume = try await second.openFile(atPath: "/up.bin", mode: .writeCreateOrAppend)
        await resume.seek(to: remoteSize)
        try await resume.write(payload.subdata(in: Int(remoteSize)..<payload.count))
        await resume.close()

        #expect(fs.file("/up.bin") == payload)
        #expect(fs.written == payload.count)  // cada byte enviado exactamente una vez
        await second.close()
    }

    @Test func downloadCutMidwayResumesFromLocalOffsetWithoutDuplicates() async throws {
        let fs = MemoryFileSystem()
        let payload = sampleData(count: 400_000)
        fs.files["/down.bin"] = payload
        let first = MemorySftpServer(fs: fs)
        first.cutAfterReads = 3
        let channel = try await connect(first)
        let download = try await channel.openFile(atPath: "/down.bin", mode: .readOnly)

        // Se entrega lo contiguo recibido antes del corte; el error, después.
        var local = try await download.read(upTo: payload.count)
        #expect(local == payload.prefix(3 * SftpFileHandle.chunkSize))
        await #expect(throws: SftpError.channelClosed) { try await download.read(upTo: 1) }
        await channel.close()

        let second = try await connect(MemorySftpServer(fs: fs))
        let resume = try await second.openFile(atPath: "/down.bin", mode: .readOnly)
        await resume.seek(to: UInt64(local.count))
        while true {
            let chunk = try await resume.read(upTo: 128 * 1024)
            if chunk.isEmpty { break }
            local.append(chunk)
        }
        #expect(local == payload)
        #expect(fs.read == payload.count)  // ningún byte servido dos veces
        await resume.close()
        await second.close()
    }

    @Test func writeErrorStopsAtLastContiguousConfirmedChunk() async throws {
        let fs = MemoryFileSystem()
        let server = MemorySftpServer(fs: fs)
        server.denyWriteNumber = 3
        let channel = try await connect(server)
        let file = try await channel.openFile(atPath: "/f", mode: .writeCreateTruncate)
        await #expect(throws: SftpError.permissionDenied) { try await file.write(sampleData(count: 200_000)) }
        #expect(await file.offset == 2 * UInt64(SftpFileHandle.chunkSize))
        await file.close()
        await channel.close()
    }

    @Test func closedHandleRejectsIO() async throws {
        let fs = MemoryFileSystem()
        fs.files["/f"] = Data("x".utf8)
        let channel = try await connect(MemorySftpServer(fs: fs))
        let file = try await channel.openFile(atPath: "/f", mode: .readOnly)
        await file.close()
        await #expect(throws: SftpError.channelClosed) { try await file.read(upTo: 1) }
        await channel.close()
        await #expect(throws: SftpError.channelClosed) { try await channel.listFiles(atPath: "/") }
    }
}
