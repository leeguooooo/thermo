// Ported from YunX-Desktop (AGPL-3.0): data/network/Pan115Api.kt.
// Endpoints, parameters, signing (Pan115Crypto) and error handling follow that file.
// Lookups that were `runCatching { ... }.getOrNull()` there return nil here.
import Foundation

public struct Pan115FilePage: Sendable, Equatable {
    public let files: [DriveFile]
    public let total: Int
}

/// A share directory. `userId` is the sharer's, which links require.
public struct Pan115SharePage: Sendable, Equatable {
    public let files: [DriveFile]
    public let total: Int
    public let userId: String
    public let title: String
    public let shareState: Int
}

public struct Pan115DownloadLink: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let fid: String
    public let filename: String
    public let downloadURL: String
    public let size: Int64
    /// The path-bound CDN cookie from the response headers. The CDN answers 403 without it.
    public let guestCookie: String
    public var description: String { "Pan115DownloadLink(\(fid), \(filename), <redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: ["fid": fid, "filename": filename, "size": size]) }
}

public struct Pan115ShareInfo: Sendable, Equatable {
    public let shareURL: String
    public let passcode: String
    public let shareCode: String
    public let title: String
    /// A `Pan115ShareExpire` code.
    public let expiredType: Int
    /// Set when the share exists but the validity change failed.
    public let warning: String?
}

