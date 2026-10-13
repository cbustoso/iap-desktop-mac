import Testing
import GCPClient
@testable import ExplorerUI

@Suite("Software package inventory")
struct InventoryViewTests {
    private let packages = [
        InventoryPackage(manager: "apt", name: "curl", version: "8.1", architecture: "arm64"),
        InventoryPackage(manager: "pip", name: "requests", version: "2.32", architecture: nil),
    ]

    @Test func filterMatchesNameVersionAndOriginIgnoringCase() {
        #expect(InventoryFilter.apply(packages, text: "CURL") == [packages[0]])
        #expect(InventoryFilter.apply(packages, text: "2.32") == [packages[1]])
        #expect(InventoryFilter.apply(packages, text: "PIP") == [packages[1]])
        #expect(InventoryFilter.apply(packages, text: "  ") == packages)
    }

    @Test func menuAppearsForInstanceAndZoneButNotProject() {
        let instance = InstanceInfo(
            project: "p", zone: "z", name: "vm", os: .linux, status: .running)
        let zone = ZoneInfo(project: "p", name: "z", instances: [instance])
        #expect(ExplorerContextMenu.entries(for: .instance(instance))
            .contains(.command(.softwarePackages)))
        #expect(ExplorerContextMenu.entries(for: .zone(zone))
            .contains(.command(.softwarePackages)))
        #expect(!ExplorerContextMenu.entries(for: .project(ProjectInfo(name: "p")))
            .contains(.command(.softwarePackages)))
    }
}
