import Combine
import DocumentPreviewAPI
import ModuleHost
import XCTest
@testable import DocumentPreviewHost

@MainActor final class DocumentPreviewOwnershipTests:XCTestCase {
    private func broker(root:URL,restart:@escaping @MainActor ()->String? = {nil})->DocumentPreviewBroker {
        .init(manager:ModuleManager(app:root.appendingPathComponent("missing.app")),worker:"com.example.owned-preview",loaded:{false},statuses:Empty(completeImmediately:false).eraseToAnyPublisher(),restartRequired:restart)
    }
    func testOffAndRestartGuardStayBeforeAcquisitionOrNewOwnership() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-preview-gates-"+UUID().uuidString)
        var gateCalls=0
        let host=broker(root:root,restart:{gateCalls+=1;return "restart required"})
        let selection=SelectedDocument(path:root.appendingPathComponent("not-created.txt").path,name:"absent",kind:.file)
        let off=DocumentPreviewController(broker:host,available:{false})
        off.open(selection,roots:[],request:UUID())
        XCTAssertEqual(gateCalls,0);XCTAssertEqual(host.sequence,0);XCTAssertNil(host.owner);XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
        let old=UUID();host.owner=old;host.sequence=9
        let replacement=DocumentPreviewController(broker:host,available:{true})
        replacement.open(selection,roots:[],request:UUID())
        XCTAssertEqual(replacement.state,.failed("restart required"));XCTAssertEqual(host.owner,old);XCTAssertEqual(host.sequence,9)
        replacement.stop(ifCurrent:nil);await replacement.finishStopping()
        XCTAssertEqual(host.owner,old,"a blocked presentation never owned the old request")
    }
    func testNewPresentationSharesSequenceAndOldStopCannotRetireIt() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-preview-owner-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("owned.txt");try Data("owned preview input".utf8).write(to:file)
        let selected=SelectedDocument(path:file.path,name:file.lastPathComponent,kind:.file),host=broker(root:root)
        let first=DocumentPreviewController(broker:host,available:{true}),old=UUID()
        first.open(selected,roots:[root.path],request:old);await Task.yield()
        XCTAssertEqual(host.sequence,1);XCTAssertEqual(host.owner,old)
        let second=DocumentPreviewController(broker:host,available:{true}),new=UUID()
        second.open(selected,roots:[root.path],request:new);XCTAssertEqual(host.sequence,2);XCTAssertEqual(host.owner,new)
        second.open(selected,roots:[root.path],request:new);XCTAssertEqual(host.sequence,2,"body recomputation must not allocate another request")
        first.stop(ifCurrent:old);await first.finishStopping()
        XCTAssertEqual(host.owner,new);XCTAssertFalse(first.canAttach(old));XCTAssertTrue(host.manager.modules.isEmpty,"no module was loaded or launched")
        second.stop(ifCurrent:new);await second.finishStopping()
        XCTAssertNil(host.owner);XCTAssertFalse(second.canAttach(new));XCTAssertEqual(try Data(contentsOf:file),Data("owned preview input".utf8))
    }
}
