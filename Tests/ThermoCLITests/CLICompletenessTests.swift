import XCTest
import CleanKit
import AgentCore
@testable import thermo
@testable import AgentDoctor

final class CLICompletenessTests: XCTestCase {
    func testClosePreviewNeverInvokesMutationEvenWithYes() throws {
        let command = PulseCommand(app: App(args: try Args(["pulse","chrome","close","https://example.test","--dry-run","--yes","--json"])))
        let tab = ChromeInspector.Tab(window: 1, index: 1, url: "https://example.test", title: "Fixture")
        var closed = false, output = ""
        try command.closeTab([tab.url], browser: "Fixture", tabs: { _ in [tab] }, close: { tabs, _ in closed = true; return tabs.map { .init(id:$0.selectionID,status:.closed) } }, write: { output = $0 })
        XCTAssertFalse(closed)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String:Any])
        XCTAssertEqual(value["dryRun"] as? Bool, true)
        XCTAssertEqual(value["outcome"] as? String, "planned")
    }
    func testCloseJSONHasNoHumanOutputAndUnconfirmedFails() throws {
        let command = PulseCommand(app: App(args: try Args(["pulse","chrome","close","https://example.test","--yes","--json"])))
        let tab = ChromeInspector.Tab(window: 1, index: 1, url: "https://example.test", title: "Fixture")
        var output: [String] = []
        XCTAssertThrowsError(try command.closeTab([tab.url], browser: "Fixture", tabs: { _ in [tab] }, close: { tabs, _ in tabs.map { .init(id:$0.selectionID,status:.failed) } }, write: { output.append($0) }))
        XCTAssertEqual(output.count, 1)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output[0].utf8)) as? [String:Any])
        XCTAssertEqual(value["outcome"] as? String, "unconfirmed")
    }
    func testCloseRejectsExtraArgumentsBeforeReadingBrowser() throws {
        let command = PulseCommand(app: App(args: try Args([])))
        XCTAssertThrowsError(try command.closeTab(["https://example.test","extra"], browser: "Fixture", tabs: { _ in XCTFail("must validate first"); return [] }))
    }
    func testScopedHelpAndCapabilityInventory() {
        let help = CommandHelp.text(for: ["clean","run"])
        XCTAssertTrue(help.contains("thermo clean run"))
        XCTAssertFalse(help.contains("temperatures, fans and power"))
        XCTAssertTrue(CommandHelp.text(for: ["agents","compare"]).contains("compare FILE"))
        XCTAssertEqual(Set(CommandHelp.capabilities.map(\.command)).count, CommandHelp.capabilities.count)
        for family in ["privacy","claude-reset","screen","app-control","permissions","integration"] {
            XCTAssertTrue(CommandHelp.capabilities.contains { $0.command == family || $0.command.hasPrefix(family + " ") })
        }
    }
    func testUnsupportedPreviewAndConflictingFormatsAreRejected() throws {
        XCTAssertThrowsError(try CommandContract.validate(Args(["agents","inspect","fixture","--dry-run"])))
        XCTAssertThrowsError(try CommandContract.validate(Args(["temps","--json","--csv"])))
        XCTAssertThrowsError(try CommandContract.validate(Args(["pulse","quit","fixture","--csv"])))
        XCTAssertNoThrow(try CommandContract.validate(Args(["pulse","chrome","close","https://example.test","--dry-run"])))
    }
    func testAppControlRequestValidationPrecedesDelivery() throws {
        XCTAssertThrowsError(try AppControlCommand.operation(command: "screen", rest: ["start"], args: Args(["--duration","0"])))
        XCTAssertThrowsError(try AppControlCommand.operation(command: "app-control", rest: ["login","invalid"], args: Args([])))
        XCTAssertThrowsError(try AppControlCommand.operation(command: "screen", rest: ["shortcut"], args: Args([])))
        let op = try AppControlCommand.operation(command: "screen", rest: ["start"], args: Args(["--duration","oneMinute"]))
        XCTAssertEqual(op.action, "screen.start"); XCTAssertTrue(op.mutates)
    }
    func testFrozenPlanIsPrivateOneShotAndExpires() throws {
        let home = "/private/tmp/thermo-plan-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let item = CleanItem(id: "fixture", category: .devCaches, title: "Fixture", safety: .safe, bytes: 10, paths: [home + "/cache"])
        let report = ScanReport(items: [item], denied: [], started: Date(), duration: 1)
        let store = CleanPlanStore(home: home)
        let plan = try store.save(report: report, selectors: [item.id], items: [item], mode: .permanent)
        XCTAssertEqual(try store.load(plan.id.uuidString, consume: false).items.first?.paths, item.paths)
        XCTAssertThrowsError(try store.load(plan.id.uuidString, consume: false, now: plan.expires))
        XCTAssertNoThrow(try store.load(plan.id.uuidString, consume: true))
        XCTAssertThrowsError(try store.load(plan.id.uuidString, consume: true))
    }
    func testFrozenPlanRejectsSymlinkAncestor() throws {
        let home = "/private/tmp/thermo-plan-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createSymbolicLink(atPath: home + "/Library", withDestinationPath: "/private/tmp")
        let report = ScanReport(items: [], denied: [], started: Date(), duration: 1)
        let item = CleanItem(id: "fixture", category: .devCaches, title: "Fixture", safety: .safe, bytes: 10)
        XCTAssertThrowsError(try CleanPlanStore(home: home).save(report: report, selectors: ["fixture"], items: [item], mode: .auto))
    }
}

