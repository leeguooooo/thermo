import Foundation
import XCTest
@testable import PreviewCore

final class PreviewMarkdownTests:XCTestCase {
    func testRendererUsesOnlySuppliedImageInputsWhenAResolverIsInstalled() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-preview-markdown-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("local.png");try Data("must not be read directly".utf8).write(to:file)
        var requested:[URL]=[]
        let denied=PreviewMarkdownDocument.render("![image](local.png)",baseURL:root,readImage:{url,_ in requested.append(url);return nil})
        XCTAssertEqual(requested.map(\.path),[file.path])
        XCTAssertFalse(denied.body.contains("data:image/png;base64"))
        XCTAssertTrue(denied.body.contains("image-placeholder"))
        let allowed=PreviewMarkdownDocument.render("![image](local.png)",baseURL:root,readImage:{_,_ in Data("selected input".utf8)})
        XCTAssertTrue(allowed.body.contains(Data("selected input".utf8).base64EncodedString()))
        XCTAssertFalse(allowed.body.contains(Data("must not be read directly".utf8).base64EncodedString()))
    }
    func testInjectedImagesStillRespectThePerResourceByteLimit() {
        let doc=PreviewMarkdownDocument.render("![image](large.png)",baseURL:URL(fileURLWithPath:"/preview/"),readImage:{_,limit in Data(repeating:0,count:limit+1)})
        XCTAssertFalse(doc.body.contains("data:image/png;base64"))
    }
}
