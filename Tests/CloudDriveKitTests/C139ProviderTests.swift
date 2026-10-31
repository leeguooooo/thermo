import XCTest
@testable import CloudDriveKit

// Response bodies are rebuilt from the field shapes read in C139Api.kt and the two 139 repositories.
// None was captured from the live service, and no real account was used. The signature and AES vectors
// were computed with an independent Python/OpenSSL implementation of the algorithm written in C139Api.kt.

private let c139Authorization = "Basic " + Data("pc:13800001111:TOKENSECRET".utf8).base64EncodedString()
private let c139Cookie = DriveCredential("Login_UserNumber=13800001111; authorization=\(c139Authorization); skey=SKEYSECRET")
private let c139Session = ShareSession(platform: .c139, shareId: "link1", accessToken: "pw12", title: "t")
private let c139File = DriveFile(id: "co1", name: "movie.mkv", size: 100, isDirectory: false, parentId: "root")
private let c139IV = Array(UInt8(0)..<UInt8(16))

private func c139Environment() -> C139Environment {
    C139Environment(now: { Date(timeIntervalSince1970: 1_700_000_000) }, nonce: { "AbCdEfGhIjKlMnOp" }, iv: { c139IV })
}

private func c139Provider(_ transport: FakeTransport, sleeps: Box<UInt64>? = nil) -> C139Provider {
    C139Provider(api: C139API(transport: transport, environment: c139Environment()), sleep: { sleeps?.add($0) })
}

/// A share endpoint answer: the gateway returns the JSON AES-encrypted.
private func encrypted(_ text: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, body: Data(try! C139Crypto.encryptBody(text, iv: c139IV).utf8))
}

private func decryptedBody(_ transport: FakeTransport, _ index: Int) throws -> LenientJSON {
    let body = String(decoding: try XCTUnwrap(transport.requests[index].body), as: UTF8.self)
    return try XCTUnwrap(LenientJSON(data: Data(try C139Crypto.decryptBody(body).utf8)))
}

final class C139ProviderTests: XCTestCase {
    func testSignatureAndEncodingKnownAnswers() {
        let body = "{\"fileId\":\"a b~!(x)\u{4E2D}\",\"n\":1}"
        XCTAssertEqual(C139Crypto.encodeURIComponent(body), "%7B%22fileId%22%3A%22a%20b%7E!(x)%E4%B8%AD%22%2C%22n%22%3A1%7D")
        XCTAssertEqual(C139Crypto.calSign(bodyJSON: body, timestamp: "2024-05-06 07:08:09", nonce: "AbCdEfGhIjKlMnOp"), "AB5377EE9962767BB33739B19BBF31B8")
    }

