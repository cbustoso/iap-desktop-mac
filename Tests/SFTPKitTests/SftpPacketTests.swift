// GH-55: framing SFTP v3 con vectores reales capturados de OpenSSH
// (`/usr/libexec/sftp-server` de macOS, alimentado con INIT/LSTAT/STAT).
import Foundation
import Testing
@testable import SFTPKit

func hex(_ string: String) -> Data {
    var data = Data()
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        data.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return data
}

/// VERSION de OpenSSH (sftp-server) con sus 11 extensiones.
let openSSHVersion = hex(
    "0000013e020000000300000018706f7369782d72656e616d65406f70656e7373682e636f6d00000001310000001373746174766673406f70656e7373682e636f6d0000000132000000146673746174766673406f70656e7373682e636f6d000000013200000014686172646c696e6b406f70656e7373682e636f6d0000000131000000116673796e63406f70656e7373682e636f6d0000000131000000146c73657473746174406f70656e7373682e636f6d0000000131000000126c696d697473406f70656e7373682e636f6d000000013100000017657870616e642d70617468406f70656e7373682e636f6d000000013100000009636f70792d6461746100000001310000000e686f6d652d6469726563746f727900000001310000001e75736572732d67726f7570732d62792d6964406f70656e7373682e636f6d0000000131")

/// ATTRS (id 7) de un fichero de 11 bytes, uid 501, gid 0, 0100644, a/mtime 1700010800.
let openSSHAttrs = hex("0000002569000000070000000f000000000000000b000001f500000000000081a465541b3065541b30")

/// STATUS (id 8) NO_SUCH_FILE "No such file", idioma vacío.
let openSSHNoSuchFile = hex("0000001d6500000008000000020000000c4e6f20737563682066696c6500000000")

private func single(_ data: Data) throws -> SftpPacket {
    var framer = SftpFramer()
    framer.append(data)
    let packet = try #require(try framer.next())
    #expect(try framer.next() == nil)
    return packet
}

@Suite("SftpPacket (GH-55)")
struct SftpPacketTests {
    @Test func initMatchesOpenSSHClient() {
        // `sftp` de OpenSSH envía exactamente esto al abrir el subsistema.
        #expect(SftpPacket.initialize(version: 3).encoded() == hex("000000050100000003"))
    }

    @Test func requestEncodingMatchesWireFormat() {
        let packet = SftpPacket.request(.lstat, id: 7) { $0.string("/tmp/a") }
        #expect(packet.encoded() == hex("0000000f07" + "00000007" + "00000006" + "2f746d702f61"))
    }

    @Test func decodesOpenSSHVersionAndExtensions() throws {
        let version = try SftpVersion.parse(try single(openSSHVersion))
        #expect(version.version == 3)
        #expect(version.extensions.count == 11)
        #expect(version.extensions["posix-rename@openssh.com"] == "1")
        #expect(version.extensions["statvfs@openssh.com"] == "2")
        #expect(version.extensions["copy-data"] == "1")
        #expect(version.extensions["users-groups-by-id@openssh.com"] == "1")
    }

    @Test func decodesOpenSSHAttrsAndReencodesIdentically() throws {
        let packet = try single(openSSHAttrs)
        let (id, response) = try SftpResponse.parse(packet)
        #expect(id == 7)
        guard case .attrs(let attributes) = response else {
            Issue.record("se esperaba ATTRS")
            return
        }
        #expect(attributes.size == 11)
        #expect(attributes.userID == 501)
        #expect(attributes.groupID == 0)
        #expect(attributes.permissions == 0o100644)
        #expect(attributes.accessTime == Date(timeIntervalSince1970: 1_700_010_800))
        #expect(attributes.modificationTime == Date(timeIntervalSince1970: 1_700_010_800))
        #expect(attributes.flags == [.size, .uidgid, .permissions, .acmodtime])

        // Ida y vuelta: mismos bytes que OpenSSH.
        let rebuilt = SftpPacket.request(.attrs, id: 7) { attributes.encode(into: &$0) }
        #expect(rebuilt.encoded() == openSSHAttrs)
    }

