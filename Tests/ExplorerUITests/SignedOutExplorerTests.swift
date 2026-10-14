// GH-78: sin sesión el Explorer no muestra nodos (ni mock): estado vacío con
// "Sign In". Con sesión, el árbol; al cerrar sesión, de vuelta al vacío.
import AppKit
import Testing
@testable import ExplorerUI

private let instance = InstanceInfo(project: "project-a", zone: "z", name: "web-01", os: .linux, status: .running)
private let live = [ProjectInfo(name: "project-a", zones: [ZoneInfo(project: "project-a", name: "z", instances: [instance])])]

@Suite("Explorer sin sesión (GH-78)")
@MainActor
struct SignedOutExplorerTests {
    @Test func signedOutShowsSignInPromptAndNoNodes() {
        let viewModel = ExplorerViewModel(isSignedIn: false)
        let controller = ExplorerWindowController(viewModel: viewModel, dataSourceLabel: "GCP")
        #expect(controller.isShowingSignInPrompt)
        #expect(controller.signInButton.title == "Sign In")
        #expect(!controller.selectNode(id: "cloud"))  // ni siquiera el nodo raíz
        #expect(controller.statusBar.summary == ExplorerViewModel.signedOutSummary)
        // Asignar proyectos sin sesión no los muestra (sin sesión no hay datos).
        viewModel.projects = live
        #expect(!controller.selectNode(id: ExplorerNode.instance(instance).id))
    }

    @Test func signInButtonOpensLogin() {
        let controller = ExplorerWindowController(viewModel: ExplorerViewModel(isSignedIn: false))
        var requests = 0
        controller.onSignInRequest = { requests += 1 }
        controller.signInButton.performClick(nil)
        #expect(requests == 1)
    }

    @Test func sessionShowsTreeAndLogoutReturnsToEmptyStateKeepingNote() {
        let viewModel = ExplorerViewModel(isSignedIn: false)
        let controller = ExplorerWindowController(viewModel: viewModel, dataSourceLabel: "GCP")

        viewModel.sessionStarted()
        viewModel.projects = live
        #expect(!controller.isShowingSignInPrompt)
        #expect(controller.selectNode(id: ExplorerNode.instance(instance).id))
        #expect(controller.statusBar.summary == "GCP — 1 proyecto, 1 instancia")

        controller.statusNote = "Google rechazó la sesión (401): vuelve a iniciar sesión."
        viewModel.sessionEnded()
        #expect(controller.isShowingSignInPrompt)
        #expect(!controller.selectNode(id: ExplorerNode.instance(instance).id))
        #expect(controller.selectedNode == nil)
        #expect(controller.statusBar.summary == ExplorerViewModel.signedOutSummary)
        #expect(controller.statusNote == "Google rechazó la sesión (401): vuelve a iniciar sesión.")  // se conserva
    }

    @Test func signedInByDefaultKeepsExistingSnapshots() {
        // Compatibilidad: un snapshot ya autorizado (tests/previews) se muestra.
        let controller = ExplorerWindowController(viewModel: ExplorerViewModel(projects: live))
        #expect(!controller.isShowingSignInPrompt)
        #expect(controller.selectNode(id: "cloud"))
    }
}
