import XCTest
@testable import CloudDriveKit

/// Replays scripted responses and records requests. The bodies are rebuilt from the field
/// shapes documented in QuarkApi.kt; none of them were captured from the live service.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    typealias Rule = (match: String, response: HTTPResponse)
    private let lock = NSLock()
    private var rules: [Rule]
    private var fallback: HTTPResponse?
    private(set) var requests: [HTTPRequest] = []

    init(_ rules: [Rule] = [], fallback: HTTPResponse? = nil) {
        self.rules = rules
        self.fallback = fallback
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        if let index = rules.firstIndex(where: { request.url.absoluteString.contains($0.match) }) {
            return rules.remove(at: index).response
        }
        if let fallback { return fallback }
        throw DriveError.transport(code: -1)
    }

    func paths() -> [String] { requests.map(\.url.path) }
    func body(_ index: Int) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[index].body)) as? [String: Any])
    }
}

func json(_ text: String, setCookies: [String] = [], status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, setCookies: setCookies, body: Data(text.utf8))
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [T] = []
    func add(_ value: T) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return stored }
}

let cookie = DriveCredential("__pus=SECRETP; __puus=SECRETU")
let session = ShareSession(platform: .quark, shareId: "abc", accessToken: "st+k/n=", title: "t")
let sharedFile = DriveFile(id: "f1", name: "a.bin", size: 100, isDirectory: false, parentId: "p1", fileToken: "ft1")

func provider(_ transport: FakeTransport, updates: Box<(DriveCredential, DriveCredential)>? = nil, sleeps: Box<UInt64>? = nil) -> QuarkProvider {
    QuarkProvider(api: QuarkAPI(transport: transport, credentialUpdated: { updates?.add(($0, $1)) }, sleep: { sleeps?.add($0) }))
}

final class ShareLinkRouterTests: XCTestCase {
    func testRoutesEverySupportedDrive() {
        let cases: [(String, DrivePlatform, String)] = [
            ("https://pan.quark.cn/s/abc123", .quark, "abc123"),
            ("https://drive.uc.cn/s/abc123", .uc, "abc123"),
            ("https://pan.xunlei.com/s/VO_a-b", .xunlei, "VO_a-b"),
            ("https://yun.139.com/shareweb/#/w/i/link1", .c139, "link1"),
            ("https://www.123pan.com/s/2785Vv-T4Ded", .pan123, "2785Vv-T4Ded"),
            ("https://1.share.123pan.cn/123pan/ab-cd", .pan123, "ab-cd"),
            ("https://www.123pan.cn/api/srr?sk=ab-cd&st=s", .pan123, "ab-cd"),
            ("https://115cdn.com/s/swabc123", .pan115, "swabc123"),
            ("https://www.guangyapan.com/s/a_b-c", .guangya, "a_b-c"),
            ("https://www.ilanzou.com/s/abc", .ilanzou, "abc"),
            ("https://wwi.lanzoui.com/iabc", .lanzou, "iabc"),
        ]
        for (text, platform, id) in cases {
            let link = ShareLinkRouter.parse(text)
            XCTAssertEqual(link?.platform, platform, text)
            XCTAssertEqual(link?.shareId, id, text)
        }
    }

    func testPasscodeSourcesAndTrailingPunctuation() {
        XCTAssertEqual(ShareLinkRouter.parse("看这个 https://pan.quark.cn/s/abc?pwd=x1y2。")?.passcode, "x1y2")
        XCTAssertEqual(ShareLinkRouter.parse("链接 https://pan.quark.cn/s/abc 提取码：Ab12")?.passcode, "Ab12")
        XCTAssertEqual(ShareLinkRouter.parse("https://115.com/s/swabc123?password=p123")?.passcode, "p123")
        XCTAssertEqual(ShareLinkRouter.parse("https://lanzou.com/iabc?pass=zz11")?.passcode, "zz11")
        let command = ShareLinkRouter.parse("https://115.com/sws8lxs36jf-n307/")
        XCTAssertEqual(command, ParsedShareLink(shareId: "sws8lxs36jf", passcode: "n307", platform: .pan115))
    }

