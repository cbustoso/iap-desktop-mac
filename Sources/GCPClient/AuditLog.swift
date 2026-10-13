import Foundation

/// Entrada de Cloud Audit Logs normalizada para el visor de eventos.
public struct InstanceAuditEvent: Equatable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let severity: String
    public let description: String
    public let user: String

    public init(
        id: String, timestamp: Date, severity: String,
        description: String, user: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.description = description
        self.user = user
    }
}

private struct AuditEntriesRequest: Encodable {
    let resourceNames: [String]
    let filter: String
    let orderBy = "timestamp desc"
    let pageSize = 1_000
}

private struct AuditEntriesResponse: Decodable {
    let entries: [AuditEntry]?
}

private struct AuditEntry: Decodable {
    struct Payload: Decodable {
        struct AuthenticationInfo: Decodable {
            let principalEmail: String?
        }

        struct Status: Decodable {
            let message: String?
        }

        let methodName: String?
        let resourceName: String?
        let authenticationInfo: AuthenticationInfo?
        let status: Status?
    }

    let insertId: String?
    let timestamp: Date
    let severity: String?
    let textPayload: String?
    let protoPayload: Payload?

    var event: InstanceAuditEvent {
        let method = protoPayload?.methodName?.split(separator: ".").last.map(String.init)
        let detail = protoPayload?.status?.message
        let description = [method, detail, textPayload]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .first ?? protoPayload?.resourceName ?? "Audit log event"
        return InstanceAuditEvent(
            id: insertId ?? "\(timestamp.timeIntervalSince1970)-\(description)",
            timestamp: timestamp,
            severity: severity?.uppercased() ?? "DEFAULT",
            description: description,
            user: protoPayload?.authenticationInfo?.principalEmail ?? "")
    }
}

extension GCPClient {
    /// Lista los eventos de Audit Logs asociados a una instancia desde `since`.
    /// La API limita cada refresco a los 1.000 eventos más recientes.
    public func listInstanceEvents(
        project: String, zone: String, instance: String, since: Date
    ) async throws -> [InstanceAuditEvent] {
        let resourceTypes = ["gce_instance", "gce_project", "audited_resource"]
            .map { "resource.type=\"\($0)\"" }
            .joined(separator: " OR ")
        let escapedZone = auditFilterLiteral(zone)
        let escapedInstance = auditFilterLiteral(instance)
        let labels = "((resource.labels.zone=\"\(escapedZone)\" AND "
            + "resource.labels.instance_id=\"\(escapedInstance)\") OR "
            + "(labels.zone=\"\(escapedZone)\" AND labels.instance_id=\"\(escapedInstance)\"))"
        let timestamp = ISO8601DateFormatter.auditLog.string(from: since)
        let request = AuditEntriesRequest(
            resourceNames: ["projects/\(project)"],
            filter: "(\(resourceTypes)) AND \(labels) AND timestamp>\"\(timestamp)\"")
        let body = try JSONEncoder().encode(request)
        let url = URL(string: "https://logging.googleapis.com/v2/entries:list")!

        let data = try await fetch("POST", url, body: body)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = ISO8601DateFormatter.auditLog.date(from: value)
                    ?? ISO8601DateFormatter.auditLogWithoutFraction.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Invalid RFC3339 timestamp")
            }
            return date
        }
        return try decoder.decode(AuditEntriesResponse.self, from: data)
            .entries?.map(\.event) ?? []
    }
}

private func auditFilterLiteral(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private extension ISO8601DateFormatter {
    static var auditLog: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static var auditLogWithoutFraction: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}
