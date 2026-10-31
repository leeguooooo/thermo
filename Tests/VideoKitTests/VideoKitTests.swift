import Foundation
import XCTest
@testable import VideoKit

/// Answers by URL substring, in registration order. Never touches the network.
final class FakeTransport: VideoTransport, @unchecked Sendable {
    typealias Handler = @Sendable (VideoRequest) throws -> VideoResponse

    private let lock = NSLock()
    private let routes: [(String, Handler)]
    private var recorded: [VideoRequest] = []

    init(_ routes: [(String, Handler)]) {
        self.routes = routes
    }

    convenience init(json: [(String, String)]) {
        self.init(json.map { pair in (pair.0, { _ in VideoResponse(status: 200, body: pair.1) }) })
    }

    var requests: [VideoRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: VideoRequest) async throws -> VideoResponse {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        guard let route = routes.first(where: { request.url.contains($0.0) }) else {
            throw URLError(.cannotFindHost)
        }
        return try route.1(request)
    }
}

private func kind(of error: Error) -> VideoParseErrorKind? { (error as? VideoParseException)?.kind }

final class VideoJSONTests: XCTestCase {
    func testKeepsKeyOrderAndIgnoresTrailingText() throws {
        let object = try XCTUnwrap(VideoJSON.parseObject(#"{"z":1,"a":{"b":[1,"x",null]},"m":true};window.x=1"#))
        XCTAssertEqual(object.keys, ["z", "a", "m"])
        XCTAssertEqual(object.optObject("a")?.optArray("b")?.optString(1), "x")
    }

    func testOptAccessorsFollowOrgJson() throws {
        let object = try XCTUnwrap(VideoJSON.parseObject(
            #"{"n":null,"i":12,"s":"34","d":1.9,"b":"true","big":1700000000000}"#
        ))
        XCTAssertEqual(object.optString("n"), "")
        XCTAssertEqual(object.optString("missing", "x"), "x")
        XCTAssertEqual(object.optString("i"), "12")
        XCTAssertEqual(object.optInt("s"), 34)
        XCTAssertEqual(object.optInt("d"), 1)
        XCTAssertTrue(object.optBoolean("b"))
        XCTAssertTrue(object.isNull("n"))
        XCTAssertTrue(object.isNull("missing"))
        XCTAssertEqual(object.optLong("big"), 1_700_000_000_000)
        XCTAssertEqual(object.optInt("missing", -1), -1)
    }

    func testEscapesAndLeniency() throws {
        let object = try XCTUnwrap(VideoJSON.parseObject(#"{a:'q',"e":"😀中\/\n","c":[1,],}"#))
        XCTAssertEqual(object.optString("a"), "q")
        XCTAssertEqual(object.optString("e"), "😀中/\n")
        XCTAssertEqual(object.optArray("c")?.count, 1)
    }

    func testRejectsNonObjectAndBrokenText() {
        XCTAssertNil(VideoJSON.parseObject("[1]"))
        XCTAssertNil(VideoJSON.parseObject("{\"a\":1"))
        XCTAssertNil(VideoJSON.parseObject("<html>"))
        XCTAssertNil(VideoJSON.parseObject(String(repeating: "[", count: 100_000)))
    }
}

final class VideoLinkParserTests: XCTestCase {
    private func check(_ text: String, _ platform: VideoPlatform, _ kind: String, _ id: String) {
        let link = VideoLinkParser.parse(text)
        XCTAssertEqual(link?.platform, platform, text)
        XCTAssertEqual(link?.kind, kind, text)
        XCTAssertEqual(link?.id, id, text)
    }

    func testEveryPlatformForm() {
        check("https://www.douyin.com/video/7123456789012", .douyin, "video", "7123456789012")
        check("https://www.douyin.com/user/self?a=1&modal_id=7123456789012", .douyin, "video", "7123456789012")
        check("https://www.iesdouyin.com/share/slides/7123456789012/", .douyin, "video", "7123456789012")
        check("https://www.xiaohongshu.com/explore/66abc0123456", .xhs, "note", "66abc0123456")
        check("https://www.kuaishou.com/short-video/3xabc", .kuaishou, "photo", "3xabc")
        check("https://www.kuaishou.com/f/XabcD", .kuaishou, "photo", "XabcD")
        check("https://v.m.chenzhongtech.com/fw/long-video/3xabc?x=1", .kuaishou, "photo", "3xabc")
        check("https://weibo.com/tv/show/1034:5001?mid=5002", .weibo, "tv", "5002")
        check("https://video.weibo.com/show?fid=1034:5001", .weibo, "fid", "1034:5001")
        check("https://m.weibo.cn/detail/5001", .weibo, "status", "5001")
        check("https://weibo.com/123/Nabcdef", .weibo, "status", "Nabcdef")
        check("https://www.acfun.cn/v/ac12345", .acfun, "ac", "12345")
        check("https://www.bilibili.com/video/BV1xx411c7mD?p=2", .bilibili, "video", "BV1xx411c7mD")
        check("https://www.bilibili.com/video/av170001", .bilibili, "video", "av170001")
        check("https://www.pixiv.net/en/artworks/123", .pixiv, "artwork", "123")
        check("https://www.pixiv.net/member_illust.php?mode=medium&illust_id=123", .pixiv, "artwork", "123")
    }

    func testShortLinksHaveNoId() {
        for (url, platform) in [
            ("https://v.douyin.com/abc_1/", VideoPlatform.douyin),
            ("https://xhslink.com/a/xyz", .xhs),
            ("https://v.kuaishou.com/abc", .kuaishou),
            ("https://b23.tv/abc", .bilibili),
            ("https://bili2233.cn/abc", .bilibili),
        ] {
            let link = VideoLinkParser.parse(url)
            XCTAssertEqual(link?.platform, platform)
            XCTAssertEqual(link?.isShortLink, true)
            XCTAssertEqual(link?.id, "")
        }
    }

    func testPicksLinkOutOfShareTextAndTrimsPunctuation() {
        let link = VideoLinkParser.parse("  看这个 1234567890123 https://www.acfun.cn/v/ac99，。 复制打开 ")
        XCTAssertEqual(link?.url, "https://www.acfun.cn/v/ac99")
        XCTAssertEqual(link?.id, "99")
    }

    func testRefusesBareIdsAndForeignLinks() {
        XCTAssertNil(VideoLinkParser.parse("7123456789012345678"))
        XCTAssertNil(VideoLinkParser.parse("https://example.com/video/1"))
        XCTAssertFalse(VideoLinkParser.looksLikeVideoLink("https://pan.quark.cn/s/abc"))
    }

    func testFullWidthSpaceDoesNotEndURLAndAsciiDigitsOnly() {
        // Java's \s is ASCII only; the id must not swallow Arabic-Indic digits either.
        XCTAssertEqual(VideoLinkParser.parse("https://www.acfun.cn/v/ac12\u{3000}x")?.url, "https://www.acfun.cn/v/ac12\u{3000}x")
        XCTAssertEqual(VideoLinkParser.parse("https://www.acfun.cn/v/ac12٣")?.id, "12")
    }
}

final class VideoHttpTests: XCTestCase {
    func testStatusMapping() {
        for (status, expected) in [(403, VideoParseErrorKind.blocked), (418, .blocked), (429, .blocked),
                                   (404, .notFound), (410, .notFound), (500, .unknown)] {
            XCTAssertThrowsError(try VideoHttp.requireSuccess(VideoResponse(status: status), what: "x")) {
                XCTAssertEqual(kind(of: $0), expected)
            }
        }
        XCTAssertNoThrow(try VideoHttp.requireSuccess(VideoResponse(status: 204), what: "x"))
    }

    func testNetworkErrorMessageDropsQuery() async {
        let http = VideoHttp(transport: FakeTransport([]))
        do {
            _ = try await http.request("https://h.example/p?token=SECRET")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(kind(of: error), .network)
            XCTAssertFalse(String(describing: error).contains("SECRET"))
        }
    }

    func testCancellationPassesThrough() async {
        let http = VideoHttp(transport: FakeTransport([("h", { _ in throw CancellationError() })]))
        do {
            _ = try await http.request("https://h.example/")
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testExpandRedirect() async throws {
        let http = VideoHttp(transport: FakeTransport([
            ("/r", { _ in VideoResponse(status: 302, headers: ["location": "https://t/"]) }),
            ("/same", { req in VideoResponse(status: 200, finalUrl: req.url) }),
            ("/moved", { _ in VideoResponse(status: 200, finalUrl: "https://t/2") }),
        ]))
        let target = try await http.expandRedirect("https://h/r")
        XCTAssertEqual(target, "https://t/")
        let same = try await http.expandRedirect("https://h/same")
        XCTAssertNil(same)
        let moved = try await http.expandRedirect("https://h/moved")
        XCTAssertEqual(moved, "https://t/2")
    }

    func testPostFormEncodesInOrder() async throws {
        let transport = FakeTransport(json: [("/f", "ok")])
        let body = try await VideoHttp(transport: transport).postForm("https://h/f", form: [("b", "1 中"), ("a", "x&y")])
        XCTAssertEqual(body, "ok")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(String(decoding: request.body ?? Data(), as: UTF8.self), "b=1+%E4%B8%AD&a=x%26y")
    }

    func testExtractInlineJson() {
        let html = "<script>window.x.y=1;window.x = {\"a\":1};</script><script>window.x = 2</script>"
        XCTAssertEqual(VideoHttp.extractInlineJson(html, key: "window.x"), "{\"a\":1};")
        XCTAssertNil(VideoHttp.extractInlineJson("window.y = 1", key: "window.y"))
    }

    func testSecureUrl() {
        XCTAssertEqual(VideoHttp.secureUrl("//a/b"), "https://a/b")
        XCTAssertEqual(VideoHttp.secureUrl("http://a/b"), "https://a/b")
        XCTAssertEqual(VideoHttp.secureUrl("https://a/b"), "https://a/b")
    }

    func testSanitizeName() {
        XCTAssertEqual(VideoFileName.sanitize(" a/b:c\u{1}? "), "a_b_c__")
        let long = String(repeating: "x", count: 130) + ".mp4"
        XCTAssertEqual(VideoFileName.sanitize(long), String(repeating: "x", count: 100) + ".mp4")
    }
}

final class VideoCatalogTests: XCTestCase {
    func testRegistryAndPlatformFacts() {
        let parsers = VideoParsers(http: VideoHttp(transport: FakeTransport([])))
        XCTAssertEqual(parsers.supportedPlatforms, [.douyin, .kuaishou, .weibo, .acfun, .bilibili, .xhs, .pixiv])
        XCTAssertEqual(parsers.of(.douyin)?.platform, .douyin)
        XCTAssertEqual(Set(parsers.all.map(\.platform)), Set(VideoPlatform.allCases))
        XCTAssertEqual(parsers.of(.pixiv)?.platform, .pixiv)
        XCTAssertEqual(VideoPlatform.fromName("BILIBILI"), .bilibili)
        XCTAssertNil(VideoPlatform.fromName("bilibili"))
        XCTAssertEqual(VideoPlatform.xhs.loginViewportWidth, 1280)
        XCTAssertFalse(VideoPlatform.kuaishou.needsLogin)
        XCTAssertTrue(VideoPlatform.pixiv.needsLogin)
    }

    func testDescriptionsHideCookiesAndTokens() {
        let media = VideoMedia(url: "https://c/x?sign=SECRET", kind: .video, headers: ["Cookie": "SESSDATA=SECRET"])
        XCTAssertFalse("\(media)".contains("SECRET"))
        XCTAssertFalse(String(reflecting: media).contains("SECRET"))
    }

    func testUserMessages() {
        XCTAssertEqual(VideoParseException(.blocked, "detail").userMessage, "平台风控拦截了本次请求，请稍后重试")
        XCTAssertEqual(VideoParseException(.unsupported, "").userMessage, "暂不支持该链接")
        XCTAssertEqual(VideoParseException(.unknown, "boom").userMessage, "boom")
    }
}

final class AcFunParserTests: XCTestCase {
    private let link = DetectedVideoLink(platform: .acfun, kind: "ac", id: "42", url: "https://www.acfun.cn/v/ac42")

    /// An ajaxpipe page escapes the whole blob once, so the nested ksPlayJson string is escaped twice.
    private func page(_ reps: Int) -> String {
        let list = (0..<reps).map { #"{\"url\":\"https://m/\#($0).m3u8\"}"# }.joined(separator: ",")
        let json = #"{"title":"标/题","description":"d","coverUrl":"https://c/1.jpg","createTime":"2024-12-1","user":{"name":"up"},"currentVideoInfo":{"ksPlayJson":"{\"adaptationSet\":[{\"representation\":["# + list + #"]}]}"}};"#
        let escaped = json.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "window.videoInfo = \(escaped)</script>"
    }

    func testPicksFourthRepresentation() async throws {
        let transport = FakeTransport(json: [("acfun.cn", page(5))])
        let parser = AcFunParser(http: VideoHttp(transport: transport), timeZone: TimeZone(identifier: "UTC")!)
        let result = try await parser.parse(link, cookie: "c=1")
        XCTAssertEqual(result.medias.first?.url, "https://m/3.m3u8")
        XCTAssertEqual(result.medias.first?.isHls, true)
        XCTAssertEqual(result.medias.first?.fileName, "标_题.mp4")
        XCTAssertEqual(result.medias.first?.headers["Cookie"], "c=1")
        XCTAssertEqual(result.author, "up")
        XCTAssertEqual(result.timestampSeconds, 1_733_011_200)
        XCTAssertEqual(transport.requests.first?.url, "https://www.acfun.cn/v/ac42?quickViewId=videoInfo_new&ajaxpipe=1")
    }

    func testShortListTakesFirstAndMissingPageIsNotFound() async throws {
        let parser = AcFunParser(http: VideoHttp(transport: FakeTransport(json: [("acfun.cn", page(2))])))
        let result = try await parser.parse(link, cookie: "")
        XCTAssertEqual(result.medias.first?.url, "https://m/0.m3u8")
        XCTAssertNil(result.medias.first?.headers["Cookie"])

        let empty = AcFunParser(http: VideoHttp(transport: FakeTransport(json: [("acfun.cn", "<html>")])))
        do {
            _ = try await empty.parse(link, cookie: "")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(kind(of: error), .notFound)
        }
    }
}

final class KuaishouParserTests: XCTestCase {
    private func parser(_ page: String, redirect: String = "https://v.m.chenzhongtech.com/fw/long-video/1?x=1") -> (KuaishouParser, FakeTransport) {
        let transport = FakeTransport([
            ("fw/photo", { _ in VideoResponse(status: 200, body: page) }),
            ("kuaishou.com", { _ in VideoResponse(status: 302, headers: ["Location": redirect]) }),
        ])
        return (KuaishouParser(http: VideoHttp(transport: transport)), transport)
    }

    private let link = DetectedVideoLink(platform: .kuaishou, kind: "photo", id: "abc", url: "https://www.kuaishou.com/f/abc")

    func testVideoAndAtlasUsingFirstPhotoInDocumentOrder() async throws {
        let page = #"""
        <script>window.INIT_STATE = {"zz":{"other":1},"yy":{"photo":{"caption":"标题","userName":"ㅤ作者 ","headUrl":"https://h","timestamp":1700000000000,"mainMvUrls":[{"url":""},{"url":"https://v/1.mp4"}],"coverUrls":[{"url":"https://c"}],"ext_params":{"atlas":{"cdnList":[{"cdn":"cdn.k"}],"list":["a.jpg","","b.jpg"]}}}},"aa":{"photo":{"caption":"wrong"}}};</script>
        """#
        let (parser, transport) = parser(page)
        let result = try await parser.parse(link, cookie: "k=1")
        XCTAssertEqual(result.title, "标题")
        XCTAssertEqual(result.author, "作者")
        XCTAssertEqual(result.timestampSeconds, 1_700_000_000)
        XCTAssertEqual(result.medias.map(\.url), ["https://v/1.mp4", "https://cdn.k/a.jpg", "https://cdn.k/b.jpg"])
        XCTAssertEqual(result.medias.map(\.fileName), ["标题.mp4", "标题_1.jpg", "标题_2.jpg"])
        // The long-video redirect target is requested as /fw/photo/, with the iPhone UA and Cookie.
        let last = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(last.url, "https://v.m.chenzhongtech.com/fw/photo/1?x=1")
        XCTAssertEqual(last.headers["User-Agent"], VideoHttp.uaIphone)
        XCTAssertEqual(last.headers["Cookie"], "k=1")
        XCTAssertEqual(transport.requests.first?.followRedirects, false)
    }

    func testMissingStateAndPhotoAreUnknown() async {
        for page in ["<html>", "window.INIT_STATE = {\"a\":{}}</script>", "window.INIT_STATE = oops[</script>"] {
            do {
                _ = try await parser(page).0.parse(link, cookie: "")
                XCTFail("expected a throw")
            } catch {
                XCTAssertEqual(kind(of: error), .unknown)
            }
        }
    }
}

final class PixivParserTests: XCTestCase {
    private let link = DetectedVideoLink(platform: .pixiv, kind: "artwork", id: "9", url: "https://www.pixiv.net/artworks/9")
    private let info = #"{"error":false,"body":{"title":"t","userName":"u","description":"d","createDate":"2024-01-01T12:00:00+09:00","illustType":0,"urls":{"original":"https://i.pximg.net/one.png"}}}"#

    func testPagesKeepExtensionsAndReferer() async throws {
        let transport = FakeTransport(json: [
            ("/pages", #"{"body":[{"urls":{"original":"https://i.pximg.net/a_p0.png"}},{"urls":{"original":"https://i.pximg.net/a_p1.jpg?x=1"}}]}"#),
            ("/illust/9", info),
        ])
        let result = try await PixivParser(http: VideoHttp(transport: transport)).parse(link, cookie: "")
        XCTAssertEqual(result.medias.map(\.fileName), ["t_1.png", "t_2.jpg"])
        XCTAssertEqual(result.medias.first?.headers["Referer"], "https://www.pixiv.net/")
        XCTAssertEqual(result.timestampSeconds, 1_704_078_000)
        XCTAssertEqual(result.cover, "https://i.pximg.net/a_p0.png")
    }

    func testFallsBackToFirstImage() async throws {
        let transport = FakeTransport(json: [("/pages", #"{"body":[]}"#), ("/illust/9", info)])
        let result = try await PixivParser(http: VideoHttp(transport: transport)).parse(link, cookie: "")
        XCTAssertEqual(result.medias.map(\.fileName), ["t.png"])
    }

    func testErrorMapping() async {
        let cases: [(String, String, VideoParseErrorKind, String)] = [
            ("Work not found", "", .notFound, "not found"),
            ("Please login", "c", .unsupported, "登录态已失效"),
            ("restricted", "", .unsupported, "需要登录后"),
            ("restricted", "c", .blocked, "restricted"),
        ]
        for (message, cookie, expected, hint) in cases {
            let transport = FakeTransport(json: [("/illust/9", "{\"error\":true,\"message\":\"\(message)\"}")])
            do {
                _ = try await PixivParser(http: VideoHttp(transport: transport)).parse(link, cookie: cookie)
                XCTFail("expected a throw")
            } catch {
                XCTAssertEqual(kind(of: error), expected)
                XCTAssertTrue((error as? VideoParseException)?.message.contains(hint) ?? false)
            }
        }
    }

    func testUgoiraIsUnsupported() async {
        let transport = FakeTransport(json: [("/illust/9", #"{"body":{"illustType":2}}"#)])
        do {
            _ = try await PixivParser(http: VideoHttp(transport: transport)).parse(link, cookie: "")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(kind(of: error), .unsupported)
        }
    }

    func testValidateCookieProbesBehaviour() async throws {
        func probe(_ handler: @escaping FakeTransport.Handler, _ cookie: String = "c") async throws -> String? {
            let transport = FakeTransport([("dashboard", handler)])
            return try await PixivParser(http: VideoHttp(transport: transport)).validateCookie(cookie)
        }
        let wall = try await probe { _ in VideoResponse(status: 302, headers: ["Location": "http://www.pixiv.net/?return_to=%2F"]) }
        XCTAssertNil(wall)
        let ok = try await probe { _ in VideoResponse(status: 200) }
        XCTAssertEqual(ok, "")
        let other = try await probe { _ in VideoResponse(status: 302, headers: ["Location": "/en/dashboard"]) }
        XCTAssertEqual(other, "")
        let failed = try await probe { _ in throw URLError(.timedOut) }
        XCTAssertEqual(failed, "")
        let blank = try await probe({ _ in VideoResponse(status: 200) }, " ")
        XCTAssertNil(blank)
    }
}

final class BilibiliParserTests: XCTestCase {
    private let link = DetectedVideoLink(platform: .bilibili, kind: "video", id: "BV1xx411c7mD", url: "https://www.bilibili.com/video/BV1xx411c7mD")
    private let view = #"{"code":0,"data":{"bvid":"BV1xx411c7mD","title":"标题","pic":"//i0/p.jpg","desc":"d","pubdate":1700000000,"owner":{"name":"up","face":"https://f"},"pages":[{"cid":77}]}}"#
    private let durl = #"{"code":0,"data":{"quality":64,"durl":[{"url":"//d/1.mp4","size":123}],"accept_quality":[64,16],"accept_description":["高清",""]}}"#
    private let dash = #"""
    {"code":0,"data":{"support_formats":[{"quality":64,"new_description":"720P 高清"},{"quality":80,"new_description":"","display_desc":"1080P"}],
    "dash":{"video":[
      {"id":80,"codecid":12,"baseUrl":"https://hevc/80.m4s"},
      {"id":80,"codecid":7,"baseUrl":"https://x.mcdn.bilivideo.cn:8082/80.m4s","backupUrl":["https://upos-sz-mirror/80.m4s"]},
      {"id":64,"codecid":7,"base_url":"https://avc/64.m4s"}],
    "audio":[{"id":30216,"baseUrl":"https://a/low"},{"id":30280,"baseUrl":null,"base_url":"//a/high"}]}}}
    """#

    private func transport(play: @escaping FakeTransport.Handler) -> FakeTransport {
        let view = view
        return FakeTransport([("web-interface/view", { _ in VideoResponse(status: 200, body: view) }), ("playurl", play)])
    }

    func testAnonymousUsesSingleFile() async throws {
        let durl = durl
        let transport = transport { _ in VideoResponse(status: 200, body: durl) }
        let result = try await BilibiliParser(http: VideoHttp(transport: transport)).parse(link, cookie: "")
        let media = try XCTUnwrap(result.medias.first)
        XCTAssertEqual(media.url, "https://d/1.mp4")
        XCTAssertEqual(media.size, 123)
        XCTAssertEqual(media.quality, "720P")
        XCTAssertEqual(result.cover, "https://i0/p.jpg")
        XCTAssertEqual(result.selectedQn, 64)
        XCTAssertEqual(result.qualities, [VideoQuality(qn: 64, label: "高清"), VideoQuality(qn: 16, label: "360P")])
        XCTAssertEqual(transport.requests.filter { $0.url.contains("fnval=4048") }.count, 0)
        XCTAssertTrue(transport.requests[1].url.contains("cid=77&qn=80&fnval=1"))
    }

    func testLoggedInPicksAvcOfficialMirrorBestAudioAndPreview() async throws {
        let (dash, durl) = (dash, durl)
        let transport = transport { req in
            VideoResponse(status: 200, body: req.url.contains("fnval=4048") ? dash : durl)
        }
        let result = try await BilibiliParser(http: VideoHttp(transport: transport)).parse(link, cookie: "S=1")
        let media = try XCTUnwrap(result.medias.first)
        XCTAssertEqual(media.url, "https://upos-sz-mirror/80.m4s")
        XCTAssertEqual(media.audioUrl, "https://a/high")
        XCTAssertEqual(media.previewUrl, "https://d/1.mp4")
        XCTAssertEqual(media.quality, "1080P")
        XCTAssertEqual(media.audioHeaders["Cookie"], "S=1")
        XCTAssertEqual(result.selectedQn, 80)
        XCTAssertEqual(result.qualities.map(\.label), ["1080P", "720P 高清"])
        XCTAssertTrue(transport.requests[1].url.contains("qn=120&fnval=4048"))
    }

    func testChosenQualityFallsToNearestLower() async throws {
        let (dash, durl) = (dash, durl)
        let transport = transport { req in
            VideoResponse(status: 200, body: req.url.contains("fnval=4048") ? dash : durl)
        }
        let parser = BilibiliParser(http: VideoHttp(transport: transport))
        let exact = try await parser.parseWithQuality(link, cookie: "S=1", qn: 64)
        XCTAssertEqual(exact.selectedQn, 64)
        let lower = try await parser.parseWithQuality(link, cookie: "S=1", qn: 74)
        XCTAssertEqual(lower.selectedQn, 64)
        let below = try await parser.parseWithQuality(link, cookie: "S=1", qn: 16)
        XCTAssertEqual(below.selectedQn, 80)
    }

    func testDashFailureFallsBackToSingleFile() async throws {
        let durl = durl
        let transport = transport { req in
            if req.url.contains("fnval=4048") { return VideoResponse(status: 500) }
            return VideoResponse(status: 200, body: durl)
        }
        let result = try await BilibiliParser(http: VideoHttp(transport: transport)).parse(link, cookie: "S=1")
        XCTAssertEqual(result.medias.first?.audioUrl, "")
        XCTAssertEqual(result.medias.first?.url, "https://d/1.mp4")
    }

    func testAvIdAndApiErrors() async {
        let transport = FakeTransport(json: [("view", #"{"code":-404,"message":"gone"}"#)])
        let av = DetectedVideoLink(platform: .bilibili, kind: "video", id: "av170001", url: "u")
        do {
            _ = try await BilibiliParser(http: VideoHttp(transport: transport)).parse(av, cookie: "")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(kind(of: error), .notFound)
        }
        XCTAssertEqual(transport.requests.first?.url, "https://api.bilibili.com/x/web-interface/view?aid=170001")
    }

    func testBangumiWithoutStreamsIsUnsupported() async {
        let transport = transport { _ in VideoResponse(status: 200, body: #"{"code":-10403,"message":"x"}"#) }
        do {
            _ = try await BilibiliParser(http: VideoHttp(transport: transport)).parse(link, cookie: "")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(kind(of: error), .unsupported)
        }
    }

    func testValidateCookie() async throws {
        func probe(_ body: String) async throws -> String? {
            let transport = FakeTransport(json: [("nav", body)])
            return try await BilibiliParser(http: VideoHttp(transport: transport)).validateCookie("c")
        }
        let good = try await probe(#"{"data":{"isLogin":true,"uname":"me"}}"#)
        XCTAssertEqual(good, "me")
        let bad = try await probe(#"{"data":{"isLogin":false}}"#)
        XCTAssertNil(bad)
    }

    func testCancellationIsNotSwallowedByDashFallback() async {
        let transport = transport { _ in throw CancellationError() }
        do {
            _ = try await BilibiliParser(http: VideoHttp(transport: transport)).parse(link, cookie: "S=1")
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

@MainActor
final class FakePage: HeadlessPage {
    var currentURL: String?
    var onLoadFailed: (() -> Void)?
    var onLoadFinished: (() -> Void)?
    var scripts: [String] = []
    var loads: [String] = []
    var reloads = 0
    /// Probes turn true after this many evaluations.
    var readyAfter = 0
    var extractResult: Any? = "payload"
    var probes: [String] = []
    private var evaluations = 0

    func setDocumentStartScripts(_ scripts: [String]) { self.scripts = scripts }

    func load(_ url: String) {
        loads.append(url)
        currentURL = url
    }

    func reload() { reloads += 1 }

    func evaluate(_ script: String) async -> Any? {
        if script.contains("__thermoSessionToken") {
            probes.append(script)
            evaluations += 1
            return evaluations > readyAfter
        }
        return extractResult
    }
}

/// A page whose web process stopped answering.
@MainActor
final class HangingPage: HeadlessPage {
    var currentURL: String?
    var onLoadFailed: (() -> Void)?
    var onLoadFinished: (() -> Void)?
    func setDocumentStartScripts(_ scripts: [String]) {}
    func load(_ url: String) {}
    func reload() {}

    func evaluate(_ script: String) async -> Any? {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        return nil
    }
}

@MainActor
final class HeadlessWebViewTests: XCTestCase {
    private func extract(_ view: HeadlessWebView, timeout: TimeInterval = 2, url: String = "https://s/a") async -> String? {
        await view.loadAndExtract(
            url: url, userAgent: "ua", readyCheckJS: "'true'", extractJS: "1",
            timeout: timeout, pollInterval: 0.005, documentStartJS: ["hook()"]
        )
    }

    func testPollsUntilReadyThenExtracts() async {
        let page = FakePage()
        page.readyAfter = 3
        let view = HeadlessWebView(parkDelay: 60) { page }
        let result = await extract(view)
        XCTAssertEqual(result, "payload")
        XCTAssertEqual(page.loads, ["https://s/a"])
        XCTAssertEqual(page.scripts, ["window.__thermoSessionToken='t1';", "hook()"])
        XCTAssertEqual(page.probes.count, 4)
    }

    func testReusedPageReloadsSameURLAndTokensAdvance() async {
        let page = FakePage()
        let view = HeadlessWebView(parkDelay: 60) { page }
        _ = await extract(view)
        _ = await extract(view)
        _ = await extract(view, url: "https://s/b")
        XCTAssertEqual(page.reloads, 1)
        XCTAssertEqual(page.loads, ["https://s/a", "https://s/b"])
        XCTAssertTrue(page.scripts[0].contains("'t3'"))
        XCTAssertTrue(page.probes.last?.contains("'t3'") ?? false)
    }

    func testTimeoutAndUnavailableReturnNil() async {
        let page = FakePage()
        page.readyAfter = .max
        let timedOut = await extract(HeadlessWebView(parkDelay: 60) { page }, timeout: 0.03)
        XCTAssertNil(timedOut)
        let unavailable = await extract(HeadlessWebView(parkDelay: 60) { nil })
        XCTAssertNil(unavailable)
    }

    func testLoadFailureEndsSession() async {
        let page = FakePage()
        page.readyAfter = .max
        let view = HeadlessWebView(parkDelay: 60) { page }
        let task = Task { await extract(view, timeout: 5) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        page.onLoadFailed?()
        let result = await task.value
        XCTAssertNil(result)
    }

    func testConcurrentRequestsRunOneAtATime() async {
        let page = FakePage()
        page.readyAfter = 3
        let view = HeadlessWebView(parkDelay: 60) { page }
        async let first = extract(view, url: "https://s/1")
        async let second = extract(view, url: "https://s/2")
        let results = await [first, second]
        XCTAssertEqual(results, ["payload", "payload"])
        XCTAssertEqual(Set(page.loads), ["https://s/1", "https://s/2"])
    }

    func testParksWhenIdleAndPrewarmParksAfterLoad() async {
        let page = FakePage()
        let view = HeadlessWebView(parkDelay: 0.01) { page }
        await view.prewarm(url: "https://s/home")
        XCTAssertEqual(page.loads, ["https://s/home"])
        page.onLoadFinished?()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(page.loads.last, "about:blank")
        // A second prewarm leaves the existing page alone.
        await view.prewarm(url: "https://s/other")
        XCTAssertEqual(page.loads.count, 2)
    }

    func testWedgedEvaluationStillTimesOut() async {
        let page = HangingPage()
        let result = await extract(HeadlessWebView(parkDelay: 60) { page }, timeout: 0.05)
        XCTAssertNil(result)
    }

    func testCancellationEndsWedgedEvaluation() async {
        let page = HangingPage()
        let view = HeadlessWebView(parkDelay: 60) { page }
        let task = Task { await extract(view, timeout: 30) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }

    /// A site's challenge depends on timers. Animation frames are not asserted: under `swift test`
    /// the page reports `hidden` and they never fire, even in an opaque window.
    func testRealWebViewRunsTimersAndSendsSafariUserAgent() async {
        let view = HeadlessWebView(parkDelay: 60)
        let result = await view.loadAndExtract(
            url: "data:text/html,<script>setTimeout(function(){window.__t=1},50)</script>",
            userAgent: "ua",
            readyCheckJS: "window.__t===1",
            extractJS: "navigator.userAgent",
            timeout: 10,
            pollInterval: 0.05,
            documentStartJS: []
        )
        XCTAssertTrue(result?.contains("Safari/605.1.15") ?? false, result ?? "nil")
    }

    /// Pages try to open the Douyin app; the refused deep link must not end the session.
    func testRealWebViewSurvivesRefusedDeepLink() async {
        let view = HeadlessWebView(parkDelay: 60)
        let result = await view.loadAndExtract(
            url: "data:text/html,<script>setTimeout(function(){location.href='snssdk1128://x'},10);setTimeout(function(){window.__t=1},300)</script>",
            userAgent: "ua",
            readyCheckJS: "window.__t===1",
            extractJS: "'alive'",
            timeout: 10,
            pollInterval: 0.05,
            documentStartJS: []
        )
        XCTAssertEqual(result, "alive")
    }

    func testProbeRequiresTokenAndStrictTruth() {
        let probe = HeadlessWebView.probeJS("check()", token: "t9")
        XCTAssertTrue(probe.contains("window.__thermoSessionToken!=='t9'"))
        XCTAssertTrue(probe.contains("r===true||r==='true'"))
    }

    /// Runs the real WKWebView on a data URL: no network, no accounts.
    func testRealWebViewRunsDocumentStartHookAndExtracts() async {
        let view = HeadlessWebView(parkDelay: 60)
        let result = await view.loadAndExtract(
            url: "data:text/html,<p>hi</p>",
            userAgent: "ua",
            readyCheckJS: "document.readyState==='complete'",
            extractJS: "({hook:window.__hook,text:document.body.innerText})",
            timeout: 15,
            pollInterval: 0.05,
            documentStartJS: ["window.__hook='early';"]
        )
        XCTAssertEqual(result, #"{"hook":"early","text":"hi"}"#)
    }
}

final class VideoRedirectTests: XCTestCase {
    private func proposal(_ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        for (name, value) in ["Cookie": "c", "Authorization": "a", "X-Token": "t", "Referer": "r", "User-Agent": "ua", "Range": "bytes=0-"] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    func testRefusesHttpsToHttp() {
        XCTAssertNil(VideoRedirect.next(proposal("http://a.test/x"), from: URL(string: "https://a.test/y")))
    }

    func testCrossOriginKeepsOnlyAllowlist() throws {
        for target in ["https://b.test/x", "https://a.test:8443/x"] {
            let next = try XCTUnwrap(VideoRedirect.next(proposal(target), from: URL(string: "https://a.test/y")))
            XCTAssertEqual(Set(next.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []), ["user-agent", "range"])
        }
    }

    func testSameOriginKeepsHeaders() throws {
        let next = try XCTUnwrap(VideoRedirect.next(proposal("https://A.test:443/x"), from: URL(string: "https://a.test/y")))
        XCTAssertEqual(next.value(forHTTPHeaderField: "X-Token"), "t")
    }
}