    @Test func decodesOpenSSHStatus() throws {
        let (id, response) = try SftpResponse.parse(try single(openSSHNoSuchFile))
        #expect(id == 8)
        #expect(response == .status(SftpStatus(code: SftpStatus.noSuchFile, message: "No such file")))
        #expect(SftpStatus(code: 2, message: "").error == .fileNotFound)
        #expect(SftpStatus(code: 3, message: "").error == .permissionDenied)
        #expect(SftpStatus(code: 7, message: "").error == .sessionLost)
        #expect(SftpStatus(code: 0, message: "").error == nil)
        #expect(SftpStatus(code: 4, message: "Failure").error == .protocolError(code: 4, message: "Failure"))
    }

    @Test func partialAttributesOnlyEncodePresentFields() throws {
        let attributes = SftpAttributes(size: 5, userID: 1)  // sin gid → sin UIDGID
        #expect(attributes.flags == [.size])
        var writer = SftpWriter()
        attributes.encode(into: &writer)
        #expect(writer.data == hex("00000001" + "0000000000000005"))
        var reader = SftpReader(writer.data)
        #expect(try SftpAttributes.decode(from: &reader) == SftpAttributes(size: 5))
        #expect(reader.isAtEnd)
    }

    @Test func extendedAttributesRoundTrip() throws {
        let attributes = SftpAttributes(permissions: 0o40755, extended: [("acl@x", Data([1, 2]))])
        var writer = SftpWriter()
        attributes.encode(into: &writer)
        var reader = SftpReader(writer.data)
        #expect(try SftpAttributes.decode(from: &reader) == attributes)
    }

    @Test func framerReassemblesSplitAndCoalescedPackets() throws {
        var framer = SftpFramer()
        let stream = openSSHAttrs + openSSHNoSuchFile
        // Byte a byte: nada hasta completar cada paquete.
        var packets: [SftpPacket] = []
        for byte in stream {
            framer.append(Data([byte]))
            while let packet = try framer.next() { packets.append(packet) }
        }
        #expect(packets.map(\.type) == [.attrs, .status])

        // Dos paquetes en un mismo mensaje del canal.
        var coalesced = SftpFramer()
        coalesced.append(stream)
        #expect(try coalesced.next()?.type == .attrs)
        #expect(try coalesced.next()?.type == .status)
        #expect(try coalesced.next() == nil)
    }

    @Test func framerRejectsHostileLengthsAndUnknownTypes() {
        var huge = SftpFramer()
        huge.append(hex("7fffffff65"))  // 2 GiB anunciados
        #expect(throws: SftpError.malformedPacket) { try huge.next() }

        var empty = SftpFramer()
        empty.append(hex("00000000"))
        #expect(throws: SftpError.malformedPacket) { try empty.next() }

        var unknown = SftpFramer()
        unknown.append(hex("00000001ee"))
        #expect(throws: SftpError.malformedPacket) { try unknown.next() }
    }

    @Test func truncatedPayloadsAreMalformedNotCrashes() {
        // NAME que anuncia 1 entrada pero no trae nada.
        let packet = SftpPacket(type: .name, payload: hex("00000009" + "00000001"))
        #expect(throws: SftpError.malformedPacket) { try SftpResponse.parse(packet) }
        // String con longitud mayor que el paquete.
        let status = SftpPacket(type: .status, payload: hex("00000001" + "00000004" + "ffffffff"))
        #expect(throws: SftpError.malformedPacket) { try SftpResponse.parse(status) }
        // Una petición nunca es respuesta.
        let request = SftpPacket.request(.open, id: 1)
        #expect(throws: SftpError.unexpectedResponse(.open)) { try SftpResponse.parse(request) }
    }
}
