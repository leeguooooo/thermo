import XCTest
@testable import CloudDriveKit

// Response bodies are rebuilt from the field shapes read in UCApi.kt and the two UC repositories.
// None was captured from the live service, and no real account was used.

private let ucCookie = DriveCredential("__pus=SECRETP; __puus=SECRETU")
private let ucSession = ShareSession(platform: .uc, shareId: "abc", accessToken: "st+k/n=", title: "t")
private let ucFile = DriveFile(id: "f1", name: "a.bin", size: 100, isDirectory: false, parentId: "p1", fileToken: "ft1")
private let ucOK = #"{"status":200,"data":[{"fid":"f1","file_name":"a.bin","download_url":"https://dl.example/x?sig=1","size":100}]}"#

private func ucProvider(_ transport: FakeTransport, updates: Box<(DriveCredential, DriveCredential)>? = nil, sleeps: Box<UInt64>? = nil) -> UCProvider {
    UCProvider(api: UCAPI(transport: transport, credentialUpdated: { updates?.add(($0, $1)) }, sleep: { sleeps?.add($0) }))
}

final class UCProviderTests: XCTestCase {
    func testRoutingAndConstants() {
        let link = ShareLinkRouter.parse("https://drive.uc.cn/s/abc123 提取码：Ab12")
        XCTAssertEqual(link, ParsedShareLink(shareId: "abc123", passcode: "Ab12", platform: .uc))
        XCTAssertEqual(UCProvider().parseShareLink("https://drive.uc.cn/s/abc123")?.shareId, "abc123")
        XCTAssertNil(UCProvider().parseShareLink("https://pan.quark.cn/s/abc123"))
        XCTAssertEqual(UCProvider().credentialRefreshInterval, 90 * 60)
        XCTAssertEqual(UCProvider().capabilities, [.shareListing, .guestShareAccess, .ownFiles, .saveToDrive])
        XCTAssertTrue(UCConstants.isValidCookie("__pus=1; __puus=2"))
        XCTAssertFalse(UCConstants.isValidCookie("__pus=1"))
        XCTAssertEqual(UCCookieUtil.merge("a=1; __puus=old", setCookies: ["__puus=new; Path=/", "__pus=p; Secure", "x=y"]), "a=1; __puus=new; __pus=p")
        XCTAssertEqual(UCCookieUtil.withoutPuus("a=1; __puus=old; __pus=p"), "a=1; __pus=p")
    }

