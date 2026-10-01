// ExplorerUI tests CBU-29: iconos, propiedades, menú contextual, status bar
// y smoke de la ventana AppKit (selección → detalle no vacío).
import AppKit
import Testing
@testable import ExplorerUI

private let linuxVM = InstanceInfo(project: "p", zone: "z", name: "web-01", os: .linux, status: .running)
private let windowsVM = InstanceInfo(project: "p", zone: "z", name: "adsrv", os: .windows, status: .stopped)

private func sample() -> [ProjectInfo] {
    [
        ProjectInfo(name: "p", zones: [ZoneInfo(project: "p", name: "z", instances: [linuxVM, windowsVM])]),
        ProjectInfo(name: "q", zones: [
            ZoneInfo(project: "q", name: "y", instances: [
                InstanceInfo(project: "q", zone: "y", name: "db-01", os: .linux, status: .unknown),
            ]),
        ]),
    ]
}

@Suite("ExplorerNode presentación")
struct ExplorerNodeTests {
    @Test func symbolsPerType() {
        #expect(ExplorerNode.cloud(projectCount: 0, instanceCount: 0).symbolName == "cloud")
        #expect(ExplorerNode.project(ProjectInfo(name: "p")).symbolName == "folder")
        #expect(ExplorerNode.zone(ZoneInfo(project: "p", name: "z")).symbolName == "globe")
        #expect(ExplorerNode.instance(linuxVM).symbolName == "terminal")
        #expect(ExplorerNode.instance(windowsVM).symbolName == "pc")
    }

    @Test func symbolsExistInSystem() {
        let nodes: [ExplorerNode] = [
            .cloud(projectCount: 0, instanceCount: 0), .project(ProjectInfo(name: "p")),
            .zone(ZoneInfo(project: "p", name: "z")), .instance(linuxVM), .instance(windowsVM),
        ]
        let symbols = nodes.map(\.symbolName) + ExplorerCommand.allCases.map(\.symbolName)
            + ["server.rack", "plus.rectangle.on.folder", "arrow.clockwise", "gearshape", "person.crop.circle"]
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
    }

    @Test func idsAreStableAcrossFiltering() {
        let full = ZoneInfo(project: "p", name: "z", instances: [linuxVM, windowsVM])
        let filtered = ZoneInfo(project: "p", name: "z", instances: [linuxVM])
        #expect(ExplorerNode.zone(full).id == ExplorerNode.zone(filtered).id)
        #expect(ExplorerNode.instance(linuxVM).id == "instance:p/z/web-01")
    }

    @Test func propertiesNeverEmpty() {
        let nodes: [ExplorerNode] = [
            .cloud(projectCount: 2, instanceCount: 3), .project(sample()[0]),
            .zone(sample()[0].zones[0]), .instance(linuxVM),
        ]
        for node in nodes {
            #expect(!node.properties.isEmpty)
            #expect(node.properties.first?.label == "Name")
        }
    }

    @Test func instanceProperties() {
        let rows = ExplorerNode.instance(windowsVM).properties
        #expect(rows.contains(PropertyRow("Operating system", "Windows")))
        #expect(rows.contains(PropertyRow("Status", "Stopped")))
        #expect(rows.contains(PropertyRow("Resource", "projects/p/zones/z/instances/adsrv")))
    }
}

@Suite("Menú contextual")
struct ContextMenuTests {
    @Test func instanceMenuMatchesSpec() {
        let titles = ExplorerContextMenu.entries(for: .instance(linuxVM)).compactMap { entry -> String? in
            if case .command(let command) = entry { return command.title }
            return nil
        }
        #expect(titles == ["Connect", "Connect as user…", "Connection settings…", "Refresh project", "Properties"])
    }

    @Test func connectionCommandsDisabledWithMilestone() {
        #expect(ExplorerCommand.connect.milestone == "M1")
        #expect(ExplorerCommand.connectAsUser.milestone == "M2")
        #expect(ExplorerCommand.connectionSettings.milestone == "M2")
        #expect(!ExplorerCommand.connect.isAvailable)
        #expect(ExplorerCommand.refreshProject.isAvailable)
        #expect(ExplorerCommand.properties.isAvailable)
    }

    @Test func nonInstanceNodesHaveNoConnect() {
        for node in [ExplorerNode.project(ProjectInfo(name: "p")), .cloud(projectCount: 0, instanceCount: 0)] {
            #expect(!ExplorerContextMenu.entries(for: node).contains(.command(.connect)))
            #expect(ExplorerContextMenu.entries(for: node).contains(.command(.properties)))
        }
    }