public actor Pan115API {
    private let transport: any HTTPTransport
    private let cipher: any Pan115Cipher
    private let sleep: DriveSleeper
    private let now: @Sendable () -> Date

    private var protocolAllowed = false
    private var clientVersionFetched = false
    /// Refreshed by `refreshClientVersion`; link requests and the download itself both use it.
    public private(set) var clientUserAgent = Pan115Constants.clientUserAgent(version: Pan115Constants.clientUAVersionFallback)

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        sleep: @escaping DriveSleeper = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.transport = transport
        self.cipher = Pan115Crypto()
        self.sleep = sleep
        self.now = { Date() }
    }

    init(transport: any HTTPTransport, cipher: any Pan115Cipher, now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping DriveSleeper = { try await Task.sleep(nanoseconds: $0) }) {
        self.transport = transport
        self.cipher = cipher
        self.sleep = sleep
        self.now = now
    }

    // MARK: Client version

    /// Fetches the current client version once per API object. Failure keeps the fallback.
    public func refreshClientVersion() async {
        if clientVersionFetched { return }
        clientVersionFetched = true
        guard let (json, _) = try? await execute(request(Pan115Constants.appVersionURL, cookie: "", referer: Pan115Constants.referer)),
              let version = json.child("data")?.child("win")?.string("version_code") else { return }
        let value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Pan115Constants.isPlausibleClientVersion(value) else { return }
        if clientUserAgent.hasSuffix("/\(value)") { return }
        clientUserAgent = Pan115Constants.clientUserAgent(version: value)
    }

    // MARK: Account

    /// `GET /user/info?ct=json`. Signed in, `data` is a masked phone number. nil when the login is invalid.
    public func fetchNickname(cookie: String) async -> String? {
        guard let json = try? await getJSON(Pan115Constants.userInfoURL, cookie: cookie, referer: Pan115Constants.referer),
              (try? checkState(json, fallback: "获取用户信息失败")) != nil else { return nil }
        return json.string("data").nonBlank
    }

    public func getQuota(cookie: String) async -> DriveQuota? {
        guard let json = try? await getJSON(Pan115Constants.indexInfoURL, cookie: cookie, referer: Pan115Constants.referer),
              (try? checkState(json, fallback: "获取空间信息失败")) != nil,
              let space = json.child("data")?.child("space_info") else { return nil }
        return DriveQuota(used: space.child("all_use")?.int64("size") ?? 0, total: space.child("all_total")?.int64("size") ?? 0)
    }

    // MARK: Own files

    /// `GET /files`. Offset paging; a folder has no `fid` (its id is `cid`), a file's `cid` is its parent.
    public func listFiles(cid: String, cookie: String, offset: Int = 0, limit: Int = Pan115Constants.pageLimit) async throws -> Pan115FilePage {
        let url = Pan115Constants.filesURL
            + "?aid=\(Pan115Constants.personalAid)&cid=\(q(cid.ifBlank(Pan115Constants.rootDirectoryId)))"
            + "&o=user_ptime&asc=0&offset=\(offset)&show_dir=1&limit=\(limit)"
            + "&snap=0&natsort=1&record_open_time=1&count_folders=1&format=json"
        let json = try await getJSON(url, cookie: cookie, referer: Pan115Constants.referer)
        try checkState(json, fallback: "获取文件列表失败")
        return Pan115FilePage(files: parsePersonalFiles(json), total: json.int("count"))
    }

    /// Personal file link. The desktop endpoint goes first because the web one refuses big files (50028);
    /// if it fails the web endpoint is the fallback and still serves small files.
    public func getDownloadLink(file: DriveFile, cookie: String) async throws -> Pan115DownloadLink? {
        let pickCode = file.fileToken
        if pickCode.isBlankText { throw DriveError.api(message: "缺少 pickcode，无法获取下载链接") }
        await refreshClientVersion()
        do {
            if let link = try await getAppDownloadLink(pickCode: pickCode, cookie: cookie) {
                return Pan115DownloadLink(fid: file.id, filename: link.filename.ifBlank(file.name), downloadURL: link.downloadURL,
                                          size: link.size > 0 ? link.size : file.size, guestCookie: link.guestCookie)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Fall back to the web endpoint.
        }
        return try await getWebDownloadLink(pickCode: pickCode, file: file, cookie: cookie)
    }

    /// `GET /files/download?pickcode=`. The CDN cookie comes in the response headers.
    private func getWebDownloadLink(pickCode: String, file: DriveFile, cookie: String) async throws -> Pan115DownloadLink? {
        await refreshClientVersion()
        let url = "\(Pan115Constants.fileDownloadURL)?pickcode=\(q(pickCode))"
        let (json, cdnCookie) = try await execute(request(url, cookie: cookie, referer: Pan115Constants.downloadReferer, userAgent: clientUserAgent))
        try checkState(json, fallback: "获取下载链接失败")
        guard let data = json.child("data"), let fileURL = data.string("file_url").nonBlank else { return nil }
        return Pan115DownloadLink(fid: file.id, filename: data.string("file_name").ifBlank(file.name), downloadURL: fileURL,
                                  size: Int64(data.string("file_size")) ?? file.size, guestCookie: cdnCookie ?? "")
    }

    /// `POST https://proapi.115.com/app/chrome/downurl?t=<unix seconds>` with `data=<encrypted {"pickcode":..}>`.
    /// The response `data` is JSON encrypted with the same key: file_id -> {file_name, file_size, url.url}.
    public func getAppDownloadLink(pickCode: String, cookie: String) async throws -> Pan115DownloadLink? {
        if pickCode.isBlankText { return nil }
        let key = cipher.newKey()
        let payload = try Self.jsonText(["pickcode": pickCode])
        let url = "\(Pan115Constants.appDownloadURL)?t=\(Int(now().timeIntervalSince1970))"
        let body = form([("data", try cipher.encode(payload, key: key))])
        let (json, cdnCookie) = try await execute(request(url, cookie: cookie, referer: Pan115Constants.downloadReferer,
                                                           body: body, userAgent: clientUserAgent))
        try checkState(json, fallback: "获取下载链接失败")
        guard let encrypted = json.string("data").nonBlank else { return nil }
        guard let decoded = LenientJSON(data: Data(try cipher.decode(encrypted, key: key).utf8)) else {
            throw DriveError.api(message: "115 下载响应无法解析")
        }
        // Dictionary order is random; sort so the same response always picks the same entry.
        let info = decoded.object.keys.sorted().compactMap { decoded.child($0) }.first { $0.child("url") != nil }
        guard let info, let fileURL = info.child("url")?.string("url").nonBlank else { return nil }
        return Pan115DownloadLink(fid: info.string("pick_code").ifBlank(pickCode), filename: info.string("file_name"), downloadURL: fileURL,
                                  size: Int64(info.string("file_size")) ?? (info.has("file_size") ? info.int64("file_size") : -1),
                                  guestCookie: cdnCookie ?? "")
    }

    /// `POST /files/add` -> `data.cid`.
    public func createDirectory(parentId: String, name: String, cookie: String) async throws -> String? {
        let json = try await postForm(Pan115Constants.fileAddURL, cookie: cookie, referer: Pan115Constants.referer,
                                      [("pid", parentId.ifBlank(Pan115Constants.rootDirectoryId)), ("cname", name)])
        try checkState(json, fallback: "新建文件夹失败")
        // The id may sit at either level.
        return (json.string("cid").nonBlank ?? json.child("data")?.string("cid").nonBlank)
    }

    /// `POST /files/batch_rename`.
    public func rename(id: String, newName: String, cookie: String) async throws {
        let json = try await postForm(Pan115Constants.fileRenameURL, cookie: cookie, referer: Pan115Constants.referer,
                                      [("fid", id), ("file_name", newName), ("files_new_name[\(id)]", newName)])
        try checkState(json, fallback: "重命名失败")
    }

    /// `POST /files/move`. Asynchronous: when the response has `move_proid` the progress is polled.
    public func move(ids: [String], toParentId: String, cookie: String) async throws {
        let ids = ids.filter { !$0.isBlankText }
        if ids.isEmpty { throw DriveError.api(message: "请选择要移动的文件") }
        var pairs = [("pid", toParentId.ifBlank(Pan115Constants.rootDirectoryId))]
        for (index, id) in ids.enumerated() { pairs.append(("fid[\(index)]", id)) }
        let json = try await postForm(Pan115Constants.fileMoveURL, cookie: cookie, referer: Pan115Constants.referer, pairs)
        try checkState(json, fallback: "移动失败")
        // Field levels are unstable at 115, so both are read.
        guard let moveId = json.string("move_proid").nonBlank ?? json.child("data")?.string("move_proid").nonBlank else { return }
        for _ in 0..<Pan115Constants.movePollMax {
            try await sleep(Pan115Constants.movePollIntervalNanoseconds)
            let url = "\(Pan115Constants.moveProgressURL)?move_proid=\(q(moveId))"
            guard let progress = try? await getJSON(url, cookie: cookie, referer: Pan115Constants.referer),
                  progress.bool("state"), let data = progress.child("data") else { return }
            if Self.double(data, "percent") >= 100 || data.int("count") <= 0 { return }
        }
    }

    /// `POST /rb/delete` (to the recycle bin). On errno 800007 the same request is sent once more to confirm.
    public func delete(ids: [String], parentId: String, cookie: String) async throws {
        let ids = ids.filter { !$0.isBlankText }
        if ids.isEmpty { throw DriveError.api(message: "请选择要删除的文件") }
        var pairs = [("pid", parentId.ifBlank(Pan115Constants.rootDirectoryId))]
        for (index, id) in ids.enumerated() { pairs.append(("fid[\(index)]", id)) }
        pairs.append(("ignore_warn", "1"))
        var json = try await postForm(Pan115Constants.fileDeleteURL, cookie: cookie, referer: Pan115Constants.referer, pairs)
        if errno(of: json) == Pan115Constants.errnoNeedConfirm {
            json = try await postForm(Pan115Constants.fileDeleteURL, cookie: cookie, referer: Pan115Constants.referer, pairs)
        }
        try checkState(json, fallback: "删除失败")
    }

    // MARK: Shares

    /// `GET /share/snap` (`cid=0` is the share root). Also returns the sharer's `user_id` and the title.
    public func getSharePage(shareCode: String, receiveCode: String, cid: String, cookie: String, offset: Int = 0,
                             limit: Int = Pan115Constants.sharePageLimit) async throws -> Pan115SharePage {
        let url = Pan115Constants.shareSnapURL
            + "?share_code=\(q(shareCode))&receive_code=\(q(receiveCode))&offset=\(offset)&limit=\(limit)"
            + "&asc=0&cid=\(q(cid.ifBlank(Pan115Constants.rootDirectoryId)))&format=json"
        let json = try await getJSON(url, cookie: cookie, referer: Pan115Constants.shareReferer(shareCode: shareCode, receiveCode: receiveCode))
        try checkState(json, fallback: "获取分享列表失败")
        guard let data = json.child("data") else {
            return Pan115SharePage(files: [], total: 0, userId: "", title: "", shareState: 0)
        }
        let info = data.child("shareinfo")
        return Pan115SharePage(files: parseShareFiles(data), total: data.int("count"),
                               userId: data.child("userinfo")?.string("user_id") ?? "",
                               title: info?.string("share_title") ?? "",
                               shareState: data.has("share_state") ? data.int("share_state") : (info?.int("share_state") ?? 0))
    }

    /// `GET /share/downurl`; `userId` must be the sharer's. The client UA is required: a browser UA is
    /// judged "version too old" (50029). The response also sets a 900 second CDN cookie.
    public func getShareDownloadLink(shareCode: String, receiveCode: String, userId: String, file: DriveFile, cookie: String) async throws -> Pan115DownloadLink? {
        if userId.isBlankText { throw DriveError.api(message: "缺少分享者标识，请重新解析分享链接") }
        await refreshClientVersion()
        var url = "\(Pan115Constants.shareDownloadURL)?dl=1&user_id=\(q(userId))&share_code=\(q(shareCode))&file_id=\(q(file.id))"
        if !receiveCode.isBlankText { url += "&receive_code=\(q(receiveCode))" }
        let (json, cdnCookie) = try await execute(request(url, cookie: cookie,
                                                           referer: Pan115Constants.shareReferer(shareCode: shareCode, receiveCode: receiveCode),
                                                           userAgent: clientUserAgent))
        try checkState(json, fallback: "获取下载链接失败")
        guard let data = json.child("data") else { return nil }
        // The web page reads file_url_302 || url.url; all three shapes are accepted.
        guard let fileURL = data.string("file_url_302").nonBlank ?? data.string("file_url").nonBlank
            ?? data.child("url")?.string("url").nonBlank else { return nil }
        return Pan115DownloadLink(fid: file.id, filename: data.string("fn").ifBlank(file.name), downloadURL: fileURL,
                                  size: Int64(data.string("fs")) ?? file.size, guestCookie: cdnCookie ?? "")
    }

    /// `POST /share/receive`. Does not return the new file id.
    public func receiveShare(shareCode: String, receiveCode: String, fileId: String, toCid: String, cookie: String) async throws {
        let json = try await postForm(Pan115Constants.shareReceiveURL, cookie: cookie, referer: Pan115Constants.referer,
                                      [("share_code", shareCode), ("receive_code", receiveCode), ("file_id", fileId),
                                       ("cid", toCid.ifBlank(Pan115Constants.rootDirectoryId))])
        try checkState(json, fallback: "转存失败")
    }

    /// Creates a share, then sets its validity: the create call has no such field, so without
    /// `share/updateshare` even "forever" would land on the 15 day default.
    /// `duration`: `-1` (forever) or 1 / 3 / 5 / 7 / 15 days.
    public func createShare(fileIds: [String], duration: String, cookie: String) async throws -> Pan115ShareInfo {
        guard let userId = Pan115Constants.extractUserId(cookie) else {
            throw DriveError.api(message: "登录态缺少用户标识，请重新登录115网盘")
        }
        let ids = fileIds.filter { !$0.isBlankText }
        if ids.isEmpty { throw DriveError.api(message: "请选择要分享的文件") }
        await allowProtocol(cookie: cookie)
        let idText = ids.joined(separator: ",")
        // A dry run (ignore_warn=0) for statistics and hints; its failure does not stop the real create.
        _ = try? await postForm(Pan115Constants.shareSendURL, cookie: cookie, referer: Pan115Constants.referer,
                                [("user_id", userId), ("file_ids", idText), ("ignore_warn", "0")])
        let json = try await postForm(Pan115Constants.shareSendURL, cookie: cookie, referer: Pan115Constants.referer,
                                      [("user_id", userId), ("file_ids", idText), ("ignore_warn", "1")])
        try checkState(json, fallback: "创建分享失败")
        // The share info is in `data`; the top level has only state/error/errno. Both levels are read.
        let data = json.child("data")
        func field(_ name: String) -> String { data?.string(name).nonBlank ?? json.string(name) }
        let shareCode = field("share_code")
        if shareCode.isBlankText { throw DriveError.api(message: "创建分享失败：响应缺少分享编号") }
        // A failed validity change must not lose the created share: report the server default plus a warning.
        var updateJSON: LenientJSON?
        var updateError: (any Error)?
        do {
            updateJSON = try await postForm(Pan115Constants.shareUpdateURL, cookie: cookie, referer: Pan115Constants.referer,
                                            [("share_code", shareCode), ("share_duration", duration)])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            updateError = error
        }
        let applied = updateJSON?.bool("state") ?? false
        let expiredType = applied ? Pan115ShareExpire.code(duration: duration) : Pan115ShareExpire.code(text: field("share_ex_duration"))
        var warning: String?
        if !applied {
            let reason = updateJSON.flatMap { $0.string("error").nonBlank ?? $0.string("msg").nonBlank }
                ?? (updateError as? LocalizedError)?.errorDescription ?? "未知原因"
            warning = "分享已创建，但有效期设置未生效（当时按服务端默认档位）：\(reason)"
        }
        return Pan115ShareInfo(shareURL: field("share_url").ifBlank("\(Pan115Constants.shareHost)/s/\(shareCode)"),
                               passcode: field("receive_code").ifBlank(field("sys_receive_code")),
                               shareCode: shareCode, title: field("share_title"), expiredType: expiredType, warning: warning)
    }

    // MARK: Internals

    /// Confirms the public share agreement once. Failure is ignored; the real create is judged by the server.
    private func allowProtocol(cookie: String) async {
        if protocolAllowed { return }
        _ = try? await postForm(Pan115Constants.allowProtocolURL, cookie: cookie, referer: Pan115Constants.referer, [("action", "pubshare")])
        protocolAllowed = true
    }

    /// A folder has no `fid` (its id is `cid`); a file's `cid` is its parent.
    private func parsePersonalFiles(_ json: LenientJSON) -> [DriveFile] {
        json.objects("data").compactMap { item in
            let fid = item.string("fid")
            let isDirectory = fid.isBlankText
            let id = isDirectory ? item.string("cid") : fid
            if id.isBlankText { return nil }
            return DriveFile(id: id, name: item.string("n"), size: isDirectory ? 0 : item.int64("s"), isDirectory: isDirectory,
                             parentId: isDirectory ? item.string("pid") : item.string("cid"), fileToken: item.string("pc"),
                             modifiedAt: item.string("t"))
        }
    }

    /// `fc == 0` is a directory (id `cid`); a file's id is `fid`. Share files carry no pickcode.
    private func parseShareFiles(_ data: LenientJSON) -> [DriveFile] {
        data.objects("list").compactMap { item in
            let fid = item.string("fid")
            let isDirectory = (item.has("fc") ? item.int("fc") : (fid.isBlankText ? 0 : 1)) == 0
            let id = isDirectory ? item.string("cid") : fid
            if id.isBlankText { return nil }
            return DriveFile(id: id, name: item.string("n"), size: isDirectory ? 0 : item.int64("s"), isDirectory: isDirectory,
                             parentId: isDirectory ? item.string("pid") : item.string("cid"), fileToken: "",
                             modifiedAt: item.string("t"))
        }
    }

    private func request(_ url: String, cookie: String, referer: String, body: String? = nil,
                         userAgent: String = Pan115Constants.webUserAgent) throws -> HTTPRequest {
        guard let parsed = URL(string: url) else { throw DriveError.api(message: "请求地址无效") }
        var headers = [
            "User-Agent": userAgent,
            "Accept": "application/json, text/plain, */*",
            "X-Requested-With": Pan115Constants.requestedWith,
            "Referer": referer,
        ]
        if !cookie.isBlankText { headers["Cookie"] = cookie }
        if let body {
            // Matches the captured web page.
            headers["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8"
            return HTTPRequest(method: .post, url: parsed, headers: headers, body: Data(body.utf8))
        }
        return HTTPRequest(method: .get, url: parsed, headers: headers)
    }

    private func getJSON(_ url: String, cookie: String, referer: String) async throws -> LenientJSON {
        try await execute(request(url, cookie: cookie, referer: referer)).0
    }

    private func postForm(_ url: String, cookie: String, referer: String, _ pairs: [(String, String)]) async throws -> LenientJSON {
        try await execute(request(url, cookie: cookie, referer: referer, body: form(pairs))).0
    }

    /// Returns the response JSON and the download cookie from the headers.
    private func execute(_ request: HTTPRequest) async throws -> (LenientJSON, String?) {
        let response = try await transport.send(request)
        let cdnCookie = Self.downloadCookie(response.cookiesWithPath.isEmpty ? response.setCookies : response.cookiesWithPath)
        if response.body.isEmpty { throw DriveError.api(message: "请求失败：响应为空（\(response.statusCode)）") }
        guard let json = LenientJSON(data: response.body) else {
            if !(200..<300).contains(response.statusCode) && String(decoding: response.body, as: UTF8.self).isBlankText {
                throw DriveError.api(message: "请求失败（HTTP \(response.statusCode)）")
            }
            throw DriveError.api(message: "响应解析失败（\(response.statusCode)）")
        }
        return (json, cdnCookie)
    }

    /// The first `name=value` from Set-Cookie. The CDN accepts only the path-bound one (`path=/<object>/`);
    /// others, such as the WAF's acw_tc, are not it. Without a path-bound entry, the first pair is returned.
    static func downloadCookie(_ headers: [String]) -> String? {
        var fallback: String?
        for raw in headers {
            let pair = String(raw.prefix { $0 != ";" }).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[..<equals])
            if name.isBlankText { continue }
            if ["expires", "path", "domain"].contains(name.lowercased()) { continue }
            if fallback == nil { fallback = pair }
            if let path = pathAttribute(raw), path != "/" { return pair }
        }
        return fallback
    }

    private static func pathAttribute(_ raw: String) -> String? {
        for attribute in raw.split(separator: ";").dropFirst() {
            let trimmed = attribute.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("path=") {
                return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines).nonBlank
            }
        }
        return nil
    }

    private func errno(of json: LenientJSON) -> Int { json.has("errno") ? json.int("errno") : json.int("errNo") }

    /// Success is `state == true`; failures map the captured error codes to readable messages.
    private func checkState(_ json: LenientJSON, fallback: String) throws {
        if json.bool("state") { return }
        let code = errno(of: json)
        let raw = json.string("error").ifBlank(json.string("msg"))
        let message: String
        switch code {
        case Pan115Constants.errnoLoginTimeout: message = "登录已过期，请重新登录115网盘"
        case Pan115Constants.errnoNeedCode: message = "该分享需要访问码，请填写访问码后重试"
        case Pan115Constants.errnoWrongCode: message = "访问码错误，请检查后重试"
        case Pan115Constants.errnoShareGone: message = "分享链接不存在或已被删除"
        case Pan115Constants.errnoEmptyFolder: message = "不允许分享空文件夹"
        case Pan115Constants.errnoBusy: message = "上一次操作还没完成，请稍后重试"
        case Pan115Constants.errnoWebSizeLimit: message = "115 拒绝向网页端下发该文件的直链（文件过大），请改用115电脑端/手机客户端下载"
        case Pan115Constants.errnoClientTooOld: message = "115 判定当前标识版本过低、拒绝下发直链，请改用115电脑端/手机客户端下载"
        default: message = raw.ifBlank(fallback)
        }
        let suffix = code != 0 && !message.contains(String(code)) ? "（errno=\(code)）" : ""
        throw DriveError.api(message: message + suffix, code: code)
    }

    private func form(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(q($0.0))=\(q($0.1))" }.joined(separator: "&")
    }

    private func q(_ value: String) -> String { HTTPClient.encodeQueryValue(value) }

    private static func double(_ json: LenientJSON, _ key: String) -> Double {
        switch json.object[key] {
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value) ?? 0
        default: return 0
        }
    }

    private static func jsonText(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
