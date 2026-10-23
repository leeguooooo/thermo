import AppKit
import XCTest
@testable import CaptureCore

final class CapturePinLibraryTests:XCTestCase {
    private func image() throws -> CGImage {
        let ctx=try XCTUnwrap(CGContext(data:nil,width:80,height:60,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.green.cgColor);ctx.fill(CGRect(x:0,y:0,width:80,height:60));return try XCTUnwrap(ctx.makeImage())
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pin-library-test-"+UUID().uuidString) }
    func testRoundTripPreservesEditableAnnotationsAndWindowState() throws {
        let root=root();defer { try? FileManager.default.removeItem(at:root) }
        let store=CapturePinLibraryStore(root:root);var library=try store.load()
        let group=CapturePinGroup(name:"Work",color:"#12ABFF");library.groups.append(group);library.currentGroupID=group.id
        var pin=CaptureSavedPin(groupID:group.id);pin.title="中文测试";pin.frame=CGRect(x:-300,y:80,width:900,height:700);pin.opacity=0.5;pin.pan=CGPoint(x:12,y:28);pin.zoom=2;pin.pinned=false;pin.locked=true;pin.shadow=false
        library.pins=[pin]
        var doc=CaptureDocument(image:try image());var effect=CaptureAnnotation(tool:.mosaic,points:[.zero,CGPoint(x:50,y:40)]);effect.options.strength=24;doc.append(effect)
        try store.save(library,documents:[pin.id:doc])
        let fresh=CapturePinLibraryStore(root:root),loaded=try fresh.load(),restored=try fresh.document(for:loaded.pins[0])
        XCTAssertEqual(loaded.currentGroupID,group.id);XCTAssertEqual(loaded.groups.last?.color,"#12ABFF");XCTAssertEqual(loaded.pins[0].title,pin.title);XCTAssertEqual(loaded.pins[0].pan,pin.pan);XCTAssertTrue(loaded.pins[0].locked);XCTAssertFalse(loaded.pins[0].shadow)
        XCTAssertEqual(restored.annotations[0].tool,.mosaic);XCTAssertEqual(restored.annotations[0].options.strength,24);XCTAssertFalse(restored.canUndo)
        XCTAssertEqual(try restored.data(),try doc.data())
    }
    func testFailedCommitKeepsPreviousSnapshotAndManifest() throws {
        let root=root();defer { try? FileManager.default.removeItem(at:root) }
        let store=CapturePinLibraryStore(root:root);var library=try store.load();let pin=CaptureSavedPin(groupID:library.currentGroupID);library.pins=[pin]
        library=try store.save(library,documents:[pin.id:CaptureDocument(image:try image())])
        let before=try Data(contentsOf:root.appendingPathComponent("library.json"))
        var broken=library;broken.pins[0].snapshotID=UUID()
        XCTAssertThrowsError(try store.save(broken))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("library.json")),before)
        XCTAssertEqual(try store.document(for:pin).image.width,80)
        var extra=CaptureSavedPin(groupID:library.currentGroupID);extra.title="Uncommitted"
        broken.pins.append(extra)
        XCTAssertThrowsError(try store.save(broken,documents:[extra.id:CaptureDocument(image:try image())]))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("snapshots/"+extra.snapshotID.uuidString).path))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("library.json")),before)
    }
    func testSymlinksAndDamagedMetadataAreRejected() throws {
        let root=root();defer { try? FileManager.default.removeItem(at:root) }
        let store=CapturePinLibraryStore(root:root);var library=try store.load();let pin=CaptureSavedPin(groupID:library.currentGroupID);library.pins=[pin]
        try store.save(library,documents:[pin.id:CaptureDocument(image:try image())])
        let folder=root.appendingPathComponent("snapshots/"+pin.snapshotID.uuidString)
        let png=folder.appendingPathComponent("image.png"),outside=root.appendingPathComponent("outside.png");try FileManager.default.moveItem(at:png,to:outside);try FileManager.default.createSymbolicLink(at:png,withDestinationURL:outside)
        XCTAssertThrowsError(try store.document(for:pin));XCTAssertThrowsError(try store.save(library))
        try FileManager.default.removeItem(at:png);try FileManager.default.moveItem(at:outside,to:png)
        try Data("{}".utf8).write(to:folder.appendingPathComponent("annotations.json"));XCTAssertThrowsError(try store.document(for:pin))
        try Data("[]".utf8).write(to:root.appendingPathComponent("library.json"));XCTAssertThrowsError(try CapturePinLibraryStore(root:root).load())
    }
    func testConcurrentStoreCannotOverwriteNewerSession() throws {
        let root=root();defer { try? FileManager.default.removeItem(at:root) }
        let first=CapturePinLibraryStore(root:root),stale=CapturePinLibraryStore(root:root)
        var a=try first.load(),b=try stale.load();a=try first.save(a);b.historyLimit=25
        XCTAssertThrowsError(try stale.save(b))
        let fresh=CapturePinLibraryStore(root:root);var c=try fresh.load();a.historyLimit=50;try first.save(a);c.historyLimit=100;XCTAssertThrowsError(try fresh.save(c))
        XCTAssertEqual(try CapturePinLibraryStore(root:root).load().historyLimit,50)
    }
    func testGroupsValidateNamesAndHistoryPrunesPerGroup() {
        var value=CapturePinLibrary();let other=CapturePinGroup(name:"Other");value.groups.append(other);value.historyLimit=1
        for group in value.groups { for i in 0..<3 { var pin=CaptureSavedPin(groupID:group.id);pin.closedAt=Date(timeIntervalSince1970:Double(i));value.pins.append(pin) };value.pins.append(.init(groupID:group.id)) }
        value.pruneHistory();XCTAssertEqual(value.pins.count,4);XCTAssertEqual(value.pins.filter { $0.closedAt != nil }.count,2)
        value.groups[1].name="  DEFAULT ";XCTAssertFalse(value.valid)
        value.groups[1].name="Other";value.groups[1].color="#nothex";XCTAssertFalse(value.valid)
        value.groups[1].color="#ABCDEF";XCTAssertTrue(value.valid)
    }
}