    func testBaiduAndUnknownLinksAreNotRecognised() {
        XCTAssertNil(ShareLinkRouter.parse("https://pan.baidu.com/s/1abc?pwd=1234"))
        XCTAssertNil(ShareLinkRouter.parse("https://example.com/s/abc"))
        XCTAssertNil(ShareLinkRouter.parse("no link"))
    }

    func testRoutingReportsMissingProvider() throws {
        let router = ShareLinkRouter(providers: [provider(FakeTransport())])
        XCTAssertEqual(try router.route("https://pan.quark.cn/s/abc").provider.platform, .quark)
        XCTAssertThrowsError(try router.route("https://drive.uc.cn/s/abc")) { XCTAssertEqual($0 as? DriveError, .providerUnavailable(.uc)) }
        XCTAssertThrowsError(try router.route("nothing")) { XCTAssertEqual($0 as? DriveError, .invalidShareLink) }
    }
}

final class HTTPLayerTests: XCTestCase {
    func testQueryEncodingMatchesURLEncoder() {
        XCTAssertEqual(HTTPClient.encodeQueryValue("a+b/c= d*-._"), "a%2Bb%2Fc%3D+d*-._")
    }

    func testSessionPersistsNothing() {
        let configuration = URLSessionTransport.makeConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
    }

    func testFoldedSetCookieIsSplit() throws {
        let url = URL(string: "https://drive-pc.quark.cn/x")!
        let folded = "__puus=new; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/, __pus=two; Path=/"
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": folded]))
        XCTAssertEqual(Set(URLSessionTransport.setCookies(from: response)), ["__puus=new", "__pus=two"])
    }

    func testRedirectToAnotherHostDropsCredentials() {
        var request = URLRequest(url: URL(string: "https://evil.example/x")!)
        request.setValue("secret", forHTTPHeaderField: "Cookie")
        request.setValue("secret", forHTTPHeaderField: "Authorization")
        let stripped = URLSessionTransport.redirected(request, from: URL(string: "https://drive-pc.quark.cn/y"))
        XCTAssertNil(stripped.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(stripped.value(forHTTPHeaderField: "Authorization"))
        let same = URLSessionTransport.redirected(request, from: URL(string: "https://evil.example/z"))
        XCTAssertEqual(same.value(forHTTPHeaderField: "Cookie"), "secret")
    }

    func testNothingPrintsSecrets() throws {
        let link = ResolvedLink(url: URL(string: "https://d/x?sig=SECRETS")!, headers: ["Cookie": "SECRETC"], fileId: "f", filename: "n", size: 1)
        for value in [cookie as Any, session as Any, link as Any] {
            var dumped = ""
            dump(value, to: &dumped)
            let text = "\(value) \(String(reflecting: value)) \(dumped)"
            XCTAssertFalse(text.contains("SECRET"), text)
            XCTAssertFalse(text.contains("st+k"), text)
        }
    }
}

final class QuarkProviderTests: XCTestCase {
    func testCookieHelpers() {
        XCTAssertEqual(QuarkCookieUtil.merge("a=1; __puus=old", setCookies: ["__puus=new; Path=/", "__pus=p; Secure", "x=y"]), "a=1; __puus=new; __pus=p")
        XCTAssertEqual(QuarkCookieUtil.withoutPuus("a=1; __puus=old; __pus=p"), "a=1; __pus=p")
        XCTAssertTrue(QuarkConstants.isValidCookie("__pus=1; __puus=2"))
        XCTAssertFalse(QuarkConstants.isValidCookie("__pus=1"))
    }

