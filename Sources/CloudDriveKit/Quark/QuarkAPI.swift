// Ported from YunX-Desktop (MIT): data/network/QuarkApi.kt.
// Endpoints, parameters and error handling follow that file. Failed lookups that returned null there return nil here.
import Foundation

public struct QuarkShareToken: Sendable, Equatable {
    public let stoken: String
    public let title: String
    public let firstFid: String
}

public struct QuarkShareInfo: Sendable, Equatable {
    public let shareURL: String
    public let passcode: String
    public let pwdId: String
    public let title: String
    public let expiredType: Int
}

public struct QuarkDownloadLink: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let fid: String
    public let filename: String
    public let downloadURL: String
    public let size: Int64
    /// `__pugs=...` for guest links, else empty.
    public let guestCookie: String
    /// The account cookie with this response's rotation applied; the link is bound to it.
    public let cookie: String
    public var description: String { "QuarkDownloadLink(\(fid), \(filename), <redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: ["fid": fid, "filename": filename, "size": size]) }
}

public typealias DriveSleeper = @Sendable (_ nanoseconds: UInt64) async throws -> Void

public actor QuarkAPI {
    private let http: HTTPClient
    private let sleep: DriveSleeper
    private let credentialUpdated: CredentialUpdateHandler?

    /// Guest token from Set-Cookie, about 3 hours. The CDN answers 412 without it.
    public private(set) var guestPugs = ""

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        credentialUpdated: CredentialUpdateHandler? = nil,
        sleep: @escaping DriveSleeper = { try await Task.sleep(nanoseconds: $0) }
    ) {
        http = HTTPClient(transport: transport, defaultHeaders: ["User-Agent": QuarkConstants.apiUserAgent])
        self.sleep = sleep
        self.credentialUpdated = credentialUpdated
    }

    // MARK: Account

    public func fetchNickname(cookie: String) async -> String? {
        guard let response = try? await http.get(QuarkConstants.accountInfoURL, headers: ["Cookie": cookie]),
              (200..<300).contains(response.statusCode),
              let json = LenientJSON(data: response.body),
              json.bool("success") else { return nil }
        return json.child("data")?.string("nickname").nonBlank
    }

    public func getQuota(cookie: String) async -> DriveQuota? {
        guard let response = try? await http.get(QuarkConstants.quotaURL, headers: ["Cookie": cookie]),
              let data = LenientJSON(data: response.body)?.child("data") else { return nil }
        return DriveQuota(used: data.int64("use_capacity"), total: data.int64("total_capacity"))
    }

    /// Requests /config without __puus so the server issues a new one. Returns nil on failure.
    public func refreshSession(cookie: String) async -> String? {
        let headers = ["Cookie": QuarkCookieUtil.withoutPuus(cookie), "Referer": QuarkConstants.downloadReferer]
        guard let response = try? await http.get(QuarkConstants.configURL, headers: headers) else { return nil }
        return mergeCookie(original: cookie, response: response)
    }

    // MARK: Shares

    public func getShareToken(shareId: String, passcode: String?, cookie: String) async throws -> QuarkShareToken {
        let response = try await http.postJSON(QuarkConstants.shareTokenURL, json: [
            "pwd_id": shareId,
            "passcode": passcode ?? "",
            "support_visit_limit_private_share": true,
        ], headers: ["Cookie": cookie])
        let data = try parseData(response, cookie: cookie)
        return QuarkShareToken(stoken: data.string("stoken"), title: data.string("title"), firstFid: data.string("first_fid"))
    }

    public func getShareFiles(shareId: String, stoken: String, pdirFid: String, cookie: String, page: Int = 1, size: Int = 100) async throws -> [DriveFile] {
        let url = QuarkConstants.shareDetailURL
            + "&pwd_id=\(q(shareId))&stoken=\(q(stoken))&pdir_fid=\(q(pdirFid))"
            + "&ver=2&force=0&_page=\(page)&_size=\(size)&_fetch_banner=0&_fetch_share=0"
            + "&fetch_relate_conversation=0&_fetch_total=1&_sort=file_type:asc,file_name:asc"
        // Origin and Referer are required here; without them the server can answer 400.
        let data = try parseData(try await http.get(url, headers: webHeaders(cookie)), cookie: cookie)
        return data.objects("list").map { item in
            DriveFile(id: item.string("fid"), name: item.string("file_name"), size: item.int64("size"),
                      isDirectory: item.bool("dir"), parentId: item.string("pdir_fid"),
                      fileToken: item.string("share_fid_token"), modifiedAt: item.string("updated_at"))
        }
    }

    // MARK: Own files

    public func getFileList(pdirFid: String, cookie: String, page: Int = 1, size: Int = 100) async throws -> [DriveFile] {
        let url = "\(QuarkConstants.fileURL)&pdir_fid=\(q(pdirFid))&page=\(page)&size=\(size)"
        let data = try parseData(try await http.get(url, headers: ["Cookie": cookie]), cookie: cookie)
        return data.objects("list").map { item in
            DriveFile(id: item.string("fid"), name: item.string("file_name").ifEmpty(item.string("fname")),
                      size: item.has("size") ? item.int64("size") : item.int64("fsize"),
                      isDirectory: item.bool("dir") || item.int("isdir") == 1, parentId: item.string("pdir_fid"),
                      fileToken: item.string("fid_token"), modifiedAt: item.string("modify_time"))
        }
    }

    public func listCloudFiles(pdirFid: String, cookie: String, page: Int = 1, size: Int = 50) async throws -> [DriveFile] {
        let url = QuarkConstants.cloudFileSortURL
            + "&uc_param_str=&pdir_fid=\(q(pdirFid))&_page=\(page)&_size=\(size)"
            + "&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type:asc,updated_at:desc"
            + "&fetch_all_file=1&fetch_risk_file_name=1"
        let data = try parseData(try await http.get(url, headers: webHeaders(cookie)), cookie: cookie)
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
        let response = try await http.postJSON(QuarkConstants.fileURL, json: [
            "pdir_fid": parentFid,
            "file_name": name,
            "dir_path": "",
            "dir_init_lock": false,
        ], headers: ["Cookie": cookie])
        return try parseData(response, cookie: cookie).string("fid")
    }

    /// Starts a save and returns the async task id, or nil when the server returned none.
    public func saveShareFile(shareId: String, stoken: String, pdirFid: String, fid: String, fidToken: String, toPdirFid: String, cookie: String) async throws -> String? {
        let response = try await http.postJSON(QuarkConstants.saveURL, json: [
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

    /// Polls up to 10 times, 1 s apart. Returns the saved fid; only that fid can be downloaded.
    public func pollTask(taskId: String, cookie: String) async throws -> String? {
        try await poll(taskId: taskId, cookie: cookie, attempts: 10) { data in
            let finished = data.int64("finished_at") > 0 || data.int("status") == 2 || data.int("task_status") == 2
            guard finished, let fids = data.child("save_as")?.array("save_as_top_fids"), let first = fids.first else { return nil }
            return (first as? String)?.nonBlank
        }
    }

    public func deleteFile(fid: String, cookie: String) async throws -> String? {
        let response = try await http.postJSON(QuarkConstants.deleteURL, json: [
            "action_type": 2,
            "filelist": [fid],
            "exclude_fids": [String](),
        ], headers: ["Cookie": cookie])
        return try parseData(response, cookie: cookie).string("task_id").nonBlank
    }

    public func renameFile(fid: String, newName: String, cookie: String) async -> Bool {
        guard let response = try? await http.postJSON(QuarkConstants.renameURL, json: ["fid": fid, "file_name": newName], headers: ["Cookie": cookie]),
              let json = LenientJSON(data: response.body) else { return false }
        return json.int("status") == 200
    }

    public func moveFile(fid: String, toPdirFid: String, cookie: String) async throws -> String? {
        let response = try await http.postJSON(QuarkConstants.moveURL, json: [
            "action_type": 1,
            "to_pdir_fid": toPdirFid,
            "filelist": [fid],
            "exclude_fids": [String](),
        ], headers: ["Cookie": cookie])
        return try parseData(response, cookie: cookie).string("task_id").nonBlank
    }

    /// `urlType`: 1 link only, 2 link and passcode. `expiredType`: 1 forever, 2 one day, 3 seven, 4 thirty.
    public func createShare(fidList: [String], title: String, urlType: Int, passcode: String, expiredType: Int, cookie: String) async throws -> String? {
        var json: [String: Any] = [
            "fid_list": fidList,
            "title": title.ifBlank("分享文件"),
            "url_type": urlType,
            "expired_type": expiredType,
            "support_error_code": ["41060"],
        ]
        if !passcode.isBlankText { json["passcode"] = passcode }
        let response = try await http.postJSON(QuarkConstants.shareCreateURL, json: json, headers: ["Cookie": cookie])
        guard let taskId = try parseData(response, cookie: cookie).string("task_id").nonBlank else { return nil }
        return try await poll(taskId: taskId, cookie: cookie, attempts: 15) { data in
            guard data.int64("finished_at") > 0 || data.int("status") == 2 else { return nil }
            return data.string("share_id").nonBlank
        }
    }

    public func getShareInfo(shareId: String, cookie: String) async throws -> QuarkShareInfo {
        let response = try await http.postJSON(QuarkConstants.shareInfoURL, json: ["share_id": shareId], headers: ["Cookie": cookie])
        let data = try parseData(response, cookie: cookie)
        return QuarkShareInfo(shareURL: data.string("share_url"), passcode: data.string("passcode"), pwdId: data.string("pwd_id"),
                              title: data.string("title"), expiredType: data.int("expired_type"))
    }

    // MARK: Direct links

    public func getDownloadLink(fid: String, cookie: String) async throws -> QuarkDownloadLink {
        let response = try await http.postJSON(QuarkConstants.downloadURL, json: ["fids": [fid]], headers: ["Cookie": cookie])
        let merged = mergeCookie(original: cookie, response: response)
        guard let json = LenientJSON(data: response.body) else { throw DriveError.api(message: "响应解析失败") }
        if json.int("status") != 200, json.int("code") != 0 {
            throw DriveError.api(message: json.string("message").ifBlank("获取下载链接失败"), code: json.int("code"))
        }
        return try downloadLink(from: json, guestCookie: "", cookie: merged)
    }

    /// Guest path, about 50 MB at most. The link must be downloaded with the `__pugs` from this response.
    public func getGuestShareDownloadLink(fid: String, fidToken: String, shareId: String, stoken: String) async throws -> QuarkDownloadLink {
        var headers: [String: String] = [:]
        if !guestPugs.isBlankText { headers["Cookie"] = guestPugs }
        let response = try await http.postJSON(QuarkConstants.downloadURL, json: shareDownloadBody(fid, fidToken, shareId, stoken), headers: headers)
        let responsePugs = response.setCookies.lazy.map(QuarkCookieUtil.pairPart).first { $0.hasPrefix("__pugs=") && $0.count > "__pugs=".count }
        if let responsePugs { guestPugs = responsePugs }
        let json = try parsedOrHTTPError(response)
        let code = json.int("code")
        if json.int("status") != 200, code != 0 {
            throw DriveError.api(message: Self.guestErrorMessage(code, json.string("message")), code: code)
        }
        return try downloadLink(from: json, guestCookie: responsePugs ?? guestPugs, cookie: "")
    }

    /// Signed-in share link that skips saving. Some share types refuse it and need the save path.
    public func getShareDownloadLinkWithoutSave(fid: String, fidToken: String, shareId: String, stoken: String, cookie: String) async throws -> QuarkDownloadLink {
        let response = try await http.postJSON(QuarkConstants.downloadURL, json: shareDownloadBody(fid, fidToken, shareId, stoken), headers: ["Cookie": cookie])
        let merged = mergeCookie(original: cookie, response: response)
        let json = try parsedOrHTTPError(response)
        let code = json.int("code")
        if json.int("status") != 200, code != 0 {
            throw DriveError.api(message: Self.noSaveErrorMessage(code, json.string("message")), code: code)
        }
        return try downloadLink(from: json, guestCookie: "", cookie: merged)
    }

    private static func noSaveErrorMessage(_ code: Int, _ message: String) -> String {
        switch code {
        case 31001: return "夸克登录态已失效，请到「网盘」页重新登录后再试"
        case 23018: return "服务端按游客限制拒绝了该文件（夸克约 50MB 上限）"
        default: return message.ifBlank("获取下载链接失败")
        }
    }

    private static func guestErrorMessage(_ code: Int, _ message: String) -> String {
        switch code {
        case 23018: return "该文件超出游客可获取的大小上限（夸克实测约 50MB），请先登录夸克网盘再下载"
        case 31001: return "该分享需要登录夸克网盘后才能下载"
        default: return message.ifBlank("获取下载链接失败")
        }
    }

    // MARK: Helpers

    private func q(_ value: String) -> String { HTTPClient.encodeQueryValue(value) }

    private func webHeaders(_ cookie: String) -> [String: String] {
        ["Cookie": cookie, "Origin": "https://pan.quark.cn", "Referer": "https://pan.quark.cn/"]
    }

    private func shareDownloadBody(_ fid: String, _ fidToken: String, _ shareId: String, _ stoken: String) -> [String: Any] {
        ["fids": [fid], "fids_token": [fidToken], "pwd_id": shareId, "stoken": stoken, "speedup_session": "", "token": ""]
    }

    private func poll(taskId: String, cookie: String, attempts: Int, result: (LenientJSON) -> String?) async throws -> String? {
        let url = "\(QuarkConstants.taskURL)&task_id=\(q(taskId))&retry_index=0"
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

    private func parsedOrHTTPError(_ response: HTTPResponse) throws -> LenientJSON {
        // A non-JSON body is usually a block page, so the HTTP status tells it apart from a dead share.
        guard let json = LenientJSON(data: response.body) else {
            throw DriveError.api(message: "响应解析失败（HTTP \(response.statusCode)）")
        }
        return json
    }

    private func parseData(_ response: HTTPResponse, cookie: String) throws -> LenientJSON {
        _ = mergeCookie(original: cookie, response: response)
        let json = try parsedOrHTTPError(response)
        if json.int("status") != 200 { throw DriveError.api(message: json.string("message").ifBlank("请求失败")) }
        guard let data = json.child("data") else { throw DriveError.api(message: "响应缺少 data") }
        return data
    }

    private func downloadLink(from json: LenientJSON, guestCookie: String, cookie: String) throws -> QuarkDownloadLink {
        guard let array = json.array("data") else { throw DriveError.api(message: "响应缺少 data") }
        guard let first = array.first as? [String: Any] else { throw DriveError.api(message: "未返回下载链接") }
        let item = LenientJSON(first)
        return QuarkDownloadLink(fid: item.string("fid"), filename: item.string("file_name").ifEmpty(item.string("filename")),
                                 downloadURL: item.string("download_url"), size: item.int64("size"),
                                 guestCookie: guestCookie, cookie: cookie)
    }

    @discardableResult
    private func mergeCookie(original: String, response: HTTPResponse) -> String {
        guard !response.setCookies.isEmpty, !original.isBlankText else { return original }
        let merged = QuarkCookieUtil.merge(original, setCookies: response.setCookies)
        if merged != original { credentialUpdated?(DriveCredential(merged), DriveCredential(original)) }
        return merged
    }
}

/// Dedupes by id so a server that ignores the page number cannot grow the list or loop forever.
struct FileAccumulator {
    private var seen = Set<String>()
    private(set) var files: [DriveFile] = []

    @discardableResult
    mutating func add(_ batch: [DriveFile]) -> Int {
        var added = 0
        for file in batch where seen.insert(file.id.ifBlank("\(file.parentId)/\(file.name)")).inserted {
            files.append(file)
            added += 1
        }
        return added
    }
}
