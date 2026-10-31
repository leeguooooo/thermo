import XCTest
@testable import CloudDriveKit

// Fake responses rebuilt from the field names in GuangYaApi.kt. None were captured from the live service,
// and no account or network was used.

private let secretAccess = "ACCESS-SECRET"
private let secretRefresh = "REFRESH-SECRET"
private let device = GuangYaDevice(deviceId: String(repeating: "a", count: 32), deviceSign: "wdi10." + String(repeating: "b", count: 32) + String(repeating: "c", count: 32))
private let gyShare = ShareSession(platform: .guangya, shareId: "sid", accessToken: "share-token", title: "t")
private let gyFile = DriveFile(id: "f1", name: "a.bin", size: 100, isDirectory: false, parentId: "p1")
private let freshCredential = GuangYaCredential(accessToken: secretAccess, refreshToken: secretRefresh, device: device,
                                                accessExpiresAt: Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000).driveCredential

private func guangya(_ transport: FakeTransport, updates: Box<(DriveCredential, DriveCredential)>? = nil, sleeps: Box<UInt64>? = nil) -> GuangYaProvider {
    let record: DriveSleeper = { sleeps?.add($0) }
    return GuangYaProvider(api: GuangYaAPI(transport: transport, credentialUpdated: { updates?.add(($0, $1)) }, sleep: record), sleep: record)
}