    func testBodyEncryptionKnownAnswersAndGzip() throws {
        XCTAssertEqual(try C139Crypto.encryptBody(#"{"hello":"world"}"#, iv: c139IV), "AAECAwQFBgcICQoLDA0OD96U837wLVQYsMEm8LOba2ZnRIYNhUknzi4I2divtbEc")
        XCTAssertEqual(try C139Crypto.decryptBody("AAECAwQFBgcICQoLDA0OD96U837wLVQYsMEm8LOba2ZnRIYNhUknzi4I2divtbEc"), #"{"hello":"world"}"#)
        let gzipped = "AAECAwQFBgcICQoLDA0ODxyBtLf2fRbNxOThTI0RRObp1X6pqzH5GpY8E3tR/UlNKemJVQaVaHWnOKJMm9XX8c8BzSylsoT1vWZrHVTCQ7E="
        XCTAssertEqual(try C139Crypto.decryptBody(gzipped), #"{"resultCode":"0","data":{"x":"gz"}}"#)
        XCTAssertThrowsError(try C139Crypto.decryptBody("not base64 !"))
        XCTAssertThrowsError(try C139Crypto.decryptBody("AAECAwQFBgcICQoLDA0ODw=="))
    }

    func testRoutingCapabilitiesAndCookieRules() {
        let link = ShareLinkRouter.parse("https://yun.139.com/shareweb/#/w/i/2qiuK9Z 提取码：ab12")
        XCTAssertEqual(link, ParsedShareLink(shareId: "2qiuK9Z", passcode: "ab12", platform: .c139))
        XCTAssertEqual(C139Provider().parseShareLink("https://yun.139.com/shareweb/#/w/i/abc")?.shareId, "abc")
        XCTAssertNil(C139Provider().parseShareLink("https://pan.quark.cn/s/abc"))
        XCTAssertNil(C139Provider().credentialRefreshInterval)
        XCTAssertEqual(C139Provider().capabilities, [.shareListing, .guestShareAccess, .ownFiles, .saveToDrive])

        XCTAssertTrue(C139Constants.isValidCookie("a=1; authorization=Basic xyz"))
        XCTAssertTrue(C139Constants.isValidCookie("Os_SSo_Sid=1; RMKEY=2"))
        XCTAssertFalse(C139Constants.isValidCookie("Os_SSo_Sid=1"))
        XCTAssertFalse(C139Constants.isValidCookie("authorization="))
        XCTAssertFalse(C139Constants.isValidCookie(nil))
        XCTAssertEqual(C139Constants.extractAuthorization(c139Cookie.value), c139Authorization)
        XCTAssertEqual(C139Constants.extractAccountFull(c139Cookie.value), "13800001111")
        XCTAssertEqual(C139Constants.extractAccountFull("ORCHES-I-ACCOUNT-ENCRYPT=\(Data("13900002222".utf8).base64EncodedString()); authorization=\(c139Authorization)"), "13900002222")
        XCTAssertEqual(C139Constants.extractAccountFull("authorization=\(c139Authorization)"), "13800001111")
        XCTAssertEqual(C139Constants.extractAccount("ORCHES-I-ACCOUNT-SIMPLIFY=138****1111; Login_UserNumber=1"), "138****1111")
        XCTAssertEqual(C139Constants.extractAccount("Login_UserNumber=777"), "777")
        XCTAssertNil(C139Constants.extractAccount("a=1"))
    }

    func testAccountStateReadsTheCookieWithoutARequest() async {
        let transport = FakeTransport()
        let provider = c139Provider(transport)
        let masked = await provider.accountState(credential: DriveCredential("ORCHES-I-ACCOUNT-SIMPLIFY=138****1111; authorization=Basic x"))
        XCTAssertEqual(masked, .signedIn(nickname: "138****1111"))
        let anonymous = await provider.accountState(credential: DriveCredential("authorization=Basic x"))
        XCTAssertEqual(anonymous, .signedIn(nickname: "139用户"))
        let signedOut = await provider.accountState(credential: DriveCredential("a=1"))
        XCTAssertEqual(signedOut, .signedOut)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testOpenShareIsAnonymousEncryptedAndPrefersTypedPasscode() async throws {
        let general = encrypted(#"{"resultCode":"0","success":true,"data":{"getOutLinkGeneralResp":{"outLinkGeneral":[{"lkName":"我的分享","passwd":"leak"}]}}}"#)
        let transport = FakeTransport([("getOutLinkGeneral", general), ("getOutLinkGeneral", general), ("getOutLinkGeneral", general)])
        let provider = c139Provider(transport)
        let link = ParsedShareLink(shareId: "link1", passcode: "fromLink", platform: .c139)
        let typed = try await provider.openShare(link, passcode: " typed ".trimmingCharacters(in: .whitespaces), credential: nil)
        XCTAssertEqual(typed.accessToken, "typed")
        XCTAssertEqual(typed.title, "我的分享")
        XCTAssertEqual(typed.platform, .c139)
        let fromLink = try await provider.openShare(link, passcode: nil, credential: nil)
        XCTAssertEqual(fromLink.accessToken, "fromLink")
        let leaked = try await provider.openShare(ParsedShareLink(shareId: "link1", passcode: nil, platform: .c139), passcode: "  ", credential: nil)
        XCTAssertEqual(leaked.accessToken, "leak")

        let request = transport.requests[0]
        XCTAssertEqual(request.url.absoluteString, "https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/getOutLinkGeneral")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.headers["hcy-cool-flag"], "1")
        XCTAssertEqual(request.headers["x-deviceinfo"], "||3|12.27.0|||||chrome 150.0.0.0|360X444|zh-cn|||")
        XCTAssertEqual(request.headers["x-huawei-channelsrc"], "10245500")
        XCTAssertEqual(request.headers["x-mm-source"], "0002")
        XCTAssertEqual(request.headers["User-Agent"], C139Constants.shareMobileUserAgent)
        XCTAssertNil(request.headers["Authorization"], "title lookup is anonymous")
        XCTAssertNil(request.headers["mcloud-sign"])
        XCTAssertNil(request.headers["Cookie"])
        let plain = try decryptedBody(transport, 0)
        let inner = try XCTUnwrap(plain.child("getOutLinkGeneralReq"))
        XCTAssertEqual(inner.string("linkID"), "link1")
        XCTAssertEqual(inner.int("isPasswd"), 1)
        XCTAssertEqual(inner.string("account"), "")
    }

    func testOpenShareFallsBackToLinkIdAndAcceptsPlainJSON() async throws {
        let failed = encrypted(#"{"resultCode":"9999","desc":"x"}"#)
        let provider = c139Provider(FakeTransport(fallback: failed))
        let opened = try await provider.openShare(ParsedShareLink(shareId: "link1", passcode: nil, platform: .c139), passcode: nil, credential: nil)
        XCTAssertEqual(opened.title, "link1")
        XCTAssertEqual(opened.accessToken, "")

        let plain = json(#"{"success":true,"data":{"getOutLinkGeneralResp":{"outLinkGeneral":[{"lkName":"T"}]}}}"#)
        let passthrough = try await c139Provider(FakeTransport(fallback: plain)).openShare(ParsedShareLink(shareId: "a", passcode: nil, platform: .c139), passcode: nil, credential: nil)
        XCTAssertEqual(passthrough.title, "T")
    }

    func testShareListingMergesFoldersAndFilesAndMapsRoot() async throws {
        let page = encrypted(#"""
        {"resultCode":"0","data":{
          "caLst":[{"caID":"ca1","caName":"子目录","udTime":"20240101","ctTime":"20230101"}],
          "coLst":[{"coID":"co1","coName":"a.bin","coSize":12,"coType":1,"udTime":"","ctTime":"20230202"},
                   {"coID":"co2","coName":"nested","coType":2},
                   {"coID":"co3","coName":"flag","isdir":true}]}}
        """#)
        let transport = FakeTransport(fallback: page)
        let files = try await c139Provider(transport).listShareFiles(session: c139Session, directoryId: nil, credential: nil)
        XCTAssertEqual(files, [
            DriveFile(id: "ca1", name: "子目录", size: 0, isDirectory: true, parentId: "root", modifiedAt: "20240101"),
            DriveFile(id: "co1", name: "a.bin", size: 12, isDirectory: false, parentId: "root", modifiedAt: "20230202"),
            DriveFile(id: "co2", name: "nested", size: 0, isDirectory: true, parentId: "root"),
            DriveFile(id: "co3", name: "flag", size: 0, isDirectory: true, parentId: "root"),
        ])
        XCTAssertEqual(transport.requests.count, 1, "a short page ends the loop")
        let inner = try XCTUnwrap(try decryptedBody(transport, 0).child("getOutLinkInfoReq"))
        XCTAssertEqual(inner.string("pCaID"), "root")
        XCTAssertEqual(inner.string("passwd"), "pw12")
        XCTAssertEqual(inner.string("account"), "")
        XCTAssertEqual([inner.int("caSrt"), inner.int("coSrt"), inner.int("srtDr"), inner.int("bNum"), inner.int("eNum")], [1, 1, 0, 1, 200])
        XCTAssertNil(transport.requests[0].headers["Authorization"])
        XCTAssertNil(transport.requests[0].headers["mcloud-sign"])

        let sub = FakeTransport(fallback: page)
        _ = try await c139Provider(sub).listShareFiles(session: c139Session, directoryId: "ca9", credential: c139Cookie)
        XCTAssertEqual(try decryptedBody(sub, 0).child("getOutLinkInfoReq")?.string("pCaID"), "ca9")
        XCTAssertNil(sub.requests[0].headers["Cookie"], "listing never sends the account")
    }

    func testShareListingPagesByTwoHundredAndStopsOnARepeat() async throws {
        func page(_ range: Range<Int>) -> HTTPResponse {
            let items = range.map { #"{"coID":"c\#($0)","coName":"n\#($0)","coSize":1}"# }.joined(separator: ",")
            return encrypted(#"{"resultCode":"0","data":{"coLst":[\#(items)]}}"#)
        }
        let transport = FakeTransport([("getOutLinkInfoV6", page(0..<200)), ("getOutLinkInfoV6", page(200..<205))])
        let files = try await c139Provider(transport).listShareFiles(session: c139Session, directoryId: nil, credential: nil)
        XCTAssertEqual(files.count, 205)
        XCTAssertEqual(try decryptedBody(transport, 1).child("getOutLinkInfoReq")?.int("bNum"), 201)
        XCTAssertEqual(try decryptedBody(transport, 1).child("getOutLinkInfoReq")?.int("eNum"), 400)

        let stuck = FakeTransport(fallback: page(0..<200))
        let capped = try await c139Provider(stuck).listShareFiles(session: c139Session, directoryId: nil, credential: nil)
        XCTAssertEqual(capped.count, 200)
        XCTAssertEqual(stuck.requests.count, 2)
    }

    func testShareErrorsKeepServerMessages() async {
        let cases: [(HTTPResponse, DriveError)] = [
            (encrypted(#"{"resultCode":"9188","desc":"提取码错误"}"#), .api(message: "提取码错误", code: 9188)),
            (encrypted(#"{"resultCode":"9530"}"#), .api(message: "获取文件列表失败（9530）", code: 9530)),
            (encrypted(#"{"success":false,"desc":"没有权限"}"#), .api(message: "没有权限")),
            (json("<html>", status: 502), .api(message: "响应解析失败（HTTP 502）")),
            (json(""), .api(message: "请求失败：响应为空")),
        ]
        for (response, expected) in cases {
            do {
                _ = try await c139Provider(FakeTransport(fallback: response)).listShareFiles(session: c139Session, directoryId: nil, credential: nil)
                XCTFail("expected a failure")
            } catch { XCTAssertEqual(error as? DriveError, expected) }
        }
    }

    func testResolveShareFileSignsOverThePlainBody() async throws {
        let transport = FakeTransport([("dlFromOutLinkV3", encrypted(#"{"resultCode":"0","data":{"redrUrl":"https://obs.example/x?sig=1","coSize":321}}"#))])
        let link = try await c139Provider(transport).resolveShareFile(session: c139Session, file: c139File, credential: c139Cookie, options: ShareResolveOptions())
        XCTAssertEqual(link.url.absoluteString, "https://obs.example/x?sig=1")
        XCTAssertEqual(link.filename, "movie.mkv", "the response has no name, so the listed one is used")
        XCTAssertEqual(link.size, 321)
        XCTAssertEqual(link.fileId, "co1")
        XCTAssertEqual(link.headers, ["User-Agent": C139Constants.pcUserAgent])
        XCTAssertNil(link.cleanupDirectoryId)

        let request = transport.requests[0]
        XCTAssertEqual(request.headers["Authorization"], c139Authorization)
        XCTAssertEqual(request.headers["hcy-cool-flag"], "1")
        XCTAssertNil(request.headers["Cookie"])
        let inner = try XCTUnwrap(try decryptedBody(transport, 0).child("dlFromOutLinkReqV3"))
        XCTAssertEqual(inner.string("account"), "13800001111")
        XCTAssertEqual(inner.string("linkID"), "link1")
        XCTAssertEqual(inner.child("coIDLst")?.array("item") as? [String], ["co1"])
        XCTAssertEqual(inner.child("commonAccountInfo")?.int("accountType"), 1)

        let plain = String(decoding: try C139Crypto.decryptBody(String(decoding: try XCTUnwrap(request.body), as: UTF8.self)).utf8, as: UTF8.self)
        let parts = try XCTUnwrap(request.headers["mcloud-sign"]).components(separatedBy: ",")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[1], "AbCdEfGhIjKlMnOp")
        XCTAssertNotNil(parts[0].range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression))
        XCTAssertEqual(parts[2], C139Crypto.calSign(bodyJSON: plain, timestamp: parts[0], nonce: parts[1]))
    }

    func testResolveShareFileNeedsAnAccount() async {
        let provider = c139Provider(FakeTransport())
        do {
            _ = try await provider.resolveShareFile(session: c139Session, file: c139File, credential: nil, options: ShareResolveOptions())
            XCTFail("a guest cannot resolve")
        } catch { XCTAssertEqual(error as? DriveError, .loginRequired) }
        do {
            _ = try await provider.resolveShareFile(session: c139Session, file: c139File, credential: DriveCredential("Os_SSo_Sid=1; RMKEY=2"), options: ShareResolveOptions())
            XCTFail("no account in the cookie")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "登录态缺少账号信息，请重新登录")) }
    }

    func testResolveShareFileWithoutAuthorizationOmitsTheHeader() async throws {
        let transport = FakeTransport(fallback: encrypted(#"{"data":{"redrUrl":"https://obs.example/y","fileName":"n.bin","size":5}}"#))
        let link = try await c139Provider(transport).resolveShareFile(session: c139Session, file: DriveFile(id: "co1", name: "", size: 0, isDirectory: false, parentId: "root"),
                                                                      credential: DriveCredential("Login_UserNumber=13800001111"), options: ShareResolveOptions())
        XCTAssertNil(transport.requests[0].headers["Authorization"])
        XCTAssertNotNil(transport.requests[0].headers["mcloud-sign"])
        XCTAssertEqual(link.filename, "n.bin")
        XCTAssertEqual(link.size, 5)
    }

    func testResolveShareFileFailures() async {
        let cases: [(HTTPResponse, DriveError)] = [
            (encrypted(#"{"resultCode":"9188","desc":"提取码错误"}"#), .api(message: "提取码错误", code: 9188)),
            (encrypted(#"{"resultCode":"0","data":{}}"#), .api(message: "获取下载链接失败")),
            (encrypted(#"{"resultCode":"0"}"#), .api(message: "获取下载链接失败")),
        ]
        for (response, expected) in cases {
            do {
                _ = try await c139Provider(FakeTransport(fallback: response)).resolveShareFile(session: c139Session, file: c139File, credential: c139Cookie, options: ShareResolveOptions())
                XCTFail("expected a failure")
            } catch { XCTAssertEqual(error as? DriveError, expected) }
        }
    }

    func testPersonalListingUsesPlainSignedRequestsWithTheChannelHeaders() async throws {
        let first = json(#"{"success":true,"code":"0000","data":{"items":[{"fileId":"f1","name":"d","type":"folder","updatedAt":"t1"},{"fileId":"f2","name":"a.bin","type":"file","size":9,"updatedAt":"t2"}],"nextPageCursor":"c2"}}"#)
        let second = json(#"{"success":true,"code":"0000","data":{"items":[{"fileId":"f3","name":"b","type":"file","size":1}],"nextPageCursor":""}}"#)
        let transport = FakeTransport([("hcy/file/list", first), ("hcy/file/list", second)])
        let files = try await c139Provider(transport).listFiles(directoryId: nil, credential: c139Cookie)
        XCTAssertEqual(files, [
            DriveFile(id: "f1", name: "d", size: 0, isDirectory: true, parentId: "/", fileToken: "f1", modifiedAt: "t1"),
            DriveFile(id: "f2", name: "a.bin", size: 9, isDirectory: false, parentId: "/", fileToken: "f2", modifiedAt: "t2"),
            DriveFile(id: "f3", name: "b", size: 1, isDirectory: false, parentId: "/", fileToken: "f3"),
        ])
        let request = transport.requests[0]
        XCTAssertEqual(request.url.absoluteString, "https://personal-kd-njs.yun.139.com/hcy/file/list")
        let firstBody = try transport.body(0)
        XCTAssertEqual(firstBody["parentFileId"] as? String, "/")
        XCTAssertEqual(firstBody["orderBy"] as? String, "updated_at")
        XCTAssertEqual(firstBody["orderDirection"] as? String, "DESC")
        XCTAssertEqual(firstBody["imageThumbnailStyleList"] as? [String], ["Small", "Large"])
        XCTAssertEqual((firstBody["pageInfo"] as? [String: Any])?["pageSize"] as? Int, 100)
        XCTAssertTrue((firstBody["pageInfo"] as? [String: Any])?["pageCursor"] is NSNull)
        XCTAssertEqual((try transport.body(1)["pageInfo"] as? [String: Any])?["pageCursor"] as? String, "c2")

        let expected: [String: String] = [
            "Authorization": c139Authorization, "x-yun-channel-source": "10000034", "x-yun-app-channel": "10000034",
            "x-huawei-channelSrc": "10000034", "mcloud-version": "7.17.9", "mcloud-client": "10701", "mcloud-channel": "1000101",
            "mcloud-route": "001", "x-yun-module-type": "100", "x-yun-api-version": "v1", "x-yun-svc-type": "1", "x-SvcType": "1",
            "caller": "web", "x-inner-ntwk": "2", "CMS-DEVICE": "default", "x-m4c-src": "10002", "x-m4c-caller": "PC",
            "X-Deviceinfo": C139Constants.xDeviceinfo, "x-yun-client-info": C139Constants.xClientInfo, "INNER-HCY-ROUTER-HTTPS": "1",
            "Sec-Fetch-Site": "same-site", "Sec-Fetch-Mode": "cors", "Sec-Fetch-Dest": "empty", "X-Requested-With": "mark.via",
            "Content-Type": "application/json;charset=UTF-8", "User-Agent": C139Constants.pcUserAgent,
            "Origin": "https://yun.139.com", "Referer": "https://yun.139.com/", "Accept": "application/json, text/plain, */*",
        ]
        for (name, value) in expected { XCTAssertEqual(request.headers[name], value, name) }
        XCTAssertNil(request.headers["Cookie"], "plain drive calls carry no cookie")
        XCTAssertNil(request.headers["mcloud-skey"])
        XCTAssertNil(request.headers["hcy-cool-flag"])
        let parts = try XCTUnwrap(request.headers["mcloud-sign"]).components(separatedBy: ",")
        let sent = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertEqual(parts[2], C139Crypto.calSign(bodyJSON: sent, timestamp: parts[0], nonce: parts[1]))
    }

    func testPersonalCallsRequireAuthorizationAndReportCodes() async {
        do {
            _ = try await c139Provider(FakeTransport()).listFiles(directoryId: nil, credential: DriveCredential("Os_SSo_Sid=1; RMKEY=2"))
            XCTFail("no authorization")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "登录态缺少 authorization，请重新登录")) }

        let cases: [(HTTPResponse, DriveError)] = [
            (json(#"{"success":false,"code":"04000005","message":"认证失败"}"#), .api(message: "认证失败（code=04000005）")),
            (json(#"{"code":"9999"}"#), .api(message: "获取文件列表失败（code=9999）")),
            (json("<html>", status: 404), .api(message: "响应解析失败（HTTP 404）")),
        ]
        for (response, expected) in cases {
            do {
                _ = try await c139Provider(FakeTransport(fallback: response)).listFiles(directoryId: "d", credential: c139Cookie)
                XCTFail("expected a failure")
            } catch {
                guard case .api(let message, _)? = error as? DriveError, case .api(let want, _) = expected else { return XCTFail("wrong error \(error)") }
                XCTAssertEqual(message, want)
                XCTAssertFalse(message.contains("TOKENSECRET"))
            }
        }
    }

    func testFolderRenameMoveDeleteAndTask() async throws {
        let ok = json(#"{"success":true,"code":"0000","data":{"fileId":"nf","taskId":"t1"}}"#)
        let transport = FakeTransport(fallback: ok)
        let api = C139API(transport: transport, environment: c139Environment())
        let cookie = c139Cookie.value
        let folder = try await api.createFolder(parentId: "/", name: "新建", cookie: cookie)
        XCTAssertEqual(folder, "nf")
        try await api.renameFile(fileId: "f1", newName: "x", cookie: cookie)
        let moved = try await api.moveFiles(fileIds: ["a", "b"], toParentId: "p", cookie: cookie)
        XCTAssertEqual(moved, "t1")
        let deleted = try await api.deleteFiles(fileIds: ["a"], cookie: cookie)
        XCTAssertEqual(deleted, "t1")
        XCTAssertEqual(transport.paths(), ["/hcy/file/create", "/hcy/file/update", "/hcy/file/batchMove", "/hcy/recyclebin/batchTrash"])
        let create = try transport.body(0)
        XCTAssertEqual(create["type"] as? String, "folder")
        XCTAssertEqual(create["fileRenameMode"] as? String, "force_rename")
        XCTAssertEqual(create["description"] as? String, "")
        XCTAssertEqual(try transport.body(1)["name"] as? String, "x")
        XCTAssertEqual(try transport.body(2)["toParentFileId"] as? String, "p")
        XCTAssertEqual(try transport.body(2)["fileIds"] as? [String], ["a", "b"])

        let noId = C139API(transport: FakeTransport(fallback: json(#"{"success":true,"code":"0000","data":{}}"#)), environment: c139Environment())
        do {
            _ = try await noId.createFolder(parentId: "/", name: "x", cookie: cookie)
            XCTFail("no id")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "移动云盘未返回文件夹编号")) }

        let task = C139API(transport: FakeTransport(fallback: json(#"{"success":true,"code":"0000","data":{"taskInfo":{"status":"Succeed","progress":100},"batchFileResults":[{"fileId":"a","errCode":"0"}]}}"#)), environment: c139Environment())
        let status = try await task.getTask(taskId: "t1", cookie: cookie)
        XCTAssertEqual(status, C139TaskStatus(status: "Succeed", progress: 100, results: [("a", "0")]))
    }

    func testResolveOwnFile() async throws {
        let transport = FakeTransport(fallback: json(#"{"success":true,"code":"0000","data":{"url":"https://obs.example/own?x=1","size":77}}"#))
        let link = try await c139Provider(transport).resolveFile(id: "f9", credential: c139Cookie)
        XCTAssertEqual(link.url.absoluteString, "https://obs.example/own?x=1")
        XCTAssertEqual(link.size, 77)
        XCTAssertEqual(link.filename, "f9", "the response has no name")
        XCTAssertEqual(link.headers, ["User-Agent": C139Constants.pcUserAgent])
        XCTAssertEqual(transport.paths(), ["/hcy/file/getDownloadUrl"])
        XCTAssertEqual(try transport.body(0)["fileId"] as? String, "f9")
        do {
            _ = try await c139Provider(FakeTransport(fallback: json(#"{"success":true,"code":"0000","data":{}}"#))).resolveFile(id: "f9", credential: c139Cookie)
            XCTFail("no url")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "获取下载链接失败")) }
    }

    func testCreateShareRequestAndResult() async throws {
        let created = json(#"{"success":true,"code":"0","data":{"getOutLinkRes":{"getOutLinkResSet":[{"linkUrl":"https://yun.139.com/shareweb/#/w/i/L1","passwd":"k3y9","linkID":"L1"}]}}}"#)
        let transport = FakeTransport(fallback: created)
        let api = C139API(transport: transport, environment: c139Environment())
        let forever = try await api.createShare(fileIds: ["f1"], folderIds: ["d1"], periodDays: nil, name: "分享", cookie: c139Cookie.value)
        XCTAssertEqual(forever, C139ShareInfo(shareURL: "https://yun.139.com/shareweb/#/w/i/L1", passcode: "k3y9", linkId: "L1", title: "分享", expiredType: 1))
        let week = try await api.createShare(fileIds: ["f1"], folderIds: [], periodDays: 7, name: "分享", cookie: c139Cookie.value)
        XCTAssertEqual(week.expiredType, 3)
        let odd = try await api.createShare(fileIds: ["f1"], folderIds: [], periodDays: 5, name: "分享", cookie: c139Cookie.value)
        XCTAssertEqual(odd.expiredType, 0)

        XCTAssertEqual(transport.requests[0].url.absoluteString, "https://yun.139.com/orchestration/personalCloud-rebuild/outlink/v1.0/getOutLink")
        XCTAssertEqual(transport.requests[0].headers["Cookie"], c139Cookie.value)
        XCTAssertEqual(transport.requests[0].headers["mcloud-skey"], "SKEYSECRET")
        let body = try XCTUnwrap(try transport.body(0)["getOutLinkReq"] as? [String: Any])
        XCTAssertNil(body["period"], "forever sends no period")
        XCTAssertEqual(body["periodUnit"] as? Int, 1)
        XCTAssertEqual(body["pubType"] as? Int, 1)
        XCTAssertEqual(body["encrypt"] as? Int, 1)
        XCTAssertEqual(body["coIDLst"] as? [String], ["f1"])
        XCTAssertEqual(body["caIDLst"] as? [String], ["d1"])
        XCTAssertEqual(body["dedicatedName"] as? String, "分享")
        XCTAssertEqual((body["extInfo"] as? [String: Any])?["shareChannel"] as? String, "3001")
        XCTAssertEqual((body["commonAccountInfo"] as? [String: Any])?["account"] as? String, "13800001111")
        XCTAssertEqual((try transport.body(1)["getOutLinkReq"] as? [String: Any])?["period"] as? Int, 7)

        let rejected = C139API(transport: FakeTransport(fallback: json(#"{"success":true,"code":"1","message":"内容违规"}"#)), environment: c139Environment())
        do {
            _ = try await rejected.createShare(fileIds: ["f1"], folderIds: [], periodDays: nil, name: "x", cookie: c139Cookie.value)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "内容违规", code: 1)) }
    }

    func testQuota() async {
        let transport = FakeTransport([("quota/detail", json(#"{"success":true,"code":"0000","data":{"diskSize":100,"freeDiskSize":60,"quotaList":[{"usedSize":30}]}}"#)),
                                       ("quota/detail", json(#"{"success":true,"code":"0000","data":{"diskSize":100,"freeDiskSize":60}}"#))])
        let provider = c139Provider(transport)
        let mb: Int64 = 1024 * 1024
        let listed = await provider.quota(credential: c139Cookie)
        XCTAssertEqual(listed, DriveQuota(used: 30 * mb, total: 100 * mb))
        let derived = await provider.quota(credential: c139Cookie)
        XCTAssertEqual(derived, DriveQuota(used: 40 * mb, total: 100 * mb))
        XCTAssertEqual(transport.requests[0].url.absoluteString, "https://user-njs.yun.139.com/user/disk/quota/detail")
        XCTAssertEqual(transport.requests[0].headers["mcloud-skey"], "SKEYSECRET")
        XCTAssertEqual(transport.requests[0].headers["Cookie"], c139Cookie.value)

        let failed = await c139Provider(FakeTransport()).quota(credential: c139Cookie)
        XCTAssertNil(failed)
        let noAuth = await c139Provider(FakeTransport()).quota(credential: DriveCredential("Os_SSo_Sid=1; RMKEY=2"))
        XCTAssertNil(noAuth)
    }

    func testSaveToDrivePollsUntilDone() async throws {
        let sleeps = Box<UInt64>()
        let transport = FakeTransport([
            ("user/disk/quota/detail", json(#"{"success":true,"code":"0000","data":{"diskSize":1,"freeDiskSize":1,"quotaList":[{"usedSize":0}]}}"#)),
            ("createOuterLinkBatchOprTask", encrypted(#"{"resultCode":"0","data":{"taskID":"sk123"}}"#)),
            ("queryBatchOprTaskDetail", encrypted(#"{"resultCode":"0","data":{"batchOprTask":{"progress":50,"taskStatus":1}}}"#)),
            ("queryBatchOprTaskDetail", encrypted(#"{"resultCode":"0","data":{"batchOprTask":{"progress":100,"taskStatus":2},"contentList":{"idRspInfo":[{"srcId":"co1","rstId":"new1","reason":"0000"},{"srcId":"co2","rstId":"x","reason":"1"}]}}}"#)),
        ])
        let saved = try await c139Provider(transport, sleeps: sleeps).saveToDrive(session: c139Session, file: c139File, directoryId: nil, credential: c139Cookie, skipSpaceCheck: false)
        XCTAssertEqual(saved, "new1")
        XCTAssertEqual(sleeps.values, [800_000_000, 800_000_000])

        let create = try XCTUnwrap(try decryptedBody(transport, 1).child("createOuterLinkBatchOprTaskReq"))
        XCTAssertEqual(create.string("msisdn"), "13800001111")
        XCTAssertEqual(create.int("taskType"), 1)
        XCTAssertEqual(create.child("taskInfo")?.array("contentInfoList") as? [String], ["/co1"])
        XCTAssertEqual(create.child("taskInfo")?.string("newCatalogID"), "/")
        XCTAssertEqual(create.child("taskInfo")?.string("linkID"), "link1")
        XCTAssertEqual(transport.requests[1].headers["Authorization"], c139Authorization)
        XCTAssertNotNil(transport.requests[1].headers["mcloud-sign"])
        XCTAssertEqual(try decryptedBody(transport, 2).child("queryBatchOprTaskDetailReq")?.string("taskID"), "sk123")
    }

    func testSaveToDriveFailures() async throws {
        let sleeps = Box<UInt64>()
        let stuck = FakeTransport([
            ("createOuterLinkBatchOprTask", encrypted(#"{"resultCode":"0","data":{"taskID":"sk1"}}"#)),
        ], fallback: encrypted(#"{"resultCode":"0","data":{"batchOprTask":{"progress":10,"taskStatus":1}}}"#))
        do {
            _ = try await c139Provider(stuck, sleeps: sleeps).saveToDrive(session: c139Session, file: c139File, directoryId: "/d", credential: c139Cookie, skipSpaceCheck: true)
            XCTFail("expected a timeout")
        } catch { XCTAssertEqual(error as? DriveError, .timedOut("转存超时或失败")) }
        XCTAssertEqual(sleeps.values.count, 30)
        XCTAssertEqual(stuck.requests.count, 31, "skipSpaceCheck sends no quota request")
        XCTAssertEqual(try decryptedBody(stuck, 0).child("createOuterLinkBatchOprTaskReq")?.child("taskInfo")?.string("newCatalogID"), "/d")

        let unmapped = FakeTransport([
            ("createOuterLinkBatchOprTask", encrypted(#"{"resultCode":"0","data":{"taskID":"sk1"}}"#)),
            ("queryBatchOprTaskDetail", encrypted(#"{"resultCode":"0","data":{"batchOprTask":{"progress":100,"taskStatus":2}}}"#)),
        ])
        do {
            _ = try await c139Provider(unmapped, sleeps: Box<UInt64>()).saveToDrive(session: c139Session, file: c139File, directoryId: nil, credential: c139Cookie, skipSpaceCheck: true)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .timedOut("转存超时或失败")) }

        let rejected = FakeTransport(fallback: encrypted(#"{"resultCode":"9188","desc":"提取码错误"}"#))
        do {
            _ = try await c139Provider(rejected).saveToDrive(session: c139Session, file: c139File, directoryId: nil, credential: c139Cookie, skipSpaceCheck: true)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "提取码错误", code: 9188)) }

        let noTask = FakeTransport(fallback: encrypted(#"{"resultCode":"0","data":{}}"#))
        do {
            _ = try await c139Provider(noTask).saveToDrive(session: c139Session, file: c139File, directoryId: nil, credential: c139Cookie, skipSpaceCheck: true)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "创建转存任务失败")) }
    }

    func testSaveToDriveChecksSpaceFirst() async {
        let transport = FakeTransport([("quota/detail", json(#"{"success":true,"code":"0000","data":{"diskSize":1,"freeDiskSize":0,"quotaList":[{"usedSize":1}]}}"#))])
        do {
            _ = try await c139Provider(transport).saveToDrive(session: c139Session, file: DriveFile(id: "co1", name: "big", size: 5 * 1024 * 1024, isDirectory: false, parentId: "root"),
                                                              directoryId: nil, credential: c139Cookie, skipSpaceCheck: false)
            XCTFail("expected insufficient space")
        } catch { XCTAssertEqual(error as? DriveError, .insufficientSpace(required: 5 * 1024 * 1024, available: 0)) }
        XCTAssertEqual(transport.requests.count, 1)

        let batch = try? await c139Provider(FakeTransport()).ensureBatchSpace(sizes: [0], credential: c139Cookie)
        XCTAssertEqual(batch, false)
    }

    func testSecretsStayOutOfDescriptionsAndErrors() async {
        XCTAssertFalse("\(c139Cookie)".contains("TOKENSECRET"))
        let link = C139DownloadLink(fid: "f", filename: "n", downloadURL: "https://obs.example/?sig=SIG", size: 1)
        XCTAssertFalse("\(link)".contains("SIG"))
        XCTAssertFalse(String(reflecting: link).contains("SIG"))
        var dumped = ""
        dump(link, to: &dumped)
        XCTAssertFalse(dumped.contains("SIG"))
        XCTAssertFalse("\(c139Session)".contains("pw12"))
        // A transport failure carries only a code.
        do {
            _ = try await c139Provider(FakeTransport()).listFiles(directoryId: nil, credential: c139Cookie)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? DriveError, .transport(code: -1))
            XCTAssertFalse("\(error)".contains("TOKENSECRET"))
        }
    }
}
