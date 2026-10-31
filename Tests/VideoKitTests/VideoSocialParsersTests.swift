import Foundation
import XCTest
@testable import VideoKit

private func failureKind(_ work: () async throws -> VideoParseResult) async -> VideoParseErrorKind? {
    do {
        _ = try await work()
        return nil
    } catch {
        return (error as? VideoParseException)?.kind
    }
}

private struct FakeHeadless: HeadlessFetching {
    var result: String?

    func loadAndExtract(
        url: String, userAgent: String, readyCheckJS: String, extractJS: String,
        timeout: TimeInterval, pollInterval: TimeInterval, documentStartJS: [String]
    ) async -> String? {
        XCTAssertEqual(timeout, 40)
        XCTAssertEqual(documentStartJS.count, 1)
        return result
    }

    func prewarm(url: String) async {}
}

final class DouyinParserTests: XCTestCase {
    private let link = DetectedVideoLink(
        platform: .douyin, kind: "video", id: "7123456789012", url: "https://www.douyin.com/note/7123456789012"
    )

    private func parser(_ browser: String?, _ transport: FakeTransport = FakeTransport([])) -> DouyinParser {
        DouyinParser(http: VideoHttp(transport: transport), headless: FakeHeadless(result: browser))
    }

    func testBrowserImagesKeepMotionPairsAligned() async throws {
        let json = #"{"title":"标题","author":"A","images":["https://p/1.webp","https://p/2.webp","https://p/3"],"motions":["","https://v/2",""],"video":"","cover":""}"#
        let result = try await parser(json).parse(link, cookie: "")
        XCTAssertEqual(result.medias.map(\.fileName), ["标题_1.webp", "标题_2.jpg", "标题_3.jpg"])
        XCTAssertEqual(result.medias.map(\.motionUrl), ["", "https://v/2", ""])
        XCTAssertEqual(result.medias[1].quality, "动图")
        XCTAssertEqual(result.cover, "https://p/1.webp")
        XCTAssertNil(result.medias[0].headers["Cookie"])
    }

    func testBrowserVideoFallsBackToIdName() async throws {
        let json = #"{"title":"","images":[],"motions":[],"video":"https://v/play","cover":"https://c"}"#
        let result = try await parser(json).parse(link, cookie: "")
        XCTAssertEqual(result.medias.first?.kind, .video)
        XCTAssertEqual(result.medias.first?.fileName, "douyin_7123456789012.mp4")
        XCTAssertEqual(result.cover, "https://c")
    }

    private func shareHtml(_ item: String) -> String {
        #"<script>window._ROUTER_DATA = {"loaderData":{"video_(id)/page":{"videoInfoRes":{"item_list":[\#(item)]}}}}</script>"#
    }

    private func ttwidRoute() -> (String, FakeTransport.Handler) {
        ("ttwid.bytedance.com", { _ in
            VideoResponse(status: 200, body: "{}", headers: ["Set-Cookie": "other=1, ttwid=1%7Cabc; Path=/"])
        })
    }

    func testFallbackPicksLargestRatioAndSendsNamedCookie() async throws {
        let item = #"{"desc":"片","create_time":17,"video":{"play_addr":{"uri":"vid1","url_list":["https://x/playwm/1"]},"cover":{"url_list":["https://c"]}},"author":{"nickname":"N","avatar_thumb":{"url_list":["https://a"]}}}"#
        let transport = FakeTransport([
            ttwidRoute(),
            ("iesdouyin.com/share", { [html = shareHtml(item)] _ in VideoResponse(status: 200, body: html) }),
            ("ratio=1080p", { _ in VideoResponse(status: 503) }),
            ("ratio=720p", { _ in VideoResponse(status: 206, headers: ["content-range": "bytes 0-1/900"], finalUrl: "https://cdn/720") }),
            ("ratio=540p", { _ in VideoResponse(status: 206, headers: ["Content-Length": "100"], finalUrl: "https://cdn/540") }),
            ("ratio=360p", { _ in throw URLError(.timedOut) }),
        ])
        let result = try await parser(nil, transport).parse(link, cookie: "")
        XCTAssertEqual(result.medias.first?.url, "https://cdn/720")
        XCTAssertEqual(result.medias.first?.size, 900)
        XCTAssertEqual(result.author, "N")
        XCTAssertEqual(result.timestampSeconds, 17)
        // A note link keeps its page type.
        let page = transport.requests.first { $0.url.contains("/share/") }
        XCTAssertTrue(page?.url.hasSuffix("/share/note/7123456789012/") ?? false)
        XCTAssertEqual(page?.headers["Cookie"], "ttwid=1%7Cabc")
    }

