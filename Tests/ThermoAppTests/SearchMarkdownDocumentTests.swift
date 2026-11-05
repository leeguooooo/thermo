import XCTest
import WebKit
import SearchCore
@testable import ThermoApp

final class SearchMarkdownDocumentTests: XCTestCase {
    func testDocumentRendersStructureAndUniqueHeadingAnchors() {
        let source = """
        # 项目 **说明**

        [跳到安装](#安装)

        ## 安装

        - [x] 完成
        - [ ] 待办

        > 引用 *内容*

        | 名称 | 内容 |
        | --- | --- |
        | 一 | **重点** |

        ```swift
        let value = "<script>不是 HTML</script>"
        ```

        ## 安装
        """
        let doc = SearchMarkdownDocument.render(source)
        XCTAssertEqual(doc.headings.map(\.anchor), ["项目-说明", "安装", "安装-1"])
        XCTAssertTrue(doc.body.contains("<strong>说明</strong>"))
        XCTAssertTrue(doc.body.contains("<table>")); XCTAssertTrue(doc.body.contains("<th>名称</th>"))
        XCTAssertTrue(doc.body.contains("<blockquote>")); XCTAssertTrue(doc.body.contains("type=\"checkbox\" disabled checked"))
        XCTAssertTrue(doc.body.contains("&lt;script&gt;不是 HTML&lt;/script&gt;"))
        XCTAssertFalse(doc.body.contains("<script>"))
        XCTAssertTrue(doc.html().contains("<nav aria-label=\"Contents\">"))
        let original = doc.html(showSource: true)
        XCTAssertTrue(original.contains("# 项目 **说明**")); XCTAssertFalse(original.contains("<nav"))
    }
    func testHTMLFormattingIsRetainedButActiveContentAndUnsafeLinksAreRemoved() {
        let doc = SearchMarkdownDocument.render("""
        <p align="center"><strong>标题</strong><br><img src="https://example.com/tracker.png" onerror="bad()" alt="logo"></p>
        <script>bad()</script><style>body{display:none}</style>

        [bad](javascript:alert%281%29) and [good](https://example.com)
        """)
        XCTAssertTrue(doc.body.contains("<p align=\"center\"><strong>标题</strong><br>"))
        XCTAssertFalse(doc.body.contains("onerror")); XCTAssertFalse(doc.body.contains("<script"))
        XCTAssertFalse(doc.body.contains("display:none")); XCTAssertFalse(doc.body.contains("javascript:"))
        XCTAssertFalse(doc.body.contains("src=\"https:"))
        XCTAssertTrue(doc.body.contains("href=\"https://example.com\""))
        XCTAssertTrue(doc.html().contains("default-src 'none'"))
    }
    func testRelativeImagesAreEmbeddedAndLinksResolveAgainstOriginalFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-markdown-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([0x89, 0x50, 0x4e, 0x47])
        try bytes.write(to: directory.appendingPathComponent("picture.png"))
        let doc = SearchMarkdownDocument.render("![图](picture.png)\n\n[下一页](next.md)", baseURL: directory.appendingPathComponent("", isDirectory: true))
        XCTAssertTrue(doc.body.contains("src=\"data:image/png;base64," + bytes.base64EncodedString()))
        XCTAssertTrue(doc.body.contains(directory.appendingPathComponent("next.md").absoluteString), doc.body)
        XCTAssertFalse(doc.body.contains("src=\"file:"))
    }
    @MainActor func testWebKitLoadsGeneratedPreviewAndFindsRenderedText() async throws {
        let model = SearchFilePreviewModel(item: SearchItem(path: "/tmp/preview-test.md", name: "preview-test.md", kind: .file))
        let coordinator = SearchMarkdownWebView.Coordinator(model: model)
        let page = coordinator.directory.appendingPathComponent("preview.html")
        try SearchMarkdownDocument.render("# Preview acceptance\n\nReadable **content**.").html().write(to: page, atomically: true, encoding: .utf8)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        web.navigationDelegate = coordinator; model.webView = web
        web.loadFileURL(page, allowingReadAccessTo: coordinator.directory)
        defer { web.stopLoading(); web.navigationDelegate = nil }
        for _ in 0..<100 {
            if let text = try? await web.evaluateJavaScript("document.body.innerText") as? String,
               text.contains("Readable content.") {
                let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                    web.find("Readable", configuration: WKFindConfiguration()) { continuation.resume(returning: $0.matchFound) }
                }
                XCTAssertTrue(result)
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Generated document did not load: " + (model.issue ?? web.url?.absoluteString ?? "no URL"))
    }
    func testBoundedReadingReportsLargeAndUnsupportedDocuments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-markdown-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.md")
        try Data(repeating: 65, count: 2 * 1024 * 1024 + 1).write(to: url)
        XCTAssertThrowsError(try SearchMarkdownDocument.load(url))
        try Data("# 中文\n\n内容".utf8).write(to: url)
        XCTAssertEqual(try SearchMarkdownDocument.load(url).headings.first?.title, "中文")
        XCTAssertTrue(SearchMarkdownDocument.supports(URL(fileURLWithPath: "/tmp/README.MDX")))
        XCTAssertFalse(SearchMarkdownDocument.supports(URL(fileURLWithPath: "/tmp/report.pdf")))
    }
}
