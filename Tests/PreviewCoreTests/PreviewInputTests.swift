import Foundation
import XCTest
@testable import PreviewCore

final class PreviewInputTests: XCTestCase {
    func testSelectedFileBecomesIndependentContainerCopyInBothModes() throws {
        for clone in [true,false] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-preview-input-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer {try? FileManager.default.removeItem(at:root)}
            let original=root.appendingPathComponent("original.pdf"),cache=root.appendingPathComponent("container")
            try Data("original input".utf8).write(to:original)
            let file=try FileHandle(forReadingFrom:original);defer {try? file.close()}
            let input=PreviewInput(kind:.file,name:"../../escape/original.pdf")
            let output=try XCTUnwrap(PreviewInputCache(root:cache,cloneEnabled:clone).prepare(input,file:file))
            XCTAssertEqual(output.deletingLastPathComponent().resolvingSymlinksInPath().path,cache.resolvingSymlinksInPath().path)
            XCTAssertEqual(output.pathExtension,"pdf")
            XCTAssertEqual(try Data(contentsOf:output),Data("original input".utf8))
            try Data("edited cached copy".utf8).write(to:output)
            XCTAssertEqual(try Data(contentsOf:original),Data("original input".utf8))
        }
    }
    func testWritableAndNonRegularDescriptorsAreRejectedBeforeReading() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-preview-reject-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let original=root.appendingPathComponent("original.txt");try Data("kept".utf8).write(to:original)
        let file=try FileHandle(forUpdating:original);defer {try? file.close()}
        let cache=PreviewInputCache(root:root.appendingPathComponent("container")),input=PreviewInput(kind:.file,name:"input.txt")
        XCTAssertThrowsError(try cache.prepare(input,file:file))
        let pipe=Pipe()
        XCTAssertThrowsError(try cache.prepare(input,file:pipe.fileHandleForReading))
        XCTAssertFalse(FileManager.default.fileExists(atPath:cache.root.path))
        XCTAssertEqual(try Data(contentsOf:original),Data("kept".utf8))
    }
    func testCancelledInputMakesNoCacheAndMetadataHasBounds() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-preview-cancel-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let original=root.appendingPathComponent("original.txt");try Data("kept".utf8).write(to:original)
        let file=try FileHandle(forReadingFrom:original);defer {try? file.close()}
        let cache=PreviewInputCache(root:root.appendingPathComponent("container")),input=PreviewInput(kind:.file,name:"input.txt")
        XCTAssertThrowsError(try cache.prepare(input,file:file,cancelled:{true}))
        XCTAssertFalse(FileManager.default.fileExists(atPath:cache.root.path))
        XCTAssertThrowsError(try PreviewInput.decode(Data(repeating:32,count:262_145)))
        XCTAssertThrowsError(try PreviewInput.decode(PreviewInput(kind:.file,name:"",entries:[]).data()))
    }
    func testDirectoryMetadataDoesNotGrantAPathOrRequireAFile() throws {
        let input=PreviewInput(kind:.directory,name:"Chosen folder",entries:[.init(name:"one.txt",directory:false,bytes:3)])
        XCTAssertEqual(try PreviewInput.decode(input.data()),input)
        let cache=PreviewInputCache(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertNil(try cache.prepare(input,file:nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath:cache.root.path))
    }
}
