import Foundation
import GCPClient
import Testing
@testable import ExplorerUI

/// Stub HTTP para `ProjectWorkspace`.
///
/// El handler DEBE ser `@Sendable`: CFNetwork lo invoca en su propio hilo
/// (`com.apple.CFNetwork.CustomProtocols`). Con un tipo no-Sendable, un closure
/// escrito dentro de un suite `@MainActor` hereda aislamiento MainActor (Swift 6)
/// y los closures anidados llevan un check dinámico de ejecutor (SE-0423) →
/// `dispatch_assert_queue` → SIGTRAP fuera del main thread.
private final class ExplorerStubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (response, data) = Self.handler?(request) ?? Self.response(for: request, status: 500)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func response(
        for request: URLRequest, status: Int = 200, json: String = "{}"
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!,
            Data(json.utf8)
        )
    }
}

private func workspace(
    handler: @escaping ExplorerStubURLProtocol.Handler
) -> ProjectWorkspace {
    ExplorerStubURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ExplorerStubURLProtocol.self]
    let client = GCPClient(session: URLSession(configuration: configuration)) { "test-token" }
    return ProjectWorkspace(client: client)
}

/// Registro de invocaciones del handler desde el hilo de CFNetwork.
/// `@unchecked Sendable`: todo acceso pasa por `lock`.
private final class HandlerCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedProjects: [String] = []
    private var sawMainThread = false

    func record(project: String?, onMainThread: Bool) {
        lock.withLock {
            recordedProjects.append(project ?? "")
            sawMainThread = sawMainThread || onMainThread
        }
    }

    var projects: [String] { lock.withLock { recordedProjects } }
    var anyOnMainThread: Bool { lock.withLock { sawMainThread } }
}

private let liveResponse = """
    {"items":{
      "zones/us-central1-b":{"instances":[{
        "name":"windows-vm","zone":"zones/us-central1-b","status":"TERMINATED",
        "disks":[{"licenses":["projects/windows-cloud/global/licenses/windows-server-2022"]}]
      }]},
      "zones/us-central1-a":{"instances":[{
        "name":"web-01","zone":"zones/us-central1-a","status":"RUNNING",
        "disks":[{"licenses":["projects/debian-cloud/global/licenses/debian-12"]}]
      },{
        "name":"diskless","zone":"zones/us-central1-a","status":"RUNNING"
      }]}
    }}
    """

