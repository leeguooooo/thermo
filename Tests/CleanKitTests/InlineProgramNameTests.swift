import AgentCore
import XCTest
@testable import CleanKit

final class InlineProgramNameTests: XCTestCase {
    func testInlineEvaluationDisplaysTheRuntimeInsteadOfSource() {
        let examples: [[String]] = [
            ["node", "-e", "setInterval(() => {}, 1000)"],
            ["node", "--eval=process.stdin.resume()"],
            ["node", "-p", "process.version"],
            ["node", "-eprocess.stdin.resume()"],
            ["node", "-r", "/fixture/preload.js", "--input-type", "module", "--eval", "await 0"],
            ["python3", "-I", "-W", "ignore", "-c", "import time; time.sleep(10)"],
            ["python3.13", "-cprint('fixture')"],
            ["python3", "-Iuc", "import time; time.sleep(10)"],
            ["ruby", "-I", "/fixture/lib", "-e", "sleep 10"],
            ["perl", "-we", "sleep 10"],
            ["php", "-d", "memory_limit=128M", "-r", "sleep(10);"],
            ["bun", "--eval", "await 0"],
            ["tsx", "--eval", "const fixture = 1"],
            ["ts-node", "-e", "const fixture = 1"],
            ["deno", "eval", "await 0"]
        ]
        for argv in examples {
            XCTAssertEqual(MachinePulse.programName(.init(argv: argv), fallback: "fixture"), argv[0], "\(argv)")
        }
    }

    func testScriptOperandsStopRuntimeOptionParsing() {
        XCTAssertEqual(MachinePulse.programName(.init(argv: ["node", "/fixture/worker.js", "-e", "user argument"]), fallback: "node"), "worker")
        XCTAssertEqual(MachinePulse.programName(.init(argv: ["node", "--", "/fixture/worker.js", "--eval", "user argument"]), fallback: "node"), "worker")
        XCTAssertEqual(MachinePulse.programName(.init(argv: ["python3", "-m", "pytest", "-c", "pytest.ini"]), fallback: "python3"), "pytest")
        XCTAssertEqual(MachinePulse.programName(.init(argv: ["node", "/p/node_modules/vitest/dist/index.js", "-e", "fixture"]), fallback: "node"), "vitest")
        for argv in [["node", "-rfixture-eval", "/fixture/worker.js"], ["python3", "-Wignore", "/fixture/worker.py"], ["ruby", "-Ifixture-eval", "/fixture/worker.rb"]] {
            XCTAssertFalse(MachinePulse.groupKey(.init(argv: argv), fallback: argv[0]).key.contains("|inline:"))
        }
    }

    func testInlineRowsKeepDistinctInvocationsAndCorrectElsewhereTotals() throws {
        let sourceA = "setInterval(() => {}, 1000)", sourceB = "setInterval(() => {}, 2000)"
        func process(_ pid: Int32, code: String, cwd: String) -> MachinePulse.Candidate {
            .init(pid: pid, uid: getuid(), name: "node", cpu: 10, memoryKB: 1024,
                  details: .init(executable: "/fixture/node", argv: ["node", "-e", code], cwd: cwd), ppid: 1)
        }
        let rows = MachinePulse.group([
            process(10, code: sourceA, cwd: "/fixture/a"), process(11, code: sourceA, cwd: "/fixture/a"),
            process(12, code: sourceB, cwd: "/fixture/a"), process(13, code: sourceA, cwd: "/fixture/b"),
            process(14, code: sourceB, cwd: "/fixture/b")
        ], byMemory: false, me: -1, limit: nil)
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0.name == "node" && !$0.id.contains("setInterval") })
        let a = try XCTUnwrap(rows.first { $0.pids.contains(10) })
        let b = try XCTUnwrap(rows.first { $0.pids.contains(12) })
        XCTAssertEqual(a.pids.sorted(), [10, 11])
        XCTAssertEqual(a.elsewhere?.processes, 1)
        XCTAssertEqual(b.elsewhere?.processes, 1)
        XCTAssertNotEqual(a.id, b.id)
    }
}