    func testFallbackRenewsTtwidOnceThenReportsDetail() async {
        let empty = #"<script>window._ROUTER_DATA = {"loaderData":{"video_(id)/page":{"isSpider":true}}}</script>"#
        let transport = FakeTransport([
            ttwidRoute(),
            ("iesdouyin.com/share", { _ in VideoResponse(status: 200, body: empty) }),
        ])
        do {
            _ = try await parser(nil, transport).parse(link, cookie: "")
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue("\(error)".contains("isSpider=true"))
        }
        XCTAssertEqual(transport.requests.filter { $0.url.contains("ttwid") }.count, 2)
        XCTAssertEqual(transport.requests.filter { $0.url.contains("/share/") }.count, 2)
    }

    func testBlockedShareIsNotRetried() async {
        let transport = FakeTransport([ttwidRoute(), ("iesdouyin.com/share", { _ in VideoResponse(status: 403) })])
        let found = await failureKind { try await parser(nil, transport).parse(link, cookie: "") }
        XCTAssertEqual(found, .blocked)
        XCTAssertEqual(transport.requests.filter { $0.url.contains("ttwid") }.count, 1)
    }

    func testFallbackImagesAndWatermarkFallback() async throws {
        let images = #"{"desc":"","images":[{"url_list":["","https://i/1"]},{"url_list":[]}]}"#
        let imageParser = parser(nil, FakeTransport([ttwidRoute(), ("/share/", { [html = shareHtml(images)] _ in VideoResponse(status: 200, body: html) })]))
        let imageResult = try await imageParser.parse(link, cookie: "")
        XCTAssertEqual(imageResult.medias.map(\.url), ["https://i/1"])

        let video = #"{"desc":"","video":{"playAddr":{"urlList":["https://x/playwm/?video_id=v2"]}}}"#
        let videoParser = parser(nil, FakeTransport([ttwidRoute(), ("/share/", { [html = shareHtml(video)] _ in VideoResponse(status: 200, body: html) })]))
        let videoResult = try await videoParser.parse(link, cookie: "")
        XCTAssertEqual(videoResult.medias.first?.url, "https://x/play/?video_id=v2")
        XCTAssertEqual(videoResult.medias.first?.size, -1)
    }

    /// The exact scripts must survive real JavaScriptCore, on a page with SSR data and no network.
    @MainActor
    func testScriptsRunInRealWebView() async throws {
        let detail = #"{"app":{"videoDetail":{"desc":"文案","authorInfo":{"nickname":"作者"},"images":[{"urlList":["https://p/1"]},{"url_list":["https://p/2"],"video":{"playAddr":[{"src":"https://v/2"}]}}]}}}"#
        let encoded = try XCTUnwrap(detail.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let html = "<html><body><img src='https://x.douyinpic.com/a?biz_tag=aweme_images'><script id='RENDER_DATA' type='application/json'>\(encoded)</script></body></html>"
        let page = try XCTUnwrap(Data(html.utf8).base64EncodedString() as String?)
        let view = HeadlessWebView(parkDelay: 60)
        let result = await view.loadAndExtract(
            url: "data:text/html;base64,\(page)",
            userAgent: VideoHttp.uaChrome,
            readyCheckJS: DouyinScripts.readyCheck,
            extractJS: DouyinScripts.extract,
            timeout: 15,
            pollInterval: 0.05,
            documentStartJS: [DouyinScripts.detailHook]
        )
        let object = try XCTUnwrap(VideoJSON.parseObject(try XCTUnwrap(result)))
        XCTAssertEqual(object.str("src"), "ssr")
        XCTAssertEqual(object.str("title"), "文案")
        XCTAssertEqual(object.str("author"), "作者")
        XCTAssertEqual(object.optArray("motions")?.optString(1), "https://v/2")
        XCTAssertEqual(object.optArray("motions")?.optString(0), "")
    }
}

final class WeiboParserTests: XCTestCase {
    private func json(_ body: String) -> FakeTransport {
        FakeTransport([("statuses/show", { _ in
            VideoResponse(status: 200, body: body, headers: ["Content-Type": "application/json; charset=utf-8"])
        })])
    }