    func testAccountStateAndQuota() async {
        let good = ucProvider(FakeTransport([("/account/info", json(#"{"success":true,"data":{"nickname":"Leo"}}"#))]))
        let state = await good.accountState(credential: ucCookie)
        XCTAssertEqual(state, .signedIn(nickname: "Leo"))
        let unverified = await ucProvider(FakeTransport()).accountState(credential: ucCookie)
        XCTAssertEqual(unverified, .unverified)
        let signedOut = await ucProvider(FakeTransport()).accountState(credential: DriveCredential("a=1"))
        XCTAssertEqual(signedOut, .signedOut)

        let transport = FakeTransport([("clouddrive/member", json(#"{"data":{"use_capacity":10,"total_capacity":100}}"#))])
        let quota = await ucProvider(transport).quota(credential: ucCookie)
        XCTAssertEqual(quota, DriveQuota(used: 10, total: 100))
        XCTAssertEqual(transport.requests[0].url.absoluteString, "https://pc-api.uc.cn/1/clouddrive/member?pr=UCBrowser&fr=pc&fetch_subscribe=true&_ch=home")
        XCTAssertEqual(transport.requests[0].headers["User-Agent"], UCConstants.cloudUserAgent)
        XCTAssertEqual(transport.requests[0].headers["Referer"], "https://drive.uc.cn/")
    }

    func testOpenShareRequest() async throws {
        let transport = FakeTransport([("sharepage/token", json(#"{"status":200,"data":{"stoken":"st","title":"T","first_fid":"x"}}"#)),
                                       ("sharepage/token", json(#"{"status":200,"data":{"stoken":"st2","title":"T"}}"#))])
        let p = ucProvider(transport)
        let link = ParsedShareLink(shareId: "abc", passcode: "link", platform: .uc)
        let opened = try await p.openShare(link, passcode: " ", credential: nil)
        XCTAssertEqual(opened.accessToken, "st")
        XCTAssertEqual(opened.platform, .uc)
        _ = try await p.openShare(link, passcode: "typed", credential: ucCookie)
        XCTAssertEqual(transport.requests[0].url.absoluteString, "https://pc-api.uc.cn/1/clouddrive/share/sharepage/token?pr=UCBrowser&fr=pc")
        XCTAssertEqual(try transport.body(0)["passcode"] as? String, "link")
        XCTAssertEqual(try transport.body(0)["share_for_transfer"] as? Bool, true)
        XCTAssertEqual(try transport.body(1)["passcode"] as? String, "typed")
        XCTAssertEqual(transport.requests[1].headers["User-Agent"], UCConstants.userAgent)
        XCTAssertEqual(transport.requests[1].headers["Cookie"], ucCookie.value)
    }

    func testServerMessagesPassThrough() async {
        let cases: [(HTTPResponse, DriveError)] = [
            (json(#"{"status":400,"message":"提取码错误"}"#), .api(message: "提取码错误")),
            (json("<html>", status: 403), .api(message: "响应解析失败（HTTP 403）")),
            (json(#"{"status":200}"#), .api(message: "响应缺少 data")),
            (json(""), .api(message: "请求失败：响应为空")),
        ]
        for (response, expected) in cases {
            do {
                _ = try await ucProvider(FakeTransport(fallback: response)).openShare(ParsedShareLink(shareId: "a", passcode: nil, platform: .uc), passcode: nil, credential: nil)
                XCTFail("expected a failure")
            } catch { XCTAssertEqual(error as? DriveError, expected) }
        }
    }

    func testShareListingUsesTransferDetailAndBothListShapes() async throws {
        let page = json(#"{"status":200,"data":{"list":[{"fid":"f1","file_name":"a","size":5,"dir":false,"pdir_fid":"0","share_fid_token":"t","updated_at":1700}]}}"#)
        let transport = FakeTransport(fallback: page)
        let files = try await ucProvider(transport).listShareFiles(session: ucSession, directoryId: nil, credential: ucCookie)
        XCTAssertEqual(files, [DriveFile(id: "f1", name: "a", size: 5, isDirectory: false, parentId: "0", fileToken: "t", modifiedAt: "1700")])
        XCTAssertEqual(transport.requests.count, 2, "a repeated page stops the loop")
        XCTAssertEqual(transport.requests[0].url.absoluteString,
            "https://pc-api.uc.cn/1/clouddrive/transfer_share/detail?entry=ft&fr=pc&pr=UCBrowser&pwd_id=abc&pdir_fid=0&fetch_file_list=1&passcode=&_page=1&_size=50&_fetch_total=1&_fetch_task=1&_fetch_share=1&_sort=&stoken=st%2Bk%2Fn%3D")
        XCTAssertEqual(transport.requests[0].headers["Origin"], "https://fast.uc.cn")
        XCTAssertEqual(transport.requests[0].headers["Referer"], "https://fast.uc.cn/")

        let nested = FakeTransport([("transfer_share/detail", json(#"{"status":200,"data":{"detail_info":{"list":[{"fid":"d1","file_name":"dir","dir":true}]}}}"#)),
                                    ("transfer_share/detail", json(#"{"status":200,"data":{"list":[]}}"#))])
        let sub = try await ucProvider(nested).listShareFiles(session: ucSession, directoryId: "d0", credential: nil)
        XCTAssertEqual(sub.map(\.id), ["d1"])
        XCTAssertTrue(sub[0].isDirectory)
        XCTAssertTrue(nested.requests[0].url.absoluteString.contains("&pdir_fid=d0&"))
    }

    func testShareDetailPostBody() async throws {
        let transport = FakeTransport(fallback: json(#"{"status":200,"data":{"detail_info":{"list":[{"fid":"a","file_name":"n"}]}}}"#))
        let api = UCAPI(transport: transport)
        let root = try await api.getShareFiles(shareId: "abc", passcode: nil, pdirFid: "0", cookie: ucCookie.value)
        XCTAssertEqual(root.map(\.id), ["a"])
        _ = try await api.getShareFiles(shareId: "abc", passcode: "pw", pdirFid: "sub", cookie: ucCookie.value)
        XCTAssertEqual(transport.requests[0].url.absoluteString, "https://pc-api.uc.cn/1/clouddrive/share/sharepage/v2/detail?pr=UCBrowser&fr=pc&ve=2.5.20")
        XCTAssertNil(try transport.body(0)["pdir_fid"])
        XCTAssertEqual(try transport.body(0)["fetch_error_background"] as? Int, 1)
        XCTAssertEqual(try transport.body(1)["pdir_fid"] as? String, "sub")
        XCTAssertEqual(try transport.body(1)["passcode"] as? String, "pw")
        XCTAssertEqual(transport.requests[0].headers["Origin"], "https://drive.uc.cn")
    }

    func testOwnListingPagesPastFifty() async throws {
        let full = (0..<50).map { #"{"fid":"a\#($0)","file_name":"n","size":1,"dir":true}"# }.joined(separator: ",")
        let transport = FakeTransport([("_page=1&", json(#"{"status":200,"data":{"list":[\#(full)]}}"#)),
                                       ("_page=2&", json(#"{"status":200,"data":{"list":[{"fid":"z","fname":"old"}]}}"#)),
                                       ("_page=3&", json(#"{"status":200,"data":{"list":[]}}"#))])
        let files = try await ucProvider(transport).listFiles(directoryId: "d", credential: ucCookie)
        XCTAssertEqual(files.count, 51)
        XCTAssertEqual(files.last?.name, "old")
        XCTAssertEqual(transport.requests[0].url.absoluteString,
            "https://pc-api.uc.cn/1/clouddrive/file/sort?pr=UCBrowser&fr=pc&pdir_fid=d&_page=1&_size=50&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type%3Aasc%2Cupdated_at%3Adesc")
        XCTAssertEqual(transport.requests[0].headers["User-Agent"], UCConstants.cloudUserAgent)
    }

    func testFileListReadsLegacyFieldNames() async throws {
        let body = #"{"status":200,"data":{"list":[{"fid":"f","fname":"old","fsize":7,"isdir":1,"pdir_fid":"0","fid_token":"tk","modify_time":5}]}}"#
        let transport = FakeTransport(fallback: json(body))
        let files = try await UCAPI(transport: transport).getFileList(pdirFid: "0", cookie: ucCookie.value)
        XCTAssertEqual(files, [DriveFile(id: "f", name: "old", size: 7, isDirectory: true, parentId: "0", fileToken: "tk", modifiedAt: "5")])
        XCTAssertEqual(transport.requests[0].url.absoluteString, "https://pc-api.uc.cn/1/clouddrive/file?pr=UCBrowser&fr=pc&pdir_fid=0&page=1&size=100")
    }

    func testSaveToDriveSendsSourceBodyAndPollsTask() async throws {
        let sleeps = Box<UInt64>()
        let transport = FakeTransport([
            ("clouddrive/member", json(#"{"data":{"use_capacity":0,"total_capacity":1000}}"#)),
            ("sharepage/save", json(#"{"status":200,"data":{"task_id":"t1"}}"#)),
            ("clouddrive/task", json(#"{"status":200,"data":{"status":1}}"#)),
            ("clouddrive/task", json(#"{"status":200,"data":{"finished_at":9,"save_as":{"save_as_top_fids":["saved1"]}}}"#)),
        ])
        let saved = try await ucProvider(transport, sleeps: sleeps).saveToDrive(session: ucSession, file: ucFile, directoryId: nil, credential: ucCookie, skipSpaceCheck: false)
        XCTAssertEqual(saved, "saved1")
        XCTAssertEqual(sleeps.values, [1_000_000_000])
        let body = try transport.body(1)
        XCTAssertEqual(body["pwd_id"] as? String, "abc")
        XCTAssertEqual(body["stoken"] as? String, "st+k/n=")
        XCTAssertEqual(body["pdir_fid"] as? String, "p1")
        XCTAssertEqual(body["to_pdir_fid"] as? String, "0")
        XCTAssertEqual(body["fid_list"] as? [String], ["f1"])
        XCTAssertEqual(body["fid_token_list"] as? [String], ["ft1"])
        XCTAssertEqual(body["scene"] as? String, "link")
        XCTAssertEqual(transport.requests[2].url.absoluteString, "https://pc-api.uc.cn/1/clouddrive/task?pr=UCBrowser&fr=pc&task_id=t1&retry_index=0")
    }

    func testSaveFailuresAndSpaceCheck() async {
        let noSpace = FakeTransport([("clouddrive/member", json(#"{"data":{"use_capacity":950,"total_capacity":1000}}"#))])
        do {
            _ = try await ucProvider(noSpace).saveToDrive(session: ucSession, file: ucFile, directoryId: nil, credential: ucCookie, skipSpaceCheck: false)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .insufficientSpace(required: 100, available: 50)) }
        XCTAssertEqual(noSpace.requests.count, 1, "no save is attempted when the space check fails")

        let noTask = FakeTransport([("sharepage/save", json(#"{"status":200,"data":{"task_id":""}}"#))])
        do {
            _ = try await ucProvider(noTask).saveToDrive(session: ucSession, file: ucFile, directoryId: "d", credential: ucCookie, skipSpaceCheck: true)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "转存失败")) }

        let sleeps = Box<UInt64>()
        let stuck = FakeTransport([("sharepage/save", json(#"{"status":200,"data":{"task_id":"t"}}"#))], fallback: json(#"{"status":200,"data":{"status":1}}"#))
        do {
            _ = try await ucProvider(stuck, sleeps: sleeps).saveToDrive(session: ucSession, file: ucFile, directoryId: "d", credential: ucCookie, skipSpaceCheck: true)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .timedOut("转存超时，请稍后重试")) }
        XCTAssertEqual(sleeps.values.count, 10)
    }

    func testResolveFileUsesShareChannelWithAccountHeaders() async throws {
        let transport = FakeTransport(fallback: json(ucOK))
        let link = try await ucProvider(transport).resolveFile(id: "f1", credential: ucCookie)
        XCTAssertEqual(link.url.absoluteString, "https://dl.example/x?sig=1")
        XCTAssertEqual(link.size, 100)
        XCTAssertEqual(link.headers, ["Cookie": ucCookie.value, "User-Agent": UCConstants.userAgent,
                                      "Referer": "https://drive.uc.cn/", "Origin": "https://drive.uc.cn"])
        XCTAssertEqual(transport.requests[0].url.absoluteString, "https://pc-api.uc.cn/1/clouddrive/file/download?entry=ft&fr=pc&pr=UCBrowser")
        XCTAssertEqual(try transport.body(0)["fids"] as? [String], ["f1"])
    }

    func testResolveShareFileSignedInSkipsSave() async throws {
        let transport = FakeTransport(fallback: json(ucOK))
        let link = try await ucProvider(transport).resolveShareFile(session: ucSession, file: ucFile, credential: ucCookie, options: ShareResolveOptions())
        XCTAssertEqual(transport.requests.count, 1)
        let body = try transport.body(0)
        XCTAssertEqual(body["fids"] as? [String], ["f1"])
        XCTAssertEqual(body["fids_token"] as? [String], ["ft1"])
        XCTAssertEqual(body["pwd_id"] as? String, "abc")
        XCTAssertEqual(body["stoken"] as? String, "st+k/n=")
        XCTAssertEqual(link.headers["Cookie"], ucCookie.value)
        XCTAssertNil(link.cleanupDirectoryId)
    }

    func testSignedInErrorUsesServerMessage() async {
        let transport = FakeTransport(fallback: json(#"{"status":400,"code":31001,"message":"need login"}"#))
        do {
            _ = try await ucProvider(transport).resolveShareFile(session: ucSession, file: ucFile, credential: ucCookie, options: ShareResolveOptions())
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "need login")) }
    }

    func testVideoPrefersPreviewAndFallsBack() async throws {
        let video = DriveFile(id: "v1", name: "Movie.MKV", size: 0, isDirectory: false, parentId: "p", fileToken: "vt")
        let preview = FakeTransport([("video_preview", json(#"{"status":200,"data":{"play_info":{"url":"https://play.example/o.mp4","size":4242}}}"#))])
        let link = try await ucProvider(preview).resolveShareFile(session: ucSession, file: video, credential: ucCookie, options: ShareResolveOptions())
        XCTAssertEqual(link.url.absoluteString, "https://play.example/o.mp4")
        XCTAssertEqual(link.size, 4242)
        XCTAssertEqual(link.filename, "Movie.MKV")
        XCTAssertEqual(link.fileId, "v1")
        XCTAssertEqual(preview.requests[0].url.absoluteString,
            "https://pc-api.uc.cn/1/clouddrive/share/sharepage/video_preview?pr=UCBrowser&fr=h5&pwd_id=abc&stoken=st%2Bk%2Fn%3D&fid=v1&fid_token=vt")
        XCTAssertEqual(preview.requests[0].method, .get)

        let fallback = FakeTransport([("video_preview", json(#"{"status":500}"#)), ("file/download", json(ucOK))])
        let second = try await ucProvider(fallback).resolveShareFile(session: ucSession, file: video, credential: ucCookie, options: ShareResolveOptions())
        XCTAssertEqual(second.url.absoluteString, "https://dl.example/x?sig=1")
        XCTAssertEqual(fallback.requests.count, 2)

        let guest = FakeTransport(fallback: json(ucOK))
        _ = try await ucProvider(guest).resolveShareFile(session: ucSession, file: video, credential: nil, options: ShareResolveOptions())
        XCTAssertFalse(guest.requests.contains { $0.url.path.contains("video_preview") })
    }

    func testGuestPathCapturesAndReusesPugs() async throws {
        let first = HTTPResponse(statusCode: 200, setCookies: ["__pugs=G1; Path=/"], body: Data(ucOK.utf8))
        let transport = FakeTransport([("file/download", first)], fallback: json(ucOK))
        let p = ucProvider(transport)
        let link = try await p.resolveShareFile(session: ucSession, file: ucFile, credential: nil, options: ShareResolveOptions())
        XCTAssertNil(transport.requests[0].headers["Cookie"])
        XCTAssertEqual(transport.requests[0].headers["User-Agent"], UCConstants.guestUserAgent)
        XCTAssertEqual(transport.requests[0].headers["Sec-Ch-Ua"], UCConstants.guestSecChUA)
        XCTAssertEqual(link.headers, ["Cookie": "__pugs=G1", "User-Agent": UCConstants.guestUserAgent,
                                      "Sec-Ch-Ua": UCConstants.guestSecChUA, "Referer": "https://drive.uc.cn/", "Origin": "https://drive.uc.cn"])
        // The next guest call sends the cached token and, with none in its own response, keeps it.
        let again = try await p.resolveShareFile(session: ucSession, file: ucFile, credential: DriveCredential("  "), options: ShareResolveOptions())
        XCTAssertEqual(transport.requests[1].headers["Cookie"], "__pugs=G1")
        XCTAssertEqual(again.headers["Cookie"], "__pugs=G1")
    }

    func testGuestErrorMessages() async {
        let cases: [(String, DriveError)] = [
            (#"{"status":400,"code":31001,"message":"x"}"#, .api(message: "该分享需要登录 UC 网盘后才能下载", code: 31001)),
            (#"{"status":400,"code":23018,"message":"x"}"#, .api(message: "该文件超出游客可获取的大小上限，请先登录 UC 网盘再下载", code: 23018)),
            (#"{"status":400,"code":14001}"#, .api(message: "分享已失效或提取码有误，请重新解析", code: 14001)),
            (#"{"status":400,"code":41020}"#, .api(message: "文件令牌已过期，请重新解析分享", code: 41020)),
            (#"{"status":400,"code":7,"message":"other"}"#, .api(message: "other", code: 7)),
            (#"{"status":400,"code":7}"#, .api(message: "获取下载链接失败", code: 7)),
            (#"{"status":200,"code":0}"#, .api(message: "响应缺少 data")),
            (#"{"status":200,"data":[]}"#, .api(message: "未返回下载链接")),
            ("<html>blocked</html>", .api(message: "响应解析失败（HTTP 200）")),
        ]
        for (body, expected) in cases {
            do {
                _ = try await ucProvider(FakeTransport(fallback: json(body))).resolveShareFile(session: ucSession, file: ucFile, credential: nil, options: ShareResolveOptions())
                XCTFail("expected a failure for \(body)")
            } catch { XCTAssertEqual(error as? DriveError, expected, body) }
        }
    }

    func testAccountDownloadErrorKeepsServerCode() async {
        do {
            _ = try await ucProvider(FakeTransport(fallback: json(#"{"status":404,"code":21001,"message":"gone"}"#))).resolveFile(id: "x", credential: ucCookie)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? DriveError, .api(message: "gone", code: 21001)) }
    }

    func testCloudDownloadChannel() async throws {
        let transport = FakeTransport(fallback: json(ucOK))
        let link = try await UCAPI(transport: transport).cloudGetDownloadLink(fid: "f1", cookie: ucCookie.value)
        XCTAssertEqual(link.downloadURL, "https://dl.example/x?sig=1")
        XCTAssertEqual(transport.requests[0].url.absoluteString, "https://pc-api.uc.cn/1/clouddrive/file/download")
        XCTAssertEqual(transport.requests[0].headers["User-Agent"], UCConstants.cloudUserAgent)
    }

    func testRefreshSessionStripsPuusAndReportsRotation() async throws {
        let updates = Box<(DriveCredential, DriveCredential)>()
        let transport = FakeTransport(fallback: HTTPResponse(setCookies: ["__puus=NEW; Path=/"], body: Data("{}".utf8)))
        let refreshed = await ucProvider(transport, updates: updates).refreshCredential(ucCookie)
        XCTAssertEqual(refreshed?.value, "__pus=SECRETP; __puus=NEW")
        XCTAssertEqual(transport.requests[0].headers["Cookie"], "__pus=SECRETP")
        XCTAssertEqual(transport.requests[0].headers["Referer"], "https://drive.uc.cn/")
        XCTAssertEqual(updates.values.count, 1)
        XCTAssertEqual(updates.values[0].1, ucCookie)
        let failed = await ucProvider(FakeTransport()).refreshCredential(ucCookie)
        XCTAssertNil(failed)
    }

    func testRotationFromApiResponseIsReported() async throws {
        let updates = Box<(DriveCredential, DriveCredential)>()
        let response = HTTPResponse(setCookies: ["__puus=ROT"], body: Data(#"{"status":200,"data":{"list":[]}}"#.utf8))
        let p = ucProvider(FakeTransport(fallback: response), updates: updates)
        _ = try await p.listFiles(directoryId: nil, credential: ucCookie)
        XCTAssertEqual(updates.values.first?.0.value, "__pus=SECRETP; __puus=ROT")
    }

    func testTempDirectoryReusedOrCreated() async throws {
        let existing = FakeTransport([("clouddrive/file?", json(#"{"status":200,"data":{"list":[{"fid":"t9","file_name":"YunX临时转存","dir":true}]}}"#))])
        let reused = try await ucProvider(existing).ensureTempDirectory(credential: ucCookie)
        XCTAssertEqual(reused, "t9")
        let none = FakeTransport([("pdir_fid=0&page", json(#"{"status":200,"data":{"list":[]}}"#)),
                                  ("clouddrive/file?pr=UCBrowser&fr=pc", json(#"{"status":200,"data":{"fid":"new1"}}"#))])
        let created = try await ucProvider(none).ensureTempDirectory(credential: ucCookie)
        XCTAssertEqual(created, "new1")
        XCTAssertEqual(try none.body(1)["file_name"] as? String, "YunX临时转存")
        XCTAssertEqual(try none.body(1)["dir_init_lock"] as? Bool, false)
    }

    func testManagementCallsAndShareCreation() async throws {
        let sleeps = Box<UInt64>()
        let transport = FakeTransport([
            ("file/delete", json(#"{"status":200,"data":{"task_id":"d1"}}"#)),
            ("file/rename", json(#"{"status":200}"#)),
            ("file/move", json(#"{"status":200,"data":{"task_id":"m1"}}"#)),
            ("clouddrive/share?", json(#"{"status":200,"data":{"task_id":"s1"}}"#)),
            ("clouddrive/task", json(#"{"status":200,"data":{"status":2,"share_id":"sid"}}"#)),
            ("share/password", json(#"{"status":200,"data":{"share_url":"https://drive.uc.cn/s/x","passcode":"p","pwd_id":"x","title":"T","expired_type":3}}"#)),
        ])
        let api = UCAPI(transport: transport, sleep: { sleeps.add($0) })
        let deleted = try await api.deleteFile(fid: "f", cookie: ucCookie.value)
        XCTAssertEqual(deleted, "d1")
        XCTAssertEqual(try transport.body(0)["action_type"] as? Int, 2)
        let renamed = await api.renameFile(fid: "f", newName: "n", cookie: ucCookie.value)
        XCTAssertTrue(renamed)
        let moved = try await api.moveFile(fid: "f", toPdirFid: "to", cookie: ucCookie.value)
        XCTAssertEqual(moved, "m1")
        XCTAssertEqual(try transport.body(2)["to_pdir_fid"] as? String, "to")
        let shareId = try await api.createShare(fidList: ["f"], title: " ", urlType: 2, passcode: "ab12", expiredType: 3, cookie: ucCookie.value)
        XCTAssertEqual(shareId, "sid")
        let body = try transport.body(3)
        XCTAssertEqual(body["title"] as? String, "分享文件")
        XCTAssertEqual(body["public_search"] as? Int, 0)
        XCTAssertEqual(body["passcode"] as? String, "ab12")
        XCTAssertNil(body["support_error_code"])
        let info = try await api.getShareInfo(shareId: "sid", cookie: ucCookie.value)
        XCTAssertEqual(info, UCShareInfo(shareURL: "https://drive.uc.cn/s/x", passcode: "p", pwdId: "x", title: "T", expiredType: 3))
    }

    func testPlayLinkTriesBothPaths() async {
        let body = #"{"status":200,"data":{"video_list":[{"video_info":{}},{"video_info":{"url":"https://v.example/a.m3u8","resolution":"super","format":"m3u8"}}]}}"#
        let transport = FakeTransport([("play/project?pr=", json(#"{"status":500}"#)), ("play/project", json(body))])
        let play = await UCAPI(transport: transport).getPlayLink(fid: "f", cookie: ucCookie.value)
        XCTAssertEqual(play, UCPlayLink(url: "https://v.example/a.m3u8", resolution: "super", format: "m3u8", isHLS: true))
        XCTAssertEqual(transport.requests[1].url.absoluteString, "https://pc-api.uc.cn/1/clouddrive/file/v2/play/project")
        XCTAssertEqual(try transport.body(0)["supports"] as? String, "fmp4_av,m3u8,dolby_vision")
    }

    func testCredentialsAndTokensStayOutOfDescriptions() throws {
        let link = ResolvedLink(url: try XCTUnwrap(URL(string: "https://dl.example/x?sig=SECRETSIG")), headers: ["Cookie": ucCookie.value], fileId: "f", filename: "a", size: 1)
        let rendered = [String(describing: link), String(reflecting: link), String(describing: ucCookie), String(describing: ucSession),
                        String(describing: UCShareToken(stoken: "STOKENSECRET", title: "t", firstFid: "")),
                        String(describing: UCDownloadLink(fid: "f", filename: "a", downloadURL: "https://x/SECRETSIG", size: 1, guestCookie: "__pugs=SECRETPUGS"))].joined()
        for secret in ["SECRETP", "SECRETU", "SECRETSIG", "STOKENSECRET", "SECRETPUGS", "st+k/n="] {
            XCTAssertFalse(rendered.contains(secret), secret)
        }
    }

    func testCancellationInPollingPropagates() async {
        let transport = FakeTransport([("sharepage/save", json(#"{"status":200,"data":{"task_id":"t"}}"#))], fallback: json(#"{"status":200,"data":{"status":1}}"#))
        let p = UCProvider(api: UCAPI(transport: transport, sleep: { _ in throw CancellationError() }))
        do {
            _ = try await p.saveToDrive(session: ucSession, file: ucFile, directoryId: nil, credential: ucCookie, skipSpaceCheck: true)
            XCTFail("expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
