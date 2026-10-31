// Ported from YunX-Desktop (MIT): data/network/Pan123Api.kt.
// Endpoints, parameters, signing and error handling follow that file. Lookups that returned null there return nil here.
import Foundation

public enum Pan123LoginResult: Sendable, Equatable {
    case success(DriveCredential)
    /// A message that is safe to show: it never repeats the server's text.
    case failure(String)
}

public struct Pan123ShareInfo: Sendable, Equatable {
    public let shareURL: String
    public let passcode: String
    public let shareKey: String
    public let title: String
}

/// A direct link and the file it belongs to.
public struct Pan123DownloadLink: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let fid: String
    public let filename: String
    public let downloadURL: String
    public let size: Int64
    public var description: String { "Pan123DownloadLink(\(fid), \(filename), <redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: ["fid": fid, "filename": filename, "size": size]) }
}

/// Fetches a CDN URL that may answer with a small JSON redirect instead of the file.
/// Returns the body only when it is small enough to be that JSON, otherwise nil.
public protocol Pan123RedirectProbe: Sendable {
    func smallBody(url: URL, headers: [String: String]) async -> Data?
}

/// Reads through the injected transport; fine for tests and small bodies only.
struct TransportRedirectProbe: Pan123RedirectProbe {
    let transport: any HTTPTransport

    func smallBody(url: URL, headers: [String: String]) async -> Data? {
        guard let response = try? await transport.send(HTTPRequest(method: .get, url: url, headers: headers)),
              response.body.count <= Pan123Constants.redirectProbeLimit else { return nil }
        return response.body
    }
}

/// Streams the response and gives up on anything whose Content-Length is unknown or above 8 KB,
/// so a real file is never pulled into memory. Sends no credentials.
public final class URLSessionRedirectProbe: Pan123RedirectProbe {
    private let session: URLSession

    public init() {
        session = URLSession(configuration: URLSessionTransport.makeConfiguration())
    }

    public func smallBody(url: URL, headers: [String: String]) async -> Data? {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
        let length = response.expectedContentLength
        guard length >= 0, length <= Int64(Pan123Constants.redirectProbeLimit) else { return nil }
        var data = Data()
        do { for try await byte in bytes { data.append(byte) } } catch { return nil }
        return data
    }
}

public struct Pan123API: Sendable {
    private let transport: any HTTPTransport
    private let probe: any Pan123RedirectProbe
    private let sleep: DriveSleeper
    private let now: @Sendable () -> Int64
    private let random: @Sendable () -> Int
    /// The `loginuuid` header. 123 treats it as a device fingerprint, so the host should persist it
    /// and pass the same value on every launch. It is not a secret.
    public let deviceId: String

    public init(
        deviceId: String? = nil,
        sleep: @escaping DriveSleeper = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.init(transport: URLSessionTransport(), redirectProbe: URLSessionRedirectProbe(), deviceId: deviceId, sleep: sleep)
    }

