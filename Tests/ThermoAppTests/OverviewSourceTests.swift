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

    func testProgramsInOneProjectByOneAgentAreNamedAsOneSource() {
        let p = pulse([hog("swift-build", cpu: 120, project: "~/github.com/thermo", owner: "Claude Code"),
                       hog("swift-test", cpu: 60, project: "~/github.com/thermo", owner: "Claude Code"),
                       hog("node", cpu: 70, project: "~/www/shop", owner: "Codex")])
        L10n.override = .english
        XCTAssertEqual(OverviewPage.sourceText(p), "Mostly the thermo project, started by Claude Code: swift-build, swift-test, using 1.8 cores")
        L10n.override = .simplifiedChinese
        XCTAssertEqual(OverviewPage.sourceText(p), "主要来自 thermo 项目（Claude Code 启动）：swift-build, swift-test，共占用 1.8 核")
    }

    func testWithoutAnOwnerTheProjectAloneIsNamed() {
        L10n.override = .english
        let p = pulse([hog("cargo", cpu: 200, project: "~/code/engine")])
        XCTAssertEqual(OverviewPage.sourceText(p), "Mostly the engine project: cargo, using 2.0 cores")
    }

    func testAppsAndSmallSharesFallBackToTheCulpritSentence() {
        XCTAssertNil(OverviewPage.sourceText(pulse([hog("Google Chrome", cpu: 300, project: "~", app: "/Applications/Google Chrome.app")])))
        // 60% of one core is not the reason for a load of 40.
        XCTAssertNil(OverviewPage.sourceText(pulse([hog("swift-build", cpu: 60, project: "~/p", owner: "Claude Code")], load: 40)))
        XCTAssertNil(OverviewPage.sourceText(pulse([hog("swift-build", cpu: 40, project: "~/p", owner: "Claude Code")], load: 0.5)))
    }
}
