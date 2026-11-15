import Darwin
import ModuleKit
import XCTest
@testable import ModuleHost

final class BoundedFileReadTests:XCTestCase {
    private func directory()throws->URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-bounded-read-"+UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock{try? FileManager.default.removeItem(at:root)};return root
    }
    private func request(_ path:String)->BrokerRequest {
        .init(manifest:.init(id:"com.example.read",name:"Fixture",summary:"",symbol:"doc",version:"1.0.0"),kind:.filesRead,operation:"read",targets:[path],payload:[:])
    }
    func testSpecialFileFailsWithoutWaitingForAWriter() async throws {
        let root=try directory(),pipe=root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path,0o600),0)
        do {_ = try await KernelServices.filesRead(request(pipe.path));XCTFail("read a pipe")}
        catch let error as BrokerError {XCTAssertTrue(error.message.contains("regular file"))}
    }
    func testOversizedRegularFileIsRefused() async throws {
        let root=try directory(),file=root.appendingPathComponent("large")
        FileManager.default.createFile(atPath:file.path,contents:Data())
        let handle=try FileHandle(forWritingTo:file);try handle.truncate(atOffset:UInt64(KernelServices.maxReadBytes+1));try handle.close()
        do {_ = try await KernelServices.filesRead(request(file.path));XCTFail("read oversized file")}
        catch let error as BrokerError {XCTAssertTrue(error.message.contains("larger"))}
    }
    func testSwappedParentLinkCannotRedirectTheActualRead() async throws {
        let root=try directory(),target=root.appendingPathComponent("target"),link=root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        try Data("fixture".utf8).write(to:target.appendingPathComponent("owned"))
        try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:target.path)
        do {_ = try await KernelServices.filesRead(request(link.appendingPathComponent("owned").path));XCTFail("followed a changed parent")}
        catch let error as BrokerError {XCTAssertEqual(error.outcome,.denied)}
    }
}
