import Foundation
import Testing
import GCPClient
@testable import ExplorerUI

@Suite("Event log filters")
struct EventLogTests {
    private let events = [
        InstanceAuditEvent(
            id: "1", timestamp: .distantPast, severity: "INFO",
            description: "Start instance", user: "ada@example.com"),
        InstanceAuditEvent(
            id: "2", timestamp: .distantFuture, severity: "ERROR",
            description: "Stop failed", user: "grace@example.com"),
    ]

    @Test func combinesSeverityAndCaseInsensitiveText() {
        #expect(EventLogFilter.apply(events, severity: "ERROR", text: "STOP") == [events[1]])
        #expect(EventLogFilter.apply(events, severity: "INFO", text: "grace").isEmpty)
    }

    @Test func textAlsoMatchesUserAndBlankMatchesEverything() {
        #expect(EventLogFilter.apply(events, severity: nil, text: "ADA") == [events[0]])
        #expect(EventLogFilter.apply(events, severity: nil, text: "  ") == events)
    }
}
