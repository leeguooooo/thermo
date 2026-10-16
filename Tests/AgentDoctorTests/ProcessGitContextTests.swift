import AgentCore
import Darwin
import Foundation
import XCTest
@testable import AgentDoctor

final class ProcessGitContextTests: XCTestCase {
    let fm=FileManager.default
    func fixture() throws -> URL {
        let root=fm.temporaryDirectory.appendingPathComponent("thermo-process-git-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) };return root
    }
    @discardableResult func git(_ root: URL,_ args: [String]) throws -> String {
        let result=CommandRunner.run("/usr/bin/git",arguments:["-c","core.hooksPath=/dev/null","-c","commit.gpgSign=false","-C",root.path]+args,
            environment:["PATH":"/usr/bin:/bin","HOME":root.path,"GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_GLOBAL":"/dev/null"],timeout:5,outputLimit:16384)
        guard result.status == 0,!result.timedOut,!result.truncated else { throw NSError(domain:result.output,code:Int(result.status)) }
        return result.output.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    func repo() throws -> URL {
        let root=try fixture();try git(root,["init","--initial-branch=main"])
        try git(root,["-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","--allow-empty","-m","fixture"])
        return root
    }
    func write(_ value: String,_ file: URL) throws { try value.write(to:file,atomically:false,encoding:.utf8) }

    func testRealRepositoryFromNestedCwdMatchesGitHead() throws {
        let root=try repo(),nested=root.appendingPathComponent("src/deep")
        try fm.createDirectory(at:nested,withIntermediateDirectories:true)
        let result=ProcessGitContext.capture(workingDirectory:nested.path)
        XCTAssertEqual(result.state,.observed);XCTAssertEqual(result.branch,"main");XCTAssertEqual(result.detached,false)
        XCTAssertEqual(result.commit,try git(root,["rev-parse","HEAD"]))
        XCTAssertEqual(result.root,try git(root,["rev-parse","--show-toplevel"]));XCTAssertTrue(result.queryComplete)
    }
    func testRealLinkedWorktreeReadsItsHeadAndCommonPackedRef() throws {
        let root=try repo(),worktree=root.appendingPathComponent("linked")
        try git(root,["worktree","add","-b","feature/test",worktree.path,"HEAD"]);try git(root,["pack-refs","--all"])
        let result=ProcessGitContext.capture(workingDirectory:worktree.path)
        XCTAssertEqual(result.state,.observed);XCTAssertEqual(result.branch,"feature/test")
        XCTAssertEqual(result.commit,try git(worktree,["rev-parse","HEAD"]))
        XCTAssertEqual(result.gitDirectory,try git(worktree,["rev-parse","--absolute-git-dir"]))
        XCTAssertTrue(result.queryComplete)
    }
    func testRealDetachedHeadIsNotPresentedAsBranch() throws {
        let root=try repo();try git(root,["checkout","--detach","HEAD"])
        let result=ProcessGitContext.capture(workingDirectory:root.path)
        XCTAssertTrue(result.queryComplete);XCTAssertTrue(result.detached == true);XCTAssertNil(result.branch)
        XCTAssertEqual(result.commit,try git(root,["rev-parse","HEAD"]))
    }
    func testUnbornAndUnsupportedRefsKeepCommitUnknown() throws {
        let root=try fixture();try git(root,["init","--initial-branch=main"])
        let result=ProcessGitContext.capture(workingDirectory:root.path)
        XCTAssertEqual(result.state,.observed);XCTAssertEqual(result.branch,"main")
        XCTAssertNil(result.commit);XCTAssertFalse(result.queryComplete)
        try write("ref: refs/custom/name\n",root.appendingPathComponent(".git/HEAD"))
        XCTAssertEqual(ProcessGitContext.capture(workingDirectory:root.path).state,.unavailable)
    }
    func testNoMarkerAndDepthExhaustionAreDistinct() throws {
        let root=try fixture()
        XCTAssertEqual(ProcessGitContext.capture(workingDirectory:root.path).state,.noneObserved)
        XCTAssertEqual(ProcessGitContext.inspect(workingDirectory:root.path,maximumDepth:1).state,.unavailable)
        XCTAssertEqual(ProcessGitContext.capture(workingDirectory:nil).state,.unavailable)
        XCTAssertEqual(ProcessGitContext.capture(workingDirectory:"relative").state,.unavailable)
    }
    func testMalformedNestedMarkerNeverBorrowsParentRepository() throws {
        let root=try repo(),nested=root.appendingPathComponent("nested")
        try fm.createDirectory(at:nested,withIntermediateDirectories:true)
        try write("not a git pointer\n",nested.appendingPathComponent(".git"))
        XCTAssertEqual(ProcessGitContext.capture(workingDirectory:nested.path).state,.unavailable)
    }
    func testFIFOAndSymlinkHeadAreRefusedWithoutOpeningSpecialData() throws {
        let root=try repo(),head=root.appendingPathComponent(".git/HEAD")
        try fm.removeItem(at:head);XCTAssertEqual(mkfifo(head.path,0o600),0)
        let before=Date();XCTAssertEqual(ProcessGitContext.capture(workingDirectory:root.path).state,.unavailable)
        XCTAssertLessThan(Date().timeIntervalSince(before),1)
        try fm.removeItem(at:head);let outside=root.appendingPathComponent("outside")
        try write(String(repeating:"a",count:40),outside);try fm.createSymbolicLink(at:head,withDestinationURL:outside)
        XCTAssertEqual(ProcessGitContext.capture(workingDirectory:root.path).state,.unavailable)
    }
    func testOversizedAndTraversalHeadAreUnavailable() throws {
        let root=try repo(),head=root.appendingPathComponent(".git/HEAD")
        for text in [String(repeating:"x",count:5000),"ref: refs/heads/../../secret\n","ref: refs/heads/evil\u{1b}\n","ref: refs/heads/main\nextra\n"] {
            try write(text,head);XCTAssertEqual(ProcessGitContext.capture(workingDirectory:root.path).state,.unavailable)
        }
    }
    func testMetadataReplacementDuringReadDiscardsObservation() throws {
        let root=try repo(),head=root.appendingPathComponent(".git/HEAD")
        let result=ProcessGitContext.inspect(workingDirectory:root.path,afterRead:{
            try! self.write(String(repeating:"b",count:40)+"\n",head)
        })
        XCTAssertEqual(result.state,.unavailable);XCTAssertNil(result.root);XCTAssertNil(result.commit)
    }
    func testAppearingMarkerInvalidatesPreviouslyEmptyObservation() throws {
        let root=try fixture()
        let result=ProcessGitContext.inspect(workingDirectory:root.path,afterRead:{
            try! self.fm.createDirectory(at:root.appendingPathComponent(".git"),withIntermediateDirectories:true)
        })
        XCTAssertEqual(result.state,.unavailable)
    }
    func testCorruptLooseRefDoesNotFallBackToStalePackedCommit() throws {
        let root=try repo();try git(root,["pack-refs","--all"])
        let ref=root.appendingPathComponent(".git/refs/heads/main")
        try write("\n",ref)
        let result=ProcessGitContext.capture(workingDirectory:root.path)
        XCTAssertEqual(result.state,.unavailable);XCTAssertNil(result.commit)
    }
    func testSHA256HeadAndRelativeGitDirectoryPointer() throws {
        let root=try fixture(),metadata=root.appendingPathComponent("metadata")
        try fm.createDirectory(at:metadata,withIntermediateDirectories:true)
        try write("gitdir: metadata\n",root.appendingPathComponent(".git"))
        try write(String(repeating:"a",count:64)+"\n",metadata.appendingPathComponent("HEAD"))
        let result=ProcessGitContext.capture(workingDirectory:root.path)
        XCTAssertEqual(result.state,.observed);XCTAssertEqual(result.commit,String(repeating:"a",count:64));XCTAssertEqual(result.detached,true)
    }
}
