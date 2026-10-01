import Foundation

/// Decodificador UTF-8 incremental (paridad `StreamingDecoder` del original).
///
/// SSH entrega bytes en paquetes arbitrarios: una secuencia multibyte (p. ej.
/// "ñ" = C3 B1, "€" = E2 82 AC, emoji de 4 bytes) puede llegar partida entre
/// dos paquetes. Decodificar cada paquete por separado produciría U+FFFD en
/// mitad del texto. Este decodificador retiene la secuencia incompleta final
/// (≤ 3 bytes) hasta el siguiente paquete. Bytes realmente inválidos se
/// sustituyen por U+FFFD, como `String(decoding:as:)`.
public struct StreamingDecoder: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    /// Bytes retenidos a la espera de completar una secuencia.
    public var pendingByteCount: Int { pending.count }

    /// Decodifica `chunk` (más lo retenido) y devuelve solo texto completo.
    public mutating func decode(_ chunk: Data) -> String {
        var bytes = pending
        bytes.append(contentsOf: chunk)
        let cut = Self.completePrefixLength(bytes)
        pending = Array(bytes[cut...])
        return String(decoding: bytes[..<cut], as: UTF8.self)
    }

    /// Fin del flujo: lo retenido ya no se completará (→ U+FFFD).
    public mutating func finish() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }

    /// Longitud del prefijo que no termina en una secuencia incompleta.
    static func completePrefixLength(_ bytes: [UInt8]) -> Int {
        // Busca el último byte inicial (no de continuación) en los 3 finales.
        var index = bytes.count - 1
        let lowerBound = max(bytes.count - 4, 0)
        while index >= lowerBound {
            let byte = bytes[index]
            if byte & 0b1100_0000 != 0b1000_0000 {
                let expected = sequenceLength(lead: byte)
                let available = bytes.count - index
                // Incompleta solo si es un inicio válido de multibyte al que
                // le faltan bytes; un lead inválido se deja pasar (→ U+FFFD).
                return expected > 1 && available < expected ? index : bytes.count
            }
            index -= 1
        }
        return bytes.count
    }

    private static func sequenceLength(lead: UInt8) -> Int {
        switch lead {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return 1  // C0, C1, F5–FF o continuación suelta: inválido
        }
    }
}
