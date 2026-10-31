import XCTest
@testable import CloudDriveKit

// Response bodies are rebuilt from the field shapes read in XunleiApi.kt and the two Xunlei repositories.
// None was captured from the live service, and no real account was used. The tokens below are made up.
// The web captcha signature has one known vector from YunX's XunleiWebCredentialTest; the app signature
// has none, so its expected value comes from re-running the documented algorithm.

private let xNow = Date(timeIntervalSince1970: 1_700_000_000)
private let xNowMs: Int64 = 1_700_000_000_000

private func jwt(sub: String = "u1", exp: Int) -> String {
    func b64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    return "\(b64(#"{"alg":"none"}"#)).\(b64(#"{"sub":"\#(sub)","exp":\#(exp)}"#)).sig0123456789"
}

private let liveAccess = jwt(exp: 1_700_003_600)
private let expiredAccess = jwt(exp: 1_699_999_000)
private let newAccess = jwt(exp: 1_700_040_000)

private func appAccount(access: String = liveAccess, refresh: String = "SECRETREFRESH0123456") -> XunleiCredential {
    XunleiCredential(accessToken: access, refreshToken: refresh, deviceId: "dev1", captchaToken: "SECRETCAPTCHA0123456", nickname: "Leo")
}

private func webAccount(access: String = liveAccess) -> XunleiCredential {
    XunleiCredential(accessToken: access, refreshToken: "SECRETWEBREFRESH0123", deviceId: "webdev1", captchaToken: "OLDWEBCAPTCHA0123456", authType: XunleiWebAuth.authType)
}

private func xProvider(_ transport: FakeTransport, updates: Box<(DriveCredential, DriveCredential)>? = nil, sleeps: Box<UInt64>? = nil) -> XunleiProvider {
    XunleiProvider(api: XunleiAPI(transport: transport, credentialUpdated: { updates?.add(($0, $1)) },
                                  sleep: { sleeps?.add($0) }, now: { xNow }))
}

private let xSession = ShareSession(platform: .xunlei, shareId: "VO_abc-12", accessToken: "PCT", title: "t")
private let xFile = DriveFile(id: "f1", name: "a.bin", size: 100, isDirectory: false, parentId: "")
private let detailBody = #"{"id":"new1","name":"a.bin","size":"100","links":{"application/octet-stream":{"url":"https://dl.example/x?sig=1&b=2"}}}"#

final class XunleiProviderTests: XCTestCase {
    // MARK: Constants and signing

    func testRoutingCapabilitiesAndRegistration() {
        let link = ShareLinkRouter.parse("https://pan.xunlei.com/s/VO_abc-12?pwd=ab12")
        XCTAssertEqual(link, ParsedShareLink(shareId: "VO_abc-12", passcode: "ab12", platform: .xunlei))
        XCTAssertEqual(XunleiProvider().parseShareLink("https://pan.xunlei.com/s/VO_abc-12")?.shareId, "VO_abc-12")
        XCTAssertNil(XunleiProvider().parseShareLink("https://pan.quark.cn/s/abc"))
        XCTAssertNil(XunleiProvider().credentialRefreshInterval)
        XCTAssertEqual(XunleiProvider().capabilities, [.shareListing, .ownFiles, .saveToDrive])
        let router = ShareLinkRouter(providers: [.xunlei()])
        XCTAssertEqual(try router.route("https://pan.xunlei.com/s/abc").provider.platform, .xunlei)
    }

    func testCaptchaSignatures() {
        // The only vector from YunX: pins the nine salts, their order, the version and the host.
        XCTAssertEqual(XunleiSigner.webCaptchaSign(deviceId: "550cfe136e9d74e95be5393738639de7", timestampMs: 1792243618981),
                       "1.4181a24198c7edfbbba2afbcf1f4fab0")
        // No vector for the app signature; this value comes from re-running the documented algorithm.
        XCTAssertEqual(XunleiSigner.appCaptchaSign(deviceId: "dev1", timestampMs: "1700000000000"), "1.1d8e6ab32cb318a19786d05c89f6b184")
    }

    func testDeviceFingerprint() {
        // The official capture's id must give the official capture's devicesign.
        let device = XunleiDevice(deviceId: "78a70629a2b17d0b4302317ffa94807a", peerId: "p")
        XCTAssertEqual(device.deviceSign, "div101.78a70629a2b17d0b4302317ffa94807a31491e163e795b39e798ed33ae58858b")
        let generated = XunleiDevice.generate()
        XCTAssertEqual(generated.deviceId.count, 32)
        XCTAssertEqual(generated.peerId.count, 32)
        XCTAssertNotEqual(generated, XunleiDevice.generate())
        XCTAssertTrue(generated.deviceId.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    // MARK: Credential

    func testCredentialParsing() throws {
        let stored = appAccount().driveCredential
        XCTAssertEqual(XunleiCredential(stored), appAccount())
        XCTAssertEqual(XunleiProvider().isWellFormed(credential: stored), true)

        let access = liveAccess
        XCTAssertEqual(XunleiCredential.parse("  Bearer \(access) ")?.accessToken, access)
        let page = #"{"credentials":{"access_token":"\#(access)","refresh_token":"SECRETREFRESH0123456","sub":"u9"},"x":1}"#
        let nested = try XCTUnwrap(XunleiCredential.parse(page))
        XCTAssertEqual(nested.userId, "u9")
        XCTAssertEqual(nested.authType, "")
        // JSON that was pasted as a quoted string, and camelCase keys.
        let quoted = String(decoding: try JSONSerialization.data(withJSONObject: #"{"accessToken":"\#(access)","deviceId":"d"}"#, options: .fragmentsAllowed), as: UTF8.self)
        XCTAssertEqual(XunleiCredential.parse(quoted)?.deviceId, "d")
        XCTAssertEqual(XunleiCredential.parseWebLogin(page)?.authType, XunleiWebAuth.authType)

        for bad in ["", "null", "short", #"{"access_token":"null"}"#, #"{"access_token":"bad token with spaces!!"}"#,
                    #"{"access_token":"\#(access)","refresh_token":"x y"}"#, "{}", #"{"nick_name":"x"}"#] {
            XCTAssertNil(XunleiCredential.parse(bad), bad)
        }
        XCTAssertFalse(XunleiProvider().isWellFormed(credential: DriveCredential("a=1; b=2")))
    }

    func testSecretsNeverAppearWhenPrinted() async throws {
        let account = appAccount()
        var output = "\(account) \(String(reflecting: account)) \(account.driveCredential)"
        dump(account, to: &output)
        dump(XunleiTokenPair(accessToken: "SECRETACCESS", refreshToken: "SECRETREFRESH"), to: &output)
        dump(XunleiLoginStep(needSMS: false, smsCreditKey: "SECRETCREDIT", smsToken: "SECRETSMS", sessionId: "SECRETSESSION"), to: &output)
        let link = XunleiDownloadLink(fid: "f", filename: "n", downloadURL: "https://dl.example/SECRETSIG", size: 1)
        output += "\(link)"
        dump(link, to: &output)
        for secret in [liveAccess, "SECRETREFRESH", "SECRETCAPTCHA", "SECRETCREDIT", "SECRETSMS", "SECRETSESSION", "SECRETACCESS", "SECRETSIG"] {
            XCTAssertFalse(output.contains(secret), secret)
        }
    }

    // MARK: Account

    func testAccountStateAndQuota() async {
        let about = FakeTransport([("drive/v1/about", json(#"{"kind":"drive#about","quota":{"usage":"10","limit":"100"}}"#))])
        let state = await xProvider(about).accountState(credential: appAccount().driveCredential)
        XCTAssertEqual(state, .signedIn(nickname: "Leo"))
        XCTAssertEqual(about.requests[0].headers["Authorization"], "Bearer \(liveAccess)")
        XCTAssertEqual(about.requests[0].headers["X-Captcha-Token"], "SECRETCAPTCHA0123456")

        let wrapped = FakeTransport([("drive/v1/about", json(#"{"data":{"quota":{}}}"#))])
        let named = await xProvider(wrapped).accountState(credential: DriveCredential(liveAccess))
        XCTAssertEqual(named, .signedIn(nickname: "迅雷用户"))
        let rejected = await xProvider(FakeTransport(fallback: json(#"{"error":"unauthenticated"}"#, status: 401))).accountState(credential: appAccount().driveCredential)
        XCTAssertEqual(rejected, .unverified)
        let none = await xProvider(FakeTransport()).accountState(credential: DriveCredential("a=1"))
        XCTAssertEqual(none, .signedOut)

        let transport = FakeTransport([("drive/v1/about", json(#"{"kind":"drive#about","quota":{"usage":"10","limit":"100"}}"#))])
        let quota = await xProvider(transport).quota(credential: appAccount().driveCredential)
        XCTAssertEqual(quota, DriveQuota(used: 10, total: 100))
        let failed = await xProvider(FakeTransport(fallback: json(#"{"error":"x"}"#, status: 500))).quota(credential: appAccount().driveCredential)
        XCTAssertNil(failed)
    }

    // MARK: Shares

    func testGuestShareSendsNoAuthorizationNoCaptchaAndKeepsPasscode() async throws {
        let share = json(#"{"title":"T","pass_code_token":"PCT","next_page_token":"","files":[{"id":"a","name":"n","size":"12","kind":"drive#folder","parent_id":"","modified_time":"2024-01-01"}]}"#)
        let transport = FakeTransport([("drive/v1/share?", share), ("drive/v1/share?", share)])
        let p = xProvider(transport)
        let link = ParsedShareLink(shareId: "VO_abc-12", passcode: "ab12", platform: .xunlei)
        let opened = try await p.openShare(link, passcode: " ", credential: nil)
        XCTAssertEqual(opened, ShareSession(platform: .xunlei, shareId: "VO_abc-12", accessToken: "PCT", title: "T"))
        let request = transport.requests[0]
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertNil(request.headers["X-Captcha-Token"])
        XCTAssertEqual(request.headers["X-Device-Id"]?.count, 32)
        XCTAssertEqual(request.headers["User-Agent"], XunleiConstants.webUserAgent)
        XCTAssertEqual(request.headers["Origin"], "https://pan.xunlei.com")
        XCTAssertEqual(request.url.absoluteString, "https://api-pan.xunlei.com/drive/v1/share?share_id=VO_abc-12&pass_code=ab12&limit=100&page_token=&thumbnail_size=SIZE_SMALL")

        // The listing asks for the passcode again, which ShareSession does not carry.
        let files = try await p.listShareFiles(session: opened, directoryId: nil, credential: nil)
        XCTAssertEqual(files, [DriveFile(id: "a", name: "n", size: 12, isDirectory: true, parentId: "", modifiedAt: "2024-01-01")])
        XCTAssertTrue(transport.requests[1].url.absoluteString.contains("pass_code=ab12"))
        XCTAssertNil(transport.requests[1].headers["Authorization"])
    }

    func testShareStatusMessagesAreNotMistakenForEmptyFolders() async {
        let cases = [("PASS_CODE_EMPTY", "请输入提取码"), ("PASS_CODE_ERROR", "提取码错误"), ("PASS_CODE_NEED", "该分享需要提取码")]
        for (status, message) in cases {
            let transport = FakeTransport(fallback: json(#"{"share_status":"\#(status)","files":[]}"#))
            do {
                _ = try await xProvider(transport).openShare(ParsedShareLink(shareId: "a", passcode: nil, platform: .xunlei), passcode: nil, credential: nil)
                XCTFail("expected a failure")
            } catch { XCTAssertEqual(error as? DriveError, .api(message: message)) }
        }
    }

    func testShareListingPagesRootAndSubdirectory() async throws {
        let root1 = json(#"{"title":"T","pass_code_token":"PCT","next_page_token":"n 1","files":[{"id":"a","name":"a","size":1,"kind":"drive#file","parent_id":""}]}"#)
        let root2 = json(#"{"files":[{"id":"b","name":"b","size":2,"kind":"drive#file","parent_id":""}]}"#)
        let sub = json(#"{"files":[{"id":"c","name":"c","size":3,"kind":"drive#file","parent_id":"d1"}]}"#)
        let opening = json(#"{"title":"T","pass_code_token":"PCT","files":[]}"#)
        let transport = FakeTransport([("drive/v1/share?", opening), ("drive/v1/share?", root1), ("drive/v1/share?", root2), ("drive/v1/share/detail", sub), ("drive/v1/share?", root2)])
        let p = xProvider(transport)
        _ = try await p.openShare(ParsedShareLink(shareId: "S", passcode: "pw", platform: .xunlei), passcode: nil, credential: nil)
        let session = ShareSession(platform: .xunlei, shareId: "S", accessToken: "PCT", title: "T")
        let all = try await p.listShareFiles(session: session, directoryId: "0", credential: nil)
        XCTAssertEqual(all.map(\.id), ["a", "b"])
        XCTAssertTrue(transport.requests[1].url.absoluteString.hasSuffix("page_token=&thumbnail_size=SIZE_SMALL"))
        XCTAssertTrue(transport.requests[1].url.absoluteString.contains("pass_code=pw"))
        XCTAssertTrue(transport.requests[2].url.absoluteString.contains("page_token=n+1&"))
        let inside = try await p.listShareFiles(session: session, directoryId: "d1", credential: nil)
        XCTAssertEqual(inside.map(\.id), ["c"])
        XCTAssertEqual(transport.requests[3].url.absoluteString, "https://api-pan.xunlei.com/drive/v1/share/detail?share_id=S&parent_id=d1&pass_code_token=PCT&limit=100&page_token=&thumbnail_size=SIZE_SMALL")
        // A blank id is the root too.
        let blank = try await p.listShareFiles(session: session, directoryId: "", credential: nil)
        XCTAssertEqual(blank.map(\.id), ["b"])
    }

    // MARK: Saving and resolving

    func testSaveToDriveBodyAndIdMapping() async throws {
        let restore = #"{"params":{"trace_file_ids":"{\"f1\":\"new1\"}"}}"#
        let transport = FakeTransport([("drive/v1/about", json(#"{"quota":{"usage":"10","limit":"1000"}}"#)),
                                       ("share/restore", json(restore)),
                                       ("share/restore", json(#"{"file_id":"fallback"}"#)),
                                       ("share/restore", json("{}"))])
        let p = xProvider(transport)
        let credential = appAccount().driveCredential
        let saved = try await p.saveToDrive(session: xSession, file: xFile, directoryId: nil, credential: credential, skipSpaceCheck: false)
        XCTAssertEqual(saved, "new1")
        XCTAssertEqual(transport.paths(), ["/drive/v1/about", "/drive/v1/share/restore"])
        let body = try transport.body(1)
        XCTAssertEqual(body["share_id"] as? String, "VO_abc-12")
        XCTAssertEqual(body["pass_code_token"] as? String, "PCT")
        XCTAssertEqual(body["parent_id"] as? String, "")
        XCTAssertEqual(body["file_ids"] as? [String], ["f1"])
        XCTAssertEqual(body["specify_parent_id"] as? Bool, true)
        XCTAssertEqual(body["ancestor_ids"] as? [String], [])
        XCTAssertEqual(transport.requests[1].headers["Authorization"], "Bearer \(liveAccess)")

        let second = try await p.saveToDrive(session: xSession, file: xFile, directoryId: "dir", credential: credential, skipSpaceCheck: true)
        XCTAssertEqual(second, "fallback")
        XCTAssertEqual(try transport.body(2)["parent_id"] as? String, "dir")
        do {
            _ = try await p.saveToDrive(session: xSession, file: xFile, directoryId: nil, credential: credential, skipSpaceCheck: true)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "转存失败")) }
    }

    func testInsufficientSpaceStopsBeforeSaving() async {
        let transport = FakeTransport([("drive/v1/about", json(#"{"quota":{"usage":"950","limit":"1000"}}"#))])
        do {
            _ = try await xProvider(transport).saveToDrive(session: xSession, file: xFile, directoryId: nil, credential: appAccount().driveCredential, skipSpaceCheck: false)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .insufficientSpace(required: 100, available: 50)) }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testSigninIsRequiredToSaveOrResolve() async {
        let p = xProvider(FakeTransport())
        for blank in [nil, DriveCredential(" "), DriveCredential("a=1")] {
            do {
                _ = try await p.resolveShareFile(session: xSession, file: xFile, credential: blank, options: ShareResolveOptions())
                XCTFail("expected a failure")
            } catch { XCTAssertEqual(error as? DriveError, .loginRequired) }
        }
        do {
            _ = try await p.saveToDrive(session: xSession, file: xFile, directoryId: nil, credential: DriveCredential(""), skipSpaceCheck: true)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .loginRequired) }
    }

    func testResolveShareFileSavesReadsLinkAndTrashesTheCopy() async throws {
        let folders = #"{"files":[{"id":"x","name":"other","kind":"drive#folder"},{"id":"tmp1","name":"YunX临时转存","kind":"drive#folder"}]}"#
        let transport = FakeTransport([("files?parent_id=", json(folders)),
                                       ("share/restore", json(#"{"params":{"trace_file_ids":"{\"f1\":\"new1\"}"}}"#)),
                                       ("files/new1?", json(detailBody)),
                                       ("files:batchTrash", json("{}"))])
        let link = try await xProvider(transport).resolveShareFile(session: xSession, file: xFile, credential: appAccount().driveCredential,
                                                                   options: ShareResolveOptions(skipSpaceCheck: true))
        XCTAssertEqual(link.url.absoluteString, "https://dl.example/x?sig=1&b=2")
        XCTAssertEqual(link.headers, ["User-Agent": XunleiConstants.appUserAgent])
        XCTAssertEqual(link.fileId, "new1")
        XCTAssertEqual(link.size, 100)
        XCTAssertNil(link.cleanupDirectoryId)
        XCTAssertEqual(try transport.body(1)["parent_id"] as? String, "tmp1")
        XCTAssertTrue(transport.requests[0].url.absoluteString.contains("filters=%7B%22trashed%22%3A%7B%22eq%22%3Afalse%7D%7D"))
        XCTAssertEqual(try transport.body(3)["ids"] as? [String], ["new1"])
        XCTAssertEqual(try transport.body(3)["space"] as? String, "")
    }

    func testMissingTempDirectoryIsCreatedAndFailedTrashIsIgnored() async throws {
        let transport = FakeTransport([("files?parent_id=", json(#"{"files":[]}"#)),
                                       ("drive/v1/files", json(#"{"id":"tmp9"}"#)),
                                       ("share/restore", json(#"{"file_id":"new1"}"#)),
                                       ("files/new1?", json(#"{"id":"new1","name":"a","size":5,"web_content_link":"https://dl.example/w"}"#))])
        let link = try await xProvider(transport).resolveShareFile(session: xSession, file: xFile, credential: appAccount().driveCredential,
                                                                   options: ShareResolveOptions(skipSpaceCheck: true))
        XCTAssertEqual(link.url.absoluteString, "https://dl.example/w")
        let folder = try transport.body(1)
        XCTAssertEqual(folder["kind"] as? String, "drive#folder")
        XCTAssertEqual(folder["name"] as? String, "YunX临时转存")
        XCTAssertEqual(folder["space"] as? String, "")
        XCTAssertEqual(try transport.body(2)["parent_id"] as? String, "tmp9")
    }

    func testResolveOwnFileAndMissingLink() async throws {
        let transport = FakeTransport([("files/new1?", json(detailBody)), ("files/new2?", json(#"{"id":"new2","name":"a"}"#))])
        let p = xProvider(transport)
        let link = try await p.resolveFile(id: "new1", credential: appAccount().driveCredential)
        XCTAssertEqual(link.filename, "a.bin")
        XCTAssertEqual(transport.requests[0].url.absoluteString, "https://api-pan.xunlei.com/drive/v1/files/new1?_magic=2021&usage=PLAY&thumbnail_size=SIZE_LARGE&with=hdr10&with=subtitle_files&with=task&with=public_share_tag")
        do {
            _ = try await p.resolveFile(id: "new2", credential: appAccount().driveCredential)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "获取下载链接失败")) }
    }

    func testListFilesFollowsPages() async throws {
        let transport = FakeTransport([("files?parent_id=", json(#"{"files":[{"id":"a","name":"a"}],"next_page_token":"t2"}"#)),
                                       ("files?parent_id=", json(#"{"files":[{"id":"b","name":"b"}]}"#))])
        let files = try await xProvider(transport).listFiles(directoryId: nil, credential: appAccount().driveCredential)
        XCTAssertEqual(files.map(\.id), ["a", "b"])
        XCTAssertTrue(transport.requests[0].url.absoluteString.hasPrefix("https://api-pan.xunlei.com/drive/v1/files?parent_id=&page_token=&limit=50&with_audit=true&filters="))
        XCTAssertTrue(transport.requests[1].url.absoluteString.contains("page_token=t2&"))
    }

    func testFileManagementBodies() async throws {
        let transport = FakeTransport([("files:batchMove", json(#"{"task_id":"tk"}"#)), ("files:batchTrash", json("{}")),
                                       ("drive/v1/share", json(#"{"share_url":"https://pan.xunlei.com/s/x","pass_code":"p","share_id":"x","title":""}"#))])
        let api = xProvider(transport).api
        let account = appAccount()
        let task = try await api.moveFiles(fileIds: ["a"], toParentId: "d", credential: account)
        XCTAssertEqual(task, "tk")
        try await api.deleteFiles(fileIds: ["a"], credential: account)
        let info = try await api.createShare(fileIds: ["a"], title: " ", expirationDays: "7", passCode: "", credential: account)
        XCTAssertEqual(info, XunleiShareInfo(shareURL: "https://pan.xunlei.com/s/x", passcode: "p", shareId: "x", title: " "))
        let move = try transport.body(0)
        XCTAssertEqual(move["ids"] as? [String], ["a"])
        XCTAssertEqual((move["to"] as? [String: Any])?["parent_id"] as? String, "d")
        XCTAssertEqual(try transport.body(1)["space"] as? String, "")
        let share = try transport.body(2)
        XCTAssertEqual(share["title"] as? String, "分享文件")
        XCTAssertEqual(share["expiration_days"] as? String, "7")
        XCTAssertEqual(share["restore_limit"] as? String, "-1")
        XCTAssertNil((share["params"] as? [String: Any])?["pass_code"])
    }

    func testPollTaskStopsOnCompletion() async {
        let sleeps = Box<UInt64>()
        let transport = FakeTransport([("tasks/t1", json(#"{"status":"PHASE_TYPE_RUNNING","error_code":5}"#)),
                                       ("tasks/t1", json(#"{"status":"PHASE_TYPE_COMPLETE"}"#))])
        let done = await xProvider(transport, sleeps: sleeps).api.pollTask(taskId: "t1", credential: appAccount())
        XCTAssertTrue(done)
        XCTAssertEqual(sleeps.values, [1_000_000_000])
        XCTAssertTrue(transport.requests[0].url.absoluteString.hasSuffix("tasks/t1?type=share"))
        let sleeps2 = Box<UInt64>()
        let never = await xProvider(FakeTransport(fallback: json(#"{"status":"RUNNING","error_code":5}"#)), sleeps: sleeps2).api.pollTask(taskId: "t", credential: appAccount())
        XCTAssertFalse(never)
        XCTAssertEqual(sleeps2.values.count, 15)
    }

    // MARK: Token and captcha recovery

    func testExpiredTokenIsRefreshedBeforeTheCallAndRotationIsReported() async throws {
        let updates = Box<(DriveCredential, DriveCredential)>()
        let refreshed = #"{"access_token":"\#(newAccess)","refresh_token":"NEWREFRESH0123456789"}"#
        let transport = FakeTransport([("v1/auth/token", json(refreshed)),
                                       ("drive/v1/about", json(#"{"quota":{"usage":1,"limit":2}}"#)),
                                       ("drive/v1/about", json(#"{"quota":{"usage":3,"limit":4}}"#))])
        let p = xProvider(transport, updates: updates)
        let old = appAccount(access: expiredAccess).driveCredential
        let first = await p.quota(credential: old)
        XCTAssertEqual(first, DriveQuota(used: 1, total: 2))
        let refresh = transport.requests[0]
        XCTAssertEqual(refresh.url.absoluteString, "https://xluser-ssl.xunlei.com/v1/auth/token")
        XCTAssertEqual(refresh.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(refresh.headers["X-Device-Id"], "dev1")
        XCTAssertEqual(String(decoding: try XCTUnwrap(refresh.body), as: UTF8.self),
                       "grant_type=refresh_token&client_id=Xp6vsxz_7IYVw2BB&client_secret=Xp6vsy4tN9toTVdMSpomVdXpRmES&refresh_token=SECRETREFRESH0123456")
        XCTAssertEqual(transport.requests[1].headers["Authorization"], "Bearer \(newAccess)")
        XCTAssertEqual(updates.values.count, 1)
        XCTAssertEqual(updates.values[0].1, old)
        let updated = try XCTUnwrap(XunleiCredential(updates.values[0].0))
        XCTAssertEqual(updated.accessToken, newAccess)
        XCTAssertEqual(updated.refreshToken, "NEWREFRESH0123456789")
        XCTAssertEqual(updated.deviceId, "dev1")
        XCTAssertEqual(updated.nickname, "Leo")
        // The same old credential again: the new token is used without a second refresh.
        _ = await p.quota(credential: old)
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(transport.requests[2].headers["Authorization"], "Bearer \(newAccess)")
    }

    func testExpiredTokenWithoutARefreshTokenIsAnError() async {
        let transport = FakeTransport()
        let expired = XunleiCredential(accessToken: expiredAccess, deviceId: "d").driveCredential
        do {
            _ = try await xProvider(transport).listFiles(directoryId: nil, credential: expired)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "迅雷登录已过期，请重新登录")) }
        XCTAssertTrue(transport.requests.isEmpty)
        // A refresh the server refuses is the same error.
        do {
            _ = try await xProvider(FakeTransport(fallback: json(#"{"error":"invalid_grant"}"#, status: 400))).listFiles(directoryId: nil, credential: appAccount(access: expiredAccess).driveCredential)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "迅雷登录已过期，请重新登录")) }
    }

    func testUnauthorizedRefreshesThenReissuesCaptchaThenRetries() async throws {
        let updates = Box<(DriveCredential, DriveCredential)>()
        let transport = FakeTransport([("drive/v1/files?", json(#"{"error":"unauthenticated"}"#, status: 401)),
                                       ("v1/auth/token", json(#"{"accessToken":"\#(newAccess)","refreshToken":"NEWREFRESH0123456789"}"#)),
                                       ("captcha/init", json(#"{"captcha_token":"NEWCAPTCHA0123456789"}"#)),
                                       ("drive/v1/files?", json(#"{"files":[{"id":"a","name":"a"}]}"#))])
        let files = try await xProvider(transport, updates: updates).listFiles(directoryId: nil, credential: appAccount().driveCredential)
        XCTAssertEqual(files.map(\.id), ["a"])
        XCTAssertEqual(transport.requests.count, 4)
        let captchaInit = try transport.body(2)
        XCTAssertEqual(captchaInit["action"] as? String, "GET:/drive/v1/files")
        XCTAssertEqual(captchaInit["client_id"] as? String, "Xp6vsxz_7IYVw2BB")
        XCTAssertEqual(captchaInit["device_id"] as? String, "dev1")
        XCTAssertEqual(captchaInit["captcha_token"] as? String, "SECRETCAPTCHA0123456")
        let meta = try XCTUnwrap(captchaInit["meta"] as? [String: Any])
        XCTAssertEqual(meta["user_id"] as? String, "u1")
        XCTAssertEqual(meta["timestamp"] as? String, "1700000000000")
        XCTAssertEqual(meta["package_name"] as? String, "com.xunlei.downloadprovider")
        XCTAssertEqual(meta["captcha_sign"] as? String, XunleiSigner.appCaptchaSign(deviceId: "dev1", timestampMs: "1700000000000"))
        XCTAssertEqual(transport.requests[2].headers["X-Client-Id"], "Xp6vsxz_7IYVw2BB")
        XCTAssertEqual(transport.requests[3].headers["Authorization"], "Bearer \(newAccess)")
        XCTAssertEqual(transport.requests[3].headers["X-Captcha-Token"], "NEWCAPTCHA0123456789")
        XCTAssertEqual(updates.values.count, 1)
    }

    func testCaptchaInvalidReissuesOnceThenGivesUp() async throws {
        let transport = FakeTransport([("drive/v1/files?", json(#"{"error":"captcha_invalid","error_description":"bad"}"#, status: 400)),
                                       ("captcha/init", json(#"{"captcha_token":"NEWCAPTCHA0123456789"}"#)),
                                       ("drive/v1/files?", json(#"{"error":"captcha_invalid","error_description":"still bad"}"#, status: 400))])
        do {
            _ = try await xProvider(transport).listFiles(directoryId: nil, credential: appAccount().driveCredential)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "still bad")) }
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(transport.requests[2].headers["X-Captcha-Token"], "NEWCAPTCHA0123456789")
    }

    func testClientIdMismatchStopsImmediately() async {
        let body = #"{"error":"captcha_invalid","error_details":[{"detail":"client_id not match"}]}"#
        let transport = FakeTransport([("drive/v1/files?", json(body, status: 400))])
        do {
            _ = try await xProvider(transport).listFiles(directoryId: nil, credential: appAccount().driveCredential)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "验证码与当前登录方式不匹配，请重新登录迅雷网页版")) }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testServerMessagesPassThrough() async {
        let cases: [(HTTPResponse, DriveError)] = [
            (json(#"{"error":"permission_denied","error_description":"没有权限"}"#, status: 403), .api(message: "没有权限")),
            (json(#"{"error":"x","message":"m"}"#, status: 400), .api(message: "m")),
            (json(#"{"error":"only_code"}"#, status: 400), .api(message: "only_code")),
            (json("{}", status: 500), .api(message: "请求失败")),
            (json("<html>", status: 502), .api(message: "响应解析失败（HTTP 502）")),
            (json(""), .api(message: "响应解析失败（HTTP 200）")),
        ]
        for (response, expected) in cases {
            do {
                _ = try await xProvider(FakeTransport(fallback: response)).listFiles(directoryId: nil, credential: appAccount().driveCredential)
                XCTFail("expected a failure")
            } catch { XCTAssertEqual(error as? DriveError, expected) }
        }
    }

    func testWebAccountSignsCaptchaLocallyAndCachesIt() async throws {
        let transport = FakeTransport([("captcha/init", json(#"{"captcha_token":"WEBCAPTCHA0123456789"}"#)),
                                       ("drive/v1/files?", json(#"{"files":[]}"#)),
                                       ("drive/v1/files?", json(#"{"files":[]}"#))])
        let p = xProvider(transport)
        _ = try await p.listFiles(directoryId: nil, credential: webAccount().driveCredential)
        let request = transport.requests[0]
        XCTAssertEqual(request.headers["Content-Type"], "text/plain;charset=UTF-8")
        XCTAssertEqual(request.headers["User-Agent"], XunleiWebAuth.desktopUserAgent)
        XCTAssertEqual(request.headers["Origin"], "https://pan.xunlei.com")
        let body = try transport.body(0)
        XCTAssertEqual(body["client_id"] as? String, "Xqp0kJBXWhwaTpB6")
        XCTAssertEqual(body["action"] as? String, "GET:/drive/v1/files")
        let meta = try XCTUnwrap(body["meta"] as? [String: Any])
        XCTAssertEqual(meta["package_name"] as? String, "pan.xunlei.com")
        XCTAssertEqual(meta["client_version"] as? String, "1.93.10")
        XCTAssertEqual(meta["user_id"] as? String, "u1")
        XCTAssertEqual(meta["captcha_sign"] as? String, XunleiSigner.webCaptchaSign(deviceId: "webdev1", timestampMs: xNowMs))
        XCTAssertEqual(transport.requests[1].headers["X-Captcha-Token"], "WEBCAPTCHA0123456789")
        // Inside its lifetime the token is reused: no second init.
        _ = try await p.listFiles(directoryId: nil, credential: webAccount().driveCredential)
        XCTAssertEqual(transport.paths().filter { $0.contains("captcha") }.count, 1)
    }

    func testRejectedWebSignatureNeedsANewLogin() async {
        for (response, message) in [(json(#"{"error":"captcha_invalid"}"#, status: 400), "迅雷网页登录已过期，请在迅雷登录页重新登录"),
                                    (json(#"{"error_details":[{"detail":"client_id not match"}]}"#, status: 400), "验证码与当前登录方式不匹配，请重新登录迅雷网页版")] {
            let transport = FakeTransport([("captcha/init", response)])
            do {
                _ = try await xProvider(transport).listFiles(directoryId: nil, credential: webAccount().driveCredential)
                XCTFail("expected a failure")
            } catch { XCTAssertEqual(error as? DriveError, .api(message: message)) }
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testWebRefreshUsesTheWebClientWithoutASecret() async throws {
        let updates = Box<(DriveCredential, DriveCredential)>()
        let transport = FakeTransport([("v1/auth/token", json(#"{"access_token":"\#(newAccess)"}"#))])
        let refreshed = await xProvider(transport, updates: updates).refreshCredential(webAccount().driveCredential)
        let request = transport.requests[0]
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["X-Client-Id"], "Xqp0kJBXWhwaTpB6")
        XCTAssertEqual(request.headers["X-Device-Id"], "webdev1")
        XCTAssertEqual(request.headers["Origin"], "https://pan.xunlei.com")
        XCTAssertEqual(request.headers["Referer"], "https://pan.xunlei.com/")
        XCTAssertEqual(request.headers["User-Agent"], XunleiWebAuth.desktopUserAgent)
        XCTAssertEqual(request.headers["Sec-Ch-Ua"], "\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"")
        XCTAssertEqual(request.headers["Sec-Ch-Ua-Mobile"], "?0")
        XCTAssertEqual(request.headers["Sec-Ch-Ua-Platform"], "\"Windows\"")
        let body = try transport.body(0)
        XCTAssertEqual(body["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(body["client_id"] as? String, "Xqp0kJBXWhwaTpB6")
        XCTAssertEqual(body["refresh_token"] as? String, "SECRETWEBREFRESH0123")
        XCTAssertNil(body["client_secret"])
        // No new refresh token in the answer keeps the old one, and the web marker survives.
        let result = try XCTUnwrap(refreshed.flatMap(XunleiCredential.init))
        XCTAssertEqual(result.refreshToken, "SECRETWEBREFRESH0123")
        XCTAssertTrue(result.isWeb)
        XCTAssertEqual(updates.values.count, 1)
    }

    func testRefreshFailureKeepsTheOldCredential() async {
        let none = await xProvider(FakeTransport(fallback: json(#"{"error":"invalid_grant"}"#, status: 400))).refreshCredential(appAccount().driveCredential)
        XCTAssertNil(none)
        let noToken = await xProvider(FakeTransport()).refreshCredential(XunleiCredential(accessToken: liveAccess).driveCredential)
        XCTAssertNil(noToken)
        let garbage = await xProvider(FakeTransport()).refreshCredential(DriveCredential("a=1"))
        XCTAssertNil(garbage)
    }

    // MARK: Login

    func testLoginChain() async throws {
        let device = XunleiDevice(deviceId: "78a70629a2b17d0b4302317ffa94807a", peerId: "peer0001")
        let transport = FakeTransport([
            ("xluser.core.login/v3/login", json(#"{"errorCode":"1007","error":"review_panel","reviewurl":"https://x/review?a=b","errorDesc":"需要验证"}"#)),
            ("v3/sendsms", json(#"{"creditkey":"CK","token":"TK"}"#)),
            ("v3/smslogin", json(#"{"errorCode":"0","sessionID":"SESS","nickName":"Leo","userID":"9","loginKey":"LK"}"#)),
            ("captcha/init", json(#"{"captcha_token":"CAPTOK"}"#)),
            ("v1/auth/signin/token", json(#"{"access_token":"AT","refresh_token":"RT"}"#)),
        ])
        let api = xProvider(transport).api
        let step = try await api.loginWithPassword(username: "13800000000", password: "pw", device: device)
        XCTAssertTrue(step.needSMS)
        XCTAssertEqual(step.reviewURL, "https://x/review?a=b")
        XCTAssertEqual(step.message, "需要验证")
        let login = try transport.body(0)
        XCTAssertEqual(login["userName"] as? String, "13800000000")
        XCTAssertEqual(login["passWord"] as? String, "pw")
        XCTAssertEqual(login["isMd5Pwd"] as? String, "0")
        XCTAssertEqual(login["creditkey"] as? String, "")
        XCTAssertEqual(login["peerID"] as? String, "peer0001")
        XCTAssertEqual(login["devicesign"] as? String, device.deviceSign)
        XCTAssertEqual(login["sdkVersion"] as? String, "513006")
        XCTAssertEqual(login["clientVersion"] as? String, "25.0.5.25")
        XCTAssertEqual(transport.requests[0].headers["User-Agent"], "android-ok-http-client/xl-acc-sdk/version-5.1.3.513006")
        XCTAssertNil(transport.requests[0].headers["Cookie"])

        let sms = try await api.sendSMS(mobile: "13800000000", device: device)
        XCTAssertEqual(sms.smsCreditKey, "CK")
        XCTAssertEqual(sms.smsToken, "TK")
        XCTAssertEqual(sms.message, "短信已发送")
        XCTAssertEqual(transport.requests[1].headers["User-Agent"], "android-ok-http-client/xl-acc-sdk/version-5.0.12.512000")
        let done = try await api.smsLogin(mobile: "13800000000", smsCode: "123456", creditKey: "CK", smsToken: "TK", device: device)
        XCTAssertEqual(done.sessionId, "SESS")
        XCTAssertEqual(done.nickname, "Leo")
        XCTAssertEqual(done.message, "登录成功")
        let smsBody = try transport.body(2)
        XCTAssertEqual(smsBody["creditkey"] as? String, "CK")
        XCTAssertEqual(smsBody["smsCode"] as? String, "123456")
        XCTAssertEqual(smsBody["token"] as? String, "TK")

        let captcha = await api.initCaptcha(device: device, username: "13800000000")
        XCTAssertEqual(captcha, "CAPTOK")
        let initBody = try transport.body(3)
        XCTAssertEqual(initBody["action"] as? String, "POST:/auth/signin/token")
        XCTAssertEqual((initBody["meta"] as? [String: Any])?["username"] as? String, "13800000000")
        XCTAssertEqual(initBody["redirect_uri"] as? String, "xlaccsdk01://xunlei.com/callback?state=harbor")

        let tokens = await api.exchangeToken(sessionId: "SESS", device: device, captchaToken: "CAPTOK")
        XCTAssertEqual(tokens, XunleiTokenPair(accessToken: "AT", refreshToken: "RT"))
        XCTAssertEqual(transport.requests[4].headers["X-Captcha-Token"], "CAPTOK")
        XCTAssertEqual(try transport.body(4)["signin_token"] as? String, "SESS")
        XCTAssertEqual(try transport.body(4)["provider"] as? String, "access_end_point_token")
    }

    func testFailedLoginStepsAreReportedNotThrown() async throws {
        let device = XunleiDevice.generate()
        let transport = FakeTransport(fallback: json(#"{"errorCode":"3","errorDesc":"密码错误"}"#))
        let step = try await xProvider(transport).api.loginWithPassword(username: "u", password: "p", device: device)
        XCTAssertFalse(step.needSMS)
        XCTAssertEqual(step.message, "密码错误")
        XCTAssertEqual(step.sessionId, "")
        let missing = await xProvider(FakeTransport()).api.exchangeToken(sessionId: "s", device: device, captchaToken: "")
        XCTAssertNil(missing)
        let blank = await xProvider(FakeTransport(fallback: json("{}"))).api.initCaptcha(device: device, username: "u")
        XCTAssertNil(blank)
    }

    // MARK: Share passwords

    func testKoulingRecognitionAndResolution() async throws {
        XCTAssertTrue(XunleiKouling.looksLikeKouling("「张三丰资源」"))
        XCTAssertFalse(XunleiKouling.looksLikeKouling("abc123"))
        XCTAssertFalse(XunleiKouling.looksLikeKouling("张三 丰"))
        XCTAssertFalse(XunleiKouling.looksLikeKouling(String(repeating: "资", count: 65)))
        XCTAssertEqual(XunleiKouling.normalize("  《张三丰》。 "), "张三丰")
        XCTAssertEqual(XunleiKouling.shareURL(fromLocation: "https://pan.xunlei.com/s/VO_x-1?pwd=ab12&channel=1&wd=z"), "https://pan.xunlei.com/s/VO_x-1?pwd=ab12")
        XCTAssertEqual(XunleiKouling.shareURL(fromLocation: "https://pan.xunlei.com/s/VO_x-1?channel=1"), "https://pan.xunlei.com/s/VO_x-1")
        XCTAssertNil(XunleiKouling.shareURL(fromLocation: "https://www.baidu.com/s?wd=x"))
        XCTAssertNil(XunleiKouling.shareURL(fromLocation: nil))

        let ok = #"{"ext":{"kouling_type":"share_page"},"location":"https://pan.xunlei.com/s/VOabc?pwd=zz99&from=x"}"#
        let transport = FakeTransport([("xlppc.searcher.api/jump", json(ok)),
                                       ("xlppc.searcher.api/jump", json(#"{"ext":{"kouling_type":"search"},"search_url":"https://s"}"#)),
                                       ("xlppc.searcher.api/jump", json("oops", status: 500))])
        let api = xProvider(transport).api
        let link = try await api.parseKouling("张三丰资源")
        XCTAssertEqual(link, "https://pan.xunlei.com/s/VOabc?pwd=zz99")
        let request = transport.requests[0]
        XCTAssertTrue(request.url.absoluteString.hasPrefix("https://api-shoulei-ssl.xunlei.com/xlppc.searcher.api/jump?noredirect=1&t=20&wd=%E5%BC%A0%E4%B8%89%E4%B8%B0%E8%B5%84%E6%BA%90&tn=15007414_5_dg"))
        XCTAssertEqual(request.headers["Origin"], "https://sl-m-ssl.xunlei.com")
        XCTAssertNil(request.headers["Authorization"])
        do {
            _ = try await api.parseKouling("无资源")
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "口令「无资源」没有对应的网盘分享")) }
        do {
            _ = try await api.parseKouling("坏")
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "口令解析失败（HTTP 500）")) }
    }
}
