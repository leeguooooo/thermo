import XCTest
@testable import CloudDriveKit

/// Response bodies below are rebuilt from the field shapes read in Pan123Api.kt. None were captured
/// from the live service, and no real account or network is used.
private final class ProbeScript: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data?]
    private(set) var urls: [URL] = []
    init(_ queue: [Data?]) { self.queue = queue }
    func next(_ url: URL) -> Data? {
        lock.lock(); defer { lock.unlock() }
        urls.append(url)
        return queue.isEmpty ? nil : queue.removeFirst()
    }
}

private struct ScriptedProbe: Pan123RedirectProbe {
    let script: ProbeScript
    func smallBody(url: URL, headers: [String: String]) async -> Data? { script.next(url) }
}

private let token = DriveCredential("jwt.header.payload")
private let deviceId = "0123456789abcdef0123456789abcdef"
private let fileToken = "1816216065-0|etag1|node9"
private let shareFile = DriveFile(id: "777", name: "movie.mkv", size: 5000, isDirectory: false, parentId: "0", fileToken: fileToken)

private func pan(_ transport: FakeTransport, probe: [Data?] = [], sleeps: Box<UInt64>? = nil) -> (Pan123Provider, ProbeScript) {
    let script = ProbeScript(probe)
    let api = Pan123API(transport: transport, redirectProbe: ScriptedProbe(script: script), deviceId: deviceId,
                        sleep: { sleeps?.add($0) }, now: { 1_700_000_000 }, random: { 1_234_567 })
    return (Pan123Provider(api: api), script)
}

private func infoItem(_ id: String, name: String, type: Int = 0, size: Int = 10) -> String {
    #"{"FileId":\#(id),"FileName":"\#(name)","Size":\#(size),"Type":\#(type),"ParentFileId":0,"S3KeyFlag":"1816216065-0","Etag":"e\#(id)","StorageNode":"m1","UpdateAt":"2025-01-01"}"#
}

final class Pan123SignTests: XCTestCase {
    func testCRC32MatchesTheStandardCheckValue() {
        XCTAssertEqual(Pan123Sign.crc32Hex("123456789"), "cbf43926")
        XCTAssertEqual(Pan123Sign.crc32Hex(""), "0")
    }

    func testSignMatchesAnIndependentComputation() {
        // Expected values come from Python zlib.crc32 over the same algorithm (UTC 202311151413 after +16 h).
        let sign = Pan123Sign.make(path: "/b/api/user/info", timestamp: 1_700_000_000, random: 1_234_567)
        XCTAssertEqual(sign.key, "f2ac3dd")
        XCTAssertEqual(sign.value, "1700000000-1234567-b6459abb")
    }

    func testDownloadURLDecoding() {
        XCTAssertEqual(Pan123API.decodeDownloadURL("aHR0cHM6Ly9jZG4uZXhhbXBsZS9maWxlP3g9MQ=="), "https://cdn.example/file?x=1")
        XCTAssertEqual(Pan123API.decodeDownloadURL("aHR0cHM6Ly9jZG4uZXhhbXBsZS9maWxlP3g9MQ"), "https://cdn.example/file?x=1", "missing padding is accepted")
        XCTAssertEqual(Pan123API.decodeDownloadURL("https://x.123pan.cn/download-v2/?params=aHR0cHM6Ly9jZG4uZXhhbXBsZS9mP2E9MSZiPX5-&auto=1"), "https://cdn.example/f?a=1&b=~~")
        XCTAssertNil(Pan123API.decodeDownloadURL("https://cdn.example/direct/file"))
        XCTAssertNil(Pan123API.decodeDownloadURL("bm90IGEgdXJs"), "a bare base64 that is not a URL")
    }

    func testTokenCodecAndShareId() {
        XCTAssertEqual(Pan123API.decodeToken("a-0|b").etag, "b")
        XCTAssertEqual(Pan123API.decodeToken("a-0|b").storageNode, "")
        XCTAssertEqual(Pan123API.shareId(of: shareFile), "1816216065")
    }
}

