import XCTest
@testable import CloudDriveKit

// Response bodies are rebuilt from the field shapes read in Pan115Api.kt. None was captured from the live
// service, and no test touches the network or a real account. The crypto vectors come from an independent
// Python rendering of Pan115Crypto.kt's algorithm; they prove the port matches the algorithm as read, not
// that 115's server accepts it.

/// Stands in for the server-side private key, which no test has. Encoding is visible in the form body;
/// a response `data` of `ENC:<json>` decodes to `<json>`.
struct FakeCipher: Pan115Cipher {
    func newKey() -> [UInt8] { Array(repeating: 7, count: 16) }
    func encode(_ payload: String, key: [UInt8]) throws -> String { "ENC:" + payload }
    func decode(_ data: String, key: [UInt8]) throws -> String {
        guard data.hasPrefix("ENC:") else { throw DriveError.api(message: "bad cipher text") }
        return String(data.dropFirst(4))
    }
}

let pan115Login = DriveCredential("UID=103616022_A1_169; CID=cidv; SEID=SECRETSEID; KID=kidv")
let pan115Session = ShareSession(platform: .pan115, shareId: "swabc", accessToken: "pw12|555", title: "T")
let pan115SharedFile = DriveFile(id: "F1", name: "a.bin", size: 100, isDirectory: false, parentId: "P1")

func pan115(_ transport: FakeTransport, sleeps: Box<UInt64>? = nil) -> Pan115Provider {
    let api = Pan115API(transport: transport, cipher: FakeCipher(), now: { Date(timeIntervalSince1970: 1_700_000_000) }, sleep: { sleeps?.add($0) })
    return Pan115Provider(api: api, sleep: { sleeps?.add($0) })
}

