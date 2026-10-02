import Foundation

/// Fragmento devuelto por `instances.getSerialPortOutput`.
public struct SerialPortOutputChunk: Equatable, Sendable {
    public let contents: String
    /// Cursor opaco que debe enviarse como `start` en la siguiente petición.
    public let next: String?

    public init(contents: String, next: String?) {
        self.contents = contents
        self.next = next
    }
}

private struct SerialPortOutputResponse: Decodable, Sendable {
    let contents: String?
    let next: String?
}

extension GCPClient {
    /// Lee la salida del puerto serie de una VM. Para hacer polling, pasar el
    /// `next` de la respuesta anterior como `start`.
    public func getSerialPortOutput(
        project: String,
        zone: String,
        instance: String,
        port: Int,
        start: String? = nil
    ) async throws -> SerialPortOutputChunk {
        guard (1...4).contains(port) else { throw GCPClientError.invalidResponse }

        let base = "https://compute.googleapis.com/compute/v1/projects/\(serialPathSegment(project))"
            + "/zones/\(serialPathSegment(zone))/instances/\(serialPathSegment(instance))"
            + "/serialPort"
        var components = URLComponents(string: base)!
        components.queryItems = [URLQueryItem(name: "port", value: String(port))]
        if let start, !start.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "start", value: start))
        }

        let response: SerialPortOutputResponse = try await get(components.url!)
        return SerialPortOutputChunk(
            contents: response.contents ?? "",
            next: response.next.flatMap { $0.isEmpty ? nil : $0 })
    }
}

private func serialPathSegment(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}
