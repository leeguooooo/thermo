import XCTest
@testable import CleanKit

final class CheckupTests: XCTestCase {
    func culprit(_ name: String, kind: SlowdownCulprit.Kind = .idleMCP, frees: Int = 800_000) -> SlowdownCulprit {
        SlowdownCulprit(kind: kind, action: .review, name: name, launcher: "codex", project: "/Users/x/github.com/wechat-project", pids: [42], identities: nil,
                        app: nil, cpu: 92, memoryKB: frees, freesKB: frees, children: nil, elapsed: nil,
                        evidence: "38 idle copies in /Users/x/github.com/thermo", guidance: "end the 6 idle ones", command: nil, sessions: nil, score: 1)
    }

    func snapshot() -> CheckupSnapshot {
        let system = SlowdownSystem(memoryBytes: 16 << 30, swapUsed: 14 << 30, swapTotal: 16 << 30, pressure: .warning, load1: 37.1, cores: 10)
        let d = SlowdownDiagnosis(sampled: Date(), system: system, memoryStrain: .tight, cpuStrain: .exhausted, headline: "CPU overloaded",
                                  culprits: [culprit("rea MCP"), culprit("codex app-server", kind: .leakyParent, frees: 4_000_000)], also: [culprit("AI sessions", kind: .agentSessions)])
        return CheckupSnapshot(model: "Mac17,2", cpuTemperature: 79.4, gpuTemperature: 66, thermalState: "nominal",
                               fans: [.init(name: "Fan 1", rpm: 6546, max: 6546, manual: true)],
                               battery: .init(percent: 88, health: 0.97, cycles: 41, charging: false, externalPower: true),
                               diskFree: 84_000_000_000, diskTotal: 994_000_000_000, diagnosis: d, home: "/Users/x")
    }

    func testFactsCoverVitalsAndNumberTheFlaggedPrograms() {
        let f = snapshot().facts
        for needle in ["Mac: Mac17,2", "pressure warning", "load 37.1", "CPU 79 °C", "100% of max, set by hand in Thermo",
                       "health 97% of design, 41 cycles", "1. rea MCP [idleMCP]", "2. codex app-server [leakyParent]", "3. AI sessions [agentSessions]",
                       "project ~/github.com/wechat-project", "Thermo saw: 38 idle copies in ~/github.com/thermo"] {
            XCTAssertTrue(f.contains(needle), "missing \(needle) in\n\(f)")
        }
        XCTAssertFalse(f.contains("/Users/x/"))
    }

    func testParsesRealShapedAnswerAndLinksCulprits() throws {
        let raw = """
        ```json
        {"overall": "attention", "summary": "内存和 CPU 都吃紧。", "findings": [
          {"area": "thermal", "severity": "low", "title": "温度正常", "detail": "79 °C", "impact": "无影响", "safety": "safe", "how": "", "culprit": 0},
          {"area": "processes", "severity": "high", "title": "codex app-server 子进程没有回收", "detail": "92 个子进程", "impact": "当前任务会中断", "safety": "interrupts", "how": "等忙完再退出 codex", "culprit": 2},
          {"area": "memory", "severity": "medium", "title": "rea MCP 闲置副本", "impact": "不受影响", "safety": "safe", "culprit": "1"},
          {"area": "gpu", "severity": "critical", "title": "未知字段", "safety": "maybe", "culprit": 9},
          {"area": "processes", "severity": "high", "title": "  ", "culprit": 1}
        ]}
        ```
        """
        let r = try XCTUnwrap(LocalAI.parseCheckup(raw, snapshot: snapshot(), source: "x"))
        XCTAssertEqual(r.overall, .attention)
        XCTAssertEqual(r.summary, "内存和 CPU 都吃紧。")
        XCTAssertEqual(r.findings.map(\.title), ["codex app-server 子进程没有回收", "rea MCP 闲置副本", "温度正常", "未知字段"])
        XCTAssertEqual(r.findings[0].culprit?.name, "codex app-server"); XCTAssertEqual(r.findings[0].safety, .interrupts)
        XCTAssertEqual(r.findings[1].culprit?.name, "rea MCP"); XCTAssertNil(r.findings[1].how)
        XCTAssertNil(r.findings[2].culprit); XCTAssertNil(r.findings[2].how)
        let odd = r.findings[3]
        XCTAssertEqual(odd.area, .other); XCTAssertEqual(odd.severity, .low); XCTAssertEqual(odd.safety, .interrupts); XCTAssertNil(odd.culprit)
    }

    func testOverallFallsBackFromFindingsAndRejectsEmptyAnswers() {
        let s = snapshot()
        XCTAssertEqual(LocalAI.parseCheckup(#"{"findings":[{"title":"swap full","severity":"high"}]}"#, snapshot: s, source: "x")?.overall, .urgent)
        XCTAssertEqual(LocalAI.parseCheckup(#"{"summary":"All fine."}"#, snapshot: s, source: "x")?.overall, .good)
        XCTAssertNil(LocalAI.parseCheckup("I cannot help with that.", snapshot: s, source: "x"))
        XCTAssertNil(LocalAI.parseCheckup(#"{"summary":"","findings":[]}"#, snapshot: s, source: "x"))
    }
}
