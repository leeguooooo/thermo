import AppKit
import CaptureCore
import XCTest
import WebKit
@testable import ThermoApp

final class CapturePinClipboardTests:XCTestCase {
    @MainActor func testRichTextAndColorClipboardRoundTripWithoutUsingGlobalBoard() throws {
        _=NSApplication.shared;let board=NSPasteboard.withUniqueName();defer { board.releaseGlobally() }
        var text=CapturePinText(plain:"Preserve 中文",html:"<strong>Preserve 中文</strong>")
        let rich=NSAttributedString(string:text.plain,attributes:[.font:NSFont.boldSystemFont(ofSize:24)]);text.rtf=try rich.data(from:NSRange(location:0,length:rich.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
        try CapturePinClipboard.copy(.text(text),to:board)
        guard case .content(.text(let result))=try CapturePinClipboard.read(board) else { return XCTFail("Expected rich text") }
        XCTAssertEqual(result,text)
        board.clearContents();board.setString("orange",forType:.string);board.setString("<span>orange</span>",forType:.html)
        guard case .content(.color(let color))=try CapturePinClipboard.read(board) else { return XCTFail("Expected color") }
        guard case .content(.text(let forced))=try CapturePinClipboard.read(board,asText:true) else { return XCTFail("Expected forced text") };XCTAssertEqual(forced.plain,"orange")
        try CapturePinClipboard.copy(.color(color),to:board,format:.rgb);XCTAssertEqual(board.string(forType:.string),"rgb(255, 165, 0)")
    }
    @MainActor func testFilesTakePriorityOverClipboardImagePreviewAndCopyAsFileURLs() throws {
        let board=NSPasteboard.withUniqueName();defer { board.releaseGlobally() }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        let a=root.appendingPathComponent("a.txt"),b=root.appendingPathComponent("b.txt");try Data("a".utf8).write(to:a);try Data("b".utf8).write(to:b)
        board.writeObjects([a,b] as [NSURL])
        let image=try CapturePinContent.color(.init(red:10,green:20,blue:30)).previewImage()
        board.setData(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]),forType:.png)
        guard case .content(.files(let files))=try CapturePinClipboard.read(board) else { return XCTFail("Expected file references") }
        XCTAssertEqual(files.count,2)
        try CapturePinClipboard.copy(.files(files),to:board,selectedFiles:[files[1].id])
        let urls=board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL];XCTAssertEqual(urls?.map { $0.resolvingSymlinksInPath().path },[b.resolvingSymlinksInPath().path])
        XCTAssertEqual(try String(contentsOf:a),"a")
    }
    @MainActor func testTypedSessionPreservesPayloadAcrossEditCloseAndRestart() throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let session=CapturePinSession(store:.init(root:root)),id=try session.open(.text(.init(plain:"Original")))
        let model=try XCTUnwrap(session.windows[id]?.model);try model.updatePinContent(.text(.init(plain:"Edited 中文")));try session.flush();session.closeAll()
        let next=CapturePinSession(store:.init(root:root));try next.restore(id)
        XCTAssertEqual(next.windows[id]?.model.pinContent,.text(.init(plain:"Edited 中文")));XCTAssertEqual(next.library.pins[0].contentKind,"text");next.closeAll()
    }
    @MainActor func testOfflineHTMLResourcePolicyCompilesInWebKit() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        let store=WKContentRuleListStore(url:root)!
        let result:WKContentRuleList=try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier:"test-policy",encodedContentRuleList:CaptureHTMLPinView.rules) { rules,error in
                if let error { continuation.resume(throwing:error) }
                else if let rules { continuation.resume(returning:rules) }
                else { continuation.resume(throwing:CaptureFailure.invalidImage) }
            }
        }
        XCTAssertNotNil(result)
    }

    @MainActor func testInvalidTextEditBlocksCloseUntilCorrectedOrReverted() throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let session=CapturePinSession(store:.init(root:root)),id=try session.open(.text(.init(plain:"Saved")))
        let editor=try XCTUnwrap(session.windows[id]),model=editor.model
        XCTAssertThrowsError(try model.updatePinContent(.text(.init(plain:String(repeating:"x",count:1024*1024+1)))))
        XCTAssertNotNil(model.pinContentSaveError);XCTAssertThrowsError(try session.flush());XCTAssertFalse(editor.windowShouldClose(try XCTUnwrap(editor.window)))
        XCTAssertEqual(try session.store.snapshot(for:session.library.pins[0]).content,.text(.init(plain:"Saved")))
        model.revertUnsavedPinText();try session.flush();session.closeAll()
    }

}
