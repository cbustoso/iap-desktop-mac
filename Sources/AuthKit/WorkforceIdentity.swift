// GH-67 (T-AUTH-7, REQ-AUTH-4): identidades de Workforce Identity Federation.
// Paridad IAP Desktop: `WorkforcePoolProviderLocator`, `WorkforcePoolIdentity`
// (`principal://iam.googleapis.com/locations/L/workforcePools/P/subject/S`) y
// rechazo tipado de OS Login para sesiones workforce.
import Foundation

/// `locations/{location}/workforcePools/{pool}/providers/{provider}`.
public struct WorkforcePoolProviderLocator: Sendable, Hashable, Codable, CustomStringConvertible {
    public let location: String
    public let pool: String
    public let provider: String

    /// IDs de GCP: minúsculas, dígitos y guiones. Sin `/`, `?`, `&`… que
    /// permitirían inyectar parámetros en la URL del portal.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 63
            && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    public init?(location: String = "global", pool: String, provider: String) {
        guard Self.isValidID(location), Self.isValidID(pool), Self.isValidID(provider) else { return nil }
        self.location = location
        self.pool = pool
        self.provider = provider
    }

    /// Lee `locations/L/workforcePools/P/providers/X` (lo que pide `provider_name`).
    public init?(_ resourceName: String) {
        let parts = resourceName.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, parts[0] == "locations", parts[2] == "workforcePools", parts[4] == "providers" else {
            return nil
        }
        self.init(location: parts[1], pool: parts[3], provider: parts[5])
    }

    public var resourceName: String { "locations/\(location)/workforcePools/\(pool)/providers/\(provider)" }
    public var description: String { resourceName }
}

/// Identidad workforce extraída de `principal://…` (el `username` de STS
/// IntrospectToken). No hay email: el `subject` lo asigna el IdP externo.
public struct WorkforceIdentity: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let principalPrefix = "principal://iam.googleapis.com/"

    public let location: String
    public let pool: String
    /// Identificador del usuario en el IdP (puede ser un email): nunca a logs.
    public let subject: String

    /// Parser estricto: solo `principal://` de **workforce** pools (no
    /// `principalSet://`, ni workload identity pools, ni segmentos extra).
    public init?(principal: String) {
        guard principal.hasPrefix(Self.principalPrefix) else { return nil }
        let path = principal.dropFirst(Self.principalPrefix.count)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, parts[0] == "locations", parts[2] == "workforcePools", parts[4] == "subject",
              WorkforcePoolProviderLocator.isValidID(parts[1]), WorkforcePoolProviderLocator.isValidID(parts[3]),
              let subject = parts[5].removingPercentEncoding, !subject.isEmpty,
              !subject.contains(where: { $0.isNewline })
        else { return nil }
        location = parts[1]
        pool = parts[3]
        self.subject = subject
    }

    /// Forma canónica (`subject` codificado como en la API).
    public var principal: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~@+"))
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? subject
        return "\(Self.principalPrefix)locations/\(location)/workforcePools/\(pool)/subject/\(encoded)"
    }

    /// Para la UI y los logs: pool y, del subject, solo el dominio si es un email.
    public var redactedSubject: String {
        subject.contains("@") ? LogRedaction.emailDomain(subject) : "<redacted>"
    }

    public var description: String { "WorkforceIdentity(pool: \(pool), location: \(location), subject: \(redactedSubject))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["location": location, "pool": pool, "subject": redactedSubject])
    }
}

/// Quién es el usuario de la sesión: cuenta Google (Gaia) o workforce (STS).
public enum SessionIdentity: Sendable, Hashable, CustomStringConvertible {
    case gaia(email: String)
    case workforce(WorkforceIdentity)

    public var issuer: OidcIssuer {
        switch self {
        case .gaia: return .gaia
        case .workforce: return .sts
        }
    }

    public var isWorkforce: Bool {
        switch self {
        case .gaia: return false
        case .workforce: return true
        }
    }

    public var description: String {
        switch self {
        case .gaia(let email): return "gaia(\(LogRedaction.emailDomain(email)))"
        case .workforce(let identity): return "workforce(\(identity))"
        }
    }
}

/// OS Login no admite identidades workforce (paridad IAP Desktop: el perfil
/// POSIX se deriva de una cuenta Google). Las capas que autorizan llaves vía
/// OS Login llaman a esto antes de tocar la API y obtienen un error tipado,
/// para que la UI ofrezca las llaves en metadata en vez de un 403 opaco.
public enum OsLoginEligibility {
    public static func requireSupported(_ identity: SessionIdentity) throws(AuthError) {
        switch identity {
        case .gaia: return
        case .workforce: throw .workforceNotSupported
        }
    }

    public static func isSupported(_ identity: SessionIdentity) -> Bool {
        (try? requireSupported(identity)) != nil
    }
}
