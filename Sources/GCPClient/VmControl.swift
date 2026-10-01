import Foundation

private struct ZoneOperation: Decodable, Sendable {
    let name: String
    let status: String?
    let error: ZoneOperationError?
}

private struct ZoneOperationError: Decodable, Sendable {
    let errors: [ZoneOperationErrorItem]?
}

private struct ZoneOperationErrorItem: Decodable, Sendable {
    let code: String?
    let message: String?
}

private enum VmAction: String {
    case start
    case stop
    case reset
    case suspend
    case resume
}

extension GCPClient {
    public func start(project: String, zone: String, instance: String) async throws {
        try await control(.start, project: project, zone: zone, instance: instance)
    }

    public func stop(project: String, zone: String, instance: String) async throws {
        try await control(.stop, project: project, zone: zone, instance: instance)
    }

    public func reset(project: String, zone: String, instance: String) async throws {
        try await control(.reset, project: project, zone: zone, instance: instance)
    }

    public func suspend(project: String, zone: String, instance: String) async throws {
        try await control(.suspend, project: project, zone: zone, instance: instance)
    }

    public func resume(project: String, zone: String, instance: String) async throws {
        try await control(.resume, project: project, zone: zone, instance: instance)
    }

    private func control(
        _ action: VmAction,
        project: String,
        zone: String,
        instance: String
    ) async throws {
        let base = "https://compute.googleapis.com/compute/v1/projects/\(pathSegment(project))"
            + "/zones/\(pathSegment(zone))"
        let actionURL = URL(
            string: "\(base)/instances/\(pathSegment(instance))/\(action.rawValue)")!
        let operation: ZoneOperation = try await send("POST", actionURL, body: nil)
        try validate(operation)
        guard operation.status != "DONE" else { return }

        let operationURL = URL(
            string: "\(base)/operations/\(pathSegment(operation.name))")!
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(120))
        var delay = Duration.milliseconds(250)

        while clock.now < deadline {
            try await Task.sleep(for: delay)
            let current: ZoneOperation = try await get(operationURL)
            try validate(current)
            if current.status == "DONE" { return }
            delay = min(delay * 2, .seconds(2))
        }

        throw GCPClientError.invalidResponse
    }

    private func validate(_ operation: ZoneOperation) throws {
        if operation.status == "DONE", operation.error?.errors?.isEmpty == false {
            throw GCPClientError.invalidResponse
        }
    }

    private func pathSegment(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
