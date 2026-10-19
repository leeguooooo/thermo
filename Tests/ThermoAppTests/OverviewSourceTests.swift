import XCTest
import ThermoL10n
@testable import CleanKit
@testable import ThermoApp

final class OverviewSourceTests: XCTestCase {
    override func tearDown() { L10n.override = nil }

    func hog(_ name: String, cpu: Double, project: String? = nil, owner: String? = nil, app: String? = nil) -> MachinePulse.Hog {
        MachinePulse.Hog(id: name + (project ?? ""), name: name, cpu: cpu, memoryKB: 100_000, pids: [1], app: app, quittable: false,
                         project: project, owner: owner)
    }

    func pulse(_ hogs: [MachinePulse.Hog], load: Double = 4) -> MachinePulse {
        MachinePulse(load1: load, load5: load, cores: 8, thermal: .nominal, memory: .normal, swapUsedMB: 0, hogs: hogs,
                     sampled: Date(timeIntervalSince1970: 100))
    }

    func testProgramsInOneDirectoryKeepTheirObservedAgentAndCPUContext() {
        let p = pulse([hog("swift-build", cpu: 120, project: "~/github.com/thermo", owner: "Claude Code"),
                       hog("swift-test", cpu: 60, project: "~/github.com/thermo", owner: "Claude Code"),
                       hog("node", cpu: 70, project: "~/www/shop", owner: "Codex")])
        L10n.override = .english
        let en = OverviewPage.sourceText(p)
        for value in ["thermo", "Claude Code", "swift-build", "swift-test", "1.8"] { XCTAssertTrue(en?.contains(value) == true) }
        L10n.override = .simplifiedChinese
        let zh = OverviewPage.sourceText(p)
        for value in ["thermo", "Claude Code", "swift-build", "swift-test", "1.8"] { XCTAssertTrue(zh?.contains(value) == true) }
    }

    func testWithoutAnOwnerTheProjectAloneIsNamed() {
        L10n.override = .english
        let p = pulse([hog("cargo", cpu: 200, project: "~/code/engine")])
        let text = OverviewPage.sourceText(p)
        for value in ["engine", "cargo", "2.0"] { XCTAssertTrue(text?.contains(value) == true) }
    }

    func testAppsAndLowObservedCPUDoNotProduceDirectoryContext() {
        XCTAssertNil(OverviewPage.sourceText(pulse([hog("Google Chrome", cpu: 300, project: "~", app: "/Applications/Google Chrome.app")])))
        // A current observation can be shown without claiming it caused a past load average.
        XCTAssertNotNil(OverviewPage.sourceText(pulse([hog("swift-build", cpu: 60, project: "~/p", owner: "Claude Code")], load: 40)))
        XCTAssertNil(OverviewPage.sourceText(pulse([hog("swift-build", cpu: 40, project: "~/p", owner: "Claude Code")], load: 0.5)))
    }
    func testDirectoryMetadataDoesNotOverrideMeasuredCapacityOrPressure() {
        var p = pulse([hog("builder", cpu: 200, project: "~/p", owner: "Codex")])
        XCTAssertNotNil(OverviewPage.sourceText(p))
        p.diskAvailableBytes = 900_000_000
        XCTAssertNil(OverviewPage.sourceText(p))
        p.diskAvailableBytes = nil
        p.memory = .warning
        XCTAssertNil(OverviewPage.sourceText(p))
        p.memory = .normal
        p.thermal = .serious
        XCTAssertNil(OverviewPage.sourceText(p))
    }

}