    @MainActor @Test func menuItemsEnabledState() {
        let items = ExplorerWindowController.contextMenuItems(for: .instance(linuxVM), target: nil)
        let byTitle = Dictionary(uniqueKeysWithValues: items.filter { !$0.isSeparatorItem }.map { ($0.title, $0) })
        #expect(byTitle["Connect"]?.isEnabled == false)
        #expect(byTitle["Connect"]?.badge?.stringValue == "M1")
        #expect(byTitle["Connect as user…"]?.isEnabled == false)
        #expect(byTitle["Refresh project"]?.isEnabled == true)
        #expect(byTitle["Properties"]?.isEnabled == true)
    }
}

@Suite("Status bar")
@MainActor
struct StatusSummaryTests {
    @Test func countsAndPlurals() {
        let vm = ExplorerViewModel(projects: sample())
        #expect(vm.statusSummary(source: "MOCK") == "MOCK — 2 proyectos, 3 instancias")
        vm.filterText = "web"
        #expect(vm.statusSummary(source: "MOCK") == "MOCK — 2 proyectos, 3 instancias (1 visible)")
    }

    @Test func singular() {
        let vm = ExplorerViewModel(projects: [sample()[1]])
        #expect(vm.statusSummary(source: "MOCK") == "MOCK — 1 proyecto, 1 instancia")
    }
}

@Suite("Ventana Explorer (smoke AppKit)")
@MainActor
struct ExplorerWindowSmokeTests {
    @Test func selectingInstanceFillsProperties() {
        let controller = ExplorerWindowController(viewModel: ExplorerViewModel(projects: sample()))
        #expect(controller.propertiesPane.rows.isEmpty)
        #expect(controller.selectNode(id: ExplorerNode.instance(linuxVM).id))
        #expect(controller.propertiesPane.rows.contains(PropertyRow("Name", "web-01")))
        #expect(controller.selectNode(id: "cloud"))
        #expect(controller.propertiesPane.rows.contains(PropertyRow("Instances", "3")))
    }

    @Test func selectionSurvivesFilterAndClearsWhenHidden() {
        let vm = ExplorerViewModel(projects: sample())
        let controller = ExplorerWindowController(viewModel: vm)
        controller.selectNode(id: ExplorerNode.instance(linuxVM).id)
        vm.filterText = "web"
        #expect(controller.selectedNode?.id == ExplorerNode.instance(linuxVM).id)
        vm.filterText = "db"
        #expect(controller.selectedNode == nil)
        #expect(vm.selection == nil)
    }

    @Test func statusBarAndEmptyState() {
        let controller = ExplorerWindowController(viewModel: ExplorerViewModel(projects: sample()))
        #expect(controller.statusBar.summary == "MOCK — 2 proyectos, 3 instancias")
        #expect(controller.accountText == "Sin sesión")  // ya no es el texto fijo del mock
        #expect(controller.sessionArea.isShowingEmptyState)
        controller.sessionArea.openSession(identifier: "s1", title: "web-01", content: NSView())
        #expect(!controller.sessionArea.isShowingEmptyState)
        controller.sessionArea.closeSession(identifier: "s1")
        #expect(controller.sessionArea.isShowingEmptyState)
    }

    @Test func toolbarHasExpectedItems() throws {
        let controller = ExplorerWindowController(viewModel: ExplorerViewModel(projects: sample()))
        let toolbar = try #require(controller.window?.toolbar)
        let labels = toolbar.items.map(\.label).filter { !$0.isEmpty }
        #expect(labels == ["Add project", "Refresh", "Settings"])
    }
}

// CBU-44: Connect por SSH habilitado solo para Linux cuando la App lo cablea.
@Suite("Connect SSH (CBU-44)")
@MainActor
struct SshConnectMenuTests {
    private let linux = InstanceInfo(project: "p", zone: "z", name: "web-01", os: .linux, status: .running)
    private let windows = InstanceInfo(project: "p", zone: "z", name: "ad-01", os: .windows, status: .running)

    private func connectItem(_ node: ExplorerNode, available: Bool) -> NSMenuItem? {
        ExplorerWindowController.contextMenuItems(for: node, target: nil, sshConnectAvailable: available)
            .first { $0.title == "Connect" }
    }

    @Test func linuxConnectEnabledWhenWired() {
        let item = connectItem(.instance(linux), available: true)
        #expect(item?.isEnabled == true)
        #expect(item?.badge == nil)
    }

    @Test func windowsStaysMilestoneEvenWhenWired() {
        let item = connectItem(.instance(windows), available: true)
        #expect(item?.isEnabled == false)
        #expect(item?.badge?.stringValue == "M1")
    }

    @Test func withoutHandlerConnectStaysDisabled() {
        #expect(connectItem(.instance(linux), available: false)?.isEnabled == false)
    }
}
