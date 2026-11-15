import AgentCore
import ModuleHost
import ModuleKit
import XCTest
@testable import CleanKit
@testable import ThermoApp

@MainActor final class ModuleProtectedReadTests:XCTestCase {
    private func home()throws->URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-protected-reads-"+UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock{try? FileManager.default.removeItem(at:root)}
        return root
    }
    private func put(_ path:String,under root:URL)throws->URL {
        let p=root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at:p.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("owned fixture".utf8).write(to:p);return p
    }
    private func broker(_ root:URL,log:ModuleAccessLog)->CapabilityBroker {
        let manifest=ModuleManifest(id:"com.example.read-protection",name:"Fixture",summary:"",symbol:"doc",version:"1.0.0",capabilities:[Capability("files.read:~")!])
        return ModuleKernel.broker(for:manifest,log:log,home:root.path,confirm:{_ in XCTFail("reading never asks for destructive confirmation");return false})
    }
    private func payload(_ operation:String)->Data {Data(("{\"op\":\""+operation+"\"}").utf8)}
    func testDeclaredReadsStillRefuseKeysDocumentsAndAgentMemory() async throws {
        let root=try home(),log=ModuleAccessLog(home:root.path),b=broker(root,log:log)
        for rel in [".ssh/key.txt","Documents/private.txt",".codex/memories/note.txt",".claude/projects/fixture/memory/note.txt"] {
            let file=try put(rel,under:root)
            for (op,target) in [("read",file),("list",file.deletingLastPathComponent()),("measure",file.deletingLastPathComponent())] {
                guard case let .failure(error)=await b.request("files.read:"+target.path,payload:payload(op)) else{return XCTFail("read protected fixture: "+rel)}
                XCTAssertEqual(error.outcome,.denied,error.message)
            }
        }
        XCTAssertEqual(log.summary(module:"com.example.read-protection").denied,12)
        XCTAssertTrue(log.summary(module:"com.example.read-protection").read.isEmpty)
    }
    func testOrdinaryCacheRootCanBeListedAndReadWithoutDeletionAuthority() async throws {
        let root=try home(),file=try put("Library/Caches/owned.txt",under:root),log=ModuleAccessLog(home:root.path),b=broker(root,log:log)
        XCTAssertNotNil(Guard(home:root.path).refusal(file.deletingLastPathComponent().path))
        let list=try await b.request("files.read:"+file.deletingLastPathComponent().path,payload:payload("list")).get()
        let entries=try XCTUnwrap((JSONSerialization.jsonObject(with:list) as? [String:Any])?["entries"] as? [[String:Any]])
        XCTAssertEqual(entries.compactMap{$0["name"] as? String},["owned.txt"])
        let read=try await b.request("files.read:"+file.path,payload:payload("read")).get()
        let data=try XCTUnwrap((JSONSerialization.jsonObject(with:read) as? [String:Any])?["base64"] as? String)
        XCTAssertEqual(Data(base64Encoded:data),Data("owned fixture".utf8))
    }
    func testProtectionListAppliesToDirectAndRecursiveReads() async throws {
        let root=try home(),file=try put("Cache/protected/owned.txt",under:root)
        _=try Whitelist.add([file.deletingLastPathComponent().path],home:root.path)
        let log=ModuleAccessLog(home:root.path),b=broker(root,log:log)
        for (op,path) in [("read",file.path),("list",root.appendingPathComponent("Cache").path),("measure",root.appendingPathComponent("Cache").path)] {
            guard case let .failure(error)=await b.request("files.read:"+path,payload:payload(op)) else{return XCTFail("protection bypassed")}
            XCTAssertEqual(error.outcome,.denied,error.message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
    }
    func testLinkToProtectedDataIsRefusedEvenWithBroadDeclaredScope() async throws {
        let root=try home(),secret=try put(".ssh/key.txt",under:root),folder=root.appendingPathComponent("Cache")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let link=folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:secret.path)
        let log=ModuleAccessLog(home:root.path),b=broker(root,log:log)
        guard case let .failure(error)=await b.request("files.read:"+link.path,payload:payload("read")) else{return XCTFail("read link")}
        XCTAssertEqual(error.outcome,.denied)
        guard case let .failure(treeError)=await b.request("files.read:"+folder.path,payload:payload("measure")) else{return XCTFail("measured protected link")}
        XCTAssertEqual(treeError.outcome,.denied)
    }
}