extension CLICompletenessTests {
    func testSubcommandRejectsFlagsItWouldOtherwiseIgnore() throws {
        XCTAssertThrowsError(try CommandContract.validate(Args(["pulse","chrome","close","https://example.test","--budget","1"])))
        XCTAssertThrowsError(try AppControlCommand.operation(command:"screen", rest:["stop"], args:Args(["--duration","manual"])))
        XCTAssertNoThrow(try CommandContract.validate(Args(["agents","inspect-all","--budget","30","--dry-run","--json"])))
    }
    func testBlockedCleanupReportsRefusalAndNonzeroCompletion() throws {
        let item = CleanItem(id:"fixture", category:.xcode, title:"Fixture", safety:.review, bytes:100, commands:[["/usr/bin/true"]])
        let report = ScanReport(items:[item],denied:[],started:Date(),duration:1)
        let command = CleanCommand(app:App(args:try Args(["--yes","--json"])))
        var output = ""
        XCTAssertThrowsError(try command.execute(report:report,picked:[item],mode:.trash,write:{ output = $0 })) { error in
            XCTAssertEqual((error as? CLIError)?.exitCode,3)
        }
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(output.utf8)) as? [String:Any])
        XCTAssertEqual(value["complete"] as? Bool,false)
        XCTAssertEqual(value["outcome"] as? String,"refused")
        XCTAssertEqual((value["skipped"] as? [Any])?.count,1)
    }
}

extension CLICompletenessTests {
    func testWhitelistPreviewDoesNotWriteConfiguration() throws {
        let home = "/private/tmp/thermo-white-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath:home,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(atPath:home) }
        let paths = try Whitelist.previewChange([home + "/cache"],adding:true,home:home)
        XCTAssertEqual(paths,[home + "/cache"])
        XCTAssertFalse(FileManager.default.fileExists(atPath:home + "/Library/Application Support/Thermo/whitelist"))
    }
}

extension CLICompletenessTests {
    func testClaudeResetCLIUsesRecoverableServiceAndPreviewIsReadOnly() throws {
        let home = "/private/tmp/thermo-reset-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath:home + "/.claude",withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(atPath:home) }
        let file = home + "/.claude/settings.json"
        let original = Data("{\"fixture\":true}".utf8)
        try original.write(to:URL(fileURLWithPath:file))
        let service = ClaudeCleanup(home:home,processes:{ ProcessTable(entries:[]) },liveSessionCheck:{ _ in false })
        try ClaudeResetCommand(app:App(args:try Args(["--dry-run","--yes","--json"]))).run(["run","settings"],service:service)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:file)),original)
        XCTAssertTrue(service.batchReport().batches.isEmpty)
        try ClaudeResetCommand(app:App(args:try Args(["--yes","--json"]))).run(["run","settings"],service:service)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file))
        let batch = try XCTUnwrap(service.batchReport().batches.first)
        let review = try service.reviewRestore(batchID:batch.id)
        XCTAssertEqual(review.ready,[.settings]); XCTAssertTrue(review.blocked.isEmpty)
        try ClaudeResetCommand(app:App(args:try Args(["--yes","--json"]))).run(["restore",batch.id],service:service)
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:file)),original)
    }
    func testPrivacyCLIPreviewDoesNotRunSystemCommandsOrCreateBackups() throws {
        let home = URL(fileURLWithPath:"/private/tmp/thermo-privacy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:home) }
        let service = PrivacyToolsService(home:home,runner:{ _,_ in XCTFail("Preview must never run commands"); return .init(status:1) })
        try PrivacyCommand(app:App(args:try Args(["--dry-run","--yes","--json"]))).run(["dns"],service:service)
        try PrivacyCommand(app:App(args:try Args(["--dry-run","--yes","--json"]))).run(["environment"],service:service)
        XCTAssertFalse(FileManager.default.fileExists(atPath:home.appendingPathComponent("Library").path))
    }
}