    private let status = DetectedVideoLink(platform: .weibo, kind: "status", id: "Pabc", url: "https://m.weibo.cn/detail/Pabc")

    func testStatusVideoImagesAndMotion() async throws {
        let transport = json(#"""
        {"data":{"bid":"Pabc","text":"a<br />b<a href='x'>c</a>","created_at":"Thu Oct 02 14:39:33 +0800 2025",
        "user":{"id":5,"screen_name":"S","profile_image_url":"https://a"},
        "page_info":{"title":"T/1","page_pic":{"url":"https://c"},"urls":{"mp4_hd_mp4":"//f/hd","mp4_ld_mp4":"//f/ld"}},
        "pics":[{"large":{"url":"https://i/1"},"videoSrc":"https://v/1"},{"large":{}},{"large":{"url":"https://i/2"}}]}}
        """#)
        let result = try await WeiboParser(http: VideoHttp(transport: transport)).parse(status, cookie: "SUB=x")
        XCTAssertEqual(result.medias.map(\.url), ["https://f/hd", "https://i/1", "https://i/2"])
        XCTAssertEqual(result.medias.map(\.fileName), ["T_1.mp4", "T_1_1.jpg", "T_1_2.jpg"])
        XCTAssertEqual(result.medias[1].quality, "动图")
        XCTAssertEqual(result.medias[1].motionUrl, "https://v/1")
        XCTAssertEqual(result.medias[2].quality, "原图")
        XCTAssertEqual(result.text, "a\nbc")
        XCTAssertEqual(result.timestampSeconds, 1_759_387_173)
        XCTAssertEqual(result.url, "https://weibo.com/5/Pabc")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertFalse(request.followRedirects)
        XCTAssertEqual(request.headers["Cookie"], "SUB=x")
    }

    func testRepostUsedOnlyWhenOuterHasNoMedia() async throws {
        let result = try await WeiboParser(http: VideoHttp(transport: json(#"""
        {"data":{"retweeted_status":{"pics":[{"large":{"url":"https://i/r"}}]}}}
        """#))).parse(status, cookie: "")
        XCTAssertEqual(result.medias.map(\.url), ["https://i/r"])
    }

    func testStatusFailures() async {
        for (response, expected) in [
            (VideoResponse(status: 302), VideoParseErrorKind.unknown),
            (VideoResponse(status: 418), .blocked),
            (VideoResponse(status: 404), .notFound),
            (VideoResponse(status: 200, body: "<html>", headers: ["content-type": "text/html"]), .blocked),
            (VideoResponse(status: 200, body: "{}", headers: ["content-type": "application/json"]), .notFound),
        ] {
            let parser = WeiboParser(http: VideoHttp(transport: FakeTransport([("statuses", { _ in response })])))
            let found = await failureKind { try await parser.parse(status, cookie: "") }
            XCTAssertEqual(found, expected)
        }
    }

    func testFidTakesFirstBitrateInDocumentOrder() async throws {
        let transport = FakeTransport(json: [("api/component", #"""
        {"data":{"Component_Play_Playinfo":{"title":"视频","text":"<b>x</b>\n\ny ","real_date":"1700000000000",
        "cover_image":"//c/1","urls":{"高清 1080P":"//f/1080","标清":"//f/480"},"stream_url":"//f/low",
        "reward":{"user":{"name":"U"}}}}}
        """#)])
        let link = DetectedVideoLink(platform: .weibo, kind: "fid", id: "1034:5001", url: "https://video.weibo.com/show?fid=1034:5001")
        let result = try await WeiboParser(http: VideoHttp(transport: transport)).parse(link, cookie: "")
        XCTAssertEqual(result.medias.first?.url, "https://f/1080")
        XCTAssertEqual(result.text, "xy")
        XCTAssertEqual(result.timestampSeconds, 1_700_000_000)
        XCTAssertEqual(result.cover, "https://c/1")
        XCTAssertEqual(result.author, "U")
        let body = String(decoding: try XCTUnwrap(transport.requests.first?.body), as: UTF8.self)
        XCTAssertTrue(body.hasPrefix("data=%7B%22Component_Play_Playinfo"))
    }

    func testTvConvertsMidAndUnknownKindRefused() async {
        let transport = json("{}")
        let link = DetectedVideoLink(platform: .weibo, kind: "tv", id: "5145615399845897", url: "u")
        _ = await failureKind { try await WeiboParser(http: VideoHttp(transport: transport)).parse(link, cookie: "") }
        XCTAssertTrue(transport.requests.first?.url.contains("id=\(WeiboParser.mid2id("5145615399845897"))&") ?? false)
        let other = DetectedVideoLink(platform: .weibo, kind: "x", id: "1", url: "u")
        let found = await failureKind { try await WeiboParser(http: VideoHttp(transport: transport)).parse(other, cookie: "") }
        XCTAssertEqual(found, .unsupported)
    }

    func testMidConversionAndDates() {
        // 3 groups: 3|0013|... values worked by hand from the base62 alphabet.
        XCTAssertEqual(WeiboParser.mid2id("0"), "0")
        XCTAssertEqual(WeiboParser.mid2id("62"), "10")
        XCTAssertEqual(WeiboParser.mid2id("10000062"), "10010")
        XCTAssertEqual(WeiboParser.parseRealDate("1700000000"), 1_700_000_000)
        XCTAssertGreaterThan(WeiboParser.parseRealDate("2025-01-02 10:00"), 0)
        XCTAssertEqual(WeiboParser.parseRealDate("nope"), 0)
        XCTAssertEqual(WeiboParser.parseWeiboTime("bad"), 0)
    }
}

final class XhsParserTests: XCTestCase {
    private let link = DetectedVideoLink(
        platform: .xhs, kind: "note", id: "66abc0123456",
        url: "https://www.xiaohongshu.com/explore/66abc0123456?xsec_token=SECRET"
    )

    private func page(_ state: String) -> String { "<script>window.__INITIAL_STATE__ = \(state)</script>" }

    private func explore(_ note: String) -> String {
        page(#"{"note":{"noteDetailMap":{"66abc0123456":{"note":\#(note)}}},"x":undefined}"#)
    }

    func testWatermarkConversion() {
        XCTAssertEqual(
            XhsParser.watermarkFreeOrRaw("http://h.xhscdn.com/202501/0f5e/img/abc!nd_dft"),
            "https://sns-img-bd.xhscdn.com/img/abc"
        )
        XCTAssertEqual(XhsParser.watermarkFreeOrRaw("https://h/abc"), "https://h/abc")
        XCTAssertEqual(XhsParser.watermarkFreeOrRaw(""), "")
    }

    func testExploreImagesFallBackOnlyOnMissing() async throws {
        let html = explore(#"{"title":"图","desc":"d","time":1700000000000,"user":{"nickname":"N","avatar":"https://a"},"imageList":[{"urlDefault":"https://h/1/2/ok!s"},{"urlDefault":"https://h/1/2/gone!s"},{"urlDefault":"https://h/1/2/flaky!s"}]}"#)
        let transport = FakeTransport([
            ("/explore/", { _ in VideoResponse(status: 200, body: html, finalUrl: "https://www.xiaohongshu.com/explore/x") }),
            ("xhscdn.com/ok", { _ in VideoResponse(status: 200) }),
            ("xhscdn.com/gone", { _ in VideoResponse(status: 404) }),
            ("xhscdn.com/flaky", { _ in throw URLError(.timedOut) }),
        ])
        let result = try await XhsParser(http: VideoHttp(transport: transport)).parse(link, cookie: "web_session=x")
        XCTAssertEqual(result.medias.map(\.url), [
            "https://sns-img-bd.xhscdn.com/ok", "https://h/1/2/gone!s", "https://sns-img-bd.xhscdn.com/flaky",
        ])
        XCTAssertTrue(result.notice.hasPrefix("1 张"))
        XCTAssertEqual(result.author, "N")
        XCTAssertEqual(result.timestampSeconds, 1_700_000_000)
        XCTAssertTrue(transport.requests[0].url.hasSuffix("?xsec_token=SECRET"))
        XCTAssertEqual(transport.requests.last?.method, "HEAD")
    }

    func testExploreVideoStreamOrderAndCover() async throws {
        let html = explore(#"{"title":"v","imageList":[{"urlDefault":"https://h/1/2/c!s"}],"video":{"media":{"stream":{"h265":[],"h264":[{"master_url":"https://v/264"}],"av1":[{"masterUrl":"https://v/av1"}]}}}}"#)
        let transport = FakeTransport(json: [("/explore/", html)])
        let result = try await XhsParser(http: VideoHttp(transport: transport)).parse(link, cookie: "")
        XCTAssertEqual(result.medias.first?.url, "https://v/264")
        XCTAssertEqual(result.medias.first?.quality, "H.264")
        XCTAssertEqual(result.cover, "https://sns-img-bd.xhscdn.com/c")
    }

    func testVideoNoteWithoutStreamFallsToDiscoveryNotImages() async throws {
        let bad = explore(#"{"video":{},"imageList":[{"urlDefault":"https://h/1/2/c!s"}]}"#)
        let good = page(#"{"noteData":{"data":{"noteData":{"title":"d","user":{"nickName":"M"},"video":{"media":{"stream":{"h265":[{"masterUrl":"https://v/d"}]}}}}},"normalNotePreloadData":{"imagesList":[{"urlSizeLarge":"https://h/1/2/p!s"}]}}}"#)
        let transport = FakeTransport(json: [("/explore/", bad), ("/discovery/item/", good)])
        let result = try await XhsParser(http: VideoHttp(transport: transport)).parse(link, cookie: "")
        XCTAssertEqual(result.author, "M")
        XCTAssertEqual(result.cover, "https://sns-img-bd.xhscdn.com/p")
        XCTAssertEqual(transport.requests[1].headers["User-Agent"], VideoHttp.uaIphone)
        XCTAssertTrue(transport.requests[1].url.hasSuffix("?xsec_token=SECRET"))
    }

    func testLoginWallStopsWithoutSecondPathAndHidesToken() async {
        let transport = FakeTransport([("/explore/", { _ in
            VideoResponse(status: 200, body: "<html>", finalUrl: "https://www.xiaohongshu.com/login?redirect=x")
        })])
        do {
            _ = try await XhsParser(http: VideoHttp(transport: transport)).parse(link, cookie: "")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual((error as? VideoParseException)?.kind, .unsupported)
            XCTAssertFalse("\(error)".contains("SECRET"))
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testNetworkFailureNeverCarriesToken() async {
        do {
            _ = try await XhsParser(http: VideoHttp(transport: FakeTransport([]))).parse(link, cookie: "")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual((error as? VideoParseException)?.kind, .network)
            XCTAssertFalse("\(error)".contains("SECRET"))
        }
    }

    func testValidateCookieProbesBehaviour() async throws {
        func verdict(_ final: String) async throws -> String? {
            let transport = FakeTransport([("/explore", { _ in VideoResponse(status: 200, finalUrl: final) })])
            return try await XhsParser(http: VideoHttp(transport: transport)).validateCookie("web_session=guest")
        }
        let loggedOut = try await verdict("https://www.xiaohongshu.com/login")
        XCTAssertNil(loggedOut)
        let loggedIn = try await verdict("https://www.xiaohongshu.com/explore")
        XCTAssertEqual(loggedIn, "")
        let offline = try await XhsParser(http: VideoHttp(transport: FakeTransport([]))).validateCookie("c")
        XCTAssertNil(offline)
        let empty = try await XhsParser(http: VideoHttp(transport: FakeTransport([]))).validateCookie(" ")
        XCTAssertNil(empty)
    }
}
