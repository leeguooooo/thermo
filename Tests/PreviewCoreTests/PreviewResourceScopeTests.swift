import Foundation
import XCTest
@testable import PreviewCore

final class PreviewResourceScopeTests:XCTestCase {
    func testOnlyRegularImageInputsWithinTheScopedDirectoryCanBeOpened() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-preview-scope-"+UUID().uuidString)
        let folder=root.appendingPathComponent("allowed"),outside=root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let image=folder.appendingPathComponent("one.png"),secret=outside.appendingPathComponent("secret.png")
        try Data("image".utf8).write(to:image);try Data("outside".utf8).write(to:secret)
        let scope=try PreviewResourceScope(root:folder)
        let input=try scope.openFile(image,imageOnly:true,maxBytes:8);defer{try? input.close()}
        XCTAssertEqual(try input.readToEnd(),Data("image".utf8))
        XCTAssertThrowsError(try scope.openFile(secret,imageOnly:true))
        XCTAssertThrowsError(try scope.openFile(image,imageOnly:true,maxBytes:2))
        let link=folder.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:secret)
        XCTAssertThrowsError(try scope.openFile(link,imageOnly:true))
        let linkedFolder=folder.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at:linkedFolder,withDestinationURL:outside)
        XCTAssertThrowsError(try scope.openFile(linkedFolder.appendingPathComponent("secret.png"),imageOnly:true))
        let text=folder.appendingPathComponent("not-an-image.txt");try Data("text".utf8).write(to:text)
        XCTAssertThrowsError(try scope.openFile(text,imageOnly:true))
    }
    func testDirectoryHandleCannotBeRedirectedByReplacingItsPath() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-preview-scope-swap-"+UUID().uuidString)
        let allowed=root.appendingPathComponent("allowed"),moved=root.appendingPathComponent("moved"),outside=root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at:allowed,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        try Data("owned".utf8).write(to:allowed.appendingPathComponent("one.png"))
        try Data("outside".utf8).write(to:outside.appendingPathComponent("one.png"))
        let scope=try PreviewResourceScope(root:allowed)
        try FileManager.default.moveItem(at:allowed,to:moved)
        try FileManager.default.createSymbolicLink(at:allowed,withDestinationURL:outside)
        let file=try scope.openFile(allowed.appendingPathComponent("one.png"),imageOnly:true);defer{try? file.close()}
        XCTAssertEqual(try file.readToEnd(),Data("owned".utf8))
    }
}
