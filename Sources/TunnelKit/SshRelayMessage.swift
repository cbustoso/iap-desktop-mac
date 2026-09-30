// SSH Relay v4: tags y close codes (port de SshRelayConstants.cs, iap-desktop).

/// Tags de mensaje del SSH Relay v4. Valores wire (UInt16 big-endian).
///
/// Los tags desconocidos no son error de protocolo: el relay los ignora
/// (SshRelayStream/SshRelaySession, rama `default`). Por eso el decode de tag
/// expone el valor crudo y `SshRelayMessageTag(rawValue:)` puede dar `nil`.
public enum SshRelayMessageTag: UInt16, Sendable, CaseIterable {
    case unused0 = 0
    case connectSuccessSid = 1
    case reconnectSuccessAck = 2
    case deprecated = 3
    case data = 4
    case unused5 = 5
    case unused6 = 6
    case ack = 7
    case unused8 = 8
    case longClose = 10
}

/// Close codes del SSH Relay v4 (extensión de los de RFC 6455).
///
/// El servidor puede enviar códigos fuera de esta lista; por eso LONG_CLOSE
/// decodifica el valor crudo y ofrece este enum como vista opcional.
public enum SshRelayCloseCode: UInt32, Sendable, CaseIterable {
    case normal = 1000
    case abnormalClosure = 1006

    case errorUnknown = 4000
    case sidUnknown = 4001
    case sidInUse = 4002
    case failedToConnectToBackend = 4003
    case reauthenticationRequired = 4004
    case badAck = 4005
    case invalidAck = 4006
    case invalidWebsocketOpcode = 4007
    case invalidTag = 4008
    case destinationWriteFailed = 4009
    case destinationReadFailed = 4010

    case invalidData = 4013
    case notAuthorized = 4033
    case lookupFailed = 4047
    case lookupFailedReconnect = 4051

    case failedToRewind = 4074
}

/// Mensaje del relay ya decodificado (vista de alto nivel sobre `SshRelayFormat`).
public enum SshRelayMessage: Sendable, Equatable {
    case connectSuccessSid(String)
    case reconnectSuccessAck(UInt64)
    case data([UInt8])
    case ack(UInt64)
    case longClose(code: UInt32, reason: String)
    /// Tag no manejado (desconocido, DEPRECATED, UNUSED_*). El llamador lo ignora.
    case unknown(tag: UInt16)
}

extension SshRelayMessage {
    /// Close code tipado de un LONG_CLOSE, si es uno conocido.
    public var closeCode: SshRelayCloseCode? {
        if case .longClose(let code, _) = self { return SshRelayCloseCode(rawValue: code) }
        return nil
    }
}
