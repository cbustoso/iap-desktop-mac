// Servidor SFTP v3 en memoria para tests de GH-57: sistema de ficheros
// compartido entre conexiones (para simular corte + reconexión) e inyección
// de fallos (corte tras N WRITE/READ, lecturas cortas, error en un bloque).
import Foundation
@testable import SFTPKit

/// Estado del "disco" remoto. `@unchecked Sendable`: todo bajo `lock`.
final class MemoryFileSystem: @unchecked Sendable {
    let lock = NSLock()
    var files: [String: Data] = [:]
    var directories: Set<String> = ["/"]
    /// Bytes de payload recibidos en WRITE (para detectar duplicados).
    var bytesWritten = 0
    /// Bytes de payload enviados en DATA.
    var bytesRead = 0

    func file(_ path: String) -> Data? { lock.withLock { files[path] } }
    func setFile(_ path: String, _ data: Data) { lock.withLock { files[path] = data } }
    var written: Int { lock.withLock { bytesWritten } }
    var read: Int { lock.withLock { bytesRead } }
}

/// Una conexión SFTP contra `MemoryFileSystem`. `@unchecked Sendable`: bajo `lock`.
final class MemorySftpServer: SftpTransport, @unchecked Sendable {
    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let fs: MemoryFileSystem
    private let lock = NSLock()
    private var framer = SftpFramer()
    private var handles: [Data: Handle] = [:]
    private var nextHandle = 0
    private var dead = false
    private(set) var received: [SftpPacketType] = []
    private(set) var readOffsets: [UInt64] = []

    /// Tras aplicar este número de WRITE, la conexión muere sin responder al último.
    var cutAfterWrites: Int?
    /// Tras responder este número de READ, la conexión muere.
    var cutAfterReads: Int?
    /// Máximo de bytes por DATA (lecturas cortas).
    var maxReadLength = Int.max
    /// Entradas por READDIR.
    var pageSize = 100
    /// WRITE (índice desde 1) que responde PERMISSION_DENIED.
    var denyWriteNumber: Int?

    private var writes = 0
    private var reads = 0

    enum Handle {
        case file(path: String)
        case directory(remaining: [(name: String, attributes: SftpAttributes)])
    }

    init(fs: MemoryFileSystem) {
        self.fs = fs
        (output, continuation) = AsyncStream<Data>.makeStream()
    }

    var receivedTypes: [SftpPacketType] { lock.withLock { received } }
    var readRequestOffsets: [UInt64] { lock.withLock { readOffsets } }

    func write(_ data: Data) async throws {
        let replies: [Data] = try lock.withLock {
            guard !dead else { throw SftpError.channelClosed }
            framer.append(data)
            var replies: [Data] = []
            while let packet = try framer.next() {
                received.append(packet.type)
                if let reply = try handle(packet) { replies.append(reply) }
                if dead { break }
            }
            return replies
        }
        for reply in replies { continuation.yield(reply) }
        if lock.withLock({ dead }) { continuation.finish() }
    }

    func close() async {
        lock.withLock { dead = true }
        continuation.finish()
    }

    // MARK: - Protocolo (bajo `lock`)

