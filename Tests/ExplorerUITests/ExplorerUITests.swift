// ExplorerUI tests: filtrado con la semántica del original (REQ-EXP-4).
import Testing
@testable import ExplorerUI

private func sample() -> [ProjectInfo] {
    [ProjectInfo(name: "p", zones: [
        ZoneInfo(project: "p", name: "z", instances: [
            InstanceInfo(project: "p", zone: "z", name: "web-01", os: .linux, status: .running),
            InstanceInfo(project: "p", zone: "z", name: "WEB-02", os: .linux, status: .stopped),
            InstanceInfo(project: "p", zone: "z", name: "adsrv", os: .windows, status: .running),
        ])
    ])]
}

@Suite("Explorer filtering")
struct ExplorerFilteringTests {
    @Test func textFilterIsCaseInsensitive() {
        let vm = ExplorerViewModel(projects: sample())
        vm.filterText = "web"
        let names = vm.filteredProjects.flatMap { $0.zones }.flatMap { $0.instances }.map { $0.name }
        #expect(names.sorted() == ["WEB-02", "web-01"])
    }

    @Test func osTogglesHideZones() {
        let vm = ExplorerViewModel(projects: sample())
        vm.showWindows = false
        #expect(vm.filteredProjects[0].zones[0].instances.count == 2)
        vm.showLinux = false
        #expect(vm.filteredProjects.isEmpty)  // zona sin instancias visibles desaparece
    }

    @Test func emptyFilterShowsAll() {
        let vm = ExplorerViewModel(projects: sample())
        #expect(vm.filteredProjects[0].zones[0].instances.count == 3)
    }
}