@Suite("ProjectWorkspace live loading", .serialized)
@MainActor
struct ProjectWorkspaceTests {
    @Test func reloadAllDiscoversProjects() async throws {
        let workspace = workspace { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/projects") {
                return ExplorerStubURLProtocol.response(for: request, json: """
                    {"projects":[{"projectId":"project-a","name":"A"}]}
                    """)
            }
            return ExplorerStubURLProtocol.response(for: request, json: liveResponse)
        }
        let projects = try await workspace.reloadAll()
        #expect(projects.map(\.name) == ["project-a"])
        #expect(projects[0].zones.map(\.name) == ["us-central1-a", "us-central1-b"])
    }

    @Test func reloadGroupsZonesAndMapsTraits() async throws {
        let workspace = workspace { request in
            ExplorerStubURLProtocol.response(for: request, json: liveResponse)
        }

        let projects = try await workspace.reload(projectIDs: ["project-a"])

        #expect(projects.map(\.name) == ["project-a"])
        #expect(projects[0].zones.map(\.name) == ["us-central1-a", "us-central1-b"])
        #expect(projects[0].zones[0].instances.map(\.name) == ["web-01"])
        #expect(projects[0].zones[0].instances.map(\.os) == [.linux])
        #expect(projects[0].zones[0].instances.map(\.status) == [.running])
        #expect(projects[0].zones[1].instances.map(\.os) == [.windows])
        #expect(projects[0].zones[1].instances.map(\.status) == [.stopped])
    }

    @Test func fallbackToStoredOnListForbidden() async throws {
        // Sin permiso de listado (403) se cargan los IDs conocidos (Add project).
        let workspace = workspace { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/projects") {
                return ExplorerStubURLProtocol.response(for: request, status: 403)
            }
            return ExplorerStubURLProtocol.response(for: request, json: liveResponse)
        }
        let (projects, discovered) = try await workspace.reloadAllowingStored(stored: ["project-a"])
        #expect(discovered == false)
        #expect(projects.map(\.name) == ["project-a"])
        #expect(!projects[0].zones.isEmpty)
    }

    @Test func forbiddenListWithoutStoredRethrows() async throws {
        let workspace = workspace { request in
            ExplorerStubURLProtocol.response(for: request, status: 403)
        }
        await #expect(throws: GCPClientError.apiError(status: 403, reason: nil)) {
            try await workspace.reloadAllowingStored(stored: [])
        }
    }

    @Test func inaccessibleProjectReturnsEmptyEntry() async throws {
        let workspace = workspace { request in
            let components = request.url?.pathComponents ?? []
            let project = components.firstIndex(of: "projects").flatMap { index in
                components.indices.contains(index + 1) ? components[index + 1] : nil
            } ?? ""
            if project == "denied" {
                return ExplorerStubURLProtocol.response(for: request, status: 403)
            }
            return ExplorerStubURLProtocol.response(for: request, json: liveResponse)
        }

        let projects = try await workspace.reload(projectIDs: ["allowed", "denied"])

        #expect(projects.map(\.name) == ["allowed", "denied"])
        #expect(!projects[0].zones.isEmpty)
        #expect(projects[1].zones.isEmpty)
    }

    /// Regresión del SIGTRAP: el handler se ejecuta en el hilo de CFNetwork y
    /// usa closures anidados (como el de 403). Si el tipo del handler deja de
    /// ser `@Sendable`, este test vuelve a morir con signal 5.
    @Test func stubHandlerRunsOffMainActorWithNestedClosures() async throws {
        let calls = HandlerCalls()
        let workspace = workspace { request in
            let segments = (request.url?.pathComponents ?? []).filter { !$0.isEmpty }
            let project = segments.firstIndex(of: "projects").flatMap { index in
                segments.indices.contains(index + 1) ? segments[index + 1] : nil
            }
            calls.record(project: project, onMainThread: Thread.isMainThread)
            return ExplorerStubURLProtocol.response(for: request, json: liveResponse)
        }

        _ = try await workspace.reload(projectIDs: ["p1", "p2", "p3"])

        #expect(calls.projects.sorted() == ["p1", "p2", "p3"])
        #expect(calls.anyOnMainThread == false)
    }

    @Test(arguments: [403, 404])
    func everyProjectInaccessibleStillLoads(status: Int) async throws {
        let workspace = workspace { request in
            ExplorerStubURLProtocol.response(for: request, status: status)
        }

        let projects = try await workspace.reload(projectIDs: ["a", "b"])

        #expect(projects.map(\.name) == ["a", "b"])
        #expect(projects.allSatisfy { $0.zones.isEmpty })
    }

    @Test func liveLoadKeepsFilterSemanticsAndSelection() async {
        let workspace = workspace { request in
            ExplorerStubURLProtocol.response(for: request, json: liveResponse)
        }
        let selected = InstanceInfo(
            project: "project-a", zone: "us-central1-a", name: "web-01",
            os: .linux, status: .stopped)
        let viewModel = ExplorerViewModel(projects: [
            ProjectInfo(name: "project-a", zones: [
                ZoneInfo(project: "project-a", name: "us-central1-a", instances: [selected])
            ])
        ])
        viewModel.selection = selected
        viewModel.filterText = "WEB"
        viewModel.showWindows = false

        await viewModel.reloadFromGCP(workspace: workspace, projectIDs: ["project-a"])

        #expect(viewModel.isLive)
        #expect(viewModel.statusSummary(source: "MOCK").hasPrefix("LIVE — 1 proyecto"))
        #expect(viewModel.filteredProjects[0].zones[0].instances.map(\.name) == ["web-01"])
        #expect(viewModel.selection?.id == selected.id)
        #expect(viewModel.selection?.status == .running)
    }

    // CBU-28d: el resultado de la auto-carga llega a la App (antes se perdía).
    @Test func reloadAllReportsFailureAndKeepsSnapshot() async {
        let workspace = workspace { request in
            ExplorerStubURLProtocol.response(for: request, status: 401)
        }
        let mock = [ProjectInfo(name: "demo (MOCK)", zones: [])]
        let viewModel = ExplorerViewModel(projects: mock)
        let outcome = await viewModel.reloadAllFromGCP(workspace: workspace)
        guard case .failure(let error) = outcome else {
            Issue.record("se esperaba fallo")
            return
        }
        #expect(error as? GCPClientError == .apiError(status: 401, reason: nil))
        #expect(viewModel.projects == mock)  // se conserva el mock
        #expect(!viewModel.isLive)
    }

    @Test func reloadAllReportsSuccess() async {
        let workspace = workspace { request in
            if request.url?.host == "cloudresourcemanager.googleapis.com" {
                return ExplorerStubURLProtocol.response(
                    for: request, json: #"{"projects":[{"projectId":"project-a","name":"A","lifecycleState":"ACTIVE"}]}"#)
            }
            return ExplorerStubURLProtocol.response(for: request, json: liveResponse)
        }
        let viewModel = ExplorerViewModel()
        let outcome = await viewModel.reloadAllFromGCP(workspace: workspace)
        guard case .success = outcome else {
            Issue.record("se esperaba éxito: \(outcome)")
            return
        }
        #expect(viewModel.isLive)
        #expect(viewModel.projectCount == 1)
    }
}