    private func handle(_ packet: SftpPacket) throws -> Data? {
        if packet.type == .initialize { return openSSHVersion }
        var reader = SftpReader(packet.payload)
        let id = try reader.uint32()
        func status(_ code: UInt32, _ message: String = "") -> Data {
            SftpPacket.request(.status, id: id) {
                $0.uint32(code)
                $0.string(message)
                $0.string("")
            }.encoded()
        }
        func newHandle(_ value: Handle) -> Data {
            nextHandle += 1
            let token = Data("h\(nextHandle)".utf8)
            handles[token] = value
            return SftpPacket.request(.handle, id: id) { $0.string(token) }.encoded()
        }

        fs.lock.lock()
        defer { fs.lock.unlock() }
        switch packet.type {
        case .open:
            let path = try reader.text()
            let flags = try reader.uint32()
            _ = try SftpAttributes.decode(from: &reader)
            if fs.files[path] == nil {
                guard flags & SftpOpenMode.create != 0 else { return status(SftpStatus.noSuchFile, "No such file") }
                fs.files[path] = Data()
            }
            if flags & SftpOpenMode.truncate != 0 { fs.files[path] = Data() }
            return newHandle(.file(path: path))
        case .close:
            handles.removeValue(forKey: try reader.string())
            return status(SftpStatus.ok)
        case .read:
            guard case .file(let path)? = handles[try reader.string()] else { return status(SftpStatus.failure) }
            let offset = try reader.uint64()
            let length = Int(try reader.uint32())
            readOffsets.append(offset)
            reads += 1
            if let cut = cutAfterReads, reads > cut {
                dead = true
                return nil
            }
            let content = fs.files[path] ?? Data()
            guard offset < UInt64(content.count) else { return status(SftpStatus.eof, "EOF") }
            let start = Int(offset)
            let end = min(content.count, start + min(length, maxReadLength))
            let chunk = Data(content[start..<end])
            fs.bytesRead += chunk.count
            return SftpPacket.request(.data, id: id) { $0.string(chunk) }.encoded()
        case .write:
            guard case .file(let path)? = handles[try reader.string()] else { return status(SftpStatus.failure) }
            let offset = Int(try reader.uint64())
            let chunk = try reader.string()
            writes += 1
            if writes == denyWriteNumber { return status(SftpStatus.permissionDenied, "Permission denied") }
            var content = fs.files[path] ?? Data()
            if content.count < offset { content.append(Data(count: offset - content.count)) }
            let end = offset + chunk.count
            if content.count < end { content.append(Data(count: end - content.count)) }
            content.replaceSubrange(offset..<end, with: chunk)
            fs.files[path] = content
            fs.bytesWritten += chunk.count
            if let cut = cutAfterWrites, writes >= cut {
                dead = true  // aplicado, pero el ACK se pierde
                return nil
            }
            return status(SftpStatus.ok)
        case .opendir:
            let path = try reader.text()
            guard fs.directories.contains(path) else { return status(SftpStatus.noSuchFile, "No such file") }
            return newHandle(.directory(remaining: [(".", dirAttributes), ("..", dirAttributes)] + entries(in: path)))
        case .readdir:
            let token = try reader.string()
            guard case .directory(let remaining)? = handles[token] else { return status(SftpStatus.failure) }
            guard !remaining.isEmpty else { return status(SftpStatus.eof, "EOF") }
            let page = Array(remaining.prefix(pageSize))
            handles[token] = .directory(remaining: Array(remaining.dropFirst(pageSize)))
            return SftpPacket.request(.name, id: id) {
                $0.uint32(UInt32(page.count))
                for entry in page {
                    $0.string(entry.name)
                    $0.string("")
                    entry.attributes.encode(into: &$0)
                }
            }.encoded()
        case .lstat, .stat:
            let path = try reader.text()
            if fs.directories.contains(path) {
                return SftpPacket.request(.attrs, id: id) { dirAttributes.encode(into: &$0) }.encoded()
            }
            guard let content = fs.files[path] else { return status(SftpStatus.noSuchFile, "No such file") }
            return SftpPacket.request(.attrs, id: id) { fileAttributes(size: content.count).encode(into: &$0) }.encoded()
        case .mkdir:
            let path = try reader.text()
            guard !fs.directories.contains(path), fs.files[path] == nil else { return status(SftpStatus.failure, "Failure") }
            fs.directories.insert(path)
            return status(SftpStatus.ok)
        case .rmdir:
            let path = try reader.text()
            guard fs.directories.contains(path) else { return status(SftpStatus.noSuchFile, "No such file") }
            guard entries(in: path).isEmpty else { return status(SftpStatus.failure, "Failure") }
            fs.directories.remove(path)
            return status(SftpStatus.ok)
        case .remove:
            let path = try reader.text()
            guard fs.files.removeValue(forKey: path) != nil else { return status(SftpStatus.noSuchFile, "No such file") }
            return status(SftpStatus.ok)
        case .rename:
            let from = try reader.text()
            let to = try reader.text()
            guard let content = fs.files[from] else { return status(SftpStatus.noSuchFile, "No such file") }
            guard fs.files[to] == nil, !fs.directories.contains(to) else { return status(SftpStatus.failure, "Failure") }
            fs.files[from] = nil
            fs.files[to] = content
            return status(SftpStatus.ok)
        default:
            return status(SftpStatus.operationUnsupported)
        }
    }

    private func entries(in directory: String) -> [(name: String, attributes: SftpAttributes)] {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        func isChild(_ path: String) -> Bool {
            path.hasPrefix(prefix) && path != prefix && !path.dropFirst(prefix.count).contains("/")
        }
        let dirs = fs.directories.filter(isChild).map { (String($0.dropFirst(prefix.count)), dirAttributes) }
        let files = fs.files.keys.filter(isChild).map {
            (String($0.dropFirst(prefix.count)), fileAttributes(size: fs.files[$0]?.count ?? 0))
        }
        return (dirs + files).sorted { $0.0 < $1.0 }
    }
}

private let dirAttributes = SftpAttributes(permissions: 0o040755)
private func fileAttributes(size: Int) -> SftpAttributes {
    SftpAttributes(size: UInt64(size), userID: 1000, groupID: 1000, permissions: 0o100644,
                   accessTime: Date(timeIntervalSince1970: 1_700_000_000),
                   modificationTime: Date(timeIntervalSince1970: 1_700_000_100))
}

func connect(_ server: MemorySftpServer) async throws -> SftpChannel {
    try await SftpChannel.open(linkState: .connected, timeout: .seconds(5)) { server }
}

/// Bytes pseudoaleatorios deterministas.
func sampleData(count: Int, seed: UInt64 = 0x9E37_79B9) -> Data {
    var state = seed
    return Data((0..<count).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: state >> 33)
    })
}
