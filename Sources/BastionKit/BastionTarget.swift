import CryptoKit
import Foundation

/// Destino de un túnel Bastion: el host del plano de datos (`properties.dnsName`
/// del bastionHost), la VM (ID ARM) y el puerto TCP de la VM.
///
/// Se construye con `validated(...)` a partir de los datos ARM ya leídos
/// (`AzureClient.AzureBastion`): un Bastion no apto se rechaza antes de llamar
/// a `/api/tokens` (REQ-AZ-5, E8 sin POST).
public struct BastionTarget: Sendable, Hashable, CustomStringConvertible {
    public static let tunnelSKUs: Set<String> = ["standard", "premium"]

    public let dnsName: String
    public let vmResourceID: String
    public let port: UInt16

    public init(dnsName: String, vmResourceID: String, port: UInt16) {
        self.dnsName = dnsName
        self.vmResourceID = vmResourceID
        self.port = port
    }

    /// Mismo gate que el CLI (`custom.py` L461‑463, research §3.1): SKU
    /// Standard/Premium con *native client support* y `dnsName` presente.
    public static func validated(
        bastionSKU: String, enableTunneling: Bool, dnsName: String?, vmResourceID: String, port: UInt16
    ) throws(BastionTunnelError) -> BastionTarget {
        guard tunnelSKUs.contains(bastionSKU.lowercased()), enableTunneling else {
            throw .nativeClientDisabled(sku: bastionSKU)
        }
        guard let dnsName, !dnsName.isEmpty else { throw .missingDNSName }
        return BastionTarget(dnsName: dnsName, vmResourceID: vmResourceID, port: port)
    }

    /// Nombre de la VM (último segmento del ID ARM) para logs y UI.
    public var vmName: String {
        vmResourceID.split(separator: "/").last.map(String.init) ?? vmResourceID
    }

    public var description: String { "\(vmName):\(port) vía \(dnsName)" }
}

/// Huella no reversible para correlacionar secretos sin mostrarlos (REQ-AZ-8):
/// longitud + prefijo de SHA-256.
public enum BastionRedaction {
    public static func fingerprint(_ secret: String) -> String {
        let digest = SHA256.hash(data: Data(secret.utf8))
        let prefix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "‹redacted len=\(secret.utf8.count) sha256=\(prefix)›"
    }
}
