import AgentCore
import Foundation
import XCTest
@testable import AgentDoctor

final class ProcessExplanationTests: XCTestCase {
    func process(_ pid: Int32, parent: Int32, executable: String = "/usr/bin/fixture", uid: UInt32 = 501) -> AgentProcess {
        var p = AgentProcess(pid:pid,ppid:parent,uid:uid,name:"fixture",executable:executable,argv:[executable],cwd:"/fixture/project")
        p.sampledIdentity = .init(pid:pid,uid:uid,started:Date(timeIntervalSince1970:10000+Double(pid)),executable:executable)
        return p
    }
    func inspect(_ processes: [AgentProcess], depth: Int = 32, paths: OpenFiles.Observation = .init(paths:[],complete:true)) throws -> ProcessExplanation {
        let byPID = Dictionary(uniqueKeysWithValues:processes.map { ($0.pid,$0) })
        return try ProcessExplanation.capture(processes[0].pid,table:.init(entries:processes),identity:{ byPID[$0]?.sampledIdentity },parent:{ byPID[$0]?.ppid },paths:{ _ in paths },uid:501,maximumDepth:depth)
    }
    func testDirectBundleLocationAndCredentialMasking() throws {
        var target = process(10,parent:1,executable:"/Applications/Example.app/Contents/MacOS/Example")
        target.argv += ["--api-key","fixture-sensitive-value"]
        var root = process(1,parent:0,executable:"/sbin/launchd",uid:0);root.argv = ["private-root-argument"]
        let report = try inspect([target,root])
        XCTAssertEqual(report.attribution,.executableLocation);XCTAssertEqual(report.application,"/Applications/Example.app")
        XCTAssertTrue(report.chainComplete);XCTAssertEqual(report.chain[0].args.last,"••••")
        XCTAssertTrue(report.chain[1].args.isEmpty);XCTAssertNil(report.chain[1].workingDirectory)
        XCTAssertFalse(String(decoding:try JSONEncoder().encode(report),as:UTF8.self).contains("fixture-sensitive-value"))
    }
    func testAncestorIsEvidenceEvenWhenTheHigherChainIsUnavailable() throws {
        let child = process(10,parent:20)
        let app = process(20,parent:1,executable:"/Applications/Editor.app/Contents/MacOS/Editor")
        let report = try inspect([child,app])
        XCTAssertEqual(report.attribution,.ancestorApplication);XCTAssertEqual(report.application,"/Applications/Editor.app")
        XCTAssertFalse(report.chainComplete);XCTAssertFalse(report.issues.isEmpty)
    }
    func testReusedTargetAndWrongReviewedIdentityAreRefused() throws {
        let p = process(10,parent:0);var changed = p.sampledIdentity!;changed.started.addTimeInterval(1)
        XCTAssertThrowsError(try ProcessExplanation.capture(10,expected:changed,table:.init(entries:[p]),identity:{ _ in p.sampledIdentity },parent:{ _ in 0 },paths:{ _ in .init(paths:[],complete:true) },uid:501))
        XCTAssertThrowsError(try ProcessExplanation.capture(10,table:.init(entries:[p]),identity:{ _ in changed },parent:{ _ in 0 },paths:{ _ in .init(paths:[],complete:true) },uid:501))
    }
    func testReusedParentCannotBecomeAnApplicationAttribution() throws {
        let child = process(10,parent:20), app = process(20,parent:0,executable:"/Applications/Old.app/Contents/MacOS/Old")
        var changed = app.sampledIdentity!;changed.started.addTimeInterval(1)
        let report = try ProcessExplanation.capture(10,table:.init(entries:[child,app]),identity:{ $0==10 ? child.sampledIdentity : changed },parent:{ $0==10 ? 20 : 0 },paths:{ _ in .init(paths:[],complete:true) },uid:501)
        XCTAssertEqual(report.chain.map(\.pid),[10]);XCTAssertNil(report.application);XCTAssertEqual(report.attribution,.unknown)
    }
    func testReparentingDuringInspectionInvalidatesTheWholeRelationship() throws {
        let child = process(10,parent:20), app = process(20,parent:0)
        XCTAssertThrowsError(try ProcessExplanation.capture(10,table:.init(entries:[child,app]),identity:{ $0==10 ? child.sampledIdentity : app.sampledIdentity },parent:{ _ in 0 },paths:{ _ in .init(paths:[],complete:true) },uid:501))
    }
    func testCycleAndDepthAreBounded() throws {
        let p = process(10,parent:20), q = process(20,parent:10)
        let cyclic = try inspect([p,q]);XCTAssertEqual(cyclic.chain.count,2);XCTAssertFalse(cyclic.chainComplete)
        XCTAssertTrue(cyclic.issues.contains { $0.contains("cycle") })
        let limited = try inspect([p,q],depth:1);XCTAssertEqual(limited.chain.count,1);XCTAssertTrue(limited.issues.contains { $0.contains("depth") })
    }
    func testUnavailableAndArgvFallbackTargetsDoNotLookVerified() throws {
        var p = process(10,parent:0);p.executableFromArgv = true
        XCTAssertThrowsError(try inspect([p]))
        XCTAssertThrowsError(try ProcessExplanation.capture(10,table:.init(entries:[p],available:false),identity:{ _ in p.sampledIdentity },parent:{ _ in 0 },paths:{ _ in .init(paths:[],complete:true) },uid:501))
    }
    func testOtherUsersHaveNoArgumentsWorkingDirectoryOrPathInspection() throws {
        let p = process(10,parent:0,uid:900)
        let report = try ProcessExplanation.capture(10,table:.init(entries:[p]),identity:{ _ in p.sampledIdentity },parent:{ _ in 0 },paths:{ _ in XCTFail("do not inspect other users' descriptors");return .init(paths:[],complete:true) },uid:501)
        XCTAssertTrue(report.chain[0].args.isEmpty);XCTAssertNil(report.chain[0].workingDirectory);XCTAssertNil(report.observedPaths)
        XCTAssertFalse(report.pathQueriesComplete)
    }
    func testPathAndArgumentBudgetsRemainExplicitlyIncomplete() throws {
        var p = process(10,parent:0);p.argv = Array(repeating:String(repeating:"x",count:3000),count:70)
        let report = try inspect([p],paths:.init(paths:(0..<130).map { "/fixture/\($0)" },complete:true))
        XCTAssertEqual(report.chain[0].args.count,64);XCTAssertEqual(report.chain[0].args[0].count,2048)
        XCTAssertEqual(report.observedPaths?.count,100);XCTAssertFalse(report.pathQueriesComplete);XCTAssertTrue(report.pathsTruncated)
        XCTAssertTrue(report.issues.contains { $0.contains("shortened") })
    }
}