private func guangYaOK(_ data: String) -> HTTPResponse { json(#"{"code":"0","data":\#(data)}"#) }

final class GuangYaCredentialTests: XCTestCase {
    func testRoundTripAndBareToken() {
        let parsed = GuangYaCredential(freshCredential)
        XCTAssertEqual(parsed.accessToken, secretAccess)
        XCTAssertEqual(parsed.refreshToken, secretRefresh)
        XCTAssertEqual(parsed.device, device)
        XCTAssertEqual(GuangYaCredential(DriveCredential("  tok  ")), GuangYaCredential(accessToken: "tok"))
        XCTAssertTrue(guangya(FakeTransport()).isWellFormed(credential: DriveCredential("tok")))
        XCTAssertFalse(guangya(FakeTransport()).isWellFormed(credential: DriveCredential(" ")))
    }

    func testNothingPrintsSecrets() {
        let tokens = GuangYaTokens(accessToken: secretAccess, refreshToken: secretRefresh, expiresIn: 1)
        let link = GuangYaDownloadLink(fid: "f", filename: "n", downloadURL: "https://x/?sig=SIG-SECRET", size: 1)
        for value in [String(describing: GuangYaCredential(freshCredential)), String(reflecting: GuangYaCredential(freshCredential)),
                      String(describing: tokens), String(reflecting: tokens), String(describing: link), String(reflecting: link),
                      String(describing: freshCredential), String(describing: gyShare)] {
            XCTAssertFalse(value.contains("SECRET"), value)
        }
    }

    func testDeviceHelpers() {
        XCTAssertEqual(GuangYaConstants.newDeviceId().count, 32)
        let sign = GuangYaConstants.newDeviceSign(deviceId: "x")
        XCTAssertTrue(sign.hasPrefix("wdi10.x"))
        XCTAssertEqual(GuangYaConstants.deviceId(fromSign: device.deviceSign, fallback: "fb"), String(repeating: "b", count: 32))
        XCTAssertEqual(GuangYaConstants.deviceId(fromSign: "nodot", fallback: "fb"), "fb")
        XCTAssertEqual(GuangYaConstants.deviceId(fromSign: "wdi10.short", fallback: "fb"), "fb")
        XCTAssertNotNil(GuangYaConstants.newTraceparent().range(of: "^00-[0-9a-f]{32}-[0-9a-f]{16}-01$", options: .regularExpression))
        XCTAssertEqual(GuangYaAPI.normalizeAccount("13800138000"), "+86 13800138000")
        XCTAssertEqual(GuangYaAPI.normalizeAccount("+8613800138000"), "+86 13800138000")
        XCTAssertEqual(GuangYaAPI.normalizeAccount(" a@b.c "), "a@b.c")
        XCTAssertEqual(GuangYaProvider.smsName("+86 13800138000"), "138****8000")
    }
}

final class GuangYaAuthTests: XCTestCase {
    func testSignInRetriesOnlyOnCaptchaThenParsesTokens() async throws {
        let transport = FakeTransport([
            ("captcha/init", json(#"{"captcha_token":"c1"}"#)),
            ("auth/signin", json(#"{"error":"captcha_invalid"}"#)),
            ("captcha/init", json(#"{"captcha_token":"c2"}"#)),
            ("auth/signin", json(#"{"data":{"access_token":"A","refresh_token":"R","expires_in":"3600"}}"#)),
        ])
        let credential = try await guangya(transport).login(account: "13800138000", password: "pw", device: device)
        let parsed = GuangYaCredential(credential)
        XCTAssertEqual(parsed.accessToken, "A")
        XCTAssertEqual(parsed.refreshToken, "R")
        XCTAssertGreaterThan(parsed.accessExpiresAt, Int64(Date().timeIntervalSince1970 * 1000))
        XCTAssertEqual(transport.paths(), ["/v1/shield/captcha/init", "/v1/auth/signin", "/v1/shield/captcha/init", "/v1/auth/signin"])
        let init1 = try transport.body(0)
        XCTAssertEqual(init1["action"] as? String, "POST:/v1/auth/signin")
        XCTAssertEqual((init1["meta"] as? [String: Any])?["phone_number"] as? String, "+86 13800138000")
        XCTAssertEqual(transport.requests[1].headers["X-Captcha-Token"], "c1")
        XCTAssertEqual(transport.requests[3].headers["X-Captcha-Token"], "c2")
        XCTAssertEqual(try transport.body(1)["username"] as? String, "+86 13800138000")
        let headers = transport.requests[1].headers
        XCTAssertEqual(headers["X-Client-Id"], "aMe-8VSlkrbQXpUR")
        XCTAssertEqual(headers["X-Device-Id"], String(repeating: "b", count: 32))
        XCTAssertEqual(headers["X-Device-Sign"], HTTPClient.encodeQueryValue(device.deviceSign))
        XCTAssertEqual(headers["X-Device-Model"], "chrome%2F131.0.0.0")
        XCTAssertEqual(headers["X-Protocol-Version"], "301")
        XCTAssertNil(headers["Authorization"])
    }

    func testSignInGivesUpAfterThreeCaptchaFailures() async {
        let captcha = json(#"{"captcha_token":"c"}"#), failed = json(#"{"code":"captcha_required"}"#)
        let transport = FakeTransport([("captcha/init", captcha), ("auth/signin", failed), ("captcha/init", captcha), ("auth/signin", failed),
                                       ("captcha/init", captcha), ("auth/signin", failed)])
        do {
            _ = try await guangya(transport).login(account: "u", password: "p", device: device)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? DriveError, .api(message: "光鸭安全验证未通过，请重试或切换网页登录"))
        }
    }

    func testSignInErrorMapping() async {
        let transport = FakeTransport([("captcha/init", json("{}")), ("auth/signin", json(#"{"error":"invalid_password"}"#))])
        do {
            _ = try await guangya(transport).login(account: "u", password: "p", device: device)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? DriveError, .api(message: "光鸭账号或密码不正确，请检查后重试"))
        }
    }

    func testSmsFlowForNewUser() async throws {
        let transport = FakeTransport([
            ("captcha/init", json(#"{"captcha_token":"c"}"#)),
            ("auth/verification", json(#"{"data":{"verification_id":"vid","is_user":false,"expires_in":99999}}"#)),
            ("verification/verify", json(#"{"verification_token":"vt"}"#)),
            ("auth/signup", json(#"{"access_token":"A","refresh_token":"R","expire_time":0}"#)),
        ])
        let provider = guangya(transport)
        let challenge = try await provider.sendSmsCode(phoneNumber: "13800138000", device: device)
        XCTAssertEqual(challenge, GuangYaSmsChallenge(verificationId: "vid", isUser: false, expiresIn: 1800))
        XCTAssertEqual(transport.requests[1].headers["X-Captcha-Token"], "c")
        let credential = try await provider.smsLogin(phoneNumber: "13800138000", verificationId: "vid", code: "123456", isUser: false, device: device)
        XCTAssertEqual(GuangYaCredential(credential).accessToken, "A")
        let signup = try transport.body(3)
        XCTAssertEqual(signup["name"] as? String, "138****8000")
        XCTAssertEqual(signup["phone_number"] as? String, "+86 13800138000")
        XCTAssertEqual(signup["verification_token"] as? String, "vt")
    }

    func testSmsRejectsBadCodeWithoutRequest() async {
        let transport = FakeTransport()
        do {
            _ = try await guangya(transport).smsLogin(phoneNumber: "13800138000", verificationId: "v", code: "12a", isUser: true, device: device)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? DriveError, .api(message: "短信验证码错误或已过期，请重新获取"))
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSmsWebCaptchaIsReported() async {
        let transport = FakeTransport([("captcha/init", json(#"{"url":"https://verify.example"}"#))])
        do {
            _ = try await guangya(transport).sendSmsCode(phoneNumber: "13800138000", device: device)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? DriveError, .api(message: "光鸭需要网页人机验证，请稍后重试或改用账号密码登录"))
        }
    }

    func testExpiryFromAbsoluteMillisecondsAndSeconds() async throws {
        let future = Int64(Date().timeIntervalSince1970 * 1000) + 7_200_000
        for value in [future, future / 1000] {
            let transport = FakeTransport([("captcha/init", json("{}")), ("auth/signin", json(#"{"access_token":"A","expires_at":\#(value)}"#))])
            let tokens = try await GuangYaAPI(transport: transport).signIn(username: "u", password: "p", device: device)
            XCTAssertTrue((7_100...7_200).contains(tokens.expiresIn), "\(tokens.expiresIn)")
        }
    }
}

final class GuangYaProviderTests: XCTestCase {
    func testAccountState() async {
        let transport = FakeTransport([("user/me", json(#"{"sub":"u1","nickname":"小鸭"}"#)), ("user/me", json(#"{"code":"x"}"#))])
        let provider = guangya(transport)
        let signedOut = await provider.accountState(credential: nil)
        XCTAssertEqual(signedOut, .signedOut)
        let signedIn = await provider.accountState(credential: freshCredential)
        XCTAssertEqual(signedIn, .signedIn(nickname: "小鸭"))
        XCTAssertEqual(transport.requests[0].headers["Authorization"], "Bearer \(secretAccess)")
        XCTAssertEqual(transport.requests[0].method, .get)
        let unverified = await provider.accountState(credential: freshCredential)
        XCTAssertEqual(unverified, .unverified)
    }

    func testQuotaReadsStringSizes() async {
        let transport = FakeTransport([("get_assets", guangYaOK(#"{"totalSpaceSize":"1000","usedSpaceSize":"250"}"#))])
        let quota = await guangya(transport).quota(credential: freshCredential)
        XCTAssertEqual(quota, DriveQuota(used: 250, total: 1000))
        XCTAssertEqual(transport.requests[0].headers["did"], device.deviceId)
        XCTAssertEqual(transport.requests[0].headers["dt"], "4")
        XCTAssertTrue(transport.requests[0].headers["traceparent"]?.hasPrefix("00-") == true)
    }

    func testColdCredentialIsRefreshedOnceAndReported() async throws {
        let cold = GuangYaCredential(accessToken: "old", refreshToken: secretRefresh, device: device).driveCredential
        let transport = FakeTransport([
            ("auth/token", json(#"{"data":{"access_token":"new","refresh_token":"","expires_in":3600}}"#)),
            ("get_assets", guangYaOK(#"{"totalSpaceSize":"10","usedSpaceSize":"1"}"#)),
            ("get_assets", guangYaOK(#"{"totalSpaceSize":"10","usedSpaceSize":"2"}"#)),
        ])
        let updates = Box<(DriveCredential, DriveCredential)>()
        let provider = guangya(transport, updates: updates)
        _ = await provider.quota(credential: cold)
        _ = await provider.quota(credential: cold)
        XCTAssertEqual(transport.paths(), ["/v1/auth/token", "/assets/v1/get_assets", "/assets/v1/get_assets"])
        XCTAssertEqual(transport.requests[0].headers["X-Action"], "401")
        XCTAssertEqual(try transport.body(0)["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(transport.requests[1].headers["Authorization"], "Bearer new")
        XCTAssertEqual(updates.values.count, 1)
        let updated = GuangYaCredential(updates.values[0].0)
        XCTAssertEqual(updated.accessToken, "new")
        XCTAssertEqual(updated.refreshToken, secretRefresh, "a blank refresh_token keeps the old one")
        XCTAssertEqual(updates.values[0].1, cold)
    }

    func testRefusedRefreshKeepsTheAccessToken() async {
        let cold = GuangYaCredential(accessToken: "old", refreshToken: "r", device: device).driveCredential
        let transport = FakeTransport([("auth/token", json(#"{"error":"invalid_grant"}"#)), ("get_assets", guangYaOK(#"{"totalSpaceSize":"1"}"#))])
        _ = await guangya(transport).quota(credential: cold)
        XCTAssertEqual(transport.requests[1].headers["Authorization"], "Bearer old")
        let refreshed = await guangya(FakeTransport([("auth/token", json(#"{"error":"invalid_grant"}"#))])).refreshCredential(cold)
        XCTAssertNil(refreshed)
    }

    func testOpenSharePrefersTypedPasscode() async throws {
        let transport = FakeTransport([("get_share_access_token", guangYaOK(#"{"accessToken":"st"}"#)), ("get_share_summary", guangYaOK(#"{"shareName":"名字"}"#))])
        let link = ParsedShareLink(shareId: "sid", passcode: "old1", platform: .guangya)
        let opened = try await guangya(transport).openShare(link, passcode: "new2", credential: nil)
        XCTAssertEqual(opened.accessToken, "st")
        XCTAssertEqual(opened.title, "名字")
        let body = try transport.body(0)
        XCTAssertEqual(body["shareId"] as? String, "sid")
        XCTAssertEqual(body["code"] as? String, "new2")
        XCTAssertNil(transport.requests[0].headers["Authorization"])
        XCTAssertEqual(transport.requests[0].headers["Origin"], "https://www.guangyapan.com")
        XCTAssertEqual(transport.requests[0].headers["Referer"], "https://www.guangyapan.com/")
        XCTAssertFalse(transport.requests[0].headers["did", default: ""].isEmpty)
    }

    func testSummaryFailureFallsBackToDefaultTitle() async throws {
        let transport = FakeTransport([("get_share_access_token", guangYaOK(#"{"access_token":"st"}"#)), ("get_share_summary", json(#"{"code":"500"}"#))])
        let opened = try await guangya(transport).openShare(ParsedShareLink(shareId: "s", passcode: nil, platform: .guangya), passcode: nil, credential: nil)
        XCTAssertEqual(opened.title, "光鸭分享")
        XCTAssertEqual(try transport.body(0)["code"] as? String, "")
    }

    func testBusinessCodesMapToMessages() async {
        let cases: [(String, String)] = [
            ("209", "光鸭分享提取码错误或缺失"),
            ("201", "光鸭分享已取消、过期或不可访问"),
            ("504", "光鸭分享下载受限，请在官网确认该分享的下载权限"),
            ("157", "光鸭网盘空间不足"),
        ]
        for (code, message) in cases {
            let transport = FakeTransport([("get_share_access_token", json(#"{"code":"\#(code)","msg":"server"}"#))])
            do {
                _ = try await GuangYaAPI(transport: transport).getShareAccessToken(shareId: "s", code: "")
                XCTFail("expected failure")
            } catch {
                XCTAssertEqual(error as? DriveError, .api(message: message, code: Int(code)!))
            }
        }
        let other = FakeTransport([("get_share_access_token", json(#"{"code":"9","msg":"服务端信息"}"#)), ("get_share_access_token", json(#"{"code":"9"}"#))])
        let api = GuangYaAPI(transport: other)
        do { _ = try await api.getShareAccessToken(shareId: "s", code: ""); XCTFail() } catch { XCTAssertEqual(error as? DriveError, .api(message: "服务端信息", code: 9)) }
        do { _ = try await api.getShareAccessToken(shareId: "s", code: ""); XCTFail() } catch { XCTAssertEqual(error as? DriveError, .api(message: "获取分享访问令牌失败（code=9）", code: 9)) }
    }

    func testEmptyAndNonJSONBodiesAreReported() async {
        let transport = FakeTransport([("get_share_access_token", json("", status: 502)), ("get_share_access_token", json("", status: 200)), ("get_share_access_token", json("<html>", status: 403))])
        let api = GuangYaAPI(transport: transport)
        var messages: [String] = []
        for _ in 0..<3 {
            do { _ = try await api.getShareAccessToken(shareId: "s", code: "") } catch { messages.append(error.localizedDescription) }
        }
        XCTAssertEqual(messages, ["请求失败（HTTP 502）", "请求失败：响应为空", "响应解析失败（HTTP 403）"])
    }

    func testShareListingFollowsCursorAndDedupes() async throws {
        let transport = FakeTransport([
            ("get_share_page_files_list", guangYaOK(#"{"list":[{"fileId":"1","fileName":"d","resType":2},{"fileId":"2","fileName":"b.mp4","fileSize":"7","resType":1,"updatedAt":"T"}],"hasMore":true,"cursor":"c2"}"#)),
            ("get_share_page_files_list", guangYaOK(#"{"items":[{"id":"2","name":"b.mp4"},{"id":"3","name":"c.txt","size":5}],"hasMore":false,"cursor":"zzz"}"#)),
        ])
        let files = try await guangya(transport).listShareFiles(session: gyShare, directoryId: nil, credential: nil)
        XCTAssertEqual(files.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(files.map(\.isDirectory), [true, false, false])
        XCTAssertEqual(files[1].size, 7)
        XCTAssertEqual(files[1].modifiedAt, "T")
        XCTAssertEqual(files[2].size, 5)
        let first = try transport.body(0)
        XCTAssertEqual(first["parentId"] as? String, "")
        XCTAssertEqual(first["accessToken"] as? String, "share-token")
        XCTAssertEqual(first["pageSize"] as? Int, 100)
        XCTAssertNil(first["cursor"])
        XCTAssertEqual(try transport.body(1)["cursor"] as? String, "c2")
    }

    func testShareListingStopsOnRepeatedCursor() async throws {
        let page = guangYaOK(#"{"list":[{"fileId":"1","fileName":"a.txt"}],"hasMore":true,"cursor":"same"}"#)
        let transport = FakeTransport(fallback: page)
        let files = try await guangya(transport).listShareFiles(session: gyShare, directoryId: "d", credential: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testGuestDownloadUsesWebHeadersAndSurfacesRestriction() async throws {
        let transport = FakeTransport([
            ("get_share_download_url", guangYaOK(#"{"signedURL":"https://cdn.example/f?sig=1","size":"42"}"#)),
            ("get_share_download_url", json(#"{"code":"207"}"#)),
        ])
        let provider = guangya(transport)
        let link = try await provider.resolveShareFile(session: gyShare, file: gyFile, credential: nil, options: ShareResolveOptions())
        XCTAssertEqual(link.url.absoluteString, "https://cdn.example/f?sig=1")
        XCTAssertEqual(link.size, 42)
        XCTAssertEqual(link.headers["Referer"], "https://www.guangyapan.com/")
        XCTAssertEqual(link.headers["User-Agent"], GuangYaConstants.webUserAgent)
        XCTAssertNil(link.headers["Cookie"])
        XCTAssertNil(link.cleanupDirectoryId)
        let body = try transport.body(0)
        XCTAssertEqual(body["fileId"] as? String, "f1")
        XCTAssertEqual(body["accessToken"] as? String, "share-token")
        do {
            _ = try await provider.resolveShareFile(session: gyShare, file: gyFile, credential: nil, options: ShareResolveOptions())
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? DriveError, .api(message: "该光鸭分享需登录并转存后下载，请先登录光鸭云盘", code: 207))
        }
    }

    func testRestrictedShareIsRestoredThroughTempFolder() async throws {
        let transport = FakeTransport([
            ("get_share_download_url", json(#"{"code":"207"}"#)),
            ("create_dir", guangYaOK(#"{"fileId":"tmp1"}"#)),
            ("restore_share", guangYaOK(#"{"taskId":"t9"}"#)),
            ("get_task_status", guangYaOK(#"{"status":2,"detail":{"code":0}}"#)),
            ("get_file_list", guangYaOK(#"{"list":[]}"#)),
            ("get_file_list", guangYaOK(#"{"list":[{"fileId":"copy1","fileName":"a.bin","fileSize":100,"resType":1}],"total":1}"#)),
            ("get_res_download_url", guangYaOK(#"{"downloadUrl":"https://cdn.example/own"}"#)),
        ])
        let sleeps = Box<UInt64>()
        let link = try await guangya(transport, sleeps: sleeps).resolveShareFile(session: gyShare, file: gyFile, credential: freshCredential, options: ShareResolveOptions())
        XCTAssertEqual(link.fileId, "copy1")
        XCTAssertEqual(link.filename, "a.bin")
        XCTAssertEqual(link.size, 100)
        XCTAssertEqual(link.cleanupDirectoryId, "tmp1")
        XCTAssertEqual(transport.paths(), ["/userres/v1/get_share_download_url", "/userres/v1/file/create_dir", "/userres/v1/restore_share",
                                           "/userres/v1/get_task_status", "/userres/v1/file/get_file_list", "/userres/v1/file/get_file_list",
                                           "/userres/v1/get_res_download_url"])
        let create = try transport.body(1)
        XCTAssertEqual(create["parentId"] as? String, "")
        XCTAssertEqual(create["failIfNameExist"] as? Bool, true)
        XCTAssertTrue((create["dirName"] as? String)?.hasPrefix("AsterLink临时转存_") == true)
        let restore = try transport.body(2)
        XCTAssertEqual(restore["accessToken"] as? String, "share-token")
        XCTAssertEqual(restore["fileIds"] as? [String], ["f1"])
        XCTAssertEqual(restore["parentId"] as? String, "tmp1")
        XCTAssertEqual(transport.requests[2].headers["Authorization"], "Bearer \(secretAccess)")
        XCTAssertNil(transport.requests[0].headers["Authorization"], "the direct share request is anonymous")
        XCTAssertEqual(sleeps.values.count, 3, "one task delay, then one per folder poll")
    }

    func testNoSavePreferenceOffGoesStraightToRestore() async throws {
        let transport = FakeTransport([("create_dir", json(#"{"code":"500","msg":"stop"}"#))])
        do {
            _ = try await guangya(transport).resolveShareFile(session: gyShare, file: gyFile, credential: freshCredential, options: ShareResolveOptions(preferNoSave: false))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? DriveError, .api(message: "stop", code: 500))
        }
        XCTAssertEqual(transport.paths(), ["/userres/v1/file/create_dir"])
    }

    func testFailedRestoreDeletesTheTempFolder() async {
        let transport = FakeTransport([
            ("get_share_download_url", json(#"{"code":"207"}"#)),
            ("create_dir", guangYaOK(#"{"id":"tmp2"}"#)),
            ("restore_share", json(#"{"code":"157"}"#)),
            ("delete_file", guangYaOK(#"{}"#)),
        ])
        do {
            _ = try await guangya(transport).resolveShareFile(session: gyShare, file: gyFile, credential: freshCredential, options: ShareResolveOptions())
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? DriveError, .api(message: "光鸭网盘空间不足", code: 157))
        }
        XCTAssertEqual(transport.paths().last, "/userres/v1/file/delete_file")
        XCTAssertEqual(try? transport.body(3)["fileIds"] as? [String], ["tmp2"])
    }

    func testCopiedFileChecks() async {
        let sizeMismatch = FakeTransport([("create_dir", guangYaOK(#"{"fileId":"t"}"#)), ("restore_share", guangYaOK("{}")),
                                          ("get_file_list", guangYaOK(#"{"list":[{"fileId":"c","fileName":"a.bin","fileSize":5,"resType":1}]}"#)), ("delete_file", guangYaOK("{}"))])
        do {
            _ = try await guangya(sizeMismatch).resolveShareFile(session: gyShare, file: gyFile, credential: freshCredential, options: ShareResolveOptions(preferNoSave: false))
            XCTFail("expected failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "光鸭转存文件大小不一致")) }
        let duplicate = FakeTransport([("create_dir", guangYaOK(#"{"fileId":"t"}"#)), ("restore_share", guangYaOK("{}")),
                                       ("get_file_list", guangYaOK(#"{"list":[{"fileId":"c","fileName":"a.bin","resType":1},{"fileId":"d","fileName":"a.bin","resType":1}]}"#)), ("delete_file", guangYaOK("{}"))])
        do {
            _ = try await guangya(duplicate).resolveShareFile(session: gyShare, file: gyFile, credential: freshCredential, options: ShareResolveOptions(preferNoSave: false))
            XCTFail("expected failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "光鸭临时目录出现同名文件，无法确定下载目标")) }
    }

    func testCopyThatNeverAppearsTimesOutAfterThirtyPolls() async {
        let transport = FakeTransport([("create_dir", guangYaOK(#"{"fileId":"t"}"#)), ("restore_share", guangYaOK("{}"))], fallback: guangYaOK(#"{"list":[]}"#))
        do {
            _ = try await guangya(transport).resolveShareFile(session: gyShare, file: gyFile, credential: freshCredential, options: ShareResolveOptions(preferNoSave: false))
            XCTFail("expected failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "光鸭转存已提交，目标文件暂不可见，请稍后重试")) }
        XCTAssertEqual(transport.paths().filter { $0.hasSuffix("get_file_list") }.count, 30)
    }

    func testSaveToDriveReturnsTargetDirectory() async throws {
        let transport = FakeTransport([("restore_share", guangYaOK(#"{"taskId":"t1"}"#)), ("get_task_status", guangYaOK(#"{"status":2,"detail":{"code":0}}"#))])
        let id = try await guangya(transport).saveToDrive(session: gyShare, file: gyFile, directoryId: "dir9", credential: freshCredential, skipSpaceCheck: false)
        XCTAssertEqual(id, "dir9")
        XCTAssertEqual(try transport.body(0)["parentId"] as? String, "dir9")
    }

    func testSaveRequiresLogin() async {
        do {
            _ = try await guangya(FakeTransport()).saveToDrive(session: gyShare, file: gyFile, directoryId: nil, credential: DriveCredential(" "), skipSpaceCheck: true)
            XCTFail("expected failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "请先登录光鸭云盘")) }
    }

    func testTaskFailureAndTimeout() async {
        let failed = FakeTransport([("restore_share", guangYaOK(#"{"taskId":"t"}"#)), ("get_task_status", guangYaOK(#"{"status":2,"detail":{"code":5,"msg":"磁盘已满"}}"#))])
        do {
            try await GuangYaAPI(transport: failed, sleep: { _ in }).restoreShare(accountToken: "a", deviceId: nil, shareToken: "s", fileIds: ["f"], parentId: "")
            XCTFail("expected failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "磁盘已满")) }
        let stuck = FakeTransport(fallback: guangYaOK(#"{"status":1}"#))
        do {
            try await GuangYaAPI(transport: stuck, sleep: { _ in }).waitTask(accessToken: "a", deviceId: nil, taskId: "t")
            XCTFail("expected failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "光鸭操作仍在处理中，请稍后刷新列表确认结果")) }
        XCTAssertEqual(stuck.requests.count, 80)
    }

    func testOwnListingPagesFromZeroUntilTotal() async throws {
        let transport = FakeTransport([
            ("get_file_list", guangYaOK(#"{"list":[{"fileId":"1","fileName":"a.txt"},{"fileId":"2","dirName":"dir"}],"total":3}"#)),
            ("get_file_list", guangYaOK(#"{"list":[{"fileId":"3","fileName":"c.txt"}],"total":3}"#)),
        ])
        let files = try await guangya(transport).listFiles(directoryId: nil, credential: freshCredential)
        XCTAssertEqual(files.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(files[1].isDirectory, true)
        XCTAssertEqual(try transport.body(0)["page"] as? Int, 0)
        XCTAssertEqual(try transport.body(1)["page"] as? Int, 1)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testRepeatedOwnPageIsAnError() async {
        let page = guangYaOK(#"{"list":[{"fileId":"1","fileName":"a.txt"}],"total":9}"#)
        do {
            _ = try await guangya(FakeTransport(fallback: page)).listFiles(directoryId: "d", credential: freshCredential)
            XCTFail("expected failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "光鸭文件列表分页重复，请重试")) }
    }

    func testFileManagementBodies() async throws {
        let transport = FakeTransport(fallback: guangYaOK("{}"))
        let api = GuangYaAPI(transport: transport, sleep: { _ in })
        let dir = try await GuangYaAPI(transport: FakeTransport([("create_dir", guangYaOK(#"{"fileId":"nd"}"#))])).createDir(accessToken: "a", deviceId: nil, parentId: "p", name: "n")
        XCTAssertEqual(dir, "nd")
        try await api.renameFile(accessToken: "a", deviceId: "d", fileId: "f", newName: "x")
        try await api.moveFiles(accessToken: "a", deviceId: "d", fileIds: ["f1", "f2"], parentId: "p")
        try await api.deleteFiles(accessToken: "a", deviceId: "d", fileIds: ["f1"])
        XCTAssertEqual(transport.paths(), ["/userres/v1/file/rename", "/userres/v1/file/move_file", "/userres/v1/file/delete_file"])
        XCTAssertEqual(try transport.body(0)["newName"] as? String, "x")
        XCTAssertEqual(try transport.body(1)["fileIds"] as? [String], ["f1", "f2"])
        XCTAssertEqual(transport.requests[0].headers["did"], "d")
    }

    func testCreateDirRejectsAFileResponse() async {
        let transport = FakeTransport([("create_dir", guangYaOK(#"{"fileId":"x","resType":"1"}"#))])
        do {
            _ = try await GuangYaAPI(transport: transport).createDir(accessToken: "a", deviceId: nil, parentId: "", name: "n")
            XCTFail("expected failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "光鸭未创建文件夹，请检查是否存在同名文件")) }
    }

    func testCreateShareBodyAndFallbackURL() async throws {
        let transport = FakeTransport([("share_file", guangYaOK(#"{"shareId":"S1"}"#))])
        let info = try await GuangYaAPI(transport: transport).createShare(accessToken: "a", deviceId: nil, fileIds: ["f"], title: "T", expireDays: nil, passcode: "ab12")
        XCTAssertEqual(info, GuangYaShareInfo(shareURL: "https://www.guangyapan.com/s/S1", passcode: "ab12", shareId: "S1", title: "T"))
        let body = try transport.body(0)
        XCTAssertEqual(body["shareType"] as? Int, 1)
        XCTAssertEqual(body["validateDuration"] as? Int, 0)
        XCTAssertEqual(body["trafficLimit"] as? String, "0")
        XCTAssertEqual(body["downloadType"] as? Int, 1)
    }

    func testDriveFileLinkUsesFileIdOnly() async throws {
        let transport = FakeTransport([("get_res_download_url", guangYaOK(#"{"url":"https://cdn.example/x"}"#))])
        let link = try await guangya(transport).resolveFile(id: "fid", credential: freshCredential)
        XCTAssertEqual(link.fileId, "fid")
        XCTAssertEqual(try transport.body(0)["fileId"] as? String, "fid")
    }

    func testCleanupDeletesTheFolder() async throws {
        let transport = FakeTransport([("delete_file", guangYaOK("{}"))])
        await guangya(transport).cleanup(directoryId: "tmp", credential: freshCredential)
        XCTAssertEqual(try transport.body(0)["fileIds"] as? [String], ["tmp"])
    }

    func testRoutesGuangYaLinks() throws {
        let router = ShareLinkRouter(providers: [guangya(FakeTransport())])
        let routed = try router.route("https://www.guangyapan.com/s/a_b-c 提取码：Zz99")
        XCTAssertEqual(routed.link, ParsedShareLink(shareId: "a_b-c", passcode: "Zz99", platform: .guangya))
        XCTAssertEqual(routed.provider.platform, .guangya)
    }
}
