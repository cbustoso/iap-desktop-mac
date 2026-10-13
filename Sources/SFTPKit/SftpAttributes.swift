import Foundation

/// `ATTRS` de SFTP v3: solo están los campos cuyo bit va en `flags`
/// (paridad: el original lanzaba si faltaba `SIZE`; aquí, opcionales).
public struct SftpAttributes: Sendable, Equatable {
    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let size = Flags(rawValue: 0x0000_0001)
        public static let uidgid = Flags(rawValue: 0x0000_0002)
        public static let permissions = Flags(rawValue: 0x0000_0004)
        public static let acmodtime = Flags(rawValue: 0x0000_0008)
        public static let extended = Flags(rawValue: 0x8000_0000)
    }

    public var size: UInt64?
    public var userID: UInt32?
    public var groupID: UInt32?
    /// `st_mode` completo (tipo en la máscara 0xF000 + permisos).
    public var permissions: UInt32?
    public var accessTime: Date?
    public var modificationTime: Date?
    public var extended: [(type: String, data: Data)]

    public init(
        size: UInt64? = nil, userID: UInt32? = nil, groupID: UInt32? = nil, permissions: UInt32? = nil,
        accessTime: Date? = nil, modificationTime: Date? = nil, extended: [(type: String, data: Data)] = []
    ) {
        self.size = size
        self.userID = userID
        self.groupID = groupID
        self.permissions = permissions
        self.accessTime = accessTime
        self.modificationTime = modificationTime
        self.extended = extended
    }

    /// Bits que corresponden a los campos presentes (UID y GID van juntos, igual
    /// que atime/mtime: si falta uno de la pareja, no se envía ninguno).
    public var flags: Flags {
        var flags: Flags = []
        if size != nil { flags.insert(.size) }
        if userID != nil, groupID != nil { flags.insert(.uidgid) }
        if permissions != nil { flags.insert(.permissions) }
        if accessTime != nil, modificationTime != nil { flags.insert(.acmodtime) }
        if !extended.isEmpty { flags.insert(.extended) }
        return flags
    }

    func encode(into writer: inout SftpWriter) {
        let flags = self.flags
        writer.uint32(flags.rawValue)
        if flags.contains(.size), let size { writer.uint64(size) }
        if flags.contains(.uidgid), let userID, let groupID {
            writer.uint32(userID)
            writer.uint32(groupID)
        }
        if flags.contains(.permissions), let permissions { writer.uint32(permissions) }
        if flags.contains(.acmodtime), let accessTime, let modificationTime {
            writer.uint32(Self.seconds(accessTime))
            writer.uint32(Self.seconds(modificationTime))
        }
        if flags.contains(.extended) {
            writer.uint32(UInt32(extended.count))
            for pair in extended {
                writer.string(pair.type)
                writer.string(pair.data)
            }
        }
    }

    static func decode(from reader: inout SftpReader) throws(SftpError) -> SftpAttributes {
        let flags = Flags(rawValue: try reader.uint32())
        var attributes = SftpAttributes()
        if flags.contains(.size) { attributes.size = try reader.uint64() }
        if flags.contains(.uidgid) {
            attributes.userID = try reader.uint32()
            attributes.groupID = try reader.uint32()
        }
        if flags.contains(.permissions) { attributes.permissions = try reader.uint32() }
        if flags.contains(.acmodtime) {
            attributes.accessTime = Date(timeIntervalSince1970: TimeInterval(try reader.uint32()))
            attributes.modificationTime = Date(timeIntervalSince1970: TimeInterval(try reader.uint32()))
        }
        if flags.contains(.extended) {
            let count = try reader.uint32()
            // Cada par ocupa al menos 8 bytes: acota un `count` absurdo.
            for _ in 0..<min(count, 1024) {
                attributes.extended.append((try reader.text(), try reader.string()))
            }
        }
        return attributes
    }

    /// SFTP v3 usa `uint32` en segundos (rango 1970…2106).
    private static func seconds(_ date: Date) -> UInt32 {
        UInt32(clamping: Int64(date.timeIntervalSince1970.rounded(.down)))
    }

    public static func == (lhs: SftpAttributes, rhs: SftpAttributes) -> Bool {
        lhs.size == rhs.size && lhs.userID == rhs.userID && lhs.groupID == rhs.groupID
            && lhs.permissions == rhs.permissions && lhs.accessTime == rhs.accessTime
            && lhs.modificationTime == rhs.modificationTime
            && lhs.extended.map(\.type) == rhs.extended.map(\.type)
            && lhs.extended.map(\.data) == rhs.extended.map(\.data)
    }
}
