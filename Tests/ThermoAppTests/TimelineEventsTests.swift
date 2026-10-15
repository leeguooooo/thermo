import XCTest
import AgentCore
import ThermoL10n
@testable import CleanKit
@testable import ThermoApp

@MainActor
final class TimelineEventsTests: XCTestCase {
    override func tearDown() { L10n.override = nil }

    func hog(_ name: String, cpu: Double, project: String? = nil, owner: String? = nil) -> MachinePulse.Hog {
        MachinePulse.Hog(id: name + "|" + (project ?? ""), name: name, cpu: cpu, memoryKB: 1, pids: [1], app: nil, quittable: false,
                         project: project, owner: owner)
    }
    func pulse(_ hogs: [MachinePulse.Hog]) -> MachinePulse {
        MachinePulse(load1: 4, load5: 4, cores: 8, thermal: .nominal, memory: .normal, swapUsedMB: 0, hogs: hogs, sampled: Date())
    }

    func testBusyAndCalmUseHysteresisAndNameTheSource() {
        L10n.override = .english
        let events = TimelineEvents()
        let t0 = Date()
        events.observe(pulse([hog("swift-build", cpu: 350, project: "~/github.com/thermo", owner: "Claude Code")]), now: t0)
        XCTAssertEqual(events.events.map(\.text), ["swift-build (thermo · Claude Code) became busy"])
        // Between the thresholds: neither busy again nor calm.
        events.observe(pulse([hog("swift-build", cpu: 50, project: "~/github.com/thermo", owner: "Claude Code")]), now: t0.addingTimeInterval(30))
        XCTAssertEqual(events.events.count, 1)
        events.observe(pulse([]), now: t0.addingTimeInterval(180))
        XCTAssertEqual(events.events.last?.kind, .calm)
        XCTAssertEqual(events.events.last?.text, "swift-build calmed down after 3 min")
    }

    func testOperationsComeFromTheJournalWithinTheWindowOnly() {
        L10n.override = .english
        let events = TimelineEvents()
        let now = Date()
        let recent = OperationRecord(time: now.addingTimeInterval(-60), feature: "pulse", action: "quit", subject: "Google Chrome",
                                     items: [.init(target: "Google Chrome", status: "done")])
        let old = OperationRecord(time: now.addingTimeInterval(-3600), feature: "clean", action: "trash", items: [.init(target: "/a", status: "done")])
        events.refreshJournal(now: now, read: { [recent, old] })
        XCTAssertEqual(events.events.map(\.text), ["Stopped a program · Google Chrome"])
        // Throttled: a second read within 30 s is skipped.
        events.refreshJournal(now: now.addingTimeInterval(5), read: { [] })
        XCTAssertEqual(events.events.count, 1)
    }
}
