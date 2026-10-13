import Foundation

/// `st_mode` POSIX tal como lo transporta SFTP (`ATTRS.permissions`). Tipo
/// congelado: los bits de permiso y las máscaras de tipo son los de POSIX y
/// nunca cambian de valor (paridad `FilePermissions` del original).
public struct PosixFileMode: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let ownerRead = PosixFileMode(rawValue: 0o400)
    public static let ownerWrite = PosixFileMode(rawValue: 0o200)
    public static let ownerExecute = PosixFileMode(rawValue: 0o100)
    public static let groupRead = PosixFileMode(rawValue: 0o040)
    public static let groupWrite = PosixFileMode(rawValue: 0o020)
    public static let groupExecute = PosixFileMode(rawValue: 0o010)
    public static let otherRead = PosixFileMode(rawValue: 0o004)
    public static let otherWrite = PosixFileMode(rawValue: 0o002)
    public static let otherExecute = PosixFileMode(rawValue: 0o001)
    public static let setUserID = PosixFileMode(rawValue: 0o4000)
    public static let setGroupID = PosixFileMode(rawValue: 0o2000)
    public static let sticky = PosixFileMode(rawValue: 0o1000)

    /// Máscara del tipo de fichero (`S_IFMT`).
    public static let fileTypeMask: UInt32 = 0o170000

    /// Tipo de fichero. Cerrado: cada caso declara su máscara en un `switch`
    /// exhaustivo (sin `default`), así que un caso nuevo no compila sin mapear;
    /// una máscara que no corresponde a ningún caso es `.unknown`, explícito.
    public enum FileType: Sendable, Equatable, CaseIterable {
        case fifo, characterDevice, directory, blockSpecial, regular, symbolicLink, socket, unknown

        /// Valor de `S_IFMT` del tipo; `nil` para `.unknown`.
        public var mask: UInt32? {
            switch self {
            case .fifo: return 0o010000
            case .characterDevice: return 0o020000
            case .directory: return 0o040000
            case .blockSpecial: return 0o060000
            case .regular: return 0o100000
            case .symbolicLink: return 0o120000
            case .socket: return 0o140000
            case .unknown: return nil
            }
        }
    }

    public var fileType: FileType {
        let bits = rawValue & Self.fileTypeMask
        return FileType.allCases.first { $0.mask == bits } ?? .unknown
    }

    /// Solo los bits de permiso (`0o7777`), sin el tipo.
    public var permissionBits: PosixFileMode { PosixFileMode(rawValue: rawValue & 0o7777) }

    /// `rwxr-xr-x` (con `s`/`S`/`t`/`T` como `ls -l`), sin el carácter de tipo.
    public var symbolic: String {
        func triplet(_ read: Self, _ write: Self, _ execute: Self, special: Self, on: Character, off: Character) -> String {
            let x: Character = contains(special) ? (contains(execute) ? on : off) : (contains(execute) ? "x" : "-")
            return String([contains(read) ? "r" : "-", contains(write) ? "w" : "-", x])
        }
        return triplet(.ownerRead, .ownerWrite, .ownerExecute, special: .setUserID, on: "s", off: "S")
            + triplet(.groupRead, .groupWrite, .groupExecute, special: .setGroupID, on: "s", off: "S")
            + triplet(.otherRead, .otherWrite, .otherExecute, special: .sticky, on: "t", off: "T")
    }
}

/// Fichero remoto (paridad `SftpFileInfo` del original): campos opcionales
/// cuando el servidor no los envía.
public struct SftpFileInfo: Sendable, Equatable {
    public let name: String
    public let permissions: PosixFileMode
    public let userID: UInt32?
    public let groupID: UInt32?
    public let lastAccessDate: Date?
    public let lastModifiedDate: Date?
    public let size: UInt64?

    public var isDirectory: Bool { permissions.fileType == .directory }
    public var isSymbolicLink: Bool { permissions.fileType == .symbolicLink }
    public var isRegular: Bool { permissions.fileType == .regular }

    public init(name: String, attributes: SftpAttributes) {
        self.name = name
        permissions = PosixFileMode(rawValue: attributes.permissions ?? 0)
        userID = attributes.userID
        groupID = attributes.groupID
        lastAccessDate = attributes.accessTime
        lastModifiedDate = attributes.modificationTime
        size = attributes.size
    }
}