    init(
        transport: any HTTPTransport,
        redirectProbe: (any Pan123RedirectProbe)? = nil,
        deviceId: String? = nil,
        sleep: @escaping DriveSleeper = { try await Task.sleep(nanoseconds: $0) },
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        random: @escaping @Sendable () -> Int = { Int.random(in: 0..<10_000_000) }
    ) {
        self.transport = transport
        self.probe = redirectProbe ?? TransportRedirectProbe(transport: transport)
        self.sleep = sleep
        self.now = now
        self.random = random
        self.deviceId = deviceId.flatMap(Self.validDeviceId) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func validDeviceId(_ value: String) -> String? {
        value.count == 32 && value.allSatisfy(\.isHexDigit) ? value : nil
    }

    // MARK: Sign-in

    /// The sign-in site is user.123pan.cn, not the drive host. Success is `code == 200` here, not 0.
    /// The password is sent as typed; only the account is trimmed.
    public func passwordLogin(account: String, password: String) async -> Pan123LoginResult {
        let passport = account.trimmingCharacters(in: .whitespacesAndNewlines)
        if passport.isEmpty || password.isEmpty { return .failure("请输入账号和密码") }
        if passport.count > 254 || password.count > 256 { return .failure("账号或密码过长") }
        let headers = [
            "platform": Pan123Constants.platformWeb,
            "app-version": Pan123Constants.appVersionSignIn,
            "loginuuid": deviceId,
            "Origin": Pan123Constants.signInOrigin,
            "Referer": Pan123Constants.signInReferer,
            "User-Agent": Pan123Constants.webUserAgent,
        ]
        do {
            let response = try await post(Pan123Constants.loginURL, json: ["passport": passport, "password": password, "remember": false], headers: headers)
            let json = LenientJSON(data: response.body)
            let code = json.flatMap { $0.has("code") ? $0.int("code") : nil } ?? -1
            let token = json?.child("data")?.string("token") ?? ""
            if (200..<300).contains(response.statusCode), code == 200, Pan123LoginSupport.isValidToken(token) {
                return .success(DriveCredential(token))
            }
            return .failure(Pan123LoginSupport.describeFailure(httpStatus: response.statusCode, code: code, serverMessage: json?.string("message") ?? ""))
        } catch {
            return .failure("网络异常，无法连接 123 登录服务，请稍后重试")
        }
    }

    // MARK: Account

    public func fetchNickname(token: String) async -> String? {
        guard let json = try? await getAuth(Pan123Constants.userInfoURL, path: "/b/api/user/info", token: token),
              (try? checkOk(json, "获取用户信息失败")) != nil else { return nil }
        return json.child("data")?.string("Nickname").nonBlank
    }

    public func getQuota(token: String) async -> DriveQuota? {
        guard let json = try? await getAuth(Pan123Constants.userInfoURL, path: "/b/api/user/info", token: token),
              (try? checkOk(json, "获取空间详情失败")) != nil,
              let data = json.child("data") else { return nil }
        return DriveQuota(used: data.int64("SpaceUsed"), total: data.int64("SpacePermanent") + data.int64("SpaceTemp"))
    }

    // MARK: Shares

    /// Anonymous and unsigned. Returns the files and the next cursor; nil means the last page.
    /// `Next == "-1"` ends the list and an empty string means more pages. `SharePwd` is left out when
    /// blank, because an empty value is answered with 400.
    public func getShareFiles(shareKey: String, sharePwd: String, parentFileId: String, next: String, page: Int) async throws -> (files: [DriveFile], next: String?) {
        var url = "\(Pan123Constants.shareGetURL)?limit=100&next=\(next)&orderBy=file_name&orderDirection=asc"
        url += "&shareKey=\(HTTPClient.encodeQueryValue(shareKey))&ParentFileId=\(parentFileId)&Page=\(page)"
        if !sharePwd.isBlankText { url += "&SharePwd=\(HTTPClient.encodeQueryValue(sharePwd))" }
        let json = try await execute(request(.get, url, headers: ["User-Agent": Pan123Constants.dartUserAgent]))
        try checkOk(json, "获取文件列表失败")
        guard let data = json.child("data") else { return ([], nil) }
        if data.bool("Expired") { throw DriveError.api(message: "分享已失效") }
        let cursor = data.string("Next")
        return (parseInfoList(data), cursor == "-1" ? nil : cursor)
    }

    /// Needs a signed-in account. The platform headers say android; the sign still says web/3.
    public func getShareDownloadLink(shareKey: String, file: DriveFile, token: String) async throws -> Pan123DownloadLink? {
        let (s3KeyFlag, etag, _) = Self.decodeToken(file.fileToken)
        let body: [String: Any] = ["ShareKey": shareKey, "FileID": file.id, "S3KeyFlag": s3KeyFlag, "Size": file.size, "Etag": etag]
        let json = try await postAuth(Pan123Constants.shareDownloadInfoURL, path: "/b/api/share/download/info", body: body, token: token,
                                      platform: Pan123Constants.platformAndroid, appVersion: Pan123Constants.appVersionAndroid)
        try checkOk(json, "获取下载链接失败")
        guard let raw = json.child("data")?.string("DownloadURL").nonBlank else { return nil }
        let real = await followRedirect(Self.decodeDownloadURL(raw) ?? raw)
        return Pan123DownloadLink(fid: file.id, filename: file.name, downloadURL: real, size: file.size)
    }

    // MARK: Own files

    /// One page of 100, newest first. Returns the files and the next cursor, as the source does.
    public func listCloudFiles(parentFileId: String, token: String) async throws -> (files: [DriveFile], next: String?) {
        var url = "\(Pan123Constants.fileListURL)?driveId=0&limit=100&next=0&orderBy=update_time&orderDirection=desc"
        url += "&parentFileId=\(parentFileId)&trashed=false&SearchData=&Page=1&OnlyLookAbnormalFile=0"
        url += "&event=homeListFile&operateType=1&inDirectSpace=false"
        let json = try await getAuth(url, path: "/b/api/file/list/new", token: token)
        try checkOk(json, "获取文件列表失败")
        guard let data = json.child("data") else { return ([], nil) }
        let cursor = data.string("Next")
        return (parseInfoList(data), cursor == "-1" ? nil : cursor)
    }

    /// POST /api/file/download_info (no /b/). The reply is often a download-v2 wrapper, so it is always decoded.
    public func getDownloadLink(file: DriveFile, token: String) async throws -> Pan123DownloadLink? {
        let (s3KeyFlag, etag, _) = Self.decodeToken(file.fileToken)
        let body: [String: Any] = [
            "driveId": 0, "etag": etag, "fileId": Int64(file.id) ?? 0, "s3keyFlag": s3KeyFlag,
            "type": 0, "fileName": file.name, "size": file.size,
        ]
        let json = try await postAuth(Pan123Constants.fileDownloadInfoURL, path: "/api/file/download_info", body: body, token: token)
        try checkOk(json, "获取下载链接失败")
        guard let raw = json.child("data")?.string("DownloadUrl").nonBlank else { return nil }
        // A relay page also starts with http, so never skip the decode on that basis.
        let url = await followRedirect(Self.decodeDownloadURL(raw) ?? raw)
        return Pan123DownloadLink(fid: file.id, filename: file.name, downloadURL: url, size: file.size)
    }

    // MARK: Saving a share

    /// Starts an asynchronous save. The mshare subdomain takes no client sign: Bearer and LoginUuid only.
    /// Returns the task id and the numeric share id that picks the subdomain.
    public func copySave(shareKey: String, sharePwd: String, file: DriveFile, toDirFid: String, token: String) async throws -> (taskId: Int64, shareId: String)? {
        let shareId = Self.shareId(of: file)
        if shareId.isEmpty { throw DriveError.api(message: "无法识别分享 ID（缺少 S3KeyFlag）") }
        let (s3KeyFlag, etag, storageNode) = Self.decodeToken(file.fileToken)
        let fileId = Int64(file.id) ?? 0
        let parentId = Int64(toDirFid) ?? 0
        let item: [String: Any] = [
            "fileID": fileId, "fileId": fileId, "size": file.size, "etag": etag, "type": file.isDirectory ? 1 : 0,
            "parentFileID": parentId, "parentFileId": parentId, "fileName": file.name, "driveID": 0, "driveId": 0,
            "s3keyFlag": s3KeyFlag, "S3KeyFlag": s3KeyFlag, "StorageNode": storageNode,
        ]
        let body: [String: Any] = [
            "fileList": [item], "shareKey": shareKey,
            // An empty string, never null, when there is no passcode.
            "sharePwd": sharePwd, "currentLevel": 1, "superAdmin": NSNull(),
        ]
        let headers = [
            "Authorization": "Bearer \(token)", "LoginUuid": deviceId, "platform": Pan123Constants.platformWeb,
            "User-Agent": Pan123Constants.dartUserAgent,
        ]
        let json = try await execute(try jsonRequest("https://\(shareId).mshare.123pan.cn/b/api/restful/goapi/v1/file/copy/save", body: body, headers: headers))
        try checkOk(json, "转存失败")
        guard let data = json.child("data") else { return nil }
        return (data.int64("taskID"), shareId)
    }

    /// Polls up to 15 times, 1 s apart, and returns the new file id, or nil on timeout.
    /// The reply shape was only partly captured, so several completion markers are accepted.
    public func pollCopySave(taskId: Int64, shareId: String, token: String) async throws -> String? {
        let url = "https://\(shareId).mshare.123pan.cn/b/api/restful/goapi/v1/file/copy/save/get?taskID=\(taskId)"
        let headers = [
            "Authorization": "Bearer \(token)", "LoginUuid": deviceId, "platform": Pan123Constants.platformWeb,
            "User-Agent": Pan123Constants.dartUserAgent,
        ]
        for _ in 0..<Pan123Constants.copyPollAttempts {
            try await sleep(1_000_000_000)
            let json = try await execute(request(.get, url, headers: headers))
            if (json.has("code") ? json.int("code") : -1) != 0 {
                let message = json.string("message")
                if !message.isBlankText { throw DriveError.api(message: "转存失败：\(message)") }
                continue
            }
            guard let data = json.child("data") else { continue }
            let status = data.has("status") ? data.int("status") : -1
            let state = data.string("state").lowercased()
            let done = data.bool("finished") || status == 2 || status == 3
                || ["success", "done", "2"].contains(state)
                || ["fileId", "FileId", "newFileId"].contains { data.object[$0] != nil }
            if done {
                return [data.string("newFileId"), data.string("FileId"), data.string("fileId")].first { !$0.isBlankText } ?? String(taskId)
            }
        }
        return nil
    }

    // MARK: Managing the account

    /// Moves files to the recycle bin.
    public func deleteFiles(_ files: [DriveFile], token: String) async throws {
        let list: [[String: Any]] = files.map { file in
            let (s3, etag, _) = Self.decodeToken(file.fileToken)
            return ["FileId": Int64(file.id) ?? 0, "FileName": file.name, "Type": file.isDirectory ? 1 : 0,
                    "Size": file.size, "S3KeyFlag": s3, "Etag": etag]
        }
        let body: [String: Any] = [
            "driveId": 0, "fileTrashInfoList": list, "operation": true, "event": "intoRecycle",
            "operatePlace": 1, "safeBox": false,
        ]
        try checkOk(try await postAuth(Pan123Constants.fileTrashURL, path: "/b/api/file/trash", body: body, token: token), "删除失败")
    }

    public func renameFile(fileId: String, newName: String, token: String) async throws {
        let body: [String: Any] = [
            "driveId": 0, "fileId": Int64(fileId) ?? 0, "fileName": newName, "duplicate": 1,
            "event": "fileRename", "operatePlace": "right", "RequestSource": NSNull(),
        ]
        try checkOk(try await postAuth(Pan123Constants.fileRenameURL, path: "/b/api/file/rename", body: body, token: token), "重命名失败")
    }

    /// Makes a folder through upload_request with `type` 1. The signed path must match the request path.
    public func createDir(parentFileId: String, name: String, token: String) async throws -> String {
        let body: [String: Any] = [
            "driveId": 0, "parentFileId": Int64(parentFileId) ?? 0, "fileName": name, "size": 0, "type": 1,
            "etag": "", "duplicate": 1, "NotReuse": true, "RequestSource": NSNull(),
        ]
        let json = try await postAuth(Pan123Constants.fileUploadRequestURL, path: "/b/api/file/upload_request", body: body, token: token)
        try checkOk(json, "新建文件夹失败")
        guard let data = json.child("data") else { throw DriveError.api(message: "123 未返回文件夹编号") }
        // The id has appeared as data.Info.FileId, data.FileId and data.fileId.
        let id = [data.child("Info")?.string("FileId") ?? "", data.string("FileId"), data.string("fileId")].first { !$0.isBlankText } ?? ""
        guard !id.isBlankText, id != "0" else { throw DriveError.api(message: "123 未返回文件夹编号") }
        return id
    }

    public func moveFiles(fileIds: [String], toParentFileId: String, token: String) async throws {
        let body: [String: Any] = [
            "fileIdList": fileIds.map { ["FileId": Int64($0) ?? 0] }, "parentFileId": Int64(toParentFileId) ?? 0,
            "event": "fileMove", "operatePlace": 1, "RequestSource": NSNull(),
        ]
        try checkOk(try await postAuth(Pan123Constants.fileModPidURL, path: "/b/api/file/mod_pid", body: body, token: token), "移动失败")
    }

    /// `expiration` is an absolute ISO time ("now + days"); use `Pan123Constants.expirationForever` for no expiry.
    /// One file goes as a scalar id and several as an array, as captured.
    public func createShare(fileIds: [String], shareName: String, expiration: String, sharePwd: String?, token: String) async throws -> Pan123ShareInfo {
        var body: [String: Any] = [
            "driveId": 0, "expiration": expiration,
            "fileIdList": fileIds.count == 1 ? (Int64(fileIds[0]) ?? 0) as Any : fileIds.map { Int64($0) ?? 0 } as Any,
            "shareName": shareName, "event": "shareCreate", "fileNum": fileIds.count, "shareModality": 4,
            "trafficLimitSwitch": 1, "trafficLimit": 0, "trafficSwitch": 1, "fillPwdSwitch": 0,
        ]
        if let sharePwd, !sharePwd.isBlankText { body["sharePwd"] = sharePwd }
        let json = try await postAuth(Pan123Constants.shareCreateURL, path: "/b/api/share/create", body: body, token: token)
        try checkOk(json, "创建分享失败")
        guard let data = json.child("data") else { throw DriveError.api(message: "创建分享失败：未返回数据") }
        let shareKey = data.string("ShareKey")
        if shareKey.isBlankText { throw DriveError.api(message: "创建分享失败：未返回 ShareKey") }
        let links = data.child("shareLinkList")
        let url = (links?.array("list")?.first as? String)?.nonBlank
            ?? links?.string("standBy").nonBlank
            ?? "https://www.123pan.com/s/\(shareKey)"
        return Pan123ShareInfo(shareURL: url, passcode: sharePwd ?? "", shareKey: shareKey, title: shareName)
    }

    // MARK: Helpers

    /// `fileToken` packs "S3KeyFlag|Etag|StorageNode"; older tokens have two parts.
    static func decodeToken(_ token: String) -> (s3KeyFlag: String, etag: String, storageNode: String) {
        let parts = token.components(separatedBy: "|")
        return (parts.count > 0 ? parts[0] : "", parts.count > 1 ? parts[1] : "", parts.count > 2 ? parts[2] : "")
    }

    static func encodeToken(s3KeyFlag: String, etag: String, storageNode: String) -> String {
        "\(s3KeyFlag)|\(etag)|\(storageNode)"
    }

    /// S3KeyFlag looks like "1816216065-0"; the part before the dash is the mshare subdomain.
    static func shareId(of file: DriveFile) -> String {
        let s3 = file.fileToken.components(separatedBy: "|").first ?? ""
        return s3.components(separatedBy: "-").first ?? ""
    }

    /// Either a bare base64 string, or a download-v2 URL whose `params` is URL-safe base64.
    static func decodeDownloadURL(_ downloadURL: String) -> String? {
        let trimmed = downloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") {
            return decodeBase64(trimmed).flatMap { $0.lowercased().hasPrefix("http") ? $0 : nil }
        }
        guard let range = trimmed.range(of: "params=") else { return nil }
        let params = String(trimmed[range.upperBound...].prefix { $0 != "&" })
        return decodeBase64(params.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))
    }

    private static func decodeBase64(_ text: String) -> String? {
        var padded = text
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded).map { String(decoding: $0, as: UTF8.self) }
    }

    /// With `auto_redirect=0` the CDN answers a small JSON holding data.redirect_url, sometimes several times.
    /// Follows up to 5 hops; a large or non-JSON reply means the current URL is the file.
    private func followRedirect(_ initial: String) async -> String {
        var url = initial
        for _ in 0..<Pan123Constants.redirectHops {
            guard let next = await probeRedirect(url) else { return url }
            url = next
        }
        return url
    }

    private func probeRedirect(_ url: String) async -> String? {
        guard let parsed = URL(string: url) else { return nil }
        let headers = ["Referer": Pan123Constants.downloadReferer, "User-Agent": Pan123Constants.dartUserAgent]
        guard let data = await probe.smallBody(url: parsed, headers: headers),
              let text = String(data: data, encoding: .utf8),
              text.drop(while: \.isWhitespace).hasPrefix("{"),
              let json = LenientJSON(data: data) else { return nil }
        return json.child("data")?.string("redirect_url").nonBlank
    }

    private func parseInfoList(_ data: LenientJSON) -> [DriveFile] {
        data.objects("InfoList").map { item in
            DriveFile(id: item.string("FileId"), name: item.string("FileName"), size: item.int64("Size"),
                      isDirectory: item.int("Type") == 1, parentId: item.string("ParentFileId"),
                      fileToken: Self.encodeToken(s3KeyFlag: item.string("S3KeyFlag"), etag: item.string("Etag"), storageNode: item.string("StorageNode")),
                      modifiedAt: item.string("UpdateAt"))
        }
    }

    /// Success is `code == 0`; sign-in is the one exception.
    private func checkOk(_ json: LenientJSON, _ fallback: String) throws {
        let code = json.has("code") ? json.int("code") : -1
        if code == 0 { return }
        throw DriveError.api(message: "\(json.string("message").ifBlank(fallback))（code=\(code)）", code: code)
    }

    private func request(_ method: HTTPMethod, _ url: String, headers: [String: String], body: Data? = nil) throws -> HTTPRequest {
        guard let parsed = URL(string: url) else { throw DriveError.api(message: "请求地址无效") }
        return HTTPRequest(method: method, url: parsed, headers: headers, body: body)
    }

    private func jsonRequest(_ url: String, body: [String: Any], headers: [String: String]) throws -> HTTPRequest {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        var merged = headers
        merged["Content-Type"] = "application/json;charset=UTF-8"
        return try request(.post, url, headers: merged, body: data)
    }

    private func post(_ url: String, json: [String: Any], headers: [String: String]) async throws -> HTTPResponse {
        try await transport.send(try jsonRequest(url, body: json, headers: headers))
    }

    private func execute(_ request: HTTPRequest) async throws -> LenientJSON {
        let response = try await transport.send(request)
        if response.body.isEmpty, !(200..<300).contains(response.statusCode) {
            throw DriveError.api(message: "请求失败（HTTP \(response.statusCode)）")
        }
        guard let json = LenientJSON(data: response.body) else {
            throw DriveError.api(message: "响应解析失败（HTTP \(response.statusCode)）")
        }
        return json
    }

    private func getAuth(_ url: String, path: String, token: String) async throws -> LenientJSON {
        let sign = Pan123Sign.make(path: path, timestamp: now(), random: random())
        return try await execute(request(.get, url, headers: [
            "platform": Pan123Constants.platformWeb, "app-version": Pan123Constants.appVersionWeb,
            "authorization": "Bearer \(token)", "loginuuid": deviceId,
            "auth-key": sign.key, "auth-value": sign.value,
            "User-Agent": Pan123Constants.webUserAgent, "Accept": "application/json, text/plain, */*",
        ]))
    }

    private func postAuth(_ url: String, path: String, body: [String: Any], token: String,
                          platform: String = Pan123Constants.platformWeb, appVersion: String = Pan123Constants.appVersionWeb) async throws -> LenientJSON {
        let sign = Pan123Sign.make(path: path, timestamp: now(), random: random())
        return try await execute(try jsonRequest(url, body: body, headers: [
            "platform": platform, "app-version": appVersion,
            "authorization": "Bearer \(token)", "loginuuid": deviceId,
            "auth-key": sign.key, "auth-value": sign.value,
            "User-Agent": Pan123Constants.webUserAgent,
        ]))
    }
}
