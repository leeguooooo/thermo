import AgentCore
import Foundation
import XCTest
@testable import CleanKit

final class ProcessActionGateTests:XCTestCase {
    func identity(_ executable:String="/fixture/tool")->ProcessIdentity {
        .init(pid:42,uid:501,started:Date(timeIntervalSince1970:100),executable:executable)
    }
    func testMatchingIdentityRequestsExactlyOneActionButDoesNotClaimProcessExit() {
        let expected=identity();var requests=0,reads=0
        let outcome=ProcessActionGate.attempt(expected,allowApplication:false,uid:501,me:99,
            identity:{_ in reads+=1;return expected},details:{_ in .init(executable:expected.executable,argv:[expected.executable])}){value in
                XCTAssertEqual(value,expected);requests+=1;return true
            }
        XCTAssertEqual(outcome,.requested);XCTAssertEqual(requests,1);XCTAssertEqual(reads,2)
    }
    func testExecOrPIDReuseAcrossDetailsReadPreventsDispatch() {
        let expected=identity();var replaced=expected;replaced.started=Date(timeIntervalSince1970:200)
        var reads=0,requests=0
        let result=ProcessActionGate.attempt(expected,allowApplication:false,uid:501,me:99,
            identity:{_ in reads+=1;return reads==1 ? expected:replaced},details:{_ in .init(executable:expected.executable)}){_ in requests+=1;return true}
        XCTAssertEqual(result,.changed);XCTAssertEqual(requests,0)
    }
    func testMissingIdentityOrExecutableDetailsCannotAuthorizeAnAction() {
        let expected=identity();var requests=0
        XCTAssertEqual(ProcessActionGate.attempt(nil,allowApplication:false,uid:501,me:99,
            identity:{_ in expected},details:{_ in .init(executable:expected.executable)}){_ in requests+=1;return true},.changed)
        XCTAssertEqual(ProcessActionGate.attempt(expected,allowApplication:false,uid:501,me:99,
            identity:{_ in expected},details:{_ in .init()}){_ in requests+=1;return true},.unavailable)
        XCTAssertEqual(requests,0)
    }
    func testInterpreterAgentAndAppServerCannotUseUnchangedPIDAsPermission() {
        let cases:[(String,[String])]=[
            ("/fixture/codex",["codex","app-server"]),
            ("/opt/homebrew/bin/node",["node","/fixture/node_modules/@anthropic-ai/claude-code/cli.js"]),
            ("/opt/homebrew/bin/node",["node","/fixture/node_modules/@openai/codex/bin/codex.js"]),
            ("/opt/homebrew/bin/python",["python","/fixture/aider.py"])
        ]
        var requests=0
        for (path,args) in cases {
            let expected=identity(path)
            let result=ProcessActionGate.attempt(expected,allowApplication:true,uid:501,me:99,
                identity:{_ in expected},details:{_ in .init(executable:path,argv:args)}){_ in requests+=1;return true}
            XCTAssertEqual(result,.protected,path)
        }
        XCTAssertEqual(requests,0)
    }
    func testManualAgentSessionCapabilityOpensOnlyAgentSessions() {
        let agents:[(String,[String])]=[
            ("/Users/fixture/.local/share/claude/versions/2.0.0",["claude"]),
            ("/opt/homebrew/bin/node",["node","/fixture/node_modules/@openai/codex/bin/codex.js"])
        ]
        var requests=0
        for (path,args) in agents {
            let expected=identity(path)
            XCTAssertEqual(ProcessActionGate.attempt(expected,allowApplication:false,allowAgentSession:true,uid:501,me:99,
                identity:{_ in expected},details:{_ in .init(executable:path,argv:args)}){_ in requests+=1;return true},.requested,path)
        }
        XCTAssertEqual(requests,agents.count)
        // The capability is about agent sessions only: system, Thermo, other users and apps stay closed.
        for path in ["/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder","/usr/libexec/helper",
                     "/Library/PrivilegedHelperTools/dev.thermo.helper","/Applications/Thermo.app/Contents/MacOS/Thermo",
                     "/Applications/Example.app/Contents/MacOS/Example"] {
            let expected=identity(path)
            XCTAssertEqual(ProcessActionGate.attempt(expected,allowApplication:false,allowAgentSession:true,uid:501,me:99,
                identity:{_ in expected},details:{_ in .init(executable:path)}){_ in requests+=1;return true},.protected,path)
        }
        let other=identity("/fixture/claude")
        XCTAssertEqual(ProcessActionGate.attempt(other,allowApplication:false,allowAgentSession:true,uid:502,me:99,
            identity:{_ in other},details:{_ in .init(executable:other.executable)}){_ in requests+=1;return true},.protected)
        XCTAssertEqual(ProcessActionGate.attempt(other,allowApplication:false,allowAgentSession:true,uid:501,me:42,
            identity:{_ in other},details:{_ in .init(executable:other.executable)}){_ in requests+=1;return true},.protected)
        XCTAssertEqual(requests,agents.count)
    }
    func testProtectedUIDSystemAndOwnBundleChildrenNeverReachSender() {
        let paths=["/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder","/usr/libexec/helper",
                   "/Library/PrivilegedHelperTools/dev.thermo.helper","/Applications/Thermo.app/Contents/Extensions/Other.appex/Contents/MacOS/Other"]
        var requests=0
        for path in paths {
            let expected=identity(path)
            XCTAssertEqual(ProcessActionGate.attempt(expected,allowApplication:true,uid:501,me:99,
                identity:{_ in expected},details:{_ in .init(executable:path)}){_ in requests+=1;return true},.protected)
        }
        let expected=identity()
        XCTAssertEqual(ProcessActionGate.attempt(expected,allowApplication:false,uid:502,me:99,
            identity:{_ in expected},details:{_ in .init(executable:expected.executable)}){_ in requests+=1;return true},.protected)
        XCTAssertEqual(requests,0)
    }
    func testApplicationsRequireTheQuitCapabilityAndRejectedRequestsStayRejected() {
        let expected=identity("/Applications/Example.app/Contents/MacOS/Example")
        var requests=0
        XCTAssertEqual(ProcessActionGate.attempt(expected,allowApplication:false,uid:501,me:99,
            identity:{_ in expected},details:{_ in .init(executable:expected.executable)}){_ in requests+=1;return true},.protected)
        XCTAssertEqual(ProcessActionGate.attempt(expected,allowApplication:true,uid:501,me:99,
            identity:{_ in expected},details:{_ in .init(executable:expected.executable)}){_ in requests+=1;return false},.declined)
        XCTAssertEqual(requests,1)
    }
    func testLegacyComputeRowsWithoutFrozenIdentityRemainUnverifiable() throws {
        let process=try JSONDecoder().decode(ComputeProcess.self,from:Data("{\"pid\":42,\"name\":\"tool\"}".utf8))
        XCTAssertNil(process.identity)
    }
}