    func testAccountState() async {
        let good = provider(FakeTransport([("/account/info", json(#"{"success":true,"data":{"nickname":"Leo"}}"#))]))
        let result = await good.accountState(credential: cookie)
        XCTAssertEqual(result, .signedIn(nickname: "Leo"))
        let failed = await provider(FakeTransport()).accountState(credential: cookie)
        XCTAssertEqual(failed, .unverified)
        let missing = await provider(FakeTransport()).accountState(credential: DriveCredential("a=1"))
        XCTAssertEqual(missing, .signedOut)
    }

    func testOpenSharePrefersTypedPasscode() async throws {
        let transport = FakeTransport([("sharepage/token", json(#"{"status":200,"data":{"stoken":"st","title":"T","first_fid":"x"}}"#)),
                                       ("sharepage/token", json(#"{"status":200,"data":{"stoken":"st","title":"T"}}"#))])
        let p = provider(transport)
        let link = ParsedShareLink(shareId: "abc", passcode: "link", platform: .quark)
        let opened = try await p.openShare(link, passcode: "  ", credential: nil)
        XCTAssertEqual(opened.accessToken, "st")
        _ = try await p.openShare(link, passcode: "typed", credential: cookie)
        XCTAssertEqual(transport.requests[0].url.absoluteString, "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc")
        XCTAssertEqual(try transport.body(0)["passcode"] as? String, "link")
        XCTAssertEqual(try transport.body(0)["support_visit_limit_private_share"] as? Bool, true)
        XCTAssertEqual(try transport.body(1)["passcode"] as? String, "typed")
        XCTAssertEqual(transport.requests[1].headers["User-Agent"], QuarkConstants.apiUserAgent)
    }

    func testServerMessagesPassThrough() async {
        let cases: [(HTTPResponse, DriveError)] = [
            (json(#"{"status":400,"message":"提取码错误"}"#), .api(message: "提取码错误")),
            (json("<html>", status: 403), .api(message: "响应解析失败（HTTP 403）")),
            (json(#"{"status":200}"#), .api(message: "响应缺少 data")),
        ]
        for (response, expected) in cases {
            do {
                _ = try await provider(FakeTransport(fallback: response)).openShare(ParsedShareLink(shareId: "a", passcode: nil, platform: .quark), passcode: nil, credential: nil)
                XCTFail("expected a failure")
            } catch { XCTAssertEqual(error as? DriveError, expected) }
        }
    }

    func testShareListingUsesSourceURLAndStopsOnRepeatedPage() async throws {
        let page = json(#"{"status":200,"data":{"list":[{"fid":"f1","file_name":"a","size":5,"dir":false,"pdir_fid":"0","share_fid_token":"t","updated_at":1700}]}}"#)
        let transport = FakeTransport(fallback: page)
        let files = try await provider(transport).listShareFiles(session: session, directoryId: nil, credential: cookie)
        XCTAssertEqual(files, [DriveFile(id: "f1", name: "a", size: 5, isDirectory: false, parentId: "0", fileToken: "t", modifiedAt: "1700")])
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].url.absoluteString,
            "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/detail?pr=ucpro&fr=pc&pwd_id=abc&stoken=st%2Bk%2Fn%3D&pdir_fid=0&ver=2&force=0&_page=1&_size=50&_fetch_banner=0&_fetch_share=0&fetch_relate_conversation=0&_fetch_total=1&_sort=file_type:asc,file_name:asc")
        XCTAssertEqual(transport.requests[0].headers["Origin"], "https://pan.quark.cn")
        XCTAssertEqual(transport.requests[0].headers["Referer"], "https://pan.quark.cn/")
    }

    func testOwnListingPagesPastFifty() async throws {
        let full = (0..<50).map { #"{"fid":"a\#($0)","file_name":"n","size":1,"dir":true}"# }.joined(separator: ",")
        let transport = FakeTransport([("_page=1&", json(#"{"status":200,"data":{"list":[\#(full)]}}"#)),
                                       ("_page=2&", json(#"{"status":200,"data":{"list":[{"fid":"z","fname":"old"}]}}"#)),
                                       ("_page=3&", json(#"{"status":200,"data":{"list":[]}}"#))])
        let files = try await provider(transport).listFiles(directoryId: "d", credential: cookie)
        XCTAssertEqual(files.count, 51)
        XCTAssertEqual(files.last?.name, "old")
        XCTAssertEqual(transport.requests[0].url.absoluteString,
            "https://drive-pc.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&uc_param_str=&pdir_fid=d&_page=1&_size=50&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type:asc,updated_at:desc&fetch_all_file=1&fetch_risk_file_name=1")
    }

    func testResolveFileUsesRotatedCookieInHeaders() async throws {
        let updates = Box<(DriveCredential, DriveCredential)>()
        let transport = FakeTransport([("file/download", json(#"{"status":200,"data":[{"fid":"f","file_name":"a.mkv","download_url":"https://dl.example/a?sign=1","size":9}]}"#, setCookies: ["__puus=NEW; Path=/"]))])
        let link = try await provider(transport, updates: updates).resolveFile(id: "f", credential: cookie)
        XCTAssertEqual(link.url.absoluteString, "https://dl.example/a?sign=1")
        XCTAssertEqual(link.headers, ["Cookie": "__pus=SECRETP; __puus=NEW", "User-Agent": QuarkConstants.apiUserAgent, "Referer": "https://pan.quark.cn/"])
        XCTAssertEqual(link.filename, "a.mkv")
        XCTAssertEqual(link.size, 9)
        XCTAssertEqual(updates.values.first?.0.value, "__pus=SECRETP; __puus=NEW")
        XCTAssertEqual(updates.values.first?.1, cookie)
        XCTAssertEqual(transport.requests[0].url.absoluteString, "https://drive-pc.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc&sys=win32&ve=3.23.2")
    }

    func testDownloadFailureKeepsCode() async {
        let transport = FakeTransport(fallback: json(#"{"code":21001,"message":"file not found"}"#))
        do {
            _ = try await provider(transport).resolveFile(id: "f", credential: cookie)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "file not found", code: 21001)) }
    }

    func testGuestLinkCarriesAndReusesPugs() async throws {
        let ok = #"{"status":200,"data":[{"fid":"f1","filename":"a","download_url":"https://dl-guest.example/a","size":1}]}"#
        let transport = FakeTransport([("file/download", json(ok, setCookies: ["__pugs=G1; Path=/"])), ("file/download", json(ok))])
        let p = provider(transport)
        let first = try await p.resolveShareFile(session: session, file: sharedFile, credential: nil, options: .init())
        let second = try await p.resolveShareFile(session: session, file: sharedFile, credential: DriveCredential(" "), options: .init())
        XCTAssertNil(transport.requests[0].headers["Cookie"])
        XCTAssertEqual(transport.requests[1].headers["Cookie"], "__pugs=G1")
        XCTAssertEqual(first.headers["Cookie"], "__pugs=G1")
        XCTAssertEqual(second.headers["Cookie"], "__pugs=G1")
        let body = try transport.body(0)
        XCTAssertEqual(body["fids"] as? [String], ["f1"])
        XCTAssertEqual(body["fids_token"] as? [String], ["ft1"])
        XCTAssertEqual(body["pwd_id"] as? String, "abc")
        XCTAssertEqual(body["stoken"] as? String, "st+k/n=")
        XCTAssertEqual(body["speedup_session"] as? String, "")
        XCTAssertEqual(body["token"] as? String, "")
    }

    func testGuestSizeLimitMessage() async {
        let transport = FakeTransport(fallback: json(#"{"code":23018,"message":"x"}"#))
        do {
            _ = try await provider(transport).resolveShareFile(session: session, file: sharedFile, credential: nil, options: .init())
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? DriveError, .api(message: "该文件超出游客可获取的大小上限（夸克实测约 50MB），请先登录夸克网盘再下载", code: 23018))
        }
    }

    func testNoSaveSuccessMakesOneRequest() async throws {
        let transport = FakeTransport([("file/download", json(#"{"status":200,"data":[{"fid":"f1","download_url":"https://dl.example/a"}]}"#))])
        let link = try await provider(transport).resolveShareFile(session: session, file: sharedFile, credential: cookie, options: .init())
        XCTAssertNil(link.cleanupDirectoryId)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].headers["Cookie"], cookie.value)
    }

    func saveFlowRules() -> [FakeTransport.Rule] {
        [("file/download", json(#"{"code":31001,"message":"denied"}"#)),
         ("clouddrive/member", json(#"{"data":{"use_capacity":10,"total_capacity":1000}}"#)),
         ("file?pr=ucpro&fr=pc&pdir_fid=0&page=1&size=100", json(#"{"status":200,"data":{"list":[{"fid":"tmp","file_name":"Thermo临时转存","dir":true}]}}"#)),
         ("file?pr=ucpro&fr=pc", json(#"{"status":200,"data":{"fid":"sub"}}"#)),
         ("sharepage/save", json(#"{"status":200,"data":{"task_id":"t+1"}}"#)),
         ("clouddrive/task", json(#"{"status":200,"data":{"status":0}}"#)),
         ("clouddrive/task", json(#"{"status":200,"data":{"status":2,"save_as":{"save_as_top_fids":["saved"]}}}"#)),
         ("file/download", json(#"{"status":200,"data":[{"fid":"saved","download_url":"https://dl.example/s"}]}"#))]
    }

    func testFailedNoSaveFallsBackToUniqueTempDirectory() async throws {
        let sleeps = Box<UInt64>()
        let transport = FakeTransport(saveFlowRules())
        let link = try await provider(transport, sleeps: sleeps).resolveShareFile(session: session, file: sharedFile, credential: cookie, options: .init())
        XCTAssertEqual(link.cleanupDirectoryId, "sub")
        XCTAssertEqual(link.fileId, "saved")
        XCTAssertEqual(sleeps.values, [1_000_000_000])
        XCTAssertEqual(transport.paths().map { $0.replacingOccurrences(of: "/1/clouddrive", with: "") },
                       ["/file/download", "/member", "/file", "/file", "/share/sharepage/save", "/task", "/task", "/file/download"])
        let folder = try transport.body(3)
        XCTAssertEqual(folder["pdir_fid"] as? String, "tmp")
        XCTAssertEqual(folder["dir_init_lock"] as? Bool, false)
        XCTAssertNotNil((folder["file_name"] as? String)?.range(of: #"^tr_\d+_\d+$"#, options: .regularExpression))
        let save = try transport.body(4)
        XCTAssertEqual(save["to_pdir_fid"] as? String, "sub")
        XCTAssertEqual(save["pdir_fid"] as? String, "p1")
        XCTAssertEqual(save["fid_token_list"] as? [String], ["ft1"])
        XCTAssertEqual(save["scene"] as? String, "link")
        XCTAssertTrue(transport.requests[5].url.absoluteString.hasSuffix("&task_id=t%2B1&retry_index=0"))
        XCTAssertEqual(try transport.body(7)["fids"] as? [String], ["saved"])
    }

    func testSpaceCheckStopsBeforeTouchingTheDrive() async {
        let transport = FakeTransport([("clouddrive/member", json(#"{"data":{"use_capacity":950,"total_capacity":1000}}"#))])
        do {
            _ = try await provider(transport).saveToDrive(session: session, file: sharedFile, directoryId: nil, credential: cookie, skipSpaceCheck: false)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? DriveError, .insufficientSpace(required: 100, available: 50))
            XCTAssertEqual(error.localizedDescription, "剩余空间不足：需要 100 B，当前可用 50 B")
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testBatchSpaceSkipsUnknownSizes() async throws {
        let transport = FakeTransport(fallback: json(#"{"data":{"use_capacity":0,"total_capacity":1000}}"#))
        let p = provider(transport)
        let unknown = try await p.ensureBatchSpace(sizes: [1, 0], credential: cookie)
        XCTAssertFalse(unknown)
        XCTAssertEqual(transport.requests.count, 0)
        let known = try await p.ensureBatchSpace(sizes: [1, 2], credential: cookie)
        XCTAssertTrue(known)
    }

    func testSaveTimesOutAfterTenPolls() async {
        let sleeps = Box<UInt64>()
        let transport = FakeTransport([("sharepage/save", json(#"{"status":200,"data":{"task_id":"t"}}"#))], fallback: json(#"{"status":200,"data":{"status":0}}"#))
        do {
            _ = try await provider(transport, sleeps: sleeps).saveToDrive(session: session, file: sharedFile, directoryId: "d", credential: cookie, skipSpaceCheck: true)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .timedOut("转存超时，请稍后重试")) }
        XCTAssertEqual(sleeps.values.count, 10)
    }

    func testRefreshStripsPuusAndReturnsRotatedCookie() async throws {
        let transport = FakeTransport([("clouddrive/config", json("{}", setCookies: ["__puus=FRESH"]))])
        let refreshed = await provider(transport).refreshCredential(cookie)
        XCTAssertEqual(refreshed?.value, "__pus=SECRETP; __puus=FRESH")
        XCTAssertEqual(transport.requests[0].headers["Cookie"], "__pus=SECRETP")
        XCTAssertEqual(transport.requests[0].headers["Referer"], "https://pan.quark.cn/")
    }

    func testFileManagementBodies() async throws {
        let transport = FakeTransport([("file/delete", json(#"{"status":200,"data":{"task_id":"d"}}"#)),
                                       ("file/rename", json(#"{"status":200}"#)),
                                       ("file/move", json(#"{"status":200,"data":{"task_id":"m"}}"#))])
        let p = provider(transport)
        await p.cleanup(directoryId: "sub", credential: cookie)
        let renamed = await p.api.renameFile(fid: "f", newName: "n", cookie: cookie.value)
        XCTAssertTrue(renamed)
        let moved = try await p.api.moveFile(fid: "f", toPdirFid: "d", cookie: cookie.value)
        XCTAssertEqual(moved, "m")
        XCTAssertEqual(try transport.body(0)["action_type"] as? Int, 2)
        XCTAssertEqual(try transport.body(0)["filelist"] as? [String], ["sub"])
        XCTAssertEqual(try transport.body(1)["file_name"] as? String, "n")
        XCTAssertEqual(try transport.body(2)["action_type"] as? Int, 1)
        XCTAssertEqual(try transport.body(2)["to_pdir_fid"] as? String, "d")
    }

    func testCreateShareWaitsForTaskAndReadsInfo() async throws {
        let transport = FakeTransport([("share/password", json(#"{"status":200,"data":{"share_url":"u","passcode":"p","pwd_id":"i","title":"t","expired_type":3}}"#)),
                                       ("clouddrive/share?", json(#"{"status":200,"data":{"task_id":"s"}}"#)),
                                       ("clouddrive/task", json(#"{"status":200,"data":{"status":2,"share_id":"sid"}}"#))])
        let api = provider(transport).api
        let id = try await api.createShare(fidList: ["f"], title: " ", urlType: 2, passcode: "pw", expiredType: 3, cookie: cookie.value)
        XCTAssertEqual(id, "sid")
        XCTAssertEqual(try transport.body(0)["title"] as? String, "分享文件")
        XCTAssertEqual(try transport.body(0)["support_error_code"] as? [String], ["41060"])
        let info = try await api.getShareInfo(shareId: "sid", cookie: cookie.value)
        XCTAssertEqual(info, QuarkShareInfo(shareURL: "u", passcode: "p", pwdId: "i", title: "t", expiredType: 3))
    }

    func testUnsupportedFeaturesFailClearly() async {
        struct Stub: CloudDriveProvider {
            let platform = DrivePlatform.lanzou
            let capabilities: DriveCapabilities = [.shareListing]
            func isWellFormed(credential: DriveCredential) -> Bool { true }
            func accountState(credential: DriveCredential?) async -> DriveAccountState { .signedOut }
            func openShare(_ link: ParsedShareLink, passcode: String?, credential: DriveCredential?) async throws -> ShareSession { session }
            func listShareFiles(session: ShareSession, directoryId: String?, credential: DriveCredential?) async throws -> [DriveFile] { [] }
            func resolveShareFile(session: ShareSession, file: DriveFile, credential: DriveCredential?, options: ShareResolveOptions) async throws -> ResolvedLink { throw DriveError.loginRequired }
        }
        do {
            _ = try await Stub().saveToDrive(session: session, file: sharedFile, directoryId: nil, credential: cookie, skipSpaceCheck: false)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .unsupported(platform: .lanzou, feature: "转存")) }
        XCTAssertNil(Stub().parseShareLink("https://pan.quark.cn/s/abc"))
    }
}

final class HTTPRedirectTests: XCTestCase {
    private func proposal(_ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        for (name, value) in ["Cookie": "c", "Authorization": "a", "X-Auth-Token": "t", "User-Agent": "ua"] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    func testCrossOriginKeepsOnlyAllowlist() {
        for target in ["https://b.test/x", "http://a.test/x", "https://a.test:8443/x"] {
            let next = URLSessionTransport.redirected(proposal(target), from: URL(string: "https://a.test/y"))
            XCTAssertEqual(Set(next.allHTTPHeaderFields?.keys.map { $0.lowercased() } ?? []), ["user-agent"], target)
        }
    }

    func testSameOriginKeepsHeaders() {
        let next = URLSessionTransport.redirected(proposal("https://a.test:443/x"), from: URL(string: "https://a.test/y"))
        XCTAssertEqual(next.value(forHTTPHeaderField: "X-Auth-Token"), "t")
    }
}
