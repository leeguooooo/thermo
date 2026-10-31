// Ported from YunX-Desktop (AGPL-3.0): data/network/ILanzouApi.kt.
// Endpoints, parameters, signing and error handling follow that file. Lookups that returned null there return nil here.
import Foundation

public struct ILanzouAccountInfo: Sendable, Equatable {
    public let userId: String
    public let account: String
    public let nickname: String
}

public struct ILanzouDownloadLink: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    /// Prefixed with `f:`.
    public let fid: String
    public let downloadURL: String
    public var description: String { "ILanzouDownloadLink(\(fid), <redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: ["fid": fid]) }
}

/// The 409 + text/html access check.
private struct AccessChallenge: Error {}

public actor ILanzouAPI {
    private let http: HTTPClient
    private let sleep: DriveSleeper
    private let now: @Sendable () -> Date
    private var guestUUID: String?

    private static let expiredMessage = "蓝奏优享登录已过期，请重新登录"

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        sleep: @escaping DriveSleeper = { try await Task.sleep(nanoseconds: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        http = HTTPClient(transport: transport)
        self.sleep = sleep
        self.now = now
    }

    // MARK: Auth

    /// Device id (§2.1).
    public func getUUID() async throws -> String {
        let url = buildURL(ILanzouConstants.getUUIDURL, uuid: "", appToken: nil, extra: true)
        let json = try await execute(.get(url))
        let uuid = json.string("uuid")
        guard ILanzouConstants.isValidUUID(uuid) else { throw DriveError.api(message: "蓝奏优享未返回有效设备标识") }
        return uuid
    }

    /// Account and password login (§2.2). Returns the appToken. The password is used for this call only.
    public func login(loginName: String, loginPwd: String, uuid: String) async throws -> String {
        let name = loginName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || loginPwd.isEmpty { throw DriveError.api(message: "请输入蓝奏优享账号和密码") }
        if name.count > 254 { throw DriveError.api(message: "蓝奏优享用户名过长") }
        if loginPwd.count > 256 { throw DriveError.api(message: "蓝奏优享密码过长") }
        let url = buildURL(ILanzouConstants.loginURL, uuid: uuid, appToken: nil, extra: true)
        let json = try await execute(.post(url, ["loginName": name, "loginPwd": loginPwd]), mode: .login)
        let token = json.child("data")?.string("appToken") ?? ""
        guard ILanzouConstants.isValidToken(token) else { throw DriveError.api(message: "蓝奏优享未返回登录凭据，请稍后重试") }
        return token
    }

    /// Login, then account lookup. The returned credential includes the userId when the lookup worked.
    public func signIn(loginName: String, loginPwd: String, uuid existingUUID: String? = nil) async throws -> ILanzouCredential {
        let uuid: String
        if let existingUUID, ILanzouConstants.isValidUUID(existingUUID) { uuid = existingUUID } else { uuid = try await getUUID() }
        let token = try await login(loginName: loginName, loginPwd: loginPwd, uuid: uuid)
        let info = await fetchAccountInfo(appToken: token, uuid: uuid)
        return ILanzouCredential(appToken: token, uuid: uuid, userId: info?.userId ?? "")
    }

    /// Account info (§2.3).
    public func fetchAccountInfo(appToken: String, uuid: String) async -> ILanzouAccountInfo? {
        let url = buildURL(ILanzouConstants.accountMapURL, uuid: uuid, appToken: appToken, extra: true)
        guard let json = try? await execute(.get(url)), let map = json.child("map") else { return nil }
        let userId = map.string("userId")
        if userId.isEmpty { return nil }
        let nickname = firstNonBlank(map.string("nickName"), map.string("nickname"), map.string("account")).ifBlank("蓝奏优享用户")
        return ILanzouAccountInfo(userId: userId, account: map.string("account"), nickname: nickname)
    }

    /// Quota (§2.3). The server counts KiB.
    public func getQuota(appToken: String, uuid: String) async -> DriveQuota? {
        let url = buildURL(ILanzouConstants.accountMapURL, uuid: uuid, appToken: appToken, extra: true)
        guard let json = try? await execute(.get(url)), let map = json.child("map") else { return nil }
        return DriveQuota(used: map.int64("usedSize") * 1024,
                          total: (map.int64("totalSize") + map.int64("vipSize") + map.int64("rewardSize")) * 1024)
    }

    /// A device id for anonymous share calls, fetched once per API instance.
    func anonymousUUID() async throws -> String {
        if let guestUUID { return guestUUID }
        let value = try await getUUID()
        guestUUID = value
        return value
    }

    // MARK: Own files

    /// File list (§3.1). Pages automatically; folders and files are merged.
    public func listFiles(appToken: String, uuid: String, folderId: String) async throws -> [DriveFile] {
        var all: [DriveFile] = []
        var seen = Set<String>()
        var page = 1
        while page <= 1000 {
            let url = buildURL(ILanzouConstants.fileListURL, uuid: uuid, appToken: appToken, extra: true, params: [
                ("offset", String(page)), ("limit", String(ILanzouConstants.pageSize)), ("folderId", folderId), ("type", "0"),
            ])
            let json = try await execute(.get(url))
            let list = json.objects("list")
            if list.isEmpty { break }
            var added = 0
            for item in list {
                if let file = parseItem(item), seen.insert(file.id).inserted {
                    all.append(file)
                    added += 1
                }
            }
            if added == 0 { throw DriveError.api(message: "蓝奏优享分页重复或不完整，请重新打开目录") }
            let totalPage = json.int("totalPage")
            if totalPage > 0 && page >= totalPage { break }
            if totalPage <= 0 && list.count < ILanzouConstants.pageSize { break }
            page += 1
        }
        return all
    }

    /// New folder (§3.2). Returns its id.
    public func createDir(appToken: String, uuid: String, parentId: String, name: String) async throws -> String {
        let url = buildURL(ILanzouConstants.folderSaveURL, uuid: uuid, appToken: appToken, extra: true)
        let json = try await execute(.post(url, ["folderDesc": "", "folderId": parentId.ifBlank(ILanzouConstants.rootFolderId), "folderName": name]))
        let id = json.objects("list").first?.string("id") ?? ""
        if id.isBlankText || id == "0" { throw DriveError.api(message: "蓝奏优享未返回新文件夹信息，请刷新确认") }
        return id
    }

    /// Folder rename (§3.3).
    public func renameFolder(appToken: String, uuid: String, folderId: String, newName: String) async throws {
        let url = buildURL(ILanzouConstants.folderEditURL, uuid: uuid, appToken: appToken, extra: true)
        _ = try await execute(.post(url, ["folderDesc": "", "folderId": folderId, "folderName": newName]))
    }

    /// File rename (§3.3).
    public func renameFile(appToken: String, uuid: String, fileId: String, newName: String) async throws {
        let url = buildURL(ILanzouConstants.fileEditURL, uuid: uuid, appToken: appToken, extra: true)
        _ = try await execute(.post(url, ["fileDesc": "", "fileId": fileId, "fileName": newName]))
    }

    /// Move (§3.4). Ids are comma-joined.
    public func moveEntries(appToken: String, uuid: String, folderIds: [String], fileIds: [String], targetId: String) async throws {
        let url = buildURL(ILanzouConstants.folderMoveURL, uuid: uuid, appToken: appToken, extra: true)
        _ = try await execute(.post(url, ["folderIds": folderIds.joined(separator: ","), "fileIds": fileIds.joined(separator: ","),
                                          "targetId": targetId.ifBlank(ILanzouConstants.rootFolderId)]))
    }

    /// Delete (§3.5).
    public func deleteEntries(appToken: String, uuid: String, folderIds: [String], fileIds: [String]) async throws {
        let url = buildURL(ILanzouConstants.fileDeleteURL, uuid: uuid, appToken: appToken, extra: true)
        _ = try await execute(.post(url, ["folderIds": folderIds.joined(separator: ","), "fileIds": fileIds.joined(separator: ","), "status": 0]))
    }

    // MARK: Download (§4.1)

    /// Download link for an own file: a 302 Location, or JSON `url` / `data.url`. The size is unknown.
    public func getDownloadLink(appToken: String, uuid: String, fileId: String, userId: String) async throws -> ILanzouDownloadLink {
        let ts = timestampMillis()
        let encodedTimestamp = ILanzouCrypto.aesHex(String(ts))
        // downloadId = AES("<fileId>|<userId>"), auth = AES("<fileId>|<ms>"); timestamp and auth share one ts.
        let params = [
            ("enable", "1"),
            ("downloadId", ILanzouCrypto.aesHex("\(fileId)|\(userId)")),
            ("auth", ILanzouCrypto.aesHex("\(fileId)|\(ts)")),
            ("timestamp", encodedTimestamp),
        ]
        // This call carries no extra=2.
        let url = buildURL(ILanzouConstants.fileRedirectURL, uuid: uuid, appToken: appToken, extra: false, params: params, timestamp: encodedTimestamp)
        let response = try await http.get(url, headers: commonHeaders(json: false), followRedirects: false)
        if let location = redirectLocation(response, base: ILanzouConstants.apiBase) {
            return ILanzouDownloadLink(fid: ILanzouConstants.filePrefix + fileId, downloadURL: location)
        }
        guard let json = LenientJSON(data: response.body) else { throw DriveError.api(message: "蓝奏优享未返回下载地址") }
        try checkCode(json)
        let link = firstNonBlank(json.string("url"), json.child("data")?.string("url") ?? "")
        if link.isEmpty { throw DriveError.api(message: "蓝奏优享未返回下载地址，请检查文件权限") }
        return ILanzouDownloadLink(fid: ILanzouConstants.filePrefix + fileId, downloadURL: link)
    }

    // MARK: Shares

    /// Share listing, anonymous. A nil `folderId` lists the share root. Pages automatically.
    public func shareList(shareId: String, folderId: String?, uuid: String) async throws -> [DriveFile] {
        var all: [DriveFile] = []
        var seen = Set<String>()
        var page = 1
        while page <= 1000 {
            var params: [(String, String)] = []
            if let folderId = folderId?.nonBlank { params.append(("folderId", folderId)) }
            params.append(("offset", String(page)))
            params.append(("limit", String(ILanzouConstants.pageSize)))
            let url = shareURL(ILanzouConstants.shareListURL, uuid: uuid, shareId: shareId, params: params)
            let json = try await execute(.get(url), mode: .share)
            let list = json.objects("list")
            if list.isEmpty { break }
            var added = 0
            for item in list {
                if let file = parseItem(item), seen.insert(file.id).inserted {
                    all.append(file)
                    added += 1
                }
            }
            if added == 0 { break }
            let totalPage = json.int("totalPage")
            if totalPage > 0 && page >= totalPage { break }
            if totalPage <= 0 && list.count < ILanzouConstants.pageSize { break }
            page += 1
        }
        return all
    }

    /// Download link for a shared file, anonymous. `userId` is empty when signed out.
    public func shareDownload(shareId: String, fileId: String, userId: String, uuid: String) async throws -> ILanzouDownloadLink {
        let ts = timestampMillis()
        let params = [
            ("downloadId", ILanzouCrypto.aesHex("\(fileId)|\(userId)")),
            ("enable", "1"),
            ("devType", ILanzouConstants.devType),
            ("uuid", uuid),
            ("timestamp", ILanzouCrypto.aesHex(String(ts))),
            ("auth", ILanzouCrypto.aesHex("\(fileId)|\(ts)")),
            ("shareId", shareId),
        ]
        let url = "\(ILanzouConstants.shareRedirectURL)?\(query(params))"
        let response = try await http.get(url, headers: commonHeaders(json: false), followRedirects: false)
        if let location = redirectLocation(response, base: ILanzouConstants.shareAPIBase) {
            return ILanzouDownloadLink(fid: ILanzouConstants.filePrefix + fileId, downloadURL: location)
        }
        guard let json = LenientJSON(data: response.body) else { throw DriveError.api(message: "蓝奏优享未返回下载地址") }
        let link = firstNonBlank(json.string("url"), json.child("data")?.string("url") ?? "")
        if link.isEmpty {
            throw DriveError.api(message: firstNonBlank(json.string("msg"), "蓝奏优享未返回下载地址，请检查文件权限"))
        }
        return ILanzouDownloadLink(fid: ILanzouConstants.filePrefix + fileId, downloadURL: link)
    }

    /// Saves share entries into the account. Returns a transferKey; empty means the save finished synchronously.
    public func transferShare(appToken: String, uuid: String, shareId: String, fileIds: [String], folderIds: [String], targetFolderId: String) async throws -> String {
        let url = buildURL(ILanzouConstants.fileTransferURL, uuid: uuid, appToken: appToken, extra: true)
        let json = try await execute(.post(url, [
            "targetFileId": fileIds.joined(separator: ","),
            "targetFolderId": folderIds.joined(separator: ","),
            "folderId": targetFolderId.ifBlank(ILanzouConstants.rootFolderId),
            "shareId": shareId,
        ]))
        return firstNonBlank(json.child("data")?.string("transferKey") ?? "", json.child("map")?.string("transferKey") ?? "",
                             json.string("transferKey"), json.string("data"))
    }

    /// Save progress: `map.num == 1` means done.
    public func transferCount(appToken: String, uuid: String, transferKey: String) async throws -> Int {
        let url = buildURL(ILanzouConstants.fileTransferNumURL, uuid: uuid, appToken: appToken, extra: true, params: [("transferKey", transferKey)])
        return try await execute(.get(url)).child("map")?.int("num") ?? 0
    }

    /// Polls an asynchronous save for up to 15 seconds. Poll errors count as "not done".
    public func waitForTransfer(appToken: String, uuid: String, transferKey: String) async throws -> Bool {
        for _ in 0..<ILanzouConstants.transferPollAttempts {
            try await sleep(ILanzouConstants.transferPollInterval)
            if (try? await transferCount(appToken: appToken, uuid: uuid, transferKey: transferKey)) == 1 { return true }
        }
        return false
    }

    // MARK: Internals

    private func parseItem(_ item: LenientJSON) -> DriveFile? {
        let modified = firstNonBlank(item.string("updTime"), item.string("addTime"))
        if item.int("fileType") == 2 {
            let id = item.string("folderId")
            if id.isBlankText || id == "0" { return nil }
            return DriveFile(id: ILanzouConstants.folderPrefix + id, name: item.string("folderName"), size: 0, isDirectory: true, parentId: "", modifiedAt: modified)
        }
        let id = item.string("fileId")
        if id.isBlankText || id == "0" { return nil }
        // The server counts KiB.
        return DriveFile(id: ILanzouConstants.filePrefix + id, name: item.string("fileName"), size: item.int64("fileSize") * 1024, isDirectory: false, parentId: "", modifiedAt: modified)
    }

    private func timestampMillis() -> Int64 { Int64(now().timeIntervalSince1970 * 1000) }

    /// Personal-drive URL: common device parameters, then the business parameters.
    private func buildURL(_ path: String, uuid: String, appToken: String?, extra: Bool, params: [(String, String)] = [], timestamp: String? = nil) -> String {
        var parts: [(String, String)] = [
            ("uuid", uuid), ("devType", ILanzouConstants.devType), ("devCode", uuid),
            ("devModel", ILanzouConstants.devModel), ("devVersion", ILanzouConstants.devVersion), ("appVersion", ""),
            ("timestamp", timestamp ?? ILanzouCrypto.aesHex(String(timestampMillis()))),
        ]
        if let appToken, !appToken.isBlankText { parts.append(("appToken", appToken)) }
        if extra { parts.append(("extra", "2")) }
        parts += params
        return "\(path)?\(query(parts))"
    }

    /// Share URL: common parameters plus shareId, no appToken.
    private func shareURL(_ path: String, uuid: String, shareId: String, params: [(String, String)]) -> String {
        let parts: [(String, String)] = [
            ("uuid", uuid), ("devType", ILanzouConstants.devType), ("devCode", uuid),
            ("devModel", ILanzouConstants.shareDevModel), ("devVersion", ILanzouConstants.devVersion), ("appVersion", ""),
            ("timestamp", ILanzouCrypto.aesHex(String(timestampMillis()))), ("extra", "2"), ("shareId", shareId),
        ] + params
        return "\(path)?\(query(parts))"
    }

    private func query(_ parts: [(String, String)]) -> String {
        parts.map { "\($0.0)=\(Self.encodeToken($0.1))" }.joined(separator: "&")
    }

    /// Standard query encoding, then `%3A` back to a literal colon (the appToken needs it).
    static func encodeToken(_ value: String) -> String {
        HTTPClient.encodeQueryValue(value).replacingOccurrences(of: "%3A", with: ":")
    }

    /// The site's WAF answers bare clients with empty lists, so the browser client hints are required.
    private func commonHeaders(json: Bool) -> [String: String] {
        var headers = [
            "User-Agent": ILanzouConstants.webUserAgent,
            "Origin": ILanzouConstants.webSite,
            "Referer": ILanzouConstants.downloadReferer,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "sec-ch-ua": "\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"",
            "sec-ch-ua-mobile": "?0",
            "sec-ch-ua-platform": "\"Windows\"",
            "sec-fetch-dest": "empty",
            "sec-fetch-mode": "cors",
            "sec-fetch-site": "same-site",
        ]
        if json { headers["Content-Type"] = "application/json; charset=utf-8" }
        return headers
    }

    private func redirectLocation(_ response: HTTPResponse, base: String) -> String? {
        guard (300...399).contains(response.statusCode), let location = response.header("Location")?.nonBlank else { return nil }
        // Location can be relative; resolve it against the API host.
        return URL(string: location, relativeTo: URL(string: base))?.absoluteString ?? location
    }

    private func firstNonBlank(_ values: String...) -> String {
        values.first { !$0.isBlankText }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: Requests and error handling

    private enum Call {
        case get(String)
        case post(String, [String: Any])
    }

    private enum Mode { case standard, login, share }

    private func send(_ call: Call) async throws -> HTTPResponse {
        switch call {
        case .get(let url): return try await http.get(url, headers: commonHeaders(json: false))
        case .post(let url, let body): return try await http.postJSON(url, json: body, headers: commonHeaders(json: true))
        }
    }

    /// Runs a call and checks the business code. A 409 + text/html access check is retried once.
    private func execute(_ call: Call, mode: Mode = .standard) async throws -> LenientJSON {
        do {
            return try interpret(try await send(call), mode: mode)
        } catch is AccessChallenge {
            guard mode != .share else { throw DriveError.api(message: "蓝奏优享分享请求失败（409）") }
            do {
                return try interpret(try await send(call), mode: mode)
            } catch is AccessChallenge {
                throw DriveError.api(message: mode == .login ? "蓝奏优享的访问验证未通过，请稍后重试" : "蓝奏优享的访问验证未通过，请稍后重试或使用网页登录")
            }
        }
    }

    private func interpret(_ response: HTTPResponse, mode: Mode) throws -> LenientJSON {
        let isHTML = (response.header("Content-Type") ?? "").contains("text/html")
        let failed = DriveError.api(message: "蓝奏优享请求失败（\(response.statusCode)），请检查登录信息或稍后重试")
        switch mode {
        case .share:
            guard let json = LenientJSON(data: response.body) else { throw DriveError.api(message: "蓝奏优享分享请求失败（\(response.statusCode)）") }
            let code = businessCode(json)
            if code != 200 { throw DriveError.api(message: firstNonBlank(json.string("msg"), "蓝奏优享分享请求失败（\(code)）"), code: code) }
            return json
        case .login:
            if !(200..<300).contains(response.statusCode) {
                if response.statusCode == 409 && isHTML { throw AccessChallenge() }
                throw DriveError.api(message: "蓝奏优享请求失败（\(response.statusCode)）")
            }
            guard let json = LenientJSON(data: response.body) else {
                if isHTML { throw AccessChallenge() }
                throw DriveError.api(message: "蓝奏优享请求失败（\(response.statusCode)）")
            }
            let code = businessCode(json)
            if code != 200 { throw DriveError.api(message: json.string("msg").ifBlank("蓝奏优享登录失败，请检查账号密码"), code: code) }
            return json
        case .standard:
            if !(200..<300).contains(response.statusCode) {
                if response.statusCode == 401 || response.statusCode == 403 { throw DriveError.api(message: Self.expiredMessage, code: response.statusCode) }
                if response.statusCode == 409 && isHTML { throw AccessChallenge() }
                throw failed
            }
            guard let json = LenientJSON(data: response.body) else {
                if isHTML { throw AccessChallenge() }
                throw failed
            }
            try checkCode(json)
            return json
        }
    }

    private func businessCode(_ json: LenientJSON) -> Int { json.has("code") ? json.int("code") : -1 }

    private func checkCode(_ json: LenientJSON) throws {
        let code = businessCode(json)
        if code == 200 { return }
        if code == -1 || code == -2 { throw DriveError.api(message: Self.expiredMessage, code: code) }
        throw DriveError.api(message: "蓝奏优享请求失败（\(code)），请检查登录信息或稍后重试", code: code)
    }
}
