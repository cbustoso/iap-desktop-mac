// GH-68: relay mTLS — host `mtls.tunnel.cloudproxy.app` y certificado de
// cliente vía `tlsConfiguration` de WebSocketKit, con handshake TLS real
// contra un servidor NIOSSL local que exige certificado de cliente.
import AuthKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import Testing
@testable import TunnelKit

@Suite("mTLS relay (GH-68)")
struct MtlsEndpointTests {
    @Test func relayHostFollowsDirections() throws {
        let plain = IapEndpoint(project: "p", zone: "z", instance: "i", port: 22)
        #expect(plain.serviceHost == "tunnel.cloudproxy.app")
        #expect(plain.connectURL()?.host == "tunnel.cloudproxy.app")

        let mtls = IapEndpoint(project: "p", zone: "z", instance: "i", port: 22, directions: .mtls)
        #expect(try #require(mtls.connectURL()).host == "mtls.tunnel.cloudproxy.app")
        // El reconnect (sid&ack) va al mismo host que el connect.
        #expect(RelayEndpoint(mtls).reconnectURL("sid-1", 42)?.host == "mtls.tunnel.cloudproxy.app")
        #expect(RelayEndpoint(plain).reconnectURL("sid-1", 42)?.host == "tunnel.cloudproxy.app")
        #expect(IapEndpoint.reconnectURL(sid: "s", ack: 1, zone: "z")?.host == "tunnel.cloudproxy.app")  // API previa intacta

        let psc = IapEndpoint(project: "p", zone: "z", instance: "i", port: 22,
                              directions: .privateServiceConnect(host: "tunnel-psc.p.googleapis.com"))
        #expect(psc.connectURL()?.host == "tunnel-psc.p.googleapis.com")
    }

    @Test func withoutIdentityTransportConfigurationIsUnchanged() throws {
        let configuration = try NIOWebSocketTransport().webSocketConfiguration()
        #expect(configuration.tlsConfiguration == nil)  // WebSocketKit usa su TLS por defecto, como antes
        #expect(configuration.maxFrameSize == 1 << 20)
    }

    @Test func withIdentityTransportPresentsTheDeviceChain() throws {
        let identity = MtlsFixtures.deviceIdentity
        let configuration = try NIOWebSocketTransport(clientIdentity: identity).webSocketConfiguration()
        let tls = try #require(configuration.tlsConfiguration)
        #expect(tls.certificateChain.count == 1)
        #expect(tls.privateKey != nil)
        #expect(tls.certificateVerification == .fullVerification)  // el servidor se sigue verificando
    }

    @Test func signingKeyOffersOnlyAlgorithmsTheKeyCanDo() {
        let key = KeychainSigningKey(identity: MtlsFixtures.deviceIdentity)
        #expect(key.signatureAlgorithms == [.ecdsaSecp256R1Sha256])
        #expect(KeychainSigningKey.secKeyAlgorithm(for: .ecdsaSecp256R1Sha256) == .ecdsaSignatureMessageX962SHA256)
        #expect(KeychainSigningKey.secKeyAlgorithm(for: .ed25519) == nil)
    }
}

/// Lo que vio el servidor TLS. `@unchecked Sendable`: bajo `lock`.
private final class ServerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [[UInt8]] = []
    private var errors = 0
    func peer(_ der: [UInt8]) { lock.withLock { peers.append(der) } }
    func error() { lock.withLock { errors += 1 } }
    var peerCertificates: [[UInt8]] { lock.withLock { peers } }
    var errorCount: Int { lock.withLock { errors } }
}

/// Registra el certificado del cliente al completar el handshake.
private final class PeerRecorder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let log: ServerLog
    init(log: ServerLog) { self.log = log }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event,
           let handler = try? context.pipeline.syncOperations.handler(type: NIOSSLServerHandler.self),
           let peer = handler.peerCertificate {
            log.peer((try? peer.toDERBytes()) ?? [])
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        log.error()
        context.close(promise: nil)
    }
}

/// Espera el fin del handshake del lado cliente.
private final class ClientHandshake: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let done: EventLoopPromise<Void>
    init(done: EventLoopPromise<Void>) { self.done = done }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event { done.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { done.fail(error) }
    func channelInactive(context: ChannelHandlerContext) { done.fail(ChannelError.ioOnClosedChannel) }
}

@Suite("mTLS handshake real (GH-68)", .serialized, .timeLimit(.minutes(1)))
struct MtlsHandshakeTests {
    private func withServer(_ body: (Int, ServerLog) async throws -> Void) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let ca = try NIOSSLCertificate(bytes: [UInt8](MtlsFixtures.der(MtlsFixtures.caPEM)), format: .der)
        var server = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(ca)],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: [UInt8](MtlsFixtures.caKeyPKCS8.utf8), format: .pem)))
        server.certificateVerification = .noHostnameVerification  // exige certificado de cliente
        server.trustRoots = .certificates([ca])
        let context = try NIOSSLContext(configuration: server)
        let log = ServerLog()
        let channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    try channel.pipeline.syncOperations.addHandler(PeerRecorder(log: log))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        do {
            try await body(channel.localAddress!.port!, log)
        } catch {
            try? await channel.close()
            try? await group.shutdownGracefully()
            throw error
        }
        try? await channel.close()
        try? await group.shutdownGracefully()
    }

    private func handshake(port: Int, configuration: TLSConfiguration) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            try await clientHandshake(port: port, configuration: configuration, group: group)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        try? await group.shutdownGracefully()
    }

    private func clientHandshake(port: Int, configuration: TLSConfiguration, group: MultiThreadedEventLoopGroup) async throws {
        var tls = configuration
        let ca = try NIOSSLCertificate(bytes: [UInt8](MtlsFixtures.der(MtlsFixtures.caPEM)), format: .der)
        tls.trustRoots = .certificates([ca])
        tls.certificateVerification = .noHostnameVerification  // el cert de test no es de 127.0.0.1
        let context = try NIOSSLContext(configuration: tls)
        let done = group.next().makePromise(of: Void.self)
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(try NIOSSLClientHandler(context: context, serverHostname: nil))
                    try channel.pipeline.syncOperations.addHandler(ClientHandshake(done: done))
                }
            }
            .connect(host: "127.0.0.1", port: port).get()
        defer { channel.close(promise: nil) }
        try await done.futureResult.get()
        // TLS 1.3: el servidor valida el certificado del cliente tras el
        // handshake del cliente; un write/read fuerza ese veredicto.
        try await channel.writeAndFlush(channel.allocator.buffer(string: "ping")).get()
        try await Task.sleep(for: .milliseconds(100))
    }

    @Test func serverReceivesTheDeviceCertificateSignedViaSecKey() async throws {
        try await withServer { port, log in
            let identity = MtlsFixtures.deviceIdentity
            try await handshake(port: port, configuration: try DeviceTLS.clientConfiguration(for: identity))
            #expect(log.peerCertificates == [[UInt8](identity.certificate.derBytes)])
            #expect(log.errorCount == 0)
        }
    }

    @Test func withoutDeviceCertificateTheServerRejects() async throws {
        try await withServer { port, log in
            try? await handshake(port: port, configuration: .makeClientConfiguration())
            try await Task.sleep(for: .milliseconds(100))
            #expect(log.peerCertificates.isEmpty)
            #expect(log.errorCount >= 1)
        }
    }
}
