import XCTest
@testable import CloudDriveKit

/// Every response here is rebuilt from the shapes LanzouApi.kt reads; none was captured from the live
/// service, so these tests prove the port follows the source, not that Lanzou still answers this way.
final class LanzouProviderTests: XCTestCase {
    private let account = DriveCredential("ylogin=1; ylogins=2; phpdisk_info=SECRETPHP; PHPSESSID=SECRETSESS")
    private let mydisk = "<script>$.ajax({url:'/doupload.php?uid=4133097', data:{ 'vei':'B1UHVFBWVQgFB1JWAFo=' }})</script>"

    private func html(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: Data(text.utf8), headers: headers)
    }

    private func lanzou(_ transport: FakeTransport, sleeps: Box<UInt64>? = nil) -> LanzouProvider {
        LanzouProvider(api: LanzouAPI(transport: transport, sleep: { sleeps?.add($0) }))
    }

    private func firstFile(_ drive: LanzouProvider, _ session: ShareSession) async throws -> DriveFile {
        let files = try await drive.listShareFiles(session: session, directoryId: nil, credential: nil)
        return try XCTUnwrap(files.first)
    }

    private func form(_ request: HTTPRequest) -> [String: String] {
        let text = String(decoding: request.body ?? Data(), as: UTF8.self)
        return Dictionary(text.split(separator: "&").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]).removingPercentEncoding?.replacingOccurrences(of: "+", with: " ") ?? "")
        }, uniquingKeysWith: { _, last in last })
    }

    private let shareURL = "https://wwi.lanzoui.com/iabc"
    private let filePage = """
    <title>test.zip - 蓝奏云</title><div class="n">test.zip</div>
    <iframe class="ifr2" name="1" src="/fn?AbCdEf" frameborder="0"></iframe> 文件大小：1.5 M
    """
    private let iframePage = """
    <script>var ajaxdata = 'WEBKEY'; var wp_sign = 'SIGNABC'; var kdns = 0;
    $.ajax({ type: 'post', url: '/ajaxm.php?file=123456' });</script>
    """

    // MARK: Pure pieces

    func testAcwChallengeCookieMatchesTheFixedTransform() {
        XCTAssertEqual(LanzouCrypto.acwScV2("0123456789abcdef0123456789abcdef01234567"), "d2c7186598ab1a508a4f6064e4fa746323ab17c6")
        XCTAssertEqual(LanzouCrypto.challengeCookie("<script>var arg1='A1B2C3D4E5F60718293A4B5C6D7E8F9012345678';</script>"),
                       "238c0fc65ebce7b3662a78f7440e76d20b3e2611")
        XCTAssertNil(LanzouCrypto.challengeCookie("<html>plain</html>"))
    }

    func testHostFamilyAndNormalisation() {
        for host in ["wwi.lanzoui.com", "lanzouw.com", "x.lanzoux.cn", "a.b.lanzous.net", "lanzoui.org"] {
            XCTAssertTrue(LanzouConstants.isLanzouHost(host), host)
        }
        for host in ["evil.com", "lanzou.evil.com", "ilanzou.com.evil.net", "notlanzoui.com"] {
            XCTAssertFalse(LanzouConstants.isLanzouHost(host), host)
        }
        XCTAssertEqual(LanzouConstants.normalizeShareURL(" http://wwi.lanzoui.com/iabc/#frag "), "https://wwi.lanzoui.com/iabc")
        XCTAssertEqual(LanzouConstants.folderId(fromListingId: "d:12"), "12")
        XCTAssertEqual(LanzouConstants.fileId(fromListingId: "f:9"), "9")
    }

    func testParseShareLinkKeepsTheMirrorHostAndPasscode() throws {
        let link = try XCTUnwrap(lanzou(FakeTransport()).parseShareLink("文件：http://wwi.lanzoui.com/iabc/ 密码：ab12。"))
        XCTAssertEqual(link.shareId, "https://wwi.lanzoui.com/iabc")
        XCTAssertEqual(link.passcode, "ab12")
        XCTAssertNil(lanzou(FakeTransport()).parseShareLink("https://pan.quark.cn/s/abc"))
        XCTAssertEqual(LanzouAPI.parseDisplaySize("1.5 M"), 1_572_864)
        XCTAssertEqual(LanzouAPI.parseDisplaySize("10 K"), 10_240)
        XCTAssertEqual(LanzouAPI.parseDisplaySize(""), 0)
    }

    func testHTTPLayerReportsHeadersAndHeadMethod() throws {
        let url = URL(string: "https://x.example/y")!
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                                                     headerFields: ["Location": "/z", "Set-Cookie": "a=b", "Content-Length": "3"]))
        let headers = URLSessionTransport.headers(from: response)
        XCTAssertEqual(headers["location"], "/z")
        XCTAssertEqual(headers["content-length"], "3")
        XCTAssertNil(headers["set-cookie"])
        XCTAssertEqual(HTTPMethod.head.rawValue, "HEAD")
        XCTAssertTrue(HTTPRequest(method: .get, url: url).followRedirects)
    }

    // MARK: Anonymous shares

    func testSingleFileShareResolvesThroughAjaxAndHeadProbe() async throws {
        let transport = FakeTransport([
            ("wwi.lanzoui.com/iabc", html(filePage)),
            ("wwi.lanzoui.com/fn?AbCdEf", html(iframePage)),
            ("/ajaxm.php?file=123456", html(#"{"zt":1,"dom":"https://dl.example-cdn.net","url":"abc123/test.zip","inf":"test.zip"}"#)),
            ("dl.example-cdn.net/file/abc123/test.zip", html("", headers: ["Content-Length": "1572864", "Content-Type": "application/zip"])),
        ])
        let drive = lanzou(transport)
        let link = try XCTUnwrap(drive.parseShareLink("https://wwi.lanzoui.com/iabc"))
        let opened = try await drive.openShare(link, passcode: nil, credential: nil)
        XCTAssertEqual(opened.shareId, shareURL)
        XCTAssertEqual(opened.title, "test.zip")
        let files = try await drive.listShareFiles(session: opened, directoryId: nil, credential: nil)
        XCTAssertEqual(files, [DriveFile(id: "iabc", name: "test.zip", size: 1_572_864, isDirectory: false, parentId: "")])
        let resolved = try await drive.resolveShareFile(session: opened, file: files[0], credential: nil, options: ShareResolveOptions())
        XCTAssertEqual(resolved.url.absoluteString, "https://dl.example-cdn.net/file/abc123/test.zip")
        XCTAssertEqual(resolved.size, 1_572_864)
        XCTAssertEqual(resolved.filename, "test.zip")
        XCTAssertEqual(resolved.headers["Cookie"], "down_ip=1")
        XCTAssertEqual(resolved.headers["Referer"], "https://dl.example-cdn.net/")
        XCTAssertEqual(resolved.headers["User-Agent"], LanzouConstants.webUserAgent)

        let post = transport.requests[2]
        XCTAssertEqual(post.method, .post)
        XCTAssertFalse(post.followRedirects)
        XCTAssertEqual(post.url.absoluteString, "https://wwi.lanzoui.com/ajaxm.php?file=123456")
        XCTAssertEqual(form(post), ["action": "downprocess", "sign": "SIGNABC", "signs": "WEBKEY", "websignkey": "WEBKEY",
                                    "websign": "", "kd": "0", "ves": "1"])
        XCTAssertEqual(post.headers["Referer"], shareURL)
        XCTAssertEqual(post.headers["X-Requested-With"], "XMLHttpRequest")
        let head = transport.requests[3]
        XCTAssertEqual(head.method, .head)
        XCTAssertFalse(head.followRedirects)
        XCTAssertTrue(head.headers["Cookie"]?.contains("down_ip=1") == true)
    }

    func testPasscodeShareUsesAjaxfileFields() async throws {
        let withPasscode = filePage.replacingOccurrences(of: "<title>", with: "<div id=\"pwbox\"></div><title>")
        let transport = FakeTransport([
            ("wwi.lanzoui.com/iabc", html(withPasscode)),
            ("/fn?AbCdEf", html("<script>var sign='SIGNP'; url:'/ajaxm.php?file=123456'</script>")),
            ("/ajaxfile.php?file=123456", html(#"{"zt":1,"dom":"https://dl.example-cdn.net","url":"k/t.zip"}"#)),
            ("dl.example-cdn.net", html("", headers: ["content-length": "10"])),
        ])
        let drive = lanzou(transport)
        do {
            _ = try await drive.openShare(ParsedShareLink(shareId: shareURL, passcode: nil, platform: .lanzou), passcode: nil, credential: nil)
            XCTFail("a protected share needs a passcode")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "此蓝奏分享需要提取码，请填写后重新解析")) }

        let transport2 = FakeTransport([
            ("wwi.lanzoui.com/iabc", html(withPasscode)),
            ("/fn?AbCdEf", html("<script>var sign='SIGNP'; url:'/ajaxm.php?file=123456'</script>")),
            ("/ajaxfile.php?file=123456", html(#"{"zt":1,"dom":"https://dl.example-cdn.net","url":"k/t.zip"}"#)),
            ("dl.example-cdn.net", html("", headers: ["content-length": "10"])),
        ])
        let drive2 = lanzou(transport2)
        let opened = try await drive2.openShare(ParsedShareLink(shareId: shareURL, passcode: "pw12", platform: .lanzou), passcode: nil, credential: nil)
        XCTAssertEqual(opened.accessToken, "pw12")
        let file = try await firstFile(drive2, opened)
        _ = try await drive2.resolveShareFile(session: opened, file: file, credential: nil, options: ShareResolveOptions())
        XCTAssertEqual(form(transport2.requests[2]), ["action": "downprocess", "sign": "SIGNP", "p": "pw12", "kd": "1"])
        _ = transport
    }

    func testFolderSharePagesUntilTheEndMarker() async throws {
        let folderPage = """
        <title>资料 - 蓝奏云</title><div class="filemore" id="filemore"></div> filemoreajax.php
        <script>var lx = '2'; var fid = '7788'; var t = '1700000000'; var k = 'abcKEY';</script>
        """
        let transport = FakeTransport([
            ("wwi.lanzoui.com/b0folder", html(folderPage)),
            ("filemoreajax.php", html(#"{"zt":1,"text":[{"id":"i1","name_all":"x.txt","size":"10 K","time":"今天"},{"id":"i2","name":"y","size":"1 M","time":"昨天"}]}"#)),
            ("filemoreajax.php", html(#"{"zt":2,"info":"no more","text":[]}"#)),
        ])
        let drive = lanzou(transport)
        let link = try XCTUnwrap(drive.parseShareLink("https://wwi.lanzoui.com/b0folder?pwd=ab12"))
        let opened = try await drive.openShare(link, passcode: nil, credential: nil)
        let files = try await drive.listShareFiles(session: opened, directoryId: nil, credential: nil)
        XCTAssertEqual(files.map(\.id), ["i1", "i2"])
        XCTAssertEqual(files.map(\.name), ["x.txt", "y"])
        XCTAssertEqual(files.map(\.size), [10_240, 1_048_576])
        XCTAssertEqual(files[0].modifiedAt, "今天")
        XCTAssertEqual(form(transport.requests[1]), ["lx": "2", "fid": "7788", "t": "1700000000", "k": "abcKEY", "pwd": "ab12", "pg": "1"])
        XCTAssertEqual(form(transport.requests[2])["pg"], "2")
    }

    func testFolderShareErrorsAndRateLimitRetry() async throws {
        let folderPage = "<div class=\"filemore\"></div><script>var lx='1';var fid='5';var t='9';var k='k';</script>"
        func open(_ responses: [HTTPResponse], sleeps: Box<UInt64>) async throws -> [DriveFile] {
            let transport = FakeTransport([("wwi.lanzoui.com/b0x", html(folderPage))] + responses.map { ("filemoreajax.php", $0) })
            let drive = lanzou(transport, sleeps: sleeps)
            let session = try await drive.openShare(ParsedShareLink(shareId: "https://wwi.lanzoui.com/b0x", passcode: nil, platform: .lanzou), passcode: nil, credential: nil)
            return try await drive.listShareFiles(session: session, directoryId: nil, credential: nil)
        }
        let sleeps = Box<UInt64>()
        do {
            _ = try await open([html(#"{"zt":3}"#)], sleeps: sleeps)
            XCTFail("zt 3 is a wrong passcode")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "蓝奏提取码错误，请检查后重新解析")) }
        let recovered = try await open([html(#"{"zt":4}"#), html(#"{"zt":1,"text":[{"id":"a","name_all":"a","size":"1"}]}"#), html(#"{"zt":2}"#)], sleeps: sleeps)
        XCTAssertEqual(recovered.map(\.id), ["a"])
        XCTAssertEqual(sleeps.values, [300_000_000])
        do {
            _ = try await open([html(#"{"zt":4}"#), html(#"{"zt":4}"#), html(#"{"zt":4}"#)], sleeps: Box<UInt64>())
            XCTFail("a page that stays rate limited must fail")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "蓝奏请求过于频繁，请稍后再试")) }
    }

    func testAjaxErrorsMapToTheSourceMessages() async throws {
        func resolve(_ ajax: String) async throws {
            let transport = FakeTransport([
                ("wwi.lanzoui.com/iabc", html(filePage)),
                ("/fn?AbCdEf", html(iframePage)),
                ("/ajaxm.php", html(ajax)),
            ])
            let drive = lanzou(transport)
            let session = try await drive.openShare(ParsedShareLink(shareId: shareURL, passcode: nil, platform: .lanzou), passcode: nil, credential: nil)
            let file = try await firstFile(drive, session)
            _ = try await drive.resolveShareFile(session: session, file: file, credential: nil, options: ShareResolveOptions())
        }
        let cases: [(String, String)] = [
            (#"{"zt":0,"inf":"密码不正确"}"#, "蓝奏提取码错误，请检查后重新解析"),
            (#"{"zt":0,"inf":"文件取消分享了"}"#, "蓝奏文件已取消分享或不存在"),
            (#"{"zt":0,"inf":"访问次数过多"}"#, "蓝奏请求过于频繁，请稍后再试"),
            (#"{"zt":0,"inf":"?"}"#, "蓝奏解析失败，请确认分享链接和提取码后重试"),
            (#"{"zt":1,"dom":"https://d.example","url":"/absolute"}"#, "蓝奏解析失败，请确认分享链接和提取码后重试"),
            ("<html>challenge</html>", "蓝奏返回了验证页面，请稍后重试或在分享页完成验证"),
        ]
        for (body, message) in cases {
            do {
                try await resolve(body)
                XCTFail("expected \(message)")
            } catch { XCTAssertEqual(error as? DriveError, .api(message: message), body) }
        }
    }

    func testSharePageChallengeIsAnsweredAndRedirectsStayOnLanzou() async throws {
        let challenge = "<script>var arg1='A1B2C3D4E5F60718293A4B5C6D7E8F9012345678';</script>"
        let transport = FakeTransport([
            ("wwi.lanzoui.com/iabc", html(challenge)),
            ("wwi.lanzoui.com/iabc", html("", status: 302, headers: ["Location": "https://www.lanzoux.com/iabc"])),
            ("lanzoux.com/iabc", html(filePage)),
        ])
        let drive = lanzou(transport)
        let session = try await drive.openShare(ParsedShareLink(shareId: shareURL, passcode: nil, platform: .lanzou), passcode: nil, credential: nil)
        XCTAssertEqual(session.shareId, shareURL, "the session keeps the link that was opened, like the source")
        XCTAssertNil(transport.requests[0].headers["Cookie"])
        XCTAssertEqual(transport.requests[1].headers["Cookie"], "acw_sc__v2=238c0fc65ebce7b3662a78f7440e76d20b3e2611")

        let hostile = FakeTransport([("wwi.lanzoui.com/iabc", html("", status: 302, headers: ["Location": "https://evil.example/x"]))])
        do {
            _ = try await lanzou(hostile).openShare(ParsedShareLink(shareId: shareURL, passcode: nil, platform: .lanzou), passcode: nil, credential: nil)
            XCTFail("a redirect off Lanzou must stop")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "蓝奏分享链接无效")) }
        do {
            _ = try await lanzou(FakeTransport()).openShare(ParsedShareLink(shareId: "https://evil.example/iabc", passcode: nil, platform: .lanzou), passcode: nil, credential: nil)
            XCTFail("a non-Lanzou host must not be fetched")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "蓝奏分享链接无效")) }
        do {
            _ = try await lanzou(FakeTransport([("wwi.lanzoui.com", html("文件取消分享了 不存在"))])).openShare(ParsedShareLink(shareId: shareURL, passcode: nil, platform: .lanzou), passcode: nil, credential: nil)
            XCTFail("a removed share must fail")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "蓝奏文件已取消分享或不存在")) }
    }

    // MARK: Download node

    private func resolveWithNode(_ nodeResponses: [HTTPResponse], sleeps: Box<UInt64>? = nil) async throws -> (ResolvedLink, FakeTransport) {
        let transport = FakeTransport([
            ("wwi.lanzoui.com/iabc", html(filePage)),
            ("/fn?AbCdEf", html(iframePage)),
            ("/ajaxm.php", html(#"{"zt":1,"dom":"https://dl.example-cdn.net","url":"t/f.bin"}"#)),
        ] + nodeResponses.map { ("example-cdn.net", $0) })
        let drive = lanzou(transport, sleeps: sleeps)
        let session = try await drive.openShare(ParsedShareLink(shareId: shareURL, passcode: nil, platform: .lanzou), passcode: nil, credential: nil)
        let file = try await firstFile(drive, session)
        return (try await drive.resolveShareFile(session: session, file: file, credential: nil, options: ShareResolveOptions()), transport)
    }

    func testNodeRedirectIsFollowedByHand() async throws {
        let (link, transport) = try await resolveWithNode([
            html("", status: 302, headers: ["Location": "/real/f.bin"]),
            html("", status: 206, headers: ["Content-Range": "bytes 0-0/4096", "Content-Type": "application/octet-stream"]),
        ])
        XCTAssertEqual(link.url.absoluteString, "https://dl.example-cdn.net/real/f.bin")
        XCTAssertEqual(link.size, 4096)
        XCTAssertEqual(transport.requests.suffix(2).map { $0.method }, [HTTPMethod.head, HTTPMethod.head])
    }

    func testNodeChallengeIsReplayedOnTheSameURL() async throws {
        // Differs from source: LanzouApi.kt would call this a redirect loop and never replay.
        let (link, transport) = try await resolveWithNode([
            html("", headers: ["Content-Type": "text/html"]),
            html("<script>var arg1='A1B2C3D4E5F60718293A4B5C6D7E8F9012345678';</script>"),
            html("", headers: ["Content-Length": "77", "Content-Type": "application/zip"]),
        ])
        XCTAssertEqual(link.size, 77)
        let replay = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(replay.method, .head)
        XCTAssertTrue(replay.headers["Cookie"]?.contains("acw_sc__v2=238c0fc65ebce7b3662a78f7440e76d20b3e2611") == true)
        // The download headers carry only down_ip, like the source.
        XCTAssertEqual(link.headers["Cookie"], "down_ip=1")
    }

    func testNodeConfirmationPageIsSubmittedAfterTwoSeconds() async throws {
        let sleeps = Box<UInt64>()
        let confirm = "<script>$.ajax({ type:'post', url:'ajax.php', data : { 'file':'FILEB64','el':el,'sign':'SIGNB64' } });</script>验证并下载"
        let transport = FakeTransport([
            ("wwi.lanzoui.com/iabc", html(filePage)),
            ("/fn?AbCdEf", html(iframePage)),
            ("/ajaxm.php", html(#"{"zt":1,"dom":"https://dl.example-cdn.net","url":"t/f.bin"}"#)),
            ("example-cdn.net/file/t/f.bin", html("", headers: ["Content-Type": "text/html"])),
            ("example-cdn.net/file/t/f.bin", html(confirm, headers: ["Content-Type": "text/html"])),
            ("example-cdn.net/file/t/ajax.php", html(#"{"zt":1,"url":"https://dl.example-cdn.net/final/f.bin"}"#)),
            ("example-cdn.net/final/f.bin", html("", headers: ["Content-Length": "5"])),
        ])
        let drive = lanzou(transport, sleeps: sleeps)
        let session = try await drive.openShare(ParsedShareLink(shareId: shareURL, passcode: nil, platform: .lanzou), passcode: nil, credential: nil)
        let file = try await firstFile(drive, session)
        let link = try await drive.resolveShareFile(session: session, file: file, credential: nil, options: ShareResolveOptions())
        XCTAssertEqual(link.url.absoluteString, "https://dl.example-cdn.net/final/f.bin")
        XCTAssertEqual(sleeps.values, [2_000_000_000])
        let verify = try XCTUnwrap(transport.requests.first { $0.url.path == "/file/t/ajax.php" })
        XCTAssertEqual(form(verify), ["file": "FILEB64", "el": "2", "sign": "SIGNB64"])
    }

    func testNodeFailuresUseTheSourceMessages() async throws {
        let cases: [(HTTPResponse, String)] = [
            (html("", status: 404), "蓝奏下载地址已失效，请稍后重新解析"),
            (html("", status: 429), "蓝奏下载请求过于频繁，请稍后再试"),
            (html("", headers: ["Content-Type": "text/html"]), "蓝奏返回的是验证页面，未创建下载任务，请在分享页完成验证后重试"),
        ]
        for (response, message) in cases {
            do {
                _ = try await resolveWithNode([response, html("plain page")])
                XCTFail("expected \(message)")
            } catch { XCTAssertEqual(error as? DriveError, .api(message: message)) }
        }
        // An unexpected status falls back to a ranged GET before giving up.
        let (ranged, _) = try await resolveWithNode([html("", status: 500), html("", status: 206, headers: ["Content-Range": "bytes 0-8191/9999"])])
        XCTAssertEqual(ranged.size, 9999)
    }

    // MARK: Personal drive

    func testAccountStateAndWellFormedness() async {
        XCTAssertFalse(lanzou(FakeTransport()).isWellFormed(credential: DriveCredential("ylogin=1")))
        XCTAssertTrue(lanzou(FakeTransport()).isWellFormed(credential: account))
        var state = await lanzou(FakeTransport()).accountState(credential: nil)
        XCTAssertEqual(state, .signedOut)
        state = await lanzou(FakeTransport(fallback: html("", status: 302))).accountState(credential: account)
        XCTAssertEqual(state, .unverified)
        state = await lanzou(FakeTransport([("mydisk.php", html(mydisk))])).accountState(credential: account)
        XCTAssertEqual(state, .signedIn(nickname: "蓝奏云用户"))
    }

    func testOwnListingMergesFoldersAndPagedFilesAndCachesLoginParams() async throws {
        let transport = FakeTransport([
            ("mydisk.php", html(mydisk)),
            ("doupload.php", html(#"{"zt":1,"info":1,"text":[{"fol_id":"111","name":"资料","time":"2024-01-01"}]}"#)),
            ("doupload.php", html(#"{"zt":1,"text":[{"id":"900","name_all":"a.zip","name":"a","size":"1.5 M","time":"2 天前"}]}"#)),
            ("doupload.php", html(#"{"zt":2,"text":[]}"#)),
            ("doupload.php", html(#"{"zt":2,"text":[]}"#)),
            ("doupload.php", html(#"{"zt":2,"text":[]}"#)),
        ])
        let drive = lanzou(transport)
        let files = try await drive.listFiles(directoryId: nil, credential: account)
        XCTAssertEqual(files, [
            DriveFile(id: "d:111", name: "资料", size: 0, isDirectory: true, parentId: "-1", modifiedAt: "2024-01-01"),
            DriveFile(id: "f:900", name: "a.zip", size: 1_572_864, isDirectory: false, parentId: "-1", modifiedAt: "2 天前"),
        ])
        let first = transport.requests[1]
        XCTAssertEqual(first.url.absoluteString, "https://pc.woozooo.com/doupload.php?uid=4133097&vei=B1UHVFBWVQgFB1JWAFo=")
        XCTAssertEqual(first.headers["Cookie"], account.value)
        XCTAssertEqual(first.headers["Referer"], LanzouConstants.mydiskURL)
        XCTAssertEqual(form(first), ["task": "47", "folder_id": "-1"])
        XCTAssertEqual(form(transport.requests[2]), ["task": "5", "folder_id": "-1", "pg": "1"])
        XCTAssertEqual(form(transport.requests[3])["pg"], "2")

        _ = try await drive.listFiles(directoryId: "d:111", credential: account)
        XCTAssertEqual(transport.requests.filter { $0.url.path == "/mydisk.php" }.count, 1, "uid and vei are fetched once")
        XCTAssertEqual(form(transport.requests[4])["folder_id"], "111")
    }

    func testDouploadErrorCodes() async throws {
        func list(_ response: HTTPResponse) async throws {
            let drive = lanzou(FakeTransport([("mydisk.php", html(mydisk)), ("doupload.php", response)]))
            _ = try await drive.listFiles(directoryId: nil, credential: account)
        }
        let cases: [(HTTPResponse, String)] = [
            (html("", status: 403), "蓝奏登录已过期，请重新登录"),
            (html("not json"), "蓝奏文件操作失败，请在官网检查权限和文件类型"),
            (html(#"{"zt":9}"#), "蓝奏登录已过期，请重新登录"),
            (html(#"{"zt":4}"#), "蓝奏请求频繁，请稍后重试"),
            (html(#"{"zt":0}"#), "蓝奏文件操作失败（0），请在官网检查权限和文件类型"),
            (html(#"{"text":[]}"#), "蓝奏文件操作失败（-1），请在官网检查权限和文件类型"),
        ]
        for (response, message) in cases {
            do {
                try await list(response)
                XCTFail("expected \(message)")
            } catch { XCTAssertEqual(error as? DriveError, .api(message: message)) }
        }
        let invalid = lanzou(FakeTransport([("mydisk.php", html("<html>login</html>"))]))
        do {
            _ = try await invalid.listFiles(directoryId: nil, credential: account)
            XCTFail("a page without uid and vei is a dead login")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "蓝奏登录态无效，请重新登录")) }
    }

    func testAccountOperationsSendTheSourceTasks() async throws {
        let transport = FakeTransport([
            ("mydisk.php", html(mydisk)),
            ("doupload.php", html(#"{"zt":1,"text":"4455"}"#)),
            ("doupload.php", html(#"{"zt":1,"info":{"f_id":"i7abc","is_newd":"https://wwi.lanzoui.com","pwd":"x9"}}"#)),
            ("doupload.php", html(#"{"zt":1,"info":{"new_url":"b0zz","is_newd":"wwi.lanzoux.com","pwd":""}}"#)),
            ("doupload.php", html(#"{"zt":1}"#)),
            ("doupload.php", html(#"{"zt":1}"#)),
            ("doupload.php", html(#"{"zt":1}"#)),
            ("doupload.php", html(#"{"zt":1}"#)),
            ("doupload.php", html(#"{"zt":1}"#)),
        ])
        let drive = lanzou(transport)
        let api = drive.api
        let params = try await api.fetchLoginParams(cookie: account.value)
        let folder = try await api.createFolder(cookie: account.value, params: params, parentId: "-1", name: "新建")
        XCTAssertEqual(folder, "4455")
        let fileShare = try await api.createFileShare(cookie: account.value, params: params, fileId: "9")
        XCTAssertEqual(fileShare, LanzouShareInfo(shareURL: "https://wwi.lanzoui.com/i7abc", passcode: "x9", pwdId: "i7abc"))
        let folderShare = try await api.createFolderShare(cookie: account.value, params: params, folderId: "4455")
        XCTAssertEqual(folderShare.shareURL, "https://wwi.lanzoux.com/b0zz")
        try await api.renameFolder(cookie: account.value, params: params, folderId: "1", newName: "n")
        try await api.renameFile(cookie: account.value, params: params, fileId: "2", newName: "m")
        try await api.moveFile(cookie: account.value, params: params, folderId: "3", fileId: "2")
        try await api.deleteFolder(cookie: account.value, params: params, folderId: "1")
        try await api.deleteFile(cookie: account.value, params: params, fileId: "2")
        let bodies = transport.requests.dropFirst().map(form)
        XCTAssertEqual(bodies[0], ["task": "2", "parent_id": "-1", "folder_name": "新建", "folder_description": ""])
        XCTAssertEqual(bodies[1], ["task": "22", "file_id": "9"])
        XCTAssertEqual(bodies[2], ["task": "18", "file_id": "4455"])
        XCTAssertEqual(bodies[3], ["task": "4", "folder_id": "1", "folder_name": "n", "folder_description": ""])
        XCTAssertEqual(bodies[4], ["task": "46", "file_id": "2", "file_name": "m", "type": "2"])
        XCTAssertEqual(bodies[5], ["task": "20", "folder_id": "3", "file_id": "2"])
        XCTAssertEqual(bodies[6], ["task": "3", "folder_id": "1"])
        XCTAssertEqual(bodies[7], ["task": "6", "file_id": "2"])
    }

    func testOwnFileResolvesThroughAFreshShare() async throws {
        let transport = FakeTransport([
            ("mydisk.php", html(mydisk)),
            ("doupload.php", html(#"{"zt":1,"info":{"f_id":"i7abc","is_newd":"https://wwi.lanzoui.com","pwd":""}}"#)),
            ("wwi.lanzoui.com/i7abc", html(filePage)),
            ("/fn?AbCdEf", html(iframePage)),
            ("/ajaxm.php", html(#"{"zt":1,"dom":"https://dl.example-cdn.net","url":"t/f.bin"}"#)),
            ("example-cdn.net", html("", headers: ["Content-Length": "42"])),
        ])
        let link = try await lanzou(transport).resolveFile(id: "f:9", credential: account)
        XCTAssertEqual(form(transport.requests[1])["file_id"], "9")
        XCTAssertEqual(link.size, 42)
        XCTAssertEqual(link.filename, "test.zip")
    }

    func testSavingIsUnsupportedLikeTheSource() async {
        let drive = lanzou(FakeTransport())
        XCTAssertFalse(drive.capabilities.contains(.saveToDrive))
        do {
            _ = try await drive.saveToDrive(session: session, file: sharedFile, directoryId: nil, credential: account, skipSpaceCheck: false)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "蓝奏分享暂不支持直接转存，请下载后上传")) }
        let expired = ShareSession(platform: .lanzou, shareId: shareURL, accessToken: "", title: "t")
        do {
            _ = try await drive.listShareFiles(session: expired, directoryId: nil, credential: nil)
            XCTFail("a session never opened has no page")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "蓝奏分享会话已失效，请重新解析")) }
    }

    // MARK: Login

    func testPasswordLoginAnswersTheChallengeAndCollectsTheCookie() async throws {
        let challenge = "<script>var arg1='A1B2C3D4E5F60718293A4B5C6D7E8F9012345678';</script>"
        let transport = FakeTransport([
            ("accounts.woozooo.com/accounts.php", html(challenge)),
            ("accounts.woozooo.com/accounts.php", html(#"{"zt":"1","msgs":"https://pc.woozooo.com/auth.php?t=handoff"}"#)),
            ("pc.woozooo.com/auth.php", HTTPResponse(statusCode: 302, setCookies: ["ylogin=77; Path=/", "phpdisk_info=SECRETPHP; Path=/"], headers: ["Location": "/mydisk.php"])),
            ("pc.woozooo.com/mydisk.php?item=files", HTTPResponse(statusCode: 200, setCookies: ["PHPSESSID=SESS1"], body: Data(mydisk.utf8))),
            ("mydisk.php?item=files", html(mydisk)),
        ])
        let secret = "p@ss word&=1"
        let credential = try await lanzou(transport).login(account: " user ", password: secret)
        XCTAssertEqual(credential.value, "ylogin=77; phpdisk_info=SECRETPHP; PHPSESSID=SESS1")

        let first = transport.requests[0]
        XCTAssertEqual(first.method, .post)
        XCTAssertEqual(form(first), ["task": "uselogin", "username": "user", "password": secret, "ref": "pc.woozooo.com"])
        XCTAssertEqual(first.headers["Origin"], "https://accounts.woozooo.com")
        let retry = transport.requests[1]
        XCTAssertEqual(retry.headers["Cookie"], "acw_sc__v2=238c0fc65ebce7b3662a78f7440e76d20b3e2611")
        // Only the two login posts carry the password.
        XCTAssertEqual(transport.requests.filter { String(decoding: $0.body ?? Data(), as: UTF8.self).contains("password=") }.count, 2)
        XCTAssertFalse(transport.requests.contains { $0.headers.values.contains { $0.contains(secret) } })
        // The hand-off hop follows the redirect with its own host's cookies and nobody else's.
        let hops = transport.requests.map(\.url.absoluteString)
        XCTAssertEqual(hops.filter { $0.hasSuffix("/mydisk.php") }.count, 1)
        XCTAssertNil(transport.requests[2].headers["Cookie"])
    }

    func testPasswordLoginFailures() async throws {
        func attempt(_ responses: [HTTPResponse], account name: String = "u", password: String = "p") async throws {
            _ = try await lanzou(FakeTransport(responses.map { ("accounts.php", $0) })).login(account: name, password: password)
        }
        let cases: [([HTTPResponse], String, String, String)] = [
            ([html(#"{"zt":"0","msgs":"密码错误"}"#)], "u", "p", "密码错误"),
            ([html(#"{"zt":"0"}"#)], "u", "p", "蓝奏云登录失败，请检查账号密码"),
            ([html("<html>oops</html>")], "u", "p", "蓝奏云登录失败，请稍后重试"),
            ([html(#"{"zt":"1","msgs":""}"#)], "u", "p", "蓝奏云登录未获取到有效凭据，请重试"),
            ([], " ", "p", "请输入蓝奏云账号和密码"),
            ([], "u", "", "请输入蓝奏云账号和密码"),
        ]
        for (responses, name, password, message) in cases {
            do {
                try await attempt(responses, account: name, password: password)
                XCTFail("expected \(message)")
            } catch { XCTAssertEqual(error as? DriveError, .api(message: message)) }
        }
    }

    // MARK: Secrets

    func testNothingPrintsLoginSecrets() throws {
        let params = LanzouLoginParams(uid: "4133097", vei: "SECRETVEI")
        let link = LanzouDownloadLink(fid: "f", filename: "n", downloadURL: "https://d/x?sig=SECRETSIG", size: 1)
        for value in [params as Any, link as Any, account as Any] {
            var dumped = ""
            dump(value, to: &dumped)
            let text = "\(value) \(String(reflecting: value)) \(dumped)"
            XCTAssertFalse(text.contains("SECRET"), text)
            XCTAssertFalse(text.contains("4133097"), text)
        }
    }

    func testRegistrationBuildsAProviderForTheRouter() throws {
        let router = ShareLinkRouter(providers: [QuarkProvider(), .lanzou(transport: FakeTransport())])
        let routed = try router.route("https://wwi.lanzoui.com/iabc")
        XCTAssertEqual(routed.link.platform, .lanzou)
        XCTAssertEqual(routed.provider.platform, .lanzou)
    }
}