extension CLICompletenessTests {
    func testPlanReplacementAfterReviewCannotExpandAuthorizedScope() throws {
        let home = "/private/tmp/thermo-plan-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath:home,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(atPath:home) }
        let item = CleanItem(id:"fixture",category:.devCaches,title:"Fixture",safety:.safe,bytes:10,paths:[home + "/cache"])
        let report = ScanReport(items:[item],denied:[],started:Date(),duration:1)
        let store = CleanPlanStore(home:home)
        let reviewed = try store.save(report:report,selectors:[item.id],items:[item],mode:.permanent)
        let url = store.directory.appendingPathComponent(reviewed.id.uuidString + ".json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        var items = try XCTUnwrap(object["items"] as? [[String:Any]])
        items[0]["paths"] = [home + "/different-cache"]
        object["items"] = items
        try JSONSerialization.data(withJSONObject:object).write(to:url)
        XCTAssertThrowsError(try store.load(reviewed.id.uuidString,consume:true,expected:reviewed))
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.directory.appendingPathComponent(reviewed.id.uuidString + ".used").path))
    }
}

extension CLICompletenessTests {
    func testFreshPlanCanExplicitlyRescanWithoutWeakeningApply() throws {
        XCTAssertNoThrow(try CommandContract.validate(Args(["clean","plan","safe","--rescan","--budget","120","--json"])))
        let command = CleanCommand(app:App(args:try Args(["clean","apply","fixture","--rescan","--yes"])))
        XCTAssertThrowsError(try command.applyPlan(["fixture"]))
    }
}

extension CLICompletenessTests {
    func testAgentProjectScopeIsExplicitAndValidated() throws {
        let project = URL(fileURLWithPath:"/private/tmp/thermo-project-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:project) }
        let command = AgentsCommand(app:App(args:try Args(["agents","list","hooks","--root",project.path,"--json"])))
        XCTAssertEqual(try command.environment().project?.resolvingSymlinksInPath(),project.resolvingSymlinksInPath())
        XCTAssertThrowsError(try AgentsCommand(app:App(args:Args(["--root",project.appendingPathComponent("missing").path]))).environment())
        XCTAssertNoThrow(try CommandContract.validate(command.app.args))
    }
    func testAgentFixJSONContainsFreshPostStateAndPreviewDoesNotRunAction() throws {
        let home = URL(fileURLWithPath:"/private/tmp/thermo-fix-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:home) }
        let log = home.appendingPathComponent("fixture.log")
        try Data("fixture".utf8).write(to:log)
        let env = DoctorEnvironment(home:home,path:[],run:{ _,_ in nil })
        let action = Action(id:"fixture",kind:.fix,title:"Truncate",summary:"Fixture only",steps:[.truncate(path:log.path)],destructive:false)
        let item = AgentItem(id:"fixture",area:.processes,agent:"fixture",name:"Fixture",detail:"",source:nil,enabled:true,severity:.warning)
        var output = ""
        try AgentsCommand(app:App(args:Args(["--json","--dry-run","--yes"]))).apply([(item,action)],env:env,write:{ output = $0 })
        XCTAssertEqual(try Data(contentsOf:log),Data("fixture".utf8))
        try AgentsCommand(app:App(args:Args(["--json","--yes"]))).apply([(item,action)],env:env,write:{ output = $0 })
        XCTAssertTrue(try Data(contentsOf:log).isEmpty)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(output.utf8)) as? [String:Any])
        XCTAssertEqual(receipt["complete"] as? Bool,true)
        XCTAssertNotNil(receipt["observedAfter"] as? [String:Any])
    }
}