final class Pan123ProviderTests: XCTestCase {
    func testLinkRoutingFindsPasscodeInMessage() throws {
        let (provider, _) = pan(FakeTransport())
        let link = try XCTUnwrap(provider.parseShareLink("快来看 https://www.123pan.com/s/AbCd-Ef12 提取码：k9x2"))
        XCTAssertEqual(link, ParsedShareLink(shareId: "AbCd-Ef12", passcode: "k9x2", platform: .pan123))
    }

    func testPasswordLoginSucceedsWithSourceHeaders() async throws {
        let transport = FakeTransport([("sign_in", json(#"{"code":200,"data":{"token":"jwt.a.b"}}"#))])
        let (provider, _) = pan(transport)
        let result = await provider.api.passwordLogin(account: "  me@example.com ", password: " pass word ")
        XCTAssertEqual(result, .success(DriveCredential("jwt.a.b")))
        let request = transport.requests[0]
        XCTAssertEqual(request.url.host, "user.123pan.cn")
        XCTAssertEqual(request.headers["app-version"], "132")
        XCTAssertEqual(request.headers["Origin"], "https://user.123pan.cn")
        XCTAssertEqual(request.headers["loginuuid"], deviceId)
        XCTAssertNil(request.headers["auth-key"], "sign-in is unsigned")
        let body = try transport.body(0)
        XCTAssertEqual(body["passport"] as? String, "me@example.com", "the account is trimmed")
        XCTAssertEqual(body["password"] as? String, " pass word ", "the password is not")
        XCTAssertEqual(body["remember"] as? Bool, false)
    }

    func testLoginFailuresNeverEchoTheServer() async {
        let echo = json(#"{"code":401,"message":"password hunter2 is wrong for me@example.com"}"#)
        let (provider, _) = pan(FakeTransport(fallback: echo))
        let result = await provider.api.passwordLogin(account: "me@example.com", password: "hunter2")
        XCTAssertEqual(result, .failure(Pan123LoginSupport.messageFallback))

        let cases: [(Int, Int, String, String)] = [
            (429, -1, "", Pan123LoginSupport.messageTooFrequent),
            (200, 429, "", Pan123LoginSupport.messageTooFrequent),
            (200, 1, "操作过于频繁", Pan123LoginSupport.messageTooFrequent),
            (200, 1, "请完成滑块", Pan123LoginSupport.messageVerifyRequired),
            (200, 1, "账号已冻结", "123 账号暂时不可登录，请先在官方客户端检查账号状态"),
            (502, -1, "", "123 登录服务暂时不可用，请稍后重试"),
            (302, -1, "", "123 登录接口发生变化，请稍后重试"),
        ]
        for (status, code, message, expected) in cases {
            XCTAssertEqual(Pan123LoginSupport.describeFailure(httpStatus: status, code: code, serverMessage: message), expected)
        }
    }

    func testLoginInputAndTransportErrors() async {
        let transport = FakeTransport()
        let (provider, _) = pan(transport)
        let empty = await provider.api.passwordLogin(account: " ", password: "x")
        XCTAssertEqual(empty, .failure("请输入账号和密码"))
        let tooLong = await provider.api.passwordLogin(account: String(repeating: "a", count: 255), password: "x")
        XCTAssertEqual(tooLong, .failure("账号或密码过长"))
        XCTAssertTrue(transport.requests.isEmpty)
        let down = await provider.api.passwordLogin(account: "a", password: "b")
        XCTAssertEqual(down, .failure("网络异常，无法连接 123 登录服务，请稍后重试"))
    }

    func testTokenWithControlCharactersIsRejected() async {
        let bad = json(#"{"code":200,"data":{"token":"abc\ndef"}}"#)
        let (provider, _) = pan(FakeTransport(fallback: bad))
        let result = await provider.api.passwordLogin(account: "a", password: "b")
        XCTAssertEqual(result, .failure(Pan123LoginSupport.messageFallback))
        XCTAssertFalse(provider.isWellFormed(credential: DriveCredential("a\u{0}b")))
        XCTAssertFalse(provider.isWellFormed(credential: DriveCredential("  ")))
        XCTAssertTrue(provider.isWellFormed(credential: token))
    }

    func testAccountStateAndQuotaAreSigned() async throws {
        let info = #"{"code":0,"data":{"Nickname":"小云","SpaceUsed":100,"SpacePermanent":1000,"SpaceTemp":24}}"#
        let transport = FakeTransport(fallback: json(info))
        let (provider, _) = pan(transport)
        let signedOut = await provider.accountState(credential: nil)
        XCTAssertEqual(signedOut, .signedOut)
        let state = await provider.accountState(credential: token)
        XCTAssertEqual(state, .signedIn(nickname: "小云"))
        let quota = await provider.quota(credential: token)
        XCTAssertEqual(quota, DriveQuota(used: 100, total: 1024))
        let headers = transport.requests[0].headers
        XCTAssertEqual(transport.requests[0].url.path, "/b/api/user/info")
        XCTAssertEqual(headers["authorization"], "Bearer jwt.header.payload")
        XCTAssertEqual(headers["auth-key"], "f2ac3dd")
        XCTAssertEqual(headers["auth-value"], "1700000000-1234567-b6459abb")
        XCTAssertEqual(headers["platform"], "web")
        XCTAssertEqual(headers["app-version"], "3")

        let (broken, _) = pan(FakeTransport(fallback: json(#"{"code":401,"message":"expired"}"#)))
        let unverified = await broken.accountState(credential: token)
        XCTAssertEqual(unverified, .unverified)
    }

    func testOpenShareOmitsBlankPasscodeAndTitlesFromFirstEntry() async throws {
        let list = #"{"code":0,"data":{"Next":"-1","InfoList":[\#(infoItem("5", name: "合集", type: 1))]}}"#
        let transport = FakeTransport(fallback: json(list))
        let (provider, _) = pan(transport)
        let link = ParsedShareLink(shareId: "AbCd-Ef12", passcode: nil, platform: .pan123)
        let opened = try await provider.openShare(link, passcode: "  ", credential: nil)
        XCTAssertEqual(opened.title, "合集")
        XCTAssertEqual(opened.accessToken, "")
        let url = transport.requests[0].url.absoluteString
        XCTAssertTrue(url.hasPrefix("https://yun.123pan.cn/b/api/share/get?limit=100&next=0&orderBy=file_name&orderDirection=asc&shareKey=AbCd-Ef12&ParentFileId=0&Page=1"), url)
        XCTAssertFalse(url.contains("SharePwd"), "an empty SharePwd is answered with 400")
        XCTAssertEqual(transport.requests[0].headers["User-Agent"], "Dart/3.12 (dart:io)")
        XCTAssertNil(transport.requests[0].headers["authorization"], "listing is anonymous")

        let withCode = FakeTransport(fallback: json(list))
        let (second, _) = pan(withCode)
        let again = try await second.openShare(link, passcode: "a+b/c", credential: nil)
        XCTAssertEqual(again.accessToken, "a+b/c")
        XCTAssertTrue(withCode.requests[0].url.absoluteString.hasSuffix("&SharePwd=a%2Bb%2Fc"))
    }

    func testShareListingPagesUntilNextIsMinusOne() async throws {
        let page1 = #"{"code":0,"data":{"Next":"","InfoList":[\#(infoItem("1", name: "a"))]}}"#
        let page2 = #"{"code":0,"data":{"Next":"-1","InfoList":[\#(infoItem("2", name: "b", type: 1))]}}"#
        let transport = FakeTransport([("Page=1", json(page1)), ("Page=2", json(page2))])
        let (provider, _) = pan(transport)
        let session = ShareSession(platform: .pan123, shareId: "K-1", accessToken: "pw", title: "t")
        let files = try await provider.listShareFiles(session: session, directoryId: "42", credential: nil)
        XCTAssertEqual(files.map(\.name), ["a", "b"])
        XCTAssertEqual(files[1].isDirectory, true)
        XCTAssertEqual(files[0].fileToken, "1816216065-0|e1|m1")
        XCTAssertEqual(files[0].modifiedAt, "2025-01-01")
        XCTAssertTrue(transport.requests[0].url.absoluteString.contains("ParentFileId=42"))
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testShareListingStopsOnEmptyPageAndFailsOnExpiredOrErrors() async {
        let empty = FakeTransport(fallback: json(#"{"code":0,"data":{"Next":"","InfoList":[]}}"#))
        let (provider, _) = pan(empty)
        let session = ShareSession(platform: .pan123, shareId: "K-1", accessToken: "", title: "t")
        let none = try? await provider.listShareFiles(session: session, directoryId: nil, credential: nil)
        XCTAssertEqual(none, [])
        XCTAssertEqual(empty.requests.count, 1)

        let (expired, _) = pan(FakeTransport(fallback: json(#"{"code":0,"data":{"Expired":true}}"#)))
        do { _ = try await expired.listShareFiles(session: session, directoryId: nil, credential: nil); XCTFail() } catch {
            XCTAssertEqual(error as? DriveError, .api(message: "分享已失效"))
        }
        let (failing, _) = pan(FakeTransport(fallback: json(#"{"code":5113,"message":"请输入提取码"}"#)))
        do { _ = try await failing.listShareFiles(session: session, directoryId: nil, credential: nil); XCTFail() } catch {
            XCTAssertEqual(error as? DriveError, .api(message: "请输入提取码（code=5113）", code: 5113))
        }
        let (html, _) = pan(FakeTransport(fallback: json("<html>blocked</html>", status: 403)))
        do { _ = try await html.listShareFiles(session: session, directoryId: nil, credential: nil); XCTFail() } catch {
            XCTAssertEqual(error as? DriveError, .api(message: "响应解析失败（HTTP 403）"))
        }
    }

    func testShareDownloadNeedsLoginAndUsesAndroidHeadersWithWebSign() async throws {
        let session = ShareSession(platform: .pan123, shareId: "K-1", accessToken: "pw", title: "t")
        let wrapped = "https://www.123865.com/download-v2/?params=aHR0cHM6Ly9jZG4uZXhhbXBsZS9taXNj"
        let reply = #"{"code":0,"data":{"DownloadURL":"\#(wrapped)"}}"#
        let transport = FakeTransport(fallback: json(reply))
        let (provider, probe) = pan(transport)

        do { _ = try await provider.resolveShareFile(session: session, file: shareFile, credential: nil, options: ShareResolveOptions()); XCTFail() } catch {
            XCTAssertEqual(error as? DriveError, .loginRequired)
        }
        XCTAssertTrue(transport.requests.isEmpty)

        let link = try await provider.resolveShareFile(session: session, file: shareFile, credential: token, options: ShareResolveOptions())
        XCTAssertEqual(link.url.absoluteString, "https://cdn.example/misc")
        XCTAssertEqual(link.headers["Referer"], "https://yun.123pan.cn/")
        XCTAssertEqual(link.headers["User-Agent"], Pan123Constants.webUserAgent)
        XCTAssertNil(link.cleanupDirectoryId)
        XCTAssertEqual(link.filename, "movie.mkv")
        XCTAssertEqual(link.size, 5000)
        XCTAssertEqual(probe.urls.map(\.absoluteString), ["https://cdn.example/misc"])

        let request = transport.requests[0]
        XCTAssertEqual(request.url.host, "www.123865.com")
        XCTAssertEqual(request.headers["platform"], "android")
        XCTAssertEqual(request.headers["app-version"], "39")
        // Computed with Python zlib.crc32 for this path; the sign says web/3 although the headers say android/39.
        XCTAssertEqual(request.headers["auth-value"], "1700000000-1234567-ecfbd1b2")
        let body = try transport.body(0)
        XCTAssertEqual(body["ShareKey"] as? String, "K-1")
        XCTAssertEqual(body["FileID"] as? String, "777")
        XCTAssertEqual(body["S3KeyFlag"] as? String, "1816216065-0")
        XCTAssertEqual(body["Etag"] as? String, "etag1")
        XCTAssertEqual(body["Size"] as? Int, 5000)
    }

    func testRedirectJsonIsFollowedUpToFiveHops() async throws {
        let hop = { (url: String) in Data(#"{"code":0,"data":{"redirect_url":"\#(url)"}}"#.utf8) }
        let reply = #"{"code":0,"data":{"DownloadUrl":"https://cdn.example/a?auto_redirect=0"}}"#
        let transport = FakeTransport(fallback: json(reply))
        let (provider, probe) = pan(transport, probe: [hop("https://cdn.example/b?auto_redirect=0"), hop("https://cdn.example/final")])
        let link = try await provider.resolveFile(shareFile, credential: token)
        XCTAssertEqual(link.url.absoluteString, "https://cdn.example/final")
        XCTAssertEqual(probe.urls.count, 3, "a nil probe reply on the last URL means it is the file")

        let endless = Data(#"{"data":{"redirect_url":"https://cdn.example/loop"}}"#.utf8)
        let (capped, loopProbe) = pan(FakeTransport(fallback: json(reply)), probe: Array(repeating: endless, count: 10))
        _ = try await capped.resolveFile(shareFile, credential: token)
        XCTAssertEqual(loopProbe.urls.count, 5)
    }

    func testOwnFileDownloadUsesUnprefixedPathAndNeedsTheFile() async throws {
        let reply = #"{"code":0,"data":{"DownloadUrl":"https://cdn.example/direct"}}"#
        let transport = FakeTransport(fallback: json(reply))
        let (provider, _) = pan(transport)
        let link = try await provider.resolveFile(shareFile, credential: token)
        XCTAssertEqual(link.url.absoluteString, "https://cdn.example/direct")
        let request = transport.requests[0]
        XCTAssertEqual(request.url.absoluteString, "https://yun.123pan.cn/api/file/download_info")
        XCTAssertEqual(request.headers["platform"], "web")
        let body = try transport.body(0)
        XCTAssertEqual(body["fileId"] as? Int, 777)
        XCTAssertEqual(body["s3keyFlag"] as? String, "1816216065-0")
        XCTAssertEqual(body["etag"] as? String, "etag1")
        XCTAssertEqual(body["fileName"] as? String, "movie.mkv")

        do { _ = try await provider.resolveFile(id: "777", credential: token); XCTFail() } catch {
            guard case .unsupported(let platform, _)? = error as? DriveError else { return XCTFail("\(error)") }
            XCTAssertEqual(platform, .pan123)
        }
    }

    func testOwnListing() async throws {
        let list = #"{"code":0,"data":{"Next":"-1","InfoList":[\#(infoItem("9", name: "doc.pdf", size: 77))]}}"#
        let transport = FakeTransport(fallback: json(list))
        let (provider, _) = pan(transport)
        let files = try await provider.listFiles(directoryId: nil, credential: token)
        XCTAssertEqual(files.map(\.id), ["9"])
        XCTAssertEqual(files[0].size, 77)
        let url = transport.requests[0].url.absoluteString
        XCTAssertTrue(url.hasPrefix("https://yun.123pan.cn/b/api/file/list/new?driveId=0&limit=100&next=0&orderBy=update_time&orderDirection=desc&parentFileId=0&trashed=false"), url)
        XCTAssertNotNil(transport.requests[0].headers["auth-key"])
    }

    func testSaveToDriveCopiesAndPollsOnTheShareSubdomain() async throws {
        let session = ShareSession(platform: .pan123, shareId: "K-1", accessToken: "", title: "t")
        let transport = FakeTransport([
            ("user/info", json(#"{"code":0,"data":{"SpaceUsed":0,"SpacePermanent":10000,"SpaceTemp":0}}"#)),
            ("copy/save/get", json(#"{"code":0,"data":{"status":1}}"#)),
            ("copy/save/get", json(#"{"code":0,"data":{"status":2,"newFileId":"4242"}}"#)),
            ("copy/save", json(#"{"code":0,"data":{"taskID":88}}"#)),
        ])
        let sleeps = Box<UInt64>()
        let (provider, _) = pan(transport, sleeps: sleeps)
        // "copy/save" is listed last so the more specific "copy/save/get" rules win.
        let saved = try await provider.saveToDrive(session: session, file: shareFile, directoryId: nil, credential: token, skipSpaceCheck: false)
        XCTAssertEqual(saved, "4242")
        XCTAssertEqual(sleeps.values, [1_000_000_000, 1_000_000_000])
        let save = try XCTUnwrap(transport.requests.first { $0.method == .post })
        XCTAssertEqual(save.url.absoluteString, "https://1816216065.mshare.123pan.cn/b/api/restful/goapi/v1/file/copy/save")
        XCTAssertEqual(save.headers["Authorization"], "Bearer jwt.header.payload")
        XCTAssertEqual(save.headers["LoginUuid"], deviceId)
        XCTAssertNil(save.headers["auth-key"], "the mshare host takes no client sign")
        let index = try XCTUnwrap(transport.requests.firstIndex { $0.method == .post })
        let body = try transport.body(index)
        XCTAssertEqual(body["sharePwd"] as? String, "")
        XCTAssertTrue(body["superAdmin"] is NSNull)
        XCTAssertEqual(body["shareKey"] as? String, "K-1")
        let item = try XCTUnwrap((body["fileList"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["parentFileId"] as? Int, 0)
        XCTAssertEqual(item["StorageNode"] as? String, "node9")
        XCTAssertEqual(item["type"] as? Int, 0)
        XCTAssertTrue(transport.requests.last!.url.absoluteString.hasSuffix("copy/save/get?taskID=88"))
    }

    func testSaveToDriveFailureModes() async throws {
        let session = ShareSession(platform: .pan123, shareId: "K-1", accessToken: "", title: "t")
        let full = FakeTransport([("user/info", json(#"{"code":0,"data":{"SpaceUsed":9990,"SpacePermanent":10000,"SpaceTemp":0}}"#))])
        let (small, _) = pan(full)
        do { _ = try await small.saveToDrive(session: session, file: shareFile, directoryId: nil, credential: token, skipSpaceCheck: false); XCTFail() } catch {
            XCTAssertEqual(error as? DriveError, .insufficientSpace(required: 5000, available: 10))
        }
        XCTAssertEqual(full.requests.count, 1, "nothing is saved after a failed space check")

        let slow = FakeTransport([("copy/save/get", json(#"{"code":0,"data":{"status":1}}"#)), ("copy/save", json(#"{"code":0,"data":{"taskID":1}}"#))],
                                 fallback: json(#"{"code":0,"data":{"status":1}}"#))
        let (never, _) = pan(slow)
        do { _ = try await never.saveToDrive(session: session, file: shareFile, directoryId: "55", credential: token, skipSpaceCheck: true); XCTFail() } catch {
            XCTAssertEqual(error as? DriveError, .timedOut("转存超时或失败"))
        }
        XCTAssertEqual(slow.requests.count, 1 + Pan123Constants.copyPollAttempts)
        XCTAssertEqual(try slow.body(0)["fileList"].flatMap { ($0 as? [[String: Any]])?.first?["parentFileId"] as? Int }, 55)

        let (failed, _) = pan(FakeTransport([("copy/save/get", json(#"{"code":5,"message":"空间不足"}"#)), ("copy/save", json(#"{"code":0,"data":{"taskID":1}}"#))]))
        do { _ = try await failed.saveToDrive(session: session, file: shareFile, directoryId: nil, credential: token, skipSpaceCheck: true); XCTFail() } catch {
            XCTAssertEqual(error as? DriveError, .api(message: "转存失败：空间不足"))
        }
        let noKey = DriveFile(id: "1", name: "x", size: 1, isDirectory: false, parentId: "0", fileToken: "|e|")
        do { _ = try await failed.saveToDrive(session: session, file: noKey, directoryId: nil, credential: token, skipSpaceCheck: true); XCTFail() } catch {
            XCTAssertEqual(error as? DriveError, .api(message: "无法识别分享 ID（缺少 S3KeyFlag）"))
        }
    }

    func testAccountManagementRequests() async throws {
        let transport = FakeTransport([
            ("file/trash", json(#"{"code":0}"#)),
            ("file/rename", json(#"{"code":0}"#)),
            ("file/upload_request", json(#"{"code":0,"data":{"Info":{"FileId":321}}}"#)),
            ("file/mod_pid", json(#"{"code":0}"#)),
            ("share/create", json(#"{"code":0,"data":{"ShareKey":"SK-1","shareLinkList":{"list":["https://www.123pan.com/s/SK-1"]}}}"#)),
            ("share/create", json(#"{"code":0,"data":{"ShareKey":"SK-2"}}"#)),
        ])
        let (provider, _) = pan(transport)
        let api = provider.api
        try await api.deleteFiles([shareFile], token: token.value)
        try await api.renameFile(fileId: "777", newName: "new", token: token.value)
        let folder = try await api.createDir(parentFileId: "0", name: "dir", token: token.value)
        XCTAssertEqual(folder, "321")
        try await api.moveFiles(fileIds: ["1", "2"], toParentFileId: "9", token: token.value)
        let one = try await api.createShare(fileIds: ["777"], shareName: "n", expiration: Pan123Constants.expirationForever, sharePwd: "abcd", token: token.value)
        XCTAssertEqual(one, Pan123ShareInfo(shareURL: "https://www.123pan.com/s/SK-1", passcode: "abcd", shareKey: "SK-1", title: "n"))
        let many = try await api.createShare(fileIds: ["1", "2"], shareName: "n", expiration: "x", sharePwd: nil, token: token.value)
        XCTAssertEqual(many.shareURL, "https://www.123pan.com/s/SK-2")

        XCTAssertEqual(transport.paths(), ["/b/api/file/trash", "/b/api/file/rename", "/b/api/file/upload_request", "/b/api/file/mod_pid", "/b/api/share/create", "/b/api/share/create"])
        let trash = try transport.body(0)
        XCTAssertEqual(trash["event"] as? String, "intoRecycle")
        XCTAssertEqual((trash["fileTrashInfoList"] as? [[String: Any]])?.first?["Etag"] as? String, "etag1")
        let dir = try transport.body(2)
        XCTAssertEqual(dir["type"] as? Int, 1)
        XCTAssertEqual(dir["NotReuse"] as? Bool, true)
        XCTAssertEqual(transport.requests[2].headers["Content-Type"], "application/json;charset=UTF-8")
        XCTAssertEqual(try transport.body(4)["fileIdList"] as? Int, 777, "one file goes as a scalar")
        XCTAssertEqual(try transport.body(5)["fileIdList"] as? [Int], [1, 2])
        XCTAssertNil(try transport.body(5)["sharePwd"])
        XCTAssertEqual((try transport.body(3)["fileIdList"] as? [[String: Any]])?.count, 2)
    }

    func testFolderWithoutAnIdIsAnError() async {
        let (provider, _) = pan(FakeTransport(fallback: json(#"{"code":0,"data":{"FileId":"0"}}"#)))
        do { _ = try await provider.api.createDir(parentFileId: "0", name: "d", token: "t"); XCTFail() } catch {
            XCTAssertEqual(error as? DriveError, .api(message: "123 未返回文件夹编号"))
        }
    }

    func testNothingPrintsTheTokenOrPasswordAndNoDefaultDeviceIdIsBlank() async {
        let link = Pan123DownloadLink(fid: "1", filename: "f", downloadURL: "https://cdn/x?sign=SECRET", size: 1)
        let printed = "\(link) \(String(reflecting: link)) \(token) \(Pan123LoginResult.success(token))"
        XCTAssertFalse(printed.contains("SECRET"))
        XCTAssertFalse(printed.contains("jwt.header"))
        let generated = Pan123API(transport: FakeTransport()).deviceId
        XCTAssertEqual(generated.count, 32)
        XCTAssertEqual(Pan123API(transport: FakeTransport(), deviceId: "not-hex").deviceId.count, 32)
        XCTAssertEqual(Pan123API(transport: FakeTransport(), deviceId: deviceId).deviceId, deviceId)
    }

    func testRedirectProbeLiveClassKeepsNoCredentials() {
        let configuration = URLSessionTransport.makeConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
    }
}