extension ProcessExplanationTests {
    func testTerminalControlCharactersAreRenderedAsData() throws {
        var p=process(10,parent:0);p.name="fixture\u{1b}]52;c;payload\u{7}";p.cwd="/fixture/\npath"
        let report=try inspect([p],paths:.init(paths:["/fixture/\u{1b}path"],complete:true))
        XCTAssertFalse(report.chain[0].name.contains("\u{1b}"));XCTAssertTrue(report.chain[0].name.contains("\\u{1B}"))
        XCTAssertFalse(report.chain[0].workingDirectory?.contains("\n") == true)
        XCTAssertFalse(report.observedPaths?.first?.contains("\u{1b}") == true)
    }
}

extension ProcessExplanationTests {
    func testListenerReadCannotPublishAfterTargetPIDReuse() throws {
        let p=process(10,parent:0);var actual=p.sampledIdentity!
        XCTAssertThrowsError(try ProcessExplanation.capture(10,table:.init(entries:[p]),identity:{ _ in actual },parent:{ _ in 0 },paths:{ _ in .init(paths:[],complete:true) },uid:501,listeners:{ _ in
            actual.started.addTimeInterval(1)
            return .init(state:.noneObserved,endpoints:[],queryComplete:true,limited:false)
        }))
    }
    func testListenerReaderDoesNotInspectAnotherUser() throws {
        let p=process(10,parent:0,uid:900)
        let report=try ProcessExplanation.capture(10,table:.init(entries:[p]),identity:{ _ in p.sampledIdentity },parent:{ _ in 0 },paths:{ _ in .init(paths:[],complete:true) },uid:501,listeners:{ _ in
            XCTFail("do not read another user's listeners");return nil
        })
        XCTAssertNil(report.listeners)
    }
}

extension ProcessExplanationTests {
    func testPowerAssertionReadCannotPublishAfterPIDReuse() throws {
        let p=process(10,parent:0);var actual=p.sampledIdentity!
        XCTAssertThrowsError(try ProcessExplanation.capture(10,table:.init(entries:[p]),identity:{ _ in actual },parent:{ _ in 0 },paths:{ _ in .init(paths:[],complete:true) },uid:501,sleepAssertions:{ _ in
            actual.started.addTimeInterval(1);return .init(state:.noneObserved,assertions:[],queryComplete:true,limited:false)
        }))
    }
    func testPowerAssertionReaderDoesNotInspectOtherUsers() throws {
        let p=process(10,parent:0,uid:900)
        let report=try ProcessExplanation.capture(10,table:.init(entries:[p]),identity:{ _ in p.sampledIdentity },parent:{ _ in 0 },paths:{ _ in .init(paths:[],complete:true) },uid:501,sleepAssertions:{ _ in
            XCTFail("do not inspect another user's power assertions");return nil
        })
        XCTAssertNil(report.sleepAssertions)
    }
}
