import XCTest
@testable import CloudDriveKit

/// Bodies are rebuilt from the field shapes in ILanzouApi.kt; none were captured from the live service.
final class ILanzouProviderTests: XCTestCase {
    private let token = "tok:en+abc/def=123456"
    private let uuidValue = "uuid-1234567890"
    private var credential: DriveCredential { ILanzouCredential(appToken: token, uuid: uuidValue, userId: "77").credential }
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func make(_ transport: FakeTransport, sleeps: Box<UInt64>? = nil) -> ILanzouProvider {
        let now = fixedNow
        return ILanzouProvider(api: ILanzouAPI(transport: transport, sleep: { sleeps?.add($0) }, now: { now }))
    }

    private func query(_ request: HTTPRequest) -> [String: String] {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    func testAESMatchesJavaCipherVectors() {
        // openssl enc -aes-128-ecb -K <hex of lanZouY-disk-app>
        XCTAssertEqual(ILanzouCrypto.aesHex("123|456"), "f2865dcb6c364c3214eaddc9ea47051a")
        XCTAssertEqual(ILanzouCrypto.aesHex("1700000000000"), "6e34576a3615fb11ef81f07a050bb9a3")
    }

    func testCredentialRoundTripAndRedaction() throws {
        let parsed = try XCTUnwrap(ILanzouCredential(credential))
        XCTAssertEqual(parsed, ILanzouCredential(appToken: token, uuid: uuidValue, userId: "77"))
        XCTAssertNil(ILanzouCredential(DriveCredential("appToken=short; uuid=uuid-1234567890")))
        XCTAssertNil(ILanzouCredential(DriveCredential("appToken=\(token)")))
        var dumped = ""
        dump(parsed, to: &dumped)
        XCTAssertFalse("\(parsed) \(dumped)".contains("abc/def"))
        let provider = make(FakeTransport())
        XCTAssertTrue(provider.isWellFormed(credential: credential))
        XCTAssertFalse(provider.isWellFormed(credential: DriveCredential("a=1")))
    }

    func testAccountStateAndQuotaUseKiBUnits() async {
        let map = json(#"{"code":200,"map":{"userId":77,"account":"a@b","nickName":"Leo","usedSize":10,"totalSize":100,"vipSize":20,"rewardSize":5}}"#)
        let transport = FakeTransport(fallback: map)
        let provider = make(transport)
        let state = await provider.accountState(credential: credential)
        XCTAssertEqual(state, .signedIn(nickname: "Leo"))
        let quota = await provider.quota(credential: credential)
        XCTAssertEqual(quota, DriveQuota(used: 10 * 1024, total: 125 * 1024))
        let unverified = await make(FakeTransport()).accountState(credential: credential)
        XCTAssertEqual(unverified, .unverified)
        let signedOut = await make(FakeTransport()).accountState(credential: DriveCredential("x=1"))
        XCTAssertEqual(signedOut, .signedOut)
    }

    func testAccountRequestShape() async throws {
        let transport = FakeTransport(fallback: json(#"{"code":200,"map":{"userId":"77","nickname":"N"}}"#))
        _ = await make(transport).accountState(credential: credential)
        let request = transport.requests[0]
        let urlText = request.url.absoluteString
        XCTAssertTrue(urlText.hasPrefix("https://apis.ilanzou.com/proved/user/account/map?uuid=uuid-1234567890&devType=6&devCode=uuid-1234567890&devModel=chrome&devVersion=125&appVersion=&timestamp="), urlText)
        // The appToken keeps its colon literal and escapes the other reserved characters.
        XCTAssertTrue(urlText.contains("&appToken=tok:en%2Babc%2Fdef%3D123456&extra=2"), urlText)
        XCTAssertEqual(query(request)["timestamp"], ILanzouCrypto.aesHex("1700000000000"))
        XCTAssertEqual(request.headers["Origin"], "https://www.ilanzou.com")
        XCTAssertEqual(request.headers["sec-fetch-site"], "same-site")
        XCTAssertNil(request.headers["Cookie"])
    }

    func testLoginPostsJSONAndSurfacesServerMessage() async throws {
        let api = ILanzouAPI(transport: FakeTransport([("unproved/getUuid", json(#"{"code":200,"uuid":"uuid-1234567890"}"#)),
                                                       ("unproved/login", json(#"{"code":200,"data":{"appToken":"tok:en+abc/def=123456"}}"#)),
                                                       ("account/map", json(#"{"code":200,"map":{"userId":77}}"#))]))
        let signedIn = try await api.signIn(loginName: " me ", loginPwd: "pw")
        XCTAssertEqual(signedIn, ILanzouCredential(appToken: token, uuid: uuidValue, userId: "77"))

        let transport = FakeTransport([("unproved/login", json(#"{"code":-1,"msg":"用户账号不存在"}"#))])
        do {
            _ = try await ILanzouAPI(transport: transport).login(loginName: "me", loginPwd: "pw", uuid: uuidValue)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "用户账号不存在", code: -1)) }
        XCTAssertEqual(try transport.body(0)["loginName"] as? String, "me")
        XCTAssertEqual(transport.requests[0].headers["Content-Type"], "application/json; charset=utf-8")
        XCTAssertFalse(transport.requests[0].url.absoluteString.contains("pw"))

        do {
            _ = try await ILanzouAPI(transport: FakeTransport()).login(loginName: " ", loginPwd: "pw", uuid: uuidValue)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "请输入蓝奏优享账号和密码")) }
    }

    func testListFilesMapsFoldersAndFilesAndPages() async throws {
        let page1 = json(#"{"code":200,"totalPage":2,"list":[{"fileType":2,"folderId":5,"folderName":"dir","updTime":"t1"},{"fileId":9,"fileName":"a.bin","fileSize":3,"addTime":"t2","fileType":1},{"fileId":0,"fileName":"skip"}]}"#)
        let page2 = json(#"{"code":200,"totalPage":2,"list":[{"fileId":"10","fileName":"b.bin","fileSize":1}]}"#)
        let transport = FakeTransport([("offset=1", page1), ("offset=2", page2)])
        let files = try await make(transport).listFiles(directoryId: "d:5", credential: credential)
        XCTAssertEqual(files, [
            DriveFile(id: "d:5", name: "dir", size: 0, isDirectory: true, parentId: "", modifiedAt: "t1"),
            DriveFile(id: "f:9", name: "a.bin", size: 3072, isDirectory: false, parentId: "", modifiedAt: "t2"),
            DriveFile(id: "f:10", name: "b.bin", size: 1024, isDirectory: false, parentId: ""),
        ])
        XCTAssertEqual(transport.requests.count, 2)
        let first = query(transport.requests[0])
        XCTAssertEqual(first["folderId"], "5")
        XCTAssertEqual(first["limit"], "60")
        XCTAssertEqual(first["type"], "0")
        XCTAssertEqual(first["extra"], "2")
    }

    func testRepeatedPageFailsLoudly() async {
        do {
            // totalPage 0 and a short page ends the loop, so force a full-size repeat.
            let full = (1...60).map { #"{"fileId":\#($0),"fileName":"f\#($0)"}"# }.joined(separator: ",")
            let repeated = json(#"{"code":200,"list":[\#(full)]}"#)
            _ = try await make(FakeTransport(fallback: repeated)).listFiles(directoryId: nil, credential: credential)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "蓝奏优享分页重复或不完整，请重新打开目录")) }
    }

    func testBusinessAndHTTPErrors() async {
        let cases: [(HTTPResponse, DriveError)] = [
            (json(#"{"code":-2}"#), .api(message: "蓝奏优享登录已过期，请重新登录", code: -2)),
            (json(#"{"msg":"x"}"#), .api(message: "蓝奏优享登录已过期，请重新登录", code: -1)),
            (json(#"{"code":500}"#), .api(message: "蓝奏优享请求失败（500），请检查登录信息或稍后重试", code: 500)),
            (json("", status: 403), .api(message: "蓝奏优享登录已过期，请重新登录", code: 403)),
            (json("oops", status: 502), .api(message: "蓝奏优享请求失败（502），请检查登录信息或稍后重试")),
            (json("<html>", status: 409), .api(message: "蓝奏优享请求失败（409），请检查登录信息或稍后重试")),
        ]
        for (response, expected) in cases {
            do {
                _ = try await make(FakeTransport(fallback: response)).listFiles(directoryId: nil, credential: credential)
                XCTFail("expected a failure")
            } catch { XCTAssertEqual(error as? DriveError, expected) }
        }
    }

    func testAccessChallengeRetriesOnce() async throws {
        var html = HTTPResponse(statusCode: 409, body: Data("<html>".utf8))
        html.headers = ["content-type": "text/html; charset=utf-8"]
        let ok = json(#"{"code":200,"list":[]}"#)
        let transport = FakeTransport([("record/file/list", html), ("record/file/list", ok)])
        let files = try await make(transport).listFiles(directoryId: nil, credential: credential)
        XCTAssertEqual(files, [])
        XCTAssertEqual(transport.requests.count, 2)

        let stuck = FakeTransport(fallback: html)
        do {
            _ = try await make(stuck).listFiles(directoryId: nil, credential: credential)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "蓝奏优享的访问验证未通过，请稍后重试或使用网页登录")) }
        XCTAssertEqual(stuck.requests.count, 2)
    }

    func testShareListingIsAnonymousAndUsesShareHost() async throws {
        let transport = FakeTransport([("getUuid", json(#"{"code":200,"uuid":"anon-uuid-12345"}"#)),
                                       ("share/list", json(#"{"code":200,"list":[{"fileType":2,"folderId":8,"folderName":"d"},{"fileId":3,"fileName":"x","fileSize":2}]}"#))])
        let provider = make(transport)
        let link = try XCTUnwrap(provider.parseShareLink("https://www.ilanzou.com/s/AbC12?pwd=zz"))
        let opened = try await provider.openShare(link, passcode: nil, credential: nil)
        XCTAssertEqual(opened.accessToken, "AbC12")
        let files = try await provider.listShareFiles(session: opened, directoryId: "d:8", credential: nil)
        XCTAssertEqual(files.map(\.id), ["d:8", "f:3"])
        let listRequest = transport.requests[1]
        XCTAssertEqual(listRequest.url.host, "apix.ilanzou.com")
        let q = query(listRequest)
        XCTAssertEqual(q["shareId"], "AbC12")
        XCTAssertEqual(q["folderId"], "8")
        XCTAssertEqual(q["uuid"], "anon-uuid-12345")
        XCTAssertEqual(q["devModel"], "Chrome")
        XCTAssertNil(q["appToken"])

        // The root sends no folderId, and the anonymous uuid is fetched only once.
        _ = try? await provider.listShareFiles(session: opened, directoryId: nil, credential: nil)
        XCTAssertEqual(transport.requests.filter { $0.url.path == "/unproved/getUuid" }.count, 1)
        XCTAssertNil(query(transport.requests[2])["folderId"])
    }

    func testShareDownloadFollowsLocationHeaderWithoutRedirecting() async throws {
        var redirect = HTTPResponse(statusCode: 302)
        redirect.headers = ["Location": "/cdn/file?sig=SECRETSIG"]
        let transport = FakeTransport(fallback: redirect)
        let shareSession = ShareSession(platform: .ilanzou, shareId: "AbC12", accessToken: "AbC12", title: "t")
        let file = DriveFile(id: "f:3", name: "x.bin", size: 2048, isDirectory: false, parentId: "")
        let link = try await make(transport).resolveShareFile(session: shareSession, file: file, credential: credential, options: ShareResolveOptions())
        XCTAssertEqual(link.url.absoluteString, "https://apix.ilanzou.com/cdn/file?sig=SECRETSIG")
        XCTAssertEqual(link.fileId, "f:3")
        XCTAssertEqual(link.headers["Referer"], "https://www.ilanzou.com/")
        XCTAssertEqual(link.headers["Origin"], "https://www.ilanzou.com")
        XCTAssertNil(link.headers["Cookie"])
        XCTAssertFalse("\(link) \(String(reflecting: link))".contains("SECRETSIG"))

        let request = transport.requests[0]
        XCTAssertFalse(request.followRedirects)
        XCTAssertTrue(request.url.absoluteString.hasPrefix("https://apix.ilanzou.com/unproved/file/redirect?downloadId=" + ILanzouCrypto.aesHex("3|77") + "&enable=1&devType=6&uuid=uuid-1234567890&timestamp="))
        let q = query(request)
        XCTAssertEqual(q["auth"], ILanzouCrypto.aesHex("3|1700000000000"))
        XCTAssertEqual(q["shareId"], "AbC12")
    }

    func testShareDownloadJSONFallbackAndFailures() async throws {
        let shareSession = ShareSession(platform: .ilanzou, shareId: "s", accessToken: "s", title: "t")
        let file = DriveFile(id: "f:3", name: "x", size: 0, isDirectory: false, parentId: "")
        let viaData = FakeTransport(fallback: json(#"{"code":200,"data":{"url":"https://cdn.example/x"}}"#))
        let link = try await make(viaData).resolveShareFile(session: shareSession, file: file, credential: credential, options: ShareResolveOptions())
        XCTAssertEqual(link.url.absoluteString, "https://cdn.example/x")

        let denied = FakeTransport(fallback: json(#"{"code":500,"msg":"分享已失效"}"#))
        do {
            _ = try await make(denied).resolveShareFile(session: shareSession, file: file, credential: credential, options: ShareResolveOptions())
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "分享已失效")) }

        let folder = DriveFile(id: "d:3", name: "d", size: 0, isDirectory: true, parentId: "")
        do {
            _ = try await make(FakeTransport()).resolveShareFile(session: shareSession, file: folder, credential: nil, options: ShareResolveOptions())
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "文件夹无法直接下载")) }
    }

    func testGuestShareDownloadUsesEmptyUserId() async throws {
        var redirect = HTTPResponse(statusCode: 302)
        redirect.headers = ["location": "https://cdn.example/g"]
        let transport = FakeTransport([("getUuid", json(#"{"code":200,"uuid":"anon-uuid-12345"}"#))], fallback: redirect)
        let shareSession = ShareSession(platform: .ilanzou, shareId: "s", accessToken: "s", title: "t")
        let file = DriveFile(id: "f:3", name: "x", size: 0, isDirectory: false, parentId: "")
        _ = try await make(transport).resolveShareFile(session: shareSession, file: file, credential: nil, options: ShareResolveOptions())
        XCTAssertEqual(query(transport.requests[1])["downloadId"], ILanzouCrypto.aesHex("3|"))
    }

    func testOwnFileResolveFillsMissingUserId() async throws {
        var redirect = HTTPResponse(statusCode: 302)
        redirect.headers = ["Location": "https://cdn.example/own"]
        let transport = FakeTransport([("account/map", json(#"{"code":200,"map":{"userId":88}}"#))], fallback: redirect)
        let bare = ILanzouCredential(appToken: token, uuid: uuidValue).credential
        let link = try await make(transport).resolveFile(id: "f:12", credential: bare)
        XCTAssertEqual(link.fileId, "f:12")
        let request = transport.requests[1]
        XCTAssertEqual(query(request)["downloadId"], ILanzouCrypto.aesHex("12|88"))
        XCTAssertNil(query(request)["extra"])
        XCTAssertEqual(query(request)["appToken"], token)
        XCTAssertFalse(request.followRedirects)
        // Two timestamp parameters, as the source builds them.
        XCTAssertEqual(request.url.absoluteString.components(separatedBy: "timestamp=").count - 1, 2)
    }

    func testSaveToDriveStartsAndPollsTransfer() async throws {
        let sleeps = Box<UInt64>()
        let transport = FakeTransport([("file/transfer?", json(#"{"code":200,"data":{"transferKey":"K1"}}"#)),
                                       ("transfer/num", json(#"{"code":200,"map":{"num":0}}"#)),
                                       ("transfer/num", json(#"{"code":200,"map":{"num":1}}"#))])
        let shareSession = ShareSession(platform: .ilanzou, shareId: "s", accessToken: "s", title: "t")
        let folder = DriveFile(id: "d:4", name: "d", size: 0, isDirectory: true, parentId: "")
        let target = try await make(transport, sleeps: sleeps).saveToDrive(session: shareSession, file: folder, directoryId: nil, credential: credential, skipSpaceCheck: false)
        XCTAssertEqual(target, "0")
        let body = try transport.body(0)
        XCTAssertEqual(body["targetFolderId"] as? String, "4")
        XCTAssertEqual(body["targetFileId"] as? String, "")
        XCTAssertEqual(body["folderId"] as? String, "0")
        XCTAssertEqual(body["shareId"] as? String, "s")
        XCTAssertEqual(sleeps.values, [500_000_000, 500_000_000])
        XCTAssertEqual(query(transport.requests[1])["transferKey"], "K1")
    }

    func testSaveToDriveTimesOutAndNeedsLogin() async {
        let transport = FakeTransport([("file/transfer?", json(#"{"code":200,"data":{"transferKey":"K1"}}"#))], fallback: json(#"{"code":200,"map":{"num":0}}"#))
        let shareSession = ShareSession(platform: .ilanzou, shareId: "s", accessToken: "s", title: "t")
        let file = DriveFile(id: "f:4", name: "f", size: 1, isDirectory: false, parentId: "")
        let sleeps = Box<UInt64>()
        do {
            _ = try await make(transport, sleeps: sleeps).saveToDrive(session: shareSession, file: file, directoryId: "d:9", credential: credential, skipSpaceCheck: false)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .timedOut("蓝奏优享仍在处理转存，请稍后刷新列表")) }
        XCTAssertEqual(sleeps.values.count, 30)
        XCTAssertEqual(try? transport.body(0)["targetFileId"] as? String, "4")
        XCTAssertEqual(try? transport.body(0)["folderId"] as? String, "9")

        do {
            _ = try await make(FakeTransport()).saveToDrive(session: shareSession, file: file, directoryId: nil, credential: DriveCredential("x"), skipSpaceCheck: false)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .loginRequired) }
    }

    func testFileManagementBodies() async throws {
        let transport = FakeTransport(fallback: json(#"{"code":200,"list":[{"id":42}]}"#))
        let api = ILanzouAPI(transport: transport, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let id = try await api.createDir(appToken: token, uuid: uuidValue, parentId: "", name: "新建")
        XCTAssertEqual(id, "42")
        try await api.renameFolder(appToken: token, uuid: uuidValue, folderId: "5", newName: "n")
        try await api.renameFile(appToken: token, uuid: uuidValue, fileId: "6", newName: "m")
        try await api.moveEntries(appToken: token, uuid: uuidValue, folderIds: ["1", "2"], fileIds: ["3"], targetId: "")
        try await api.deleteEntries(appToken: token, uuid: uuidValue, folderIds: [], fileIds: ["3", "4"])
        XCTAssertEqual(transport.paths(), ["/proved/file/folder/save", "/proved/file/folder/edit", "/proved/file/edit", "/proved/file/folder/move", "/proved/file/delete"])
        XCTAssertEqual(try transport.body(0)["folderId"] as? String, "0")
        XCTAssertEqual(try transport.body(0)["folderName"] as? String, "新建")
        XCTAssertEqual(try transport.body(3)["folderIds"] as? String, "1,2")
        XCTAssertEqual(try transport.body(3)["targetId"] as? String, "0")
        XCTAssertEqual(try transport.body(4)["fileIds"] as? String, "3,4")
        XCTAssertEqual(try transport.body(4)["status"] as? Int, 0)
    }

    func testHTTPResponseHeaderLookupIsCaseInsensitive() {
        var response = HTTPResponse()
        response.headers = ["lOcAtIoN": "x"]
        XCTAssertEqual(response.header("Location"), "x")
        let url = URL(string: "https://a.example/x")!
        let http = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "/y", "Set-Cookie": "a=SECRET"])!
        XCTAssertEqual(URLSessionTransport.headers(from: http), ["location": "/y"])
    }
}