func ok(_ extra: String = "") -> HTTPResponse { json(#"{"state":true"# + extra + "}") }

final class Pan115CryptoTests: XCTestCase {
    private let key = Array(0..<16).map(UInt8.init)

    func testRequestEncodingMatchesReferenceVectors() throws {
        XCTAssertEqual(try Pan115Crypto().encode(#"{"pickcode":"abc123XYZ"}"#, key: key),
                       "g4W33su+NGj7e5buMLpwqPO2i8ZE6Z1yOwrZz4N9mI7A2s3R7QeulXBcwcpbCl74gt0hAWFZtox3b0qBmjjyoRbmtG33DlAodGZC+bPO5pVpTCdANR+EcNlkh1gJ20A+GXLBYNQvSTNBnwpfJwMQsLKRwUGlhC+l0BSnBClDrrM=")
    }

    func testMultiBlockEncodingMatchesReferenceVector() throws {
        // 16 + 200 bytes span two RSA blocks. ASCII only, so the bytes equal the reference's.
        let payload = String(decoding: (0..<200).map { UInt8(($0 * 7 + 3) % 128) }, as: UTF8.self)
        XCTAssertEqual(try Pan115Crypto().encode(payload, key: key),
                       "Q2s4Y1aiTFdm3weUM+5mTMPpJq/lprzaf20U0qbxynNVmeyafPaWyMYrDUeKKKNbrL0MYXmtpxXTRqQVMdAFhS84E/bnAng1SudtH2utz7MNQUa5Ka1KMWWx1fPZGrXFZw22WE9aS1LO3Pd3Hg1s+5s/PWs1TFJEjDivIjQqPk0GO0264xwRqNkpz4sqBUYBQYkHsA7T2gWk23imIbveKYI7lA4CqM10q+J/QTCzseHHEwmB++D4gyGXX3Imm/VpUFK7yk86uBhmjQ9ao8bufUQoC0vY5Q/SwR0nX2lLLm2rO9h37E4s2JIJEcxC3ewk4qGmvcTx1zAQKtcGAQPGFQ==")
    }

    func testModPowAgainstReferenceValue() {
        let base = Pan115BigUInt(hex: "0123456789abcdef0123456789abcdef")!
        let result = base.modPow(Pan115Crypto.exponent, modulus: Pan115Crypto.modulus).bytes(length: 128)
        XCTAssertEqual(result.map { String(format: "%02x", $0) }.joined(),
                       "7ae13f5c8c30c342283e1d7adfc508f9824a29ed7a1ebfb48393f807f1dbec6e8a9dbd8c0cd72a2ac13e21a1bd699e6baa002eb78fd949c0f10d7b7521e736b1d290706ba084ac3aa09adefcde8b4c69c6badc347516b37b6443bce2d5dfec9dc56a13e8a882809a313e7aafa5eb8b9a73e94b84ee8ce3479583e91121b56018")
    }

    func testSmallBigUIntArithmetic() {
        XCTAssertEqual(Pan115BigUInt(7).modPow(Pan115BigUInt(13), modulus: Pan115BigUInt(11)), Pan115BigUInt(2))
        XCTAssertEqual(Pan115BigUInt(0).modPow(Pan115BigUInt(5), modulus: Pan115BigUInt(11)).isZero, true)
        XCTAssertEqual(Pan115BigUInt(bytes: [1, 0, 0, 0, 0]).bytes(length: 6), [0, 1, 0, 0, 0, 0])
    }

    func testResponseUnwrapMatchesReferenceVector() throws {
        let hex = "6465666768696a6b6c6d6e6f7071727305c31ca714371ddb7057d545b8c789a7573a09862a4fdd0feedf93f04f34479a360f8854ee89c3e000790bab3a01cf53eec8dba78f4349"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)! }
        XCTAssertEqual(try Pan115Crypto.unwrap(bytes, key: key), #"{"1":{"file_name":"a.bin","url":{"url":"https://x/y"}}}"#)
        XCTAssertThrowsError(try Pan115Crypto.unwrap(Array(bytes.prefix(16)), key: key))
    }

    func testKeyMustBe16Bytes() {
        XCTAssertThrowsError(try Pan115Crypto().encode("{}", key: [1, 2, 3]))
        XCTAssertThrowsError(try Pan115Crypto().decode("AAAA", key: [1, 2, 3]))
        XCTAssertEqual(Pan115Crypto().newKey().count, 16)
    }

    func testGarbageResponseIsAnErrorNotACrash() {
        XCTAssertThrowsError(try Pan115Crypto().decode("%%%", key: key))
        XCTAssertThrowsError(try Pan115Crypto().decode("", key: key))
        // A block that is not a response decodes to junk (as in the source) rather than crashing.
        XCTAssertNoThrow(try Pan115Crypto().decode(Data(repeating: 0, count: 128).base64EncodedString(), key: key))
    }
}

final class Pan115ConstantsTests: XCTestCase {
    func testCookieHelpers() {
        let cookie = "UID=103616022_A1_169; CID=c; SEID=s"
        XCTAssertTrue(Pan115Constants.hasLoginCookie(cookie))
        XCTAssertFalse(Pan115Constants.hasLoginCookie("CID=c"))
        XCTAssertEqual(Pan115Constants.extractUserId(cookie), "103616022")
        XCTAssertTrue(Pan115Constants.isValidCookie(cookie))
        XCTAssertFalse(Pan115Constants.isValidCookie("UID=1_A1_2"))
        XCTAssertEqual(Pan115Constants.filterLoginCookies("UID=1; junk=2; CID=3; UID=dup; KID=4"), "UID=1; CID=3; KID=4")
        XCTAssertEqual(Pan115Constants.mergeCookies("a=1", "", "b=2"), "a=1; b=2")
    }

    func testShareTokenRoundTrip() {
        let token = Pan115Constants.encodeShareToken(receiveCode: "pw12", userId: "555")
        XCTAssertEqual(token, "pw12|555")
        XCTAssertTrue(Pan115Constants.decodeShareToken(token) == ("pw12", "555"))
        XCTAssertTrue(Pan115Constants.decodeShareToken("pw12") == ("pw12", ""))
    }

    func testRefererAndExpiryCodes() {
        XCTAssertEqual(Pan115Constants.shareReferer(shareCode: "swabc", receiveCode: ""), "https://115cdn.com/s/swabc")
        XCTAssertEqual(Pan115Constants.shareReferer(shareCode: "swabc", receiveCode: "pw12"), "https://115cdn.com/s/swabc?password=pw12&")
        XCTAssertEqual(Pan115ShareExpire.code(duration: "-1"), Pan115ShareExpire.forever)
        XCTAssertEqual(Pan115ShareExpire.code(duration: "5"), Pan115ShareExpire.unknown)
        XCTAssertEqual(Pan115ShareExpire.code(text: "15天"), Pan115ShareExpire.fifteenDays)
        XCTAssertEqual(Pan115ShareExpire.code(text: "长期"), Pan115ShareExpire.forever)
        XCTAssertEqual(Pan115ShareExpire.code(text: ""), Pan115ShareExpire.unknown)
    }

    func testClientVersionValidation() {
        XCTAssertTrue(Pan115Constants.isPlausibleClientVersion("36.0.10"))
        XCTAssertFalse(Pan115Constants.isPlausibleClientVersion(""))
        XCTAssertFalse(Pan115Constants.isPlausibleClientVersion("v36"))
        XCTAssertFalse(Pan115Constants.isPlausibleClientVersion("1.2.3.4.5.6.7.8.9.0"))
        XCTAssertFalse(Pan115Constants.isPlausibleClientVersion("36.0<script>"))
    }

    func testRouterSendsLinksToPan115() {
        let link = Pan115Provider(api: Pan115API(transport: FakeTransport())).parseShareLink("https://115cdn.com/s/swabc?password=pw12")
        XCTAssertEqual(link, ParsedShareLink(shareId: "swabc", passcode: "pw12", platform: .pan115))
        XCTAssertNil(Pan115Provider(api: Pan115API(transport: FakeTransport())).parseShareLink("https://pan.quark.cn/s/abc"))
    }

    func testTransportKeepsCookiePathsForTheCDNCookie() throws {
        let url = URL(string: "https://webapi.115.com/share/downurl")!
        let folded = "acw_tc=waf; Path=/, abcdef0123=tok; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/obj/f/"
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": folded]))
        let withPath = URLSessionTransport.cookiesWithPath(from: response)
        XCTAssertEqual(Set(withPath), ["acw_tc=waf; Path=/", "abcdef0123=tok; Path=/obj/f/"])
        XCTAssertEqual(Pan115API.downloadCookie(withPath), "abcdef0123=tok")
        // The existing name=value list is unchanged.
        XCTAssertEqual(Set(URLSessionTransport.setCookies(from: response)), ["acw_tc=waf", "abcdef0123=tok"])
    }

    func testDownloadCookieChoosesThePathBoundOne() {
        XCTAssertEqual(Pan115API.downloadCookie(["acw_tc=waf; Path=/", "abc123=tok; Path=/obj/x/; HttpOnly"]), "abc123=tok")
        XCTAssertEqual(Pan115API.downloadCookie(["acw_tc=waf; Path=/", "other=1"]), "acw_tc=waf")
        XCTAssertNil(Pan115API.downloadCookie([]))
        XCTAssertNil(Pan115API.downloadCookie(["Path=/x", "=nameless"]))
    }
}

final class Pan115ProviderTests: XCTestCase {
    func testAccountState() async {
        let good = pan115(FakeTransport([("/user/info?ct=json", json(#"{"state":true,"data":"138****0000"}"#))]))
        let signedIn = await good.accountState(credential: pan115Login)
        XCTAssertEqual(signedIn, .signedIn(nickname: "138****0000"))
        let expired = pan115(FakeTransport([("/user/info", json(#"{"state":false,"errno":990001}"#))]))
        let unverified = await expired.accountState(credential: pan115Login)
        XCTAssertEqual(unverified, .unverified)
        let signedOut = await good.accountState(credential: DriveCredential("CID=x"))
        XCTAssertEqual(signedOut, .signedOut)
        let guest = await good.accountState(credential: nil)
        XCTAssertEqual(guest, .signedOut)
    }

    func testQuota() async {
        let body = #"{"state":true,"data":{"space_info":{"all_total":{"size":1000},"all_use":{"size":"250"}}}}"#
        let p = pan115(FakeTransport([("index_info?count_space_nums=1", json(body))]))
        let quota = await p.quota(credential: pan115Login)
        XCTAssertEqual(quota, DriveQuota(used: 250, total: 1000))
        let missing = await pan115(FakeTransport()).quota(credential: pan115Login)
        XCTAssertNil(missing)
    }

    func testListFilesRequestAndParsing() async throws {
        let body = #"""
        {"state":true,"count":3,"data":[
          {"cid":"D1","pid":"0","n":"docs","t":"2024-01-01"},
          {"fid":"F1","cid":"0","n":"a.bin","s":1234,"pc":"PCA","t":"2024-01-02"},
          {"fid":"","cid":"","n":"ghost"}]}
        """#
        let transport = FakeTransport([("webapi.115.com/files?aid=1", json(body))])
        let files = try await pan115(transport).listFiles(directoryId: nil, credential: pan115Login)
        XCTAssertEqual(files, [
            DriveFile(id: "D1", name: "docs", size: 0, isDirectory: true, parentId: "0", fileToken: "", modifiedAt: "2024-01-01"),
            DriveFile(id: "F1", name: "a.bin", size: 1234, isDirectory: false, parentId: "0", fileToken: "PCA", modifiedAt: "2024-01-02"),
        ])
        let request = transport.requests[0]
        XCTAssertEqual(request.url.absoluteString, "https://webapi.115.com/files?aid=1&cid=0&o=user_ptime&asc=0&offset=0&show_dir=1&limit=100&snap=0&natsort=1&record_open_time=1&count_folders=1&format=json")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.headers["Cookie"], pan115Login.value)
        XCTAssertEqual(request.headers["Referer"], "https://115.com/")
        XCTAssertEqual(request.headers["X-Requested-With"], "XMLHttpRequest")
        XCTAssertEqual(request.headers["User-Agent"], Pan115Constants.webUserAgent)
    }

    func testListFilesPagesUntilCountReached() async throws {
        func page(_ range: Range<Int>, count: Int) -> HTTPResponse {
            let items = range.map { #"{"fid":"f\#($0)","cid":"0","n":"n\#($0)","s":1}"# }.joined(separator: ",")
            return json(#"{"state":true,"count":\#(count),"data":[\#(items)]}"#)
        }
        let transport = FakeTransport([("offset=0&", page(0..<100, count: 130)), ("offset=100&", page(100..<130, count: 130))])
        let files = try await pan115(transport).listFiles(directoryId: "D", credential: pan115Login)
        XCTAssertEqual(files.count, 130)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testErrorsAreReadableAndCarryTheCode() async {
        let transport = FakeTransport([("share/snap", json(#"{"state":false,"errno":4100012,"error":"x"}"#)),
                                       ("share/snap", json(#"{"state":false,"errno":4100008}"#)),
                                       ("share/snap", json(#"{"state":false,"errNo":4100026}"#)),
                                       ("share/snap", json(#"{"state":false,"errno":123,"error":"自定义"}"#)),
                                       ("share/snap", json(#"{"state":false}"#)),
                                       ("share/snap", HTTPResponse(statusCode: 502))])
        let p = pan115(transport)
        let link = ParsedShareLink(shareId: "swabc", passcode: nil, platform: .pan115)
        var messages: [String] = []
        var codes: [Int] = []
        for _ in 0..<6 {
            do { _ = try await p.openShare(link, passcode: nil, credential: nil) } catch DriveError.api(let message, let code) {
                messages.append(message)
                codes.append(code)
            } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(messages, ["该分享需要访问码，请填写访问码后重试（errno=4100012）", "访问码错误，请检查后重试（errno=4100008）",
                                  "分享链接不存在或已被删除（errno=4100026）", "自定义（errno=123）", "获取分享列表失败", "请求失败：响应为空（502）"])
        XCTAssertEqual(codes, [4100012, 4100008, 4100026, 123, 0, 0])
    }

    func testOpenShareKeepsSharerIdAndPrefersTypedPasscode() async throws {
        let body = #"{"state":true,"data":{"count":1,"userinfo":{"user_id":"555"},"shareinfo":{"share_title":"分享标题"},"list":[]}}"#
        let transport = FakeTransport([("share/snap", json(body)), ("share/snap", json(body))])
        let p = pan115(transport)
        let link = ParsedShareLink(shareId: "swabc", passcode: "linkpw", platform: .pan115)
        let opened = try await p.openShare(link, passcode: "typed", credential: nil)
        XCTAssertEqual(opened.accessToken, "typed|555")
        XCTAssertEqual(opened.title, "分享标题")
        let fromLink = try await p.openShare(link, passcode: " ", credential: nil)
        XCTAssertEqual(fromLink.accessToken, "linkpw|555")
        let url = transport.requests[0].url.absoluteString
        XCTAssertTrue(url.hasPrefix("https://webapi.115.com/share/snap?share_code=swabc&receive_code=typed&offset=0&limit=100&asc=0&cid=0&format=json"), url)
        XCTAssertEqual(transport.requests[0].headers["Referer"], "https://115cdn.com/s/swabc?password=typed&")
        XCTAssertNil(transport.requests[0].headers["Cookie"])
    }

    func testListShareFiles() async throws {
        let body = #"""
        {"state":true,"data":{"count":2,"list":[
          {"cid":"D1","pid":"0","n":"dir","fc":0},
          {"fid":"F1","cid":"D1","n":"a.bin","s":"42","fc":1}]}}
        """#
        let transport = FakeTransport([("share/snap", json(body))])
        let files = try await pan115(transport).listShareFiles(session: pan115Session, directoryId: "D1", credential: nil)
        XCTAssertEqual(files.map(\.id), ["D1", "F1"])
        XCTAssertEqual(files.map(\.isDirectory), [true, false])
        XCTAssertEqual(files[1].size, 42)
        XCTAssertEqual(files[1].parentId, "D1")
        XCTAssertTrue(transport.requests[0].url.absoluteString.contains("receive_code=pw12"))
        XCTAssertTrue(transport.requests[0].url.absoluteString.contains("cid=D1"))
    }

    func testShareLinkUsesClientUAAndPicksPathBoundCookie() async throws {
        var cdn = json(#"{"state":true,"data":{"file_url":"https://cdn.example/f?sig=1","fn":"","fs":"100"}}"#)
        cdn.cookiesWithPath = ["acw_tc=waf; Path=/", "abcdef0123=tok; Path=/obj/f/"]
        let transport = FakeTransport([("appversion.115.com", json(#"{"data":{"win":{"version_code":"37.1.2"}}}"#)), ("share/downurl", cdn)])
        let link = try await pan115(transport).resolveShareFile(session: pan115Session, file: pan115SharedFile, credential: pan115Login, options: ShareResolveOptions())
        XCTAssertEqual(link.url.absoluteString, "https://cdn.example/f?sig=1")
        XCTAssertEqual(link.filename, "a.bin")
        XCTAssertEqual(link.size, 100)
        XCTAssertNil(link.cleanupDirectoryId)
        XCTAssertEqual(link.headers["Cookie"], "\(pan115Login.value); abcdef0123=tok")
        XCTAssertEqual(link.headers["User-Agent"], "Mozilla/5.0 115Browser/37.1.2")
        XCTAssertEqual(link.headers["Referer"], "https://115.com/")
        let request = transport.requests[1]
        XCTAssertEqual(request.url.absoluteString, "https://webapi.115.com/share/downurl?dl=1&user_id=555&share_code=swabc&file_id=F1&receive_code=pw12")
        XCTAssertEqual(request.headers["User-Agent"], "Mozilla/5.0 115Browser/37.1.2")
        XCTAssertEqual(request.headers["Referer"], "https://115cdn.com/s/swabc?password=pw12&")
        XCTAssertEqual(transport.requests[0].headers["Cookie"], nil, "the version lookup sends no login")
    }

    func testClientVersionIsFetchedOnceAndGarbageKeepsFallback() async throws {
        let transport = FakeTransport([("appversion.115.com", json(#"{"data":{"win":{"version_code":"<b>"}}}"#))],
                                      fallback: json(#"{"state":true,"data":{"file_url":"https://c/f"}}"#))
        let p = pan115(transport)
        _ = try await p.resolveShareFile(session: pan115Session, file: pan115SharedFile, credential: nil, options: ShareResolveOptions())
        _ = try await p.resolveShareFile(session: pan115Session, file: pan115SharedFile, credential: nil, options: ShareResolveOptions())
        XCTAssertEqual(transport.requests.filter { $0.url.host == "appversion.115.com" }.count, 1)
        let ua = await p.api.clientUserAgent
        XCTAssertEqual(ua, "Mozilla/5.0 115Browser/36.0.1")
    }

    func testGuestShareFailureIsPassedOnWithoutSaving() async {
        let transport = FakeTransport([("appversion", json("{}")), ("share/downurl", json(#"{"state":false,"errno":50029,"error":"当前版本过低"}"#))])
        do {
            _ = try await pan115(transport).resolveShareFile(session: pan115Session, file: pan115SharedFile, credential: nil, options: ShareResolveOptions())
            XCTFail("expected failure")
        } catch DriveError.api(let message, let code) {
            XCTAssertTrue(message.contains("115 判定当前标识版本过低"), message)
            XCTAssertEqual(code, 50029)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(transport.requests.count, 2, "a guest never saves")
    }

    func testBigShareFileFallsBackToTemporarySaveAndDesktopLink() async throws {
        let big = DriveFile(id: "F1", name: "big.bin", size: 5000, isDirectory: false, parentId: "P1")
        var app = json(#"{"state":true,"data":"ENC:{\"F9\":{\"pick_code\":\"PC9\",\"file_name\":\"big.bin\",\"file_size\":\"5000\",\"url\":{\"url\":\"https://cdn.example/big\"}}}"}"#)
        app.cookiesWithPath = ["abcdef0123=tok; Path=/obj/big/"]
        let transport = FakeTransport([
            ("appversion", json("{}")),
            ("share/downurl", json(#"{"state":false,"errno":50029}"#)),
            ("webapi.115.com/files?aid=1&cid=0&", json(#"{"state":true,"count":1,"data":[{"cid":"T1","pid":"0","n":"Thermo临时转存"}]}"#)),
            ("files/add", ok(#","cid":"SUB1""#)),
            ("share/receive", ok()),
            ("files?aid=1&cid=SUB1&", json(#"{"state":true,"count":1,"data":[{"fid":"F9","cid":"SUB1","n":"big.bin","s":5000,"pc":"PC9"}]}"#)),
            ("proapi.115.com/app/chrome/downurl", app),
        ])
        let sleeps = Box<UInt64>()
        let link = try await pan115(transport, sleeps: sleeps).resolveShareFile(
            session: pan115Session, file: big, credential: pan115Login, options: ShareResolveOptions(preferNoSave: true, skipSpaceCheck: true))
        XCTAssertEqual(link.url.absoluteString, "https://cdn.example/big")
        XCTAssertEqual(link.cleanupDirectoryId, "SUB1")
        XCTAssertEqual(link.fileId, "F9")
        XCTAssertEqual(link.headers["Cookie"], "\(pan115Login.value); abcdef0123=tok")

        let form = { (index: Int) in String(decoding: transport.requests[index].body ?? Data(), as: UTF8.self) }
        let paths = transport.requests.map { $0.url.path }
        XCTAssertEqual(paths, ["/1/web/1.0/api/chrome", "/share/downurl", "/files", "/files/add", "/share/receive", "/files", "/app/chrome/downurl"])
        XCTAssertTrue(form(3).hasPrefix("pid=T1&cname=tr_"), form(3))
        XCTAssertEqual(form(4), "share_code=swabc&receive_code=pw12&file_id=F1&cid=SUB1")
        let desktop = transport.requests[6]
        XCTAssertEqual(desktop.url.absoluteString, "https://proapi.115.com/app/chrome/downurl?t=1700000000")
        XCTAssertEqual(form(6), "data=ENC%3A%7B%22pickcode%22%3A%22PC9%22%7D")
        XCTAssertEqual(desktop.headers["Content-Type"], "application/x-www-form-urlencoded; charset=utf-8")
        XCTAssertEqual(desktop.method, .post)
        XCTAssertTrue(sleeps.values.isEmpty, "found on the first try")
    }

    func testCleanupDeletesTheTemporaryDirectoryThroughTheRoot() async throws {
        let transport = FakeTransport([
            ("webapi.115.com/files?aid=1&cid=0&", json(#"{"state":true,"data":[{"cid":"T1","pid":"0","n":"Thermo临时转存"}]}"#)),
            ("rb/delete", json(#"{"state":false,"errno":800007}"#)),
            ("rb/delete", ok()),
        ])
        await pan115(transport).cleanup(directoryId: "SUB1", credential: pan115Login)
        XCTAssertEqual(transport.requests.map { $0.url.path }, ["/files", "/rb/delete", "/rb/delete"], "errno 800007 is confirmed once")
        XCTAssertEqual(String(decoding: transport.requests[1].body ?? Data(), as: UTF8.self), "pid=T1&fid%5B0%5D=SUB1&ignore_warn=1")
        await pan115(FakeTransport()).cleanup(directoryId: "SUB1", credential: DriveCredential("CID=x"))
    }

    func testFailedDesktopLinkRemovesTheSavedCopy() async {
        let big = DriveFile(id: "F1", name: "big.bin", size: 0, isDirectory: false, parentId: "P1")
        let root = #"{"state":true,"data":[{"cid":"T1","pid":"0","n":"Thermo临时转存"}]}"#
        let transport = FakeTransport([
            ("appversion", json("{}")),
            ("share/downurl", json(#"{"state":false,"errno":50029}"#)),
            ("webapi.115.com/files?aid=1&cid=0&", json(root)),
            ("files/add", ok(#","cid":"SUB1""#)),
            ("share/receive", ok()),
            ("files?aid=1&cid=SUB1&", json(#"{"state":true,"data":[{"fid":"F9","cid":"SUB1","n":"big.bin","s":5,"pc":"PC9"}]}"#)),
            ("proapi.115.com", json(#"{"state":false,"errno":99,"error":"nope"}"#)),
            ("webapi.115.com/files?aid=1&cid=0&", json(root)),
            ("rb/delete", ok()),
        ])
        do {
            _ = try await pan115(transport).resolveShareFile(session: pan115Session, file: big, credential: pan115Login, options: ShareResolveOptions())
            XCTFail("expected failure")
        } catch DriveError.api(let message, _) {
            XCTAssertEqual(message, "该分享文件暂时无法获取电脑端下载链接，请稍后重试")
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(transport.requests.last?.url.path, "/rb/delete")
    }

    func testSaveClaimsRenamedCopyAfterRetries() async throws {
        let empty = json(#"{"state":true,"data":[]}"#)
        let transport = FakeTransport([
            ("share/receive", ok()),
            ("files?aid=1&cid=D9&", empty),
            ("files?aid=1&cid=D9&", empty),
            ("files?aid=1&cid=D9&", json(#"{"state":true,"data":[{"fid":"N1","cid":"D9","n":"a(1).bin","s":100,"pc":"P"}]}"#)),
        ])
        let sleeps = Box<UInt64>()
        let id = try await pan115(transport, sleeps: sleeps).saveToDrive(session: pan115Session, file: pan115SharedFile, directoryId: "D9",
                                                                         credential: pan115Login, skipSpaceCheck: true)
        XCTAssertEqual(id, "N1")
        XCTAssertEqual(sleeps.values, [500_000_000, 500_000_000])
    }

    func testSaveReportsAMissingCopyAndRequiresLoginAndSpace() async {
        let missing = FakeTransport([("share/receive", ok())], fallback: json(#"{"state":true,"data":[]}"#))
        do {
            _ = try await pan115(missing).saveToDrive(session: pan115Session, file: pan115SharedFile, directoryId: nil, credential: pan115Login, skipSpaceCheck: true)
            XCTFail("expected failure")
        } catch DriveError.api(let message, _) {
            XCTAssertEqual(message, "转存已完成，但未在目标目录找到文件，请到115网盘查看")
        } catch { XCTFail("\(error)") }

        do {
            _ = try await pan115(FakeTransport()).saveToDrive(session: pan115Session, file: pan115SharedFile, directoryId: nil,
                                                               credential: DriveCredential("CID=x"), skipSpaceCheck: true)
            XCTFail("expected failure")
        } catch { XCTAssertEqual(error as? DriveError, .loginRequired) }

        let full = FakeTransport([("index_info", json(#"{"state":true,"data":{"space_info":{"all_total":{"size":150},"all_use":{"size":100}}}}"#))])
        do {
            _ = try await pan115(full).saveToDrive(session: pan115Session, file: pan115SharedFile, directoryId: nil, credential: pan115Login, skipSpaceCheck: false)
            XCTFail("expected failure")
        } catch { XCTAssertEqual(error as? DriveError, .insufficientSpace(required: 100, available: 50)) }
        XCTAssertEqual(full.requests.count, 1, "nothing is saved when it cannot fit")
    }

    func testOwnFileLinkUsesDesktopEndpointThenWebFallback() async throws {
        let file = DriveFile(id: "F1", name: "mine.bin", size: 77, isDirectory: false, parentId: "0", fileToken: "PCX")
        let app = json(#"{"state":true,"data":"ENC:{\"F1\":{\"file_name\":\"\",\"file_size\":12,\"url\":{\"url\":\"https://cdn.example/m\"}}}"}"#)
        let transport = FakeTransport([("appversion", json("{}")), ("proapi.115.com", app)])
        let link = try await pan115(transport).resolveFile(file, credential: pan115Login)
        XCTAssertEqual(link.url.absoluteString, "https://cdn.example/m")
        XCTAssertEqual(link.filename, "mine.bin")
        XCTAssertEqual(link.size, 12)

        let web = FakeTransport([("appversion", json("{}")), ("proapi.115.com", json(#"{"state":false,"errno":50028}"#)),
                                 ("files/download?pickcode=PCX", json(#"{"state":true,"data":{"file_url":"https://cdn.example/w","file_name":"w.bin","file_size":"9"}}"#))])
        let fallback = try await pan115(web).resolveFile(file, credential: pan115Login)
        XCTAssertEqual(fallback.url.absoluteString, "https://cdn.example/w")
        XCTAssertEqual(fallback.filename, "w.bin")
        XCTAssertEqual(fallback.size, 9)

        do {
            _ = try await pan115(FakeTransport()).resolveFile(DriveFile(id: "F", name: "n", size: 1, isDirectory: false, parentId: "0"), credential: pan115Login)
            XCTFail("expected failure")
        } catch DriveError.api(let message, _) { XCTAssertEqual(message, "缺少 pickcode，无法获取下载链接") } catch { XCTFail("\(error)") }

        do {
            _ = try await pan115(FakeTransport()).resolveFile(id: "F1", credential: pan115Login)
            XCTFail("expected failure")
        } catch { XCTAssertEqual((error as? DriveError).map { if case .unsupported = $0 { return true } else { return false } }, true) }
    }

    func testMoveRenameDeleteCreateRequests() async throws {
        let transport = FakeTransport([
            ("115.com/files/move", ok(#","data":{"move_proid":"MP1"}"#)),
            ("move_progress?move_proid=MP1", json(#"{"state":true,"data":{"percent":40.5,"count":3}}"#)),
            ("move_progress?move_proid=MP1", json(#"{"state":true,"data":{"percent":100,"count":3}}"#)),
            ("batch_rename", ok()),
            ("files/add", ok(#","data":{"cid":"NEW1"}"#)),
        ])
        let sleeps = Box<UInt64>()
        let api = Pan115API(transport: transport, cipher: FakeCipher(), sleep: { sleeps.add($0) })
        try await api.move(ids: ["A", " ", "B"], toParentId: "", cookie: pan115Login.value)
        XCTAssertEqual(sleeps.values, [400_000_000, 400_000_000])
        XCTAssertEqual(String(decoding: transport.requests[0].body ?? Data(), as: UTF8.self), "pid=0&fid%5B0%5D=A&fid%5B1%5D=B")
        try await api.rename(id: "A", newName: "新 名.txt", cookie: pan115Login.value)
        XCTAssertEqual(String(decoding: transport.requests[3].body ?? Data(), as: UTF8.self),
                       "fid=A&file_name=%E6%96%B0+%E5%90%8D.txt&files_new_name%5BA%5D=%E6%96%B0+%E5%90%8D.txt")
        let created = try await api.createDirectory(parentId: "0", name: "x", cookie: pan115Login.value)
        XCTAssertEqual(created, "NEW1")
        do { try await api.move(ids: [" "], toParentId: "0", cookie: "") } catch DriveError.api(let message, _) { XCTAssertEqual(message, "请选择要移动的文件") }
    }

    func testCreateShareSetsValidityAndKeepsShareWhenThatFails() async throws {
        let created = ok(#","data":{"share_code":"swNEW","receive_code":"ab12","share_url":"https://115cdn.com/s/swNEW","share_title":"T","share_ex_duration":"15天"}"#)
        let transport = FakeTransport([("user/allow_protocol", ok()), ("share/send", json(#"{"state":false}"#)), ("share/send", created),
                                       ("share/updateshare", ok())])
        let api = Pan115API(transport: transport, cipher: FakeCipher())
        let info = try await api.createShare(fileIds: ["A", "", "B"], duration: "-1", cookie: pan115Login.value)
        XCTAssertEqual(info, Pan115ShareInfo(shareURL: "https://115cdn.com/s/swNEW", passcode: "ab12", shareCode: "swNEW", title: "T",
                                             expiredType: Pan115ShareExpire.forever, warning: nil))
        let bodies = transport.requests.map { String(decoding: $0.body ?? Data(), as: UTF8.self) }
        XCTAssertEqual(bodies[1], "user_id=103616022&file_ids=A%2CB&ignore_warn=0")
        XCTAssertEqual(bodies[2], "user_id=103616022&file_ids=A%2CB&ignore_warn=1")
        XCTAssertEqual(bodies[3], "share_code=swNEW&share_duration=-1")

        let failing = FakeTransport([("allow_protocol", ok()), ("share/send", ok()), ("share/send", created),
                                     ("updateshare", json(#"{"state":false,"error":"频繁"}"#))])
        let warned = try await Pan115API(transport: failing, cipher: FakeCipher()).createShare(fileIds: ["A"], duration: "7", cookie: pan115Login.value)
        XCTAssertEqual(warned.expiredType, Pan115ShareExpire.fifteenDays)
        XCTAssertEqual(warned.warning, "分享已创建，但有效期设置未生效（当时按服务端默认档位）：频繁")
        XCTAssertEqual(failing.requests.filter { $0.url.path == "/user/allow_protocol" }.count, 1)

        do {
            _ = try await api.createShare(fileIds: ["A"], duration: "1", cookie: "CID=x")
            XCTFail("expected failure")
        } catch DriveError.api(let message, _) { XCTAssertEqual(message, "登录态缺少用户标识，请重新登录115网盘") } catch { XCTFail("\(error)") }
    }

    func testCredentialsNeverAppearInErrorsOrDescriptions() async {
        let transport = FakeTransport([("share/snap", json(#"{"state":false,"errno":990001}"#))])
        var texts: [String] = []
        do { _ = try await pan115(transport).listShareFiles(session: pan115Session, directoryId: nil, credential: pan115Login) } catch {
            texts.append(error.localizedDescription)
            texts.append("\(error)")
        }
        let link = Pan115DownloadLink(fid: "1", filename: "f", downloadURL: "https://c/secret-sig", size: 1, guestCookie: "tok=SECRETCDN")
        texts += [String(describing: link), String(reflecting: link), "\(Mirror(reflecting: link).children.map { "\($0.value)" })"]
        let resolved = ResolvedLink(url: URL(string: "https://c/x")!, headers: ["Cookie": "SECRETSEID"], fileId: "1", filename: "f", size: 1)
        texts += [String(describing: resolved), String(describing: pan115Login)]
        for text in texts {
            XCTAssertFalse(text.contains("SECRET") || text.contains("secret-sig"), text)
        }
    }

    func testBatchSpaceCheck() async throws {
        let quota = #"{"state":true,"data":{"space_info":{"all_total":{"size":1000},"all_use":{"size":900}}}}"#
        let p = pan115(FakeTransport([("index_info", json(quota)), ("index_info", json(quota))]))
        let fits = try await p.ensureBatchSpace(sizes: [40, 50], credential: pan115Login)
        XCTAssertTrue(fits)
        do { _ = try await p.ensureBatchSpace(sizes: [60, 50], credential: pan115Login); XCTFail("expected failure") } catch {
            XCTAssertEqual(error as? DriveError, .insufficientSpace(required: 110, available: 100))
        }
    }
}
