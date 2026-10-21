// GH-89: identidad de la cuenta de la sesión `az login`, leída de los claims
// del access token ARM que emite `az` (`tid`, `oid`, `upn`/`unique_name`).
// Es lo que identifica a un perfil Azure: cuenta (`oid`) + tenant (`tid`).
import Foundation

public struct AzureAccountIdentity: Sendable, Equatable, Codable, CustomStringConvertible {
    /// Tenant del token (con `--tenant`, el pedido; sin él, el por defecto de `az`).
    public let tenantID: String
    /// Object ID de la cuenta: estable (el UPN puede cambiar y en B2B lleva `#EXT#`).
    public let objectID: String
    /// UPN; solo en memoria, nunca en el índice de perfiles ni en logs.
    public let username: String

    public init(tenantID: String, objectID: String, username: String) {
        self.tenantID = tenantID
        self.objectID = objectID
        self.username = username
    }

    /// Desde un access token ARM (JWT; la firma no se verifica: lo acaba de
    /// emitir `az` desde su caché local).
    public init(accessToken: String) throws {
        guard let claims = JWTClaims.decode(accessToken),
              let tenantID = claims["tid"] as? String, let objectID = claims["oid"] as? String,
              AzureTenantID.isValid(tenantID), !objectID.isEmpty
        else { throw AzCliError.malformedOutput }
        let username = ["upn", "unique_name", "preferred_username", "email"].lazy.compactMap { claims[$0] as? String }.first
        self.init(tenantID: tenantID, objectID: objectID, username: username ?? "")
    }

    public var description: String {
        "AzureAccountIdentity(tenant: \(tenantID), account: \(ProfileDescriptor.redactedAccount(azureUsername: username)))"
    }
}

/// Identificadores de tenant que aceptamos (GUID o dominio verificado).
public enum AzureTenantID {
    /// Va como argumento de `az` y dentro de URLs: sin `/`, `?`, espacios,
    /// `..` ni `-` inicial (no debe parecer una opción de línea de comandos).
    public static func isValid(_ tenant: String) -> Bool {
        (1...256).contains(tenant.count) && !tenant.contains("..") && !tenant.hasPrefix("-")
            && tenant.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == ".") }
    }
}

/// Claims del payload de un JWT, sin verificar firma.
enum JWTClaims {
    static func decode(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload.append(String(repeating: "=", count: (4 - payload.count % 4) % 4))
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
