// GH-65: panel de resultados del diagnóstico (filas, acciones correctivas, re-ejecución).
import AppKit
import GCPClient
import Testing
@testable import ExplorerUI

private let target = DiagnosticsTarget.ssh(project: "p", zone: "z", instance: "vm-1")
private let firewallHelp = DiagnosticHelp(
    title: DiagnosticHelp.createFirewallRule.title, url: DiagnosticHelp.createFirewallRule.url,
    command: "gcloud compute firewall-rules create allow-ingress-from-iap-22 --project=p")

private func report(_ results: [DiagnosticStepResult]) -> DiagnosticsReport {
    DiagnosticsReport(
        target: target,
        steps: zip(DiagnosticStepKind.allCases, results).map { DiagnosticsStep(kind: $0, result: $1) },
        startedAt: Date(), finishedAt: Date())
}

private let mixed = report([
    .passed(info: "iap.tunnelInstances.accessViaIAP y compute.instances.get concedidos."),
    .failed(reason: .noMatchingFirewallRule(expectedRange: "35.235.240.0/20", port: 22), help: firewallHelp),
    .failed(reason: .authRejected, help: .grantAccess),
])

@Suite("Panel de diagnóstico (GH-65)")
@MainActor
struct DiagnosticsPanelTests {
    @Test func rowsCarryStatusMessageAndHelp() {
        let rows = DiagnosticsRowModel.rows(for: mixed)
        #expect(rows.map(\.title) == ["Permisos IAM", "Regla de firewall para IAP", "Conexión WebSocket con IAP"])
        #expect(rows.map(\.status) == [.passed, .failed, .failed])
        #expect(rows[1].detail == "Ninguna regla de firewall permite 35.235.240.0/20 → tcp:22 hacia esta instancia.")
        #expect(rows[1].help == firewallHelp)
        #expect(rows[0].help == nil)
        #expect(DiagnosticsRowModel.summary(for: mixed) == "2 problema(s) encontrado(s).")
        #expect(DiagnosticsRowModel.summary(for: report([.passed(info: nil), .passed(info: nil), .passed(info: nil)])) == "Conectividad IAP correcta.")
        #expect(DiagnosticsRowModel.summary(for: report([.passed(info: nil), .skipped(because: "x"), .passed(info: nil)])) == "Diagnóstico incompleto.")
    }

    @Test func correctiveActionsOpenDocsAndCopyCommand() {
        let panel = DiagnosticsPanelView()
        var opened: [URL] = []
        var copied: [String] = []
        panel.openURL = { opened.append($0) }
        panel.copyText = { copied.append($0) }
        panel.show(mixed)

        #expect(panel.rowsStack.arrangedSubviews.count == 3)
        #expect(panel.helpButtons.map(\.title) == [firewallHelp.title, DiagnosticHelp.grantAccess.title])
        #expect(panel.copyButtons.count == 1)  // solo el paso con comando
        panel.helpButtons[1].performClick(nil)
        panel.helpButtons[0].performClick(nil)
        #expect(opened == [DiagnosticHelp.grantAccess.url, firewallHelp.url])
        panel.copyButtons[0].performClick(nil)
        #expect(copied == [firewallHelp.command!])
    }

    @Test func runningStateThenRerun() {
        let panel = DiagnosticsPanelView()
        #expect(panel.summaryLabel.stringValue == "Ejecutando diagnóstico…")
        #expect(panel.rows.map(\.status) == [.running, .running, .running])
        #expect(!panel.rerunButton.isEnabled)
        var reruns = 0
        panel.onRerun = { reruns += 1 }
        panel.show(mixed)
        #expect(panel.rerunButton.isEnabled)
        panel.rerunButton.performClick(nil)
        #expect(reruns == 1)
        #expect(panel.summaryLabel.stringValue == "2 problema(s) encontrado(s).")
    }

    @Test func windowRunsOnceAtATimeAndShowsReport() async {
        var runs = 0
        let controller = DiagnosticsWindowController(instanceName: "vm-1") {
            runs += 1
            try? await Task.sleep(for: .milliseconds(20))
            return mixed
        }
        controller.start()
        controller.start()  // pulsación repetida durante la ejecución: ignorada
        await controller.waitForRun()
        #expect(runs == 1)
        #expect(controller.lastReport == mixed)
        #expect(controller.panel.rows.map(\.status) == [.passed, .failed, .failed])
        #expect(controller.window?.title == "Diagnóstico de conexión — vm-1")
        controller.start()
        await controller.waitForRun()
        #expect(runs == 2)
        controller.close()
    }

    @Test func layoutIsUnambiguous() {
        let panel = DiagnosticsPanelView()
        panel.show(mixed)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        window.layoutIfNeeded()
        #expect(!panel.hasAmbiguousLayout)
        window.close()
    }
}
