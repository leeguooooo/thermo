// Ported from YunX-Desktop (MIT): data/network/UCApi.kt.
// Endpoints, parameters and error handling follow that file. Lookups that returned null there and
// swallow their errors return nil here; the others throw `DriveError`.
import Foundation

public struct UCShareToken: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let stoken: String
    public let title: String
    public let firstFid: String
    public var description: String { "UCShareToken(\(title), <redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: ["title": title]) }
}

public struct UCShareInfo: Sendable, Equatable {
    public let shareURL: String
    public let passcode: String
    public let pwdId: String
    public let title: String
    public let expiredType: Int
}

public struct UCDownloadLink: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let fid: String
    public let filename: String
    public let downloadURL: String
    public let size: Int64
    /// `__pugs=...` for guest links, else empty.
    public let guestCookie: String
    public var description: String { "UCDownloadLink(\(fid), \(filename), <redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: ["fid": fid, "filename": filename, "size": size]) }
}

public struct UCPlayLink: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let url: String
    public let resolution: String
    public let format: String
    public let isHLS: Bool
    public var description: String { "UCPlayLink(\(resolution), \(format), <redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: ["resolution": resolution, "format": format, "isHLS": isHLS]) }
}

public actor UCAPI {
    private let http: HTTPClient
    private let sleep: DriveSleeper
    private let credentialUpdated: CredentialUpdateHandler?

    /// Guest token from Set-Cookie, about 3 hours. The download layer answers 403 without it.
    public private(set) var guestPugs = ""

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        credentialUpdated: CredentialUpdateHandler? = nil,
        sleep: @escaping DriveSleeper = { try await Task.sleep(nanoseconds: $0) }
    ) {
        http = HTTPClient(transport: transport, defaultHeaders: ["User-Agent": UCConstants.userAgent])
        self.sleep = sleep
        self.credentialUpdated = credentialUpdated
    }

    // MARK: Account

    public func fetchNickname(cookie: String) async -> String? {
        guard let response = try? await http.get(UCConstants.accountInfoURL, headers: ["Cookie": cookie]),
              (200..<300).contains(response.statusCode),
              let json = LenientJSON(data: response.body),
              json.bool("success") else { return nil }
        return json.child("data")?.string("nickname").nonBlank
    }

    public func getQuota(cookie: String) async -> DriveQuota? {
        let headers = ["Cookie": cookie, "User-Agent": UCConstants.cloudUserAgent,
                       "Origin": UCConstants.webOrigin, "Referer": "\(UCConstants.webOrigin)/"]
        guard let response = try? await http.get(UCConstants.quotaURL, headers: headers),
              let data = LenientJSON(data: response.body)?.child("data") else { return nil }
        return DriveQuota(used: data.int64("use_capacity"), total: data.int64("total_capacity"))
    }

    /// Requests /config without __puus so the server issues a new one. Returns nil on failure.
    public func refreshSession(cookie: String) async -> String? {
        let headers = ["Cookie": UCCookieUtil.withoutPuus(cookie), "Referer": UCConstants.downloadReferer]
        guard let response = try? await http.get(UCConstants.configURL, headers: headers) else { return nil }
        return mergeCookie(original: cookie, response: response)
    }

    // MARK: Shares

    public func getShareToken(shareId: String, passcode: String?, cookie: String) async throws -> UCShareToken {
        let response = try await http.postJSON(UCConstants.shareTokenURL, json: [
            "pwd_id": shareId,
            "passcode": passcode ?? "",
            "share_for_transfer": true,
        ], headers: ["Cookie": cookie])
        let data = try parseData(response, cookie: cookie)
        return UCShareToken(stoken: data.string("stoken"), title: data.string("title"), firstFid: data.string("first_fid"))
    }

    /// transfer_share/detail, the listing the official download flow uses. Its `share_fid_token` is
    /// bound to the stoken, which is what lets download pass its token check.
    public func getTransferShareFiles(shareId: String, stoken: String, pdirFid: String, cookie: String, page: Int = 1, size: Int = 50) async throws -> [DriveFile] {
        let url = UCConstants.transferShareDetailURL
            + "&pwd_id=\(q(shareId))&pdir_fid=\(q(pdirFid))&fetch_file_list=1&passcode="
            + "&_page=\(page)&_size=\(size)&_fetch_total=1&_fetch_task=1&_fetch_share=1&_sort="
            + "&stoken=\(q(stoken))"
        let headers = ["Cookie": cookie, "Origin": "https://fast.uc.cn", "Referer": "https://fast.uc.cn/"]
        let data = try parseData(try await http.get(url, headers: headers), cookie: cookie)
        // The list sits in data.list or data.detail_info.list.
        let items = data.array("list") != nil ? data.objects("list") : (data.child("detail_info")?.objects("list") ?? [])
        return items.map(Self.shareFile)
    }

    /// sharepage/v2/detail (POST). Not used by the source's resolve repository, which lists with
    /// `getTransferShareFiles`; kept for parity with UCApi.kt.
    public func getShareFiles(shareId: String, passcode: String?, pdirFid: String, cookie: String, page: Int = 1, size: Int = 50) async throws -> [DriveFile] {
        var body: [String: Any] = [
            "pwd_id": shareId,
            "passcode": passcode ?? "",
            "force": 0,
            "page": page,
            "size": size,
            "fetch_banner": 1,
            "fetch_share": 1,
            "fetch_total": 1,
            "sort": "file_type:asc,file_name:asc",
            "banner_platform": "other",
            "web_platform": "windows",
            "fetch_error_background": 1,
        ]
        // The root is not sent; only sub-directories carry pdir_fid.
        if !pdirFid.isBlankText, pdirFid != UCConstants.rootDirectoryId { body["pdir_fid"] = pdirFid }
        let headers = ["Cookie": cookie, "Origin": UCConstants.webOrigin, "Referer": "\(UCConstants.webOrigin)/"]
        let response = try await http.postJSON("\(UCConstants.shareDetailURL)&ve=2.5.20", json: body, headers: headers)
        let data = try parseData(response, cookie: cookie)
        return (data.child("detail_info")?.objects("list") ?? []).map(Self.shareFile)
    }

    // MARK: Own files

    public func getFileList(pdirFid: String, cookie: String, page: Int = 1, size: Int = 100) async throws -> [DriveFile] {
        let url = "\(UCConstants.fileURL)&pdir_fid=\(q(pdirFid))&page=\(page)&size=\(size)"
        let data = try parseData(try await http.get(url, headers: ["Cookie": cookie]), cookie: cookie)
        return data.objects("list").map { item in
            DriveFile(id: item.string("fid"), name: item.string("file_name").ifEmpty(item.string("fname")),
                      size: item.has("size") ? item.int64("size") : item.int64("fsize"),
                      isDirectory: item.bool("dir") || item.int("isdir") == 1, parentId: item.string("pdir_fid"),
                      fileToken: item.string("fid_token"), modifiedAt: item.string("modify_time"))
        }
    }

    public func listCloudFiles(pdirFid: String, cookie: String, page: Int = 1, size: Int = 50) async throws -> [DriveFile] {
        let url = UCConstants.cloudFileSortURL
            + "&pdir_fid=\(q(pdirFid))&_page=\(page)&_size=\(size)&_fetch_total=1&_fetch_sub_dirs=0"
            + "&_sort=file_type%3Aasc%2Cupdated_at%3Adesc"
        let headers = ["Cookie": cookie, "User-Agent": UCConstants.cloudUserAgent,
                       "Origin": UCConstants.webOrigin, "Referer": "\(UCConstants.webOrigin)/"]
        let data = try parseData(try await http.get(url, headers: headers), cookie: cookie)
        return data.objects("list").map { item in
            DriveFile(id: item.string("fid"), name: item.string("file_name").ifEmpty(item.string("fname")),
                      size: item.int64("size"), isDirectory: item.bool("dir"), parentId: item.string("pdir_fid"),
                      fileToken: "", modifiedAt: item.string("updated_at"))
        }
    }

    /// Pages through a whole directory. The server caps a page at 50 items.
    public func listAllCloudFiles(pdirFid: String, cookie: String, pageSize: Int = 50, maxPages: Int = 200) async throws -> [DriveFile] {
        let first = try await listCloudFiles(pdirFid: pdirFid, cookie: cookie, page: 1, size: pageSize)
        var merged = FileAccumulator()
        merged.add(first)
        var page = 2
        while first.count >= pageSize, page <= maxPages {
            let batch = try await listCloudFiles(pdirFid: pdirFid, cookie: cookie, page: page, size: pageSize)
            if batch.isEmpty || merged.add(batch) == 0 { break }
            page += 1
        }
        return merged.files
    }

    public func createFolder(name: String, parentFid: String, cookie: String) async throws -> String {
        let response = try await http.postJSON(UCConstants.fileURL, json: [
            "pdir_fid": parentFid,
            "file_name": name,
            "dir_path": "",
            "dir_init_lock": false,
        ], headers: ["Cookie": cookie])
        return try parseData(response, cookie: cookie).string("fid")
    }

    /// Starts a save and returns the async task id, or nil when the server returned none.
    public func saveShareFile(shareId: String, stoken: String, pdirFid: String, fid: String, fidToken: String, toPdirFid: String, cookie: String) async throws -> String? {
        let response = try await http.postJSON(UCConstants.saveURL, json: [
            "pwd_id": shareId,
            "stoken": stoken,
            "pdir_fid": pdirFid,
            "to_pdir_fid": toPdirFid,
            "fid_list": [fid],
            "fid_token_list": [fidToken],
            "scene": "link",
        ], headers: ["Cookie": cookie])
        return try parseData(response, cookie: cookie).string("task_id").nonBlank
    }

    /// Polls up to 10 times, 1 s apart. Returns the saved fid.
    public func pollTask(taskId: String, cookie: String) async throws -> String? {
        try await poll(taskId: taskId, cookie: cookie, attempts: 10) { data in
            let finished = data.int64("finished_at") > 0 || data.int("status") == 2 || data.int("task_status") == 2
            guard finished, let fids = data.child("save_as")?.array("save_as_top_fids"), let first = fids.first else { return nil }
            return (first as? String)?.nonBlank
        }
    }

    public func deleteFile(fid: String, cookie: String) async throws -> String? {
        let response = try await http.postJSON(UCConstants.deleteURL, json: [
            "action_type": 2,
            "filelist": [fid],
            "exclude_fids": [String](),
        ], headers: ["Cookie": cookie])
        return try parseData(response, cookie: cookie).string("task_id").nonBlank
    }

    public func renameFile(fid: String, newName: String, cookie: String) async -> Bool {
        guard let response = try? await http.postJSON(UCConstants.renameURL, json: ["fid": fid, "file_name": newName], headers: ["Cookie": cookie]),
              let json = LenientJSON(data: response.body) else { return false }
        return json.int("status") == 200
    }

    public func moveFile(fid: String, toPdirFid: String, cookie: String) async throws -> String? {
        let response = try await http.postJSON(UCConstants.moveURL, json: [
            "action_type": 1,
            "to_pdir_fid": toPdirFid,
            "filelist": [fid],
            "exclude_fids": [String](),
        ], headers: ["Cookie": cookie])
        return try parseData(response, cookie: cookie).string("task_id").nonBlank
    }

    /// `urlType`: 1 link only, 2 link and passcode. `expiredType`: 1 forever, 2 one day, 3 seven, 4 thirty.
    /// Creation is an async task; this polls it (15 times, 1 s apart) and returns the share id, or nil on timeout.
    public func createShare(fidList: [String], title: String, urlType: Int, passcode: String, expiredType: Int, cookie: String) async throws -> String? {
        var json: [String: Any] = [
            "fid_list": fidList,
            "title": title.ifBlank("分享文件"),
            "url_type": urlType,
            "expired_type": expiredType,
            "public_search": passcode.isBlankText ? 1 : 0,
        ]
        if !passcode.isBlankText { json["passcode"] = passcode }
        let response = try await http.postJSON(UCConstants.shareCreateURL, json: json, headers: ["Cookie": cookie])
        guard let taskId = try parseData(response, cookie: cookie).string("task_id").nonBlank else { return nil }
        return try await poll(taskId: taskId, cookie: cookie, attempts: 15) { data in
            guard data.int64("finished_at") > 0 || data.int("status") == 2 else { return nil }
            return data.string("share_id").nonBlank
        }
    }

    public func getShareInfo(shareId: String, cookie: String) async throws -> UCShareInfo {
        let response = try await http.postJSON(UCConstants.shareInfoURL, json: ["share_id": shareId], headers: ["Cookie": cookie])
        let data = try parseData(response, cookie: cookie)
        return UCShareInfo(shareURL: data.string("share_url"), passcode: data.string("passcode"), pwdId: data.string("pwd_id"),
                           title: data.string("title"), expiredType: data.int("expired_type"))
    }

    // MARK: Direct links

    /// Signed-in share link. No save is needed: the share fid, its token and the stoken are enough.
    public func getShareDownloadLink(fid: String, fidToken: String, stoken: String, pwdId: String, cookie: String) async throws -> UCDownloadLink {
        let response = try await http.postJSON(UCConstants.downloadURL, json: shareDownloadBody(fid, fidToken, stoken, pwdId), headers: ["Cookie": cookie])
        let json = try parsedDownloadBody(response)
        if json.int("status") != 200 {
            throw DriveError.api(message: json.string("message").ifBlank("获取下载链接失败"))
        }
        // The source reads the first item of data here and reports a missing one as "no link".
        guard let first = json.array("data")?.first as? [String: Any] else { throw DriveError.api(message: "未返回下载链接") }
        return Self.downloadLink(LenientJSON(first), guestCookie: "")
    }

    /// Guest path. The link must be downloaded with the `__pugs` from this same response.
    public func getGuestShareDownloadLink(fid: String, fidToken: String, stoken: String, pwdId: String) async throws -> UCDownloadLink {
        var headers = ["User-Agent": UCConstants.guestUserAgent, "Sec-Ch-Ua": UCConstants.guestSecChUA]
        if !guestPugs.isBlankText { headers["Cookie"] = guestPugs }
        let response = try await http.postJSON(UCConstants.downloadURL, json: shareDownloadBody(fid, fidToken, stoken, pwdId), headers: headers)
        let responsePugs = response.setCookies.lazy.map(UCCookieUtil.pairPart).first { $0.hasPrefix("__pugs=") && $0.count > "__pugs=".count }
        if let responsePugs { guestPugs = responsePugs }
        guard let json = LenientJSON(data: response.body) else {
            // A non-JSON body is usually a block page, so the HTTP status tells it apart from a dead share.
            throw DriveError.api(message: "响应解析失败（HTTP \(response.statusCode)）")
        }
        let code = json.int("code")
        if json.int("status") != 200, code != 0 {
            throw DriveError.api(message: Self.guestErrorMessage(code, json.string("message")), code: code)
        }
        let item = try firstDownloadItem(json)
        return Self.downloadLink(item, guestCookie: responsePugs ?? guestPugs)
    }

    /// Link for a file in the account (also what a file saved from a share is fetched with).
    public func getDownloadLink(fid: String, cookie: String) async throws -> UCDownloadLink {
        let response = try await http.postJSON(UCConstants.downloadURL, json: ["fids": [fid]], headers: ["Cookie": cookie])
        return try accountDownloadLink(response)
    }

    /// Cloud download channel with the uc-cloud-drive UA: the personal drive path, not the share channel.
    public func cloudGetDownloadLink(fid: String, cookie: String) async throws -> UCDownloadLink {
        let headers = ["Cookie": cookie, "User-Agent": UCConstants.cloudUserAgent,
                       "Origin": UCConstants.webOrigin, "Referer": "\(UCConstants.webOrigin)/"]
        let response = try await http.postJSON(UCConstants.cloudDownloadURL, json: ["fids": [fid]], headers: headers)
        return try accountDownloadLink(response)
    }

    /// Original-quality video link of a share (video_preview). Any failure returns nil.
    /// It plays through the playback callback, which avoids the promo clip non-members get on download.
    public func getVideoPreview(pwdId: String, stoken: String, fid: String, fidToken: String, cookie: String) async -> UCDownloadLink? {
        let url = "\(UCConstants.videoPreviewURL)?pr=UCBrowser&fr=h5&pwd_id=\(q(pwdId))&stoken=\(q(stoken))&fid=\(q(fid))&fid_token=\(q(fidToken))"
        let headers = ["Cookie": cookie, "Origin": UCConstants.webOrigin, "Referer": UCConstants.downloadReferer,
                       "Content-Type": "application/json"]
        guard let response = try? await http.get(url, headers: headers) else { return nil }
        let json = LenientJSON(data: response.body) ?? LenientJSON([:])
        if json.int("status") != 200, json.int("code") != 0 { return nil }
        guard let playInfo = json.child("data")?.child("play_info"), let direct = playInfo.string("url").nonBlank else { return nil }
        return UCDownloadLink(fid: fid, filename: "", downloadURL: direct, size: playInfo.int64("size"), guestCookie: "")
    }

    /// Transcoded play stream. Tries the pr/fr path first, then the bare path. Any failure returns nil.
    public func getPlayLink(fid: String, cookie: String) async -> UCPlayLink? {
        if let link = await playProject(UCConstants.playURL, fid: fid, cookie: cookie) { return link }
        return await playProject(UCConstants.barePlayURL, fid: fid, cookie: cookie)
    }

    private func playProject(_ url: String, fid: String, cookie: String) async -> UCPlayLink? {
        let body: [String: Any] = ["fid": fid, "resolutions": "low,normal,high,super,2k,4k", "supports": "fmp4_av,m3u8,dolby_vision"]
        let headers = ["Cookie": cookie, "Origin": UCConstants.webOrigin, "Referer": UCConstants.downloadReferer]
        guard let response = try? await http.postJSON(url, json: body, headers: headers) else { return nil }
        let json = LenientJSON(data: response.body) ?? LenientJSON([:])
        if json.int("status") != 200, json.int("code") != 0 { return nil }
        for entry in json.child("data")?.objects("video_list") ?? [] {
            guard let info = entry.child("video_info"), let link = info.string("url").nonBlank else { continue }
            let format = info.string("format")
            return UCPlayLink(url: link, resolution: info.string("resolution"), format: format,
                              isHLS: link.contains(".m3u8") || format.range(of: "m3u8", options: .caseInsensitive) != nil)
        }
        return nil
    }

    // MARK: Helpers

    private static func guestErrorMessage(_ code: Int, _ message: String) -> String {
        switch code {
        case 31001: return "该分享需要登录 UC 网盘后才能下载"
        case 23018: return "该文件超出游客可获取的大小上限，请先登录 UC 网盘再下载"
        case 14001: return "分享已失效或提取码有误，请重新解析"
        case 41020: return "文件令牌已过期，请重新解析分享"
        default: return message.ifBlank("获取下载链接失败")
        }
    }

    private func q(_ value: String) -> String { HTTPClient.encodeQueryValue(value) }

    private static func shareFile(_ item: LenientJSON) -> DriveFile {
        DriveFile(id: item.string("fid"), name: item.string("file_name"), size: item.int64("size"),
                  isDirectory: item.bool("dir"), parentId: item.string("pdir_fid"),
                  fileToken: item.string("share_fid_token"), modifiedAt: item.string("updated_at"))
    }

    private func shareDownloadBody(_ fid: String, _ fidToken: String, _ stoken: String, _ pwdId: String) -> [String: Any] {
        ["fids": [fid], "pwd_id": pwdId, "stoken": stoken, "fids_token": [fidToken]]
    }

    private static func downloadLink(_ item: LenientJSON, guestCookie: String) -> UCDownloadLink {
        UCDownloadLink(fid: item.string("fid"), filename: item.string("file_name").ifEmpty(item.string("filename")),
                       downloadURL: item.string("download_url"), size: item.int64("size"), guestCookie: guestCookie)
    }

    private func parsedDownloadBody(_ response: HTTPResponse) throws -> LenientJSON {
        guard !response.body.isEmpty else { throw DriveError.api(message: "获取下载链接失败：响应为空") }
        guard let json = LenientJSON(data: response.body) else { throw DriveError.api(message: "响应解析失败") }
        return json
    }

    private func firstDownloadItem(_ json: LenientJSON) throws -> LenientJSON {
        guard let array = json.array("data") else { throw DriveError.api(message: "响应缺少 data") }
        guard let first = array.first as? [String: Any] else { throw DriveError.api(message: "未返回下载链接") }
        return LenientJSON(first)
    }

    private func accountDownloadLink(_ response: HTTPResponse) throws -> UCDownloadLink {
        let json = try parsedDownloadBody(response)
        if json.int("status") != 200, json.int("code") != 0 {
            throw DriveError.api(message: json.string("message").ifBlank("获取下载链接失败"), code: json.int("code"))
        }
        return Self.downloadLink(try firstDownloadItem(json), guestCookie: "")
    }

    private func poll(taskId: String, cookie: String, attempts: Int, result: (LenientJSON) -> String?) async throws -> String? {
        let url = "\(UCConstants.taskURL)&task_id=\(q(taskId))&retry_index=0"
        for _ in 0..<attempts {
            // A failed attempt counts as not finished, as in the source.
            if let response = try? await http.get(url, headers: ["Cookie": cookie]),
               let json = LenientJSON(data: response.body), json.int("status") == 200,
               let data = json.child("data"), let value = result(data) {
                return value
            }
            try await sleep(1_000_000_000)
        }
        return nil
    }

    private func parseData(_ response: HTTPResponse, cookie: String) throws -> LenientJSON {
        mergeCookie(original: cookie, response: response)
        guard !response.body.isEmpty else { throw DriveError.api(message: "请求失败：响应为空") }
        // A non-JSON body is usually a block page, so the HTTP status tells it apart from a dead share.
        guard let json = LenientJSON(data: response.body) else {
            throw DriveError.api(message: "响应解析失败（HTTP \(response.statusCode)）")
        }
        if json.int("status") != 200 { throw DriveError.api(message: json.string("message").ifBlank("请求失败")) }
        guard let data = json.child("data") else { throw DriveError.api(message: "响应缺少 data") }
        return data
    }

    /// Folds a rotated __puus/__pus back into the cookie and reports it, like the source's cookieSink.
    @discardableResult
    private func mergeCookie(original: String, response: HTTPResponse) -> String {
        guard !response.setCookies.isEmpty, !original.isBlankText else { return original }
        let merged = UCCookieUtil.merge(original, setCookies: response.setCookies)
        if merged != original { credentialUpdated?(DriveCredential(merged), DriveCredential(original)) }
        return merged
    }
}
