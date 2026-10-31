// Ported from YunX-Desktop (AGPL-3.0): data/network/GuangYaApi.kt.
// Endpoints, bodies, headers, polling and error mapping follow that file. Kotlin IllegalStateException
// messages become DriveError.api; lookups that returned null there return nil here.
import Foundation

/// Business code 207: the sharer did not allow download without login. A logged-in user falls back to
/// "restore into a temporary folder, then fetch the link from the drive"; a guest must log in first.
public struct GuangYaShareRestrictedError: Error, Equatable, LocalizedError, Sendable {
    public var errorDescription: String? { "该光鸭分享需登录并转存后下载，请先登录光鸭云盘" }
}

public struct GuangYaDownloadLink: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let fid: String
    public let filename: String
    public let downloadURL: String
    public let size: Int64
    public var description: String { "GuangYaDownloadLink(\(fid), \(filename), <redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: ["fid": fid, "filename": filename, "size": size]) }
}

public struct GuangYaShareInfo: Sendable, Equatable {
    public let shareURL: String
    public let passcode: String
    public let shareId: String
    public let title: String
}

public actor GuangYaAPI {
    private let http: HTTPClient
    private let sleep: DriveSleeper
    private let now: @Sendable () -> Date
    private let credentialUpdated: CredentialUpdateHandler?
    /// Business requests always need `did`; guests use this stand-in, made once per API instance.
    private let publicDeviceId = GuangYaConstants.newDeviceId()
    /// Rotations this instance already made, keyed by the credential that was passed in, so a host that
    /// has not stored the update yet does not trigger a second refresh. Memory only.
    private var rotated: [String: GuangYaCredential] = [:]

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        credentialUpdated: CredentialUpdateHandler? = nil,
        sleep: @escaping DriveSleeper = { try await Task.sleep(nanoseconds: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        http = HTTPClient(transport: transport)
        self.sleep = sleep
        self.now = now
        self.credentialUpdated = credentialUpdated
    }

    private struct CaptchaRetry: Error {}
    private struct CaptchaInit { let token: String?; let url: String? }

    // MARK: Credential

    /// GuangYaAccountRepository.ensureAccessToken: use the access token while it has more than 60 s left,
    /// otherwise rotate it with the refresh token. Without a refresh token, or when the server refuses,
    /// the current access token is used as is.
    public func activeCredential(_ credential: DriveCredential) async throws -> GuangYaCredential {
        var current = rotated[credential.value] ?? GuangYaCredential(credential)
        let nowMillis = Int64(now().timeIntervalSince1970 * 1000)
        if !current.accessToken.isBlankText, current.accessExpiresAt > nowMillis + 60_000 { return current }
        if current.refreshToken.isBlankText { return current }
        let device = current.device ?? .make()
        guard let tokens = try await refreshToken(current.refreshToken, device: device) else { return current }
        current.accessToken = tokens.accessToken
        current.refreshToken = tokens.refreshToken.ifBlank(current.refreshToken)
        current.device = device
        current.accessExpiresAt = tokens.expiresIn > 0 ? nowMillis + tokens.expiresIn * 1000 : 0
        rotated[credential.value] = current
        credentialUpdated?(current.driveCredential, credential)
        return current
    }

    // MARK: Authentication

    private func initCaptcha(device: GuangYaDevice, meta: [String: Any], action: String) async throws -> CaptchaInit {
        let json = try await postAccount(GuangYaConstants.captchaInitURL, [
            "client_id": GuangYaConstants.clientId,
            "action": action,
            "device_id": device.deviceId,
            "captcha_token": "",
            "meta": meta,
        ], device: device)
        return CaptchaInit(token: json.string("captcha_token").nonBlank, url: json.string("url").nonBlank)
    }

    /// Password login. Retries only on captcha_required / captcha_invalid, at most twice.
    public func signIn(username: String, password: String, device: GuangYaDevice) async throws -> GuangYaTokens {
        let normalized = Self.normalizeAccount(username)
        let meta = Self.meta(for: normalized)
        var captcha = try await initCaptcha(device: device, meta: meta, action: "POST:/v1/auth/signin")
        var attempt = 0
        while true {
            do {
                return try await doSignIn(username: normalized, password: password, captchaToken: captcha.token, device: device)
            } catch is CaptchaRetry {
                if attempt >= 2 { throw DriveError.api(message: "光鸭安全验证未通过，请重试或切换网页登录") }
                attempt += 1
                captcha = try await initCaptcha(device: device, meta: meta, action: "POST:/v1/auth/signin")
            }
        }
    }

    private func doSignIn(username: String, password: String, captchaToken: String?, device: GuangYaDevice) async throws -> GuangYaTokens {
        var extra: [String: String] = [:]
        if let captchaToken, !captchaToken.isBlankText { extra["X-Captcha-Token"] = captchaToken }
        let json = try await postAccount(GuangYaConstants.signinURL, [
            "client_id": GuangYaConstants.clientId, "username": username, "password": password,
        ], device: device, extraHeaders: extra)
        let code = json.string("code"), error = json.string("error")
        if Self.isCaptchaFailure(code, error) { throw CaptchaRetry() }
        if !Self.isSuccess(json) { throw DriveError.api(message: Self.signinErrorMessage(json, error)) }
        return try Self.parseTokens(json, now: now())
    }

    /// Returns nil when the refresh token is no longer accepted.
    public func refreshToken(_ refreshToken: String, device: GuangYaDevice) async throws -> GuangYaTokens? {
        let json = try await postAccount(GuangYaConstants.authTokenURL, [
            "client_id": GuangYaConstants.clientId, "grant_type": "refresh_token", "refresh_token": refreshToken,
        ], device: device, extraHeaders: ["X-Action": "401"])
        return Self.isSuccess(json) ? try Self.parseTokens(json, now: now()) : nil
    }

    // MARK: SMS login and sign-up

    private static let phoneCaptchaMessage = "光鸭需要网页人机验证，请稍后重试或改用账号密码登录"

    public func sendSmsCode(phoneNumber: String, device: GuangYaDevice) async throws -> GuangYaSmsChallenge {
        let meta: [String: Any] = ["phone_number": phoneNumber]
        var captcha = try await initCaptcha(device: device, meta: meta, action: "POST:/v1/auth/verification")
        // A url means the check needs a web page, which this client cannot complete.
        if captcha.url?.isBlankText == false { throw DriveError.api(message: Self.phoneCaptchaMessage) }
        var attempt = 0
        while true {
            do {
                return try await doSendSmsCode(phoneNumber: phoneNumber, captchaToken: captcha.token, device: device)
            } catch is CaptchaRetry {
                if attempt >= 2 { throw DriveError.api(message: "光鸭安全验证未通过，请重试或改用账号密码登录") }
                attempt += 1
                captcha = try await initCaptcha(device: device, meta: meta, action: "POST:/v1/auth/verification")
                if captcha.url?.isBlankText == false { throw DriveError.api(message: Self.phoneCaptchaMessage) }
            }
        }
    }

    private func doSendSmsCode(phoneNumber: String, captchaToken: String?, device: GuangYaDevice) async throws -> GuangYaSmsChallenge {
        // The header is always sent, even empty: the server decides "no captcha" by its presence.
        let json = try await postAccount(GuangYaConstants.verificationURL, [
            "client_id": GuangYaConstants.clientId, "phone_number": phoneNumber, "target": "ANY",
        ], device: device, extraHeaders: ["X-Captcha-Token": captchaToken ?? ""])
        if Self.isCaptchaFailure(json.string("code"), json.string("error")) { throw CaptchaRetry() }
        try Self.ensureAccountSuccess(json, fallback: "发送验证码失败")
        let verificationId = Self.accountString(json, "verification_id")
        if verificationId.isBlankText { throw DriveError.api(message: "验证码请求过于频繁，请稍后重试") }
        return GuangYaSmsChallenge(verificationId: verificationId, isUser: Self.accountBool(json, "is_user"),
                                   expiresIn: min(max(Self.accountInt(json, "expires_in", 600), 1), 1800))
    }

    /// The code must match ^[0-9]{4,8}$. Returns the verification token.
    public func verifySmsCode(verificationId: String, code: String, device: GuangYaDevice) async throws -> String {
        let invalid = "短信验证码错误或已过期，请重新获取"
        guard code.range(of: "^[0-9]{4,8}$", options: .regularExpression) != nil else { throw DriveError.api(message: invalid) }
        let json = try await postAccount(GuangYaConstants.verificationVerifyURL, [
            "client_id": GuangYaConstants.clientId, "verification_id": verificationId, "verification_code": code,
        ], device: device)
        try Self.ensureAccountSuccess(json, fallback: invalid)
        let token = Self.accountString(json, "verification_token")
        if token.isBlankText { throw DriveError.api(message: invalid) }
        return token
    }

    /// Existing user.
    public func smsSignIn(phoneNumber: String, code: String, verificationToken: String, device: GuangYaDevice) async throws -> GuangYaTokens {
        let json = try await postAccount(GuangYaConstants.signinURL, [
            "client_id": GuangYaConstants.clientId, "username": phoneNumber,
            "verification_code": code, "verification_token": verificationToken,
        ], device: device)
        try Self.ensureAccountSuccess(json, fallback: "短信验证码错误或已过期，请重新获取")
        return try Self.parseTokens(json, now: now())
    }

    /// New user. `name` is the first 3 digits + **** + the last 4.
    public func smsSignUp(phoneNumber: String, name: String, code: String, verificationToken: String, device: GuangYaDevice) async throws -> GuangYaTokens {
        let json = try await postAccount(GuangYaConstants.signupURL, [
            "client_id": GuangYaConstants.clientId, "phone_number": phoneNumber, "name": name,
            "verification_code": code, "verification_token": verificationToken,
        ], device: device)
        try Self.ensureAccountSuccess(json, fallback: "短信验证码错误或已过期，请重新获取")
        return try Self.parseTokens(json, now: now())
    }

    // MARK: Account

    public func fetchAccountInfo(accessToken: String, device: GuangYaDevice) async -> GuangYaAccountInfo? {
        guard let json = try? await getAccount(GuangYaConstants.userMeURL, device: device, token: accessToken),
              Self.isSuccess(json) else { return nil }
        let userId = Self.firstNonBlank(json.string("sub"), json.string("user_id"), json.string("userId"))
        let nickname = Self.firstNonBlank(json.string("nickname"), json.string("nick_name"), json.string("name"), json.string("username"))
        return userId.isEmpty ? nil : GuangYaAccountInfo(userId: userId, nickname: nickname)
    }

    public func getQuota(accessToken: String, deviceId: String?) async -> DriveQuota? {
        guard let json = try? await postBusiness(GuangYaConstants.getAssetsURL, [:], deviceId: deviceId, token: accessToken),
              (try? Self.checkBusiness(json, "获取容量信息失败")) != nil,
              let data = Self.dataOf(json) else { return nil }
        let total = data.int64("totalSpaceSize")
        if total < 0 { return nil }
        return DriveQuota(used: data.int64("usedSpaceSize"), total: total)
    }

    // MARK: Shares

    public func getShareSummary(shareId: String) async -> String? {
        guard let json = try? await postBusiness(GuangYaConstants.shareSummaryURL, ["shareId": shareId], deviceId: nil, token: nil),
              (try? Self.checkBusiness(json, "获取分享信息失败")) != nil else { return nil }
        let data = Self.dataOf(json) ?? json
        return Self.firstNonBlank(data.string("title"), data.string("shareName")).nonBlank
    }

    /// Exchanges the passcode for the share access token. Code 209 means a wrong passcode.
    public func getShareAccessToken(shareId: String, code: String) async throws -> String {
        let json = try await postBusiness(GuangYaConstants.shareAccessTokenURL, ["shareId": shareId, "code": code], deviceId: nil, token: nil)
        try Self.checkBusiness(json, "获取分享访问令牌失败")
        guard let data = Self.dataOf(json) else { throw DriveError.api(message: "光鸭分享链接无效") }
        let token = Self.firstNonBlank(data.string("accessToken"), data.string("access_token"))
        if token.isEmpty { throw DriveError.api(message: "光鸭分享链接无效") }
        return token
    }

    /// Returns one page and the cursor of the next, or nil when there is no more.
    public func listShareFiles(accessToken: String, parentId: String, cursor: String?) async throws -> (files: [DriveFile], next: String?) {
        var body: [String: Any] = ["parentId": parentId, "pageSize": GuangYaConstants.pageSize, "orderBy": 0, "sortType": 0, "accessToken": accessToken]
        if let cursor, !cursor.isBlankText { body["cursor"] = cursor }
        let json = try await postBusiness(GuangYaConstants.shareFilesURL, body, deviceId: nil, token: nil)
        try Self.checkBusiness(json, "获取分享文件列表失败")
        guard let data = Self.dataOf(json) else { return ([], nil) }
        let files = Self.parseFileList(Self.listArray(data))
        let next = data.string("cursor").nonBlank
        return (files, data.bool("hasMore") ? next : nil)
    }

    /// Business code 207 throws `GuangYaShareRestrictedError`.
    public func getShareDownloadURL(file: DriveFile, accessToken: String) async throws -> GuangYaDownloadLink? {
        let json = try await postBusiness(GuangYaConstants.shareDownloadURL, ["fileId": file.id, "accessToken": accessToken], deviceId: nil, token: nil)
        if json.string("code") == "207" { throw GuangYaShareRestrictedError() }
        try Self.checkBusiness(json, "获取下载地址失败")
        return try Self.downloadLink(json, file: file)
    }

    /// `shareToken` goes in the body; `accountToken` is the Bearer. A returned task is waited for.
    public func restoreShare(accountToken: String, deviceId: String?, shareToken: String, fileIds: [String], parentId: String) async throws {
        let json = try await postBusiness(GuangYaConstants.restoreShareURL, ["accessToken": shareToken, "fileIds": fileIds, "parentId": parentId], deviceId: deviceId, token: accountToken)
        try Self.checkBusiness(json, "转存失败")
        if let taskId = Self.dataOf(json)?.string("taskId").nonBlank { try await waitTask(accessToken: accountToken, deviceId: deviceId, taskId: taskId) }
    }

    public func createShare(accessToken: String, deviceId: String?, fileIds: [String], title: String, expireDays: Int?, passcode: String?) async throws -> GuangYaShareInfo {
        let code = passcode ?? ""
        let json = try await postBusiness(GuangYaConstants.shareFileURL, [
            "fileIds": fileIds, "title": title, "validateDuration": expireDays ?? 0,
            "shareType": code.isBlankText ? 0 : 1, "code": code, "autoFillCode": false,
            "trafficLimit": "0", "maxRestoreCount": 0, "downloadType": 1,
        ], deviceId: deviceId, token: accessToken)
        try Self.checkBusiness(json, "创建分享失败")
        guard let data = Self.dataOf(json) else { throw DriveError.api(message: "创建分享失败") }
        let shareId = Self.firstNonBlank(data.string("shareId"), data.string("id"))
        var url = data.string("shareUrl")
        if url.isBlankText {
            if shareId.isEmpty { throw DriveError.api(message: "创建分享失败") }
            url = "\(GuangYaConstants.webSite)/s/\(shareId)"
        }
        return GuangYaShareInfo(shareURL: url, passcode: data.string("code").ifBlank(code), shareId: shareId, title: title)
    }

    // MARK: Own files

    /// Pages from 0 until the list ends, the total is reached or a page repeats.
    public func listCloudFiles(accessToken: String, deviceId: String?, parentId: String) async throws -> [DriveFile] {
        var all: [DriveFile] = []
        var seen = Set<String>()
        var page = 0
        while page < 1000 {
            let json = try await postBusiness(GuangYaConstants.fileListURL, [
                "parentId": parentId, "pageSize": GuangYaConstants.pageSize, "orderBy": 0, "sortType": 0, "page": page,
            ], deviceId: deviceId, token: accessToken)
            try Self.checkBusiness(json, "获取文件列表失败")
            guard let data = Self.dataOf(json) else { break }
            let list = Self.parseFileList(Self.listArray(data))
            if list.isEmpty { break }
            var added = 0
            for file in list where seen.insert(file.id).inserted {
                all.append(file)
                added += 1
            }
            if added == 0 { throw DriveError.api(message: "光鸭文件列表分页重复，请重试") }
            let total = data.int64("total")
            if total > 0, Int64(all.count) >= total { break }
            if total <= 0, list.count < GuangYaConstants.pageSize { break }
            page += 1
        }
        return all
    }

    public func createDir(accessToken: String, deviceId: String?, parentId: String, name: String) async throws -> String {
        let json = try await postBusiness(GuangYaConstants.createDirURL, ["parentId": parentId, "dirName": name, "failIfNameExist": true], deviceId: deviceId, token: accessToken)
        try Self.checkBusiness(json, "新建文件夹失败")
        let failure = DriveError.api(message: "光鸭未创建文件夹，请检查是否存在同名文件")
        guard let data = Self.dataOf(json) else { throw failure }
        let id = Self.firstNonBlank(data.string("fileId"), data.string("id"))
        if id.isEmpty || data.string("resType") == "1" { throw failure }
        return id
    }

    public func renameFile(accessToken: String, deviceId: String?, fileId: String, newName: String) async throws {
        try await runTask(GuangYaConstants.renameURL, ["fileId": fileId, "newName": newName], "重命名失败", accessToken, deviceId)
    }

    public func moveFiles(accessToken: String, deviceId: String?, fileIds: [String], parentId: String) async throws {
        try await runTask(GuangYaConstants.moveFileURL, ["fileIds": fileIds, "parentId": parentId], "移动失败", accessToken, deviceId)
    }

    public func deleteFiles(accessToken: String, deviceId: String?, fileIds: [String]) async throws {
        try await runTask(GuangYaConstants.deleteFileURL, ["fileIds": fileIds], "删除失败", accessToken, deviceId)
    }

    public func getDownloadLink(accessToken: String, deviceId: String?, file: DriveFile) async throws -> GuangYaDownloadLink? {
        let json = try await postBusiness(GuangYaConstants.resDownloadURL, ["fileId": file.id], deviceId: deviceId, token: accessToken)
        try Self.checkBusiness(json, "获取下载地址失败")
        return try Self.downloadLink(json, file: file)
    }

    /// Waits 750 ms, then polls up to 80 times: status 2 with detail.code 0 is done; status 3, or 2 with a
    /// non-zero detail.code, is a failure. A poll without data is retried at once.
    public func waitTask(accessToken: String, deviceId: String?, taskId: String) async throws {
        try await sleep(GuangYaConstants.taskDelayNanoseconds)
        for _ in 0..<GuangYaConstants.taskMaxPolls {
            let json = try await postBusiness(GuangYaConstants.taskStatusURL, ["taskId": taskId], deviceId: deviceId, token: accessToken)
            try Self.checkBusiness(json, "任务状态查询失败")
            guard let data = Self.dataOf(json) else { continue }
            let status = data.int("status")
            let detail = data.child("detail")
            let detailCode = detail?.int("code") ?? 0
            if status == 2, detailCode == 0 { return }
            if status == 3 || (status == 2 && detailCode != 0) {
                throw DriveError.api(message: (detail?.string("msg") ?? "").ifBlank("光鸭操作失败"))
            }
            try await sleep(GuangYaConstants.taskDelayNanoseconds)
        }
        throw DriveError.api(message: "光鸭操作仍在处理中，请稍后刷新列表确认结果")
    }

    private func runTask(_ url: String, _ body: [String: Any], _ fallback: String, _ token: String, _ deviceId: String?) async throws {
        let json = try await postBusiness(url, body, deviceId: deviceId, token: token)
        try Self.checkBusiness(json, fallback)
        if let taskId = Self.dataOf(json)?.string("taskId").nonBlank { try await waitTask(accessToken: token, deviceId: deviceId, taskId: taskId) }
    }

    // MARK: Requests

    private func postBusiness(_ url: String, _ body: [String: Any], deviceId: String?, token: String?) async throws -> LenientJSON {
        var headers = [
            "Accept": "application/json, text/plain, */*",
            "User-Agent": GuangYaConstants.webUserAgent,
            "Origin": GuangYaConstants.webSite,
            "Referer": GuangYaConstants.downloadReferer,
            "dt": "4",
            "traceparent": GuangYaConstants.newTraceparent(),
            "did": deviceId?.nonBlank ?? publicDeviceId,
        ]
        if let token, !token.isBlankText { headers["Authorization"] = "Bearer \(token)" }
        return try Self.parse(try await http.postJSON(url, json: body, headers: headers))
    }

    private func accountHeaders(device: GuangYaDevice, token: String?) -> [String: String] {
        let deviceId = GuangYaConstants.deviceId(fromSign: device.deviceSign, fallback: device.deviceId)
        var headers = [
            "X-Client-Id": GuangYaConstants.clientId,
            "X-Client-Version": GuangYaConstants.clientVersion,
            // X-Device-Id and X-Device-Sign are URL encoded.
            "X-Device-Id": HTTPClient.encodeQueryValue(deviceId),
            "X-Device-Model": GuangYaConstants.deviceModel,
            "X-Device-Name": GuangYaConstants.deviceName,
            "X-Device-Sign": HTTPClient.encodeQueryValue(device.deviceSign),
            "X-Os-Version": GuangYaConstants.osVersion,
            "X-Platform-Version": GuangYaConstants.platformVersion,
            "X-Protocol-Version": GuangYaConstants.protocolVersion,
            "X-Sdk-Version": GuangYaConstants.sdkVersion,
            "Accept": "application/json, text/plain, */*",
            "User-Agent": GuangYaConstants.webUserAgent,
        ]
        if let token, !token.isBlankText { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }

    private func postAccount(_ url: String, _ body: [String: Any], device: GuangYaDevice, extraHeaders: [String: String] = [:]) async throws -> LenientJSON {
        let headers = accountHeaders(device: device, token: nil).merging(extraHeaders) { _, new in new }
        return try Self.parse(try await http.postJSON(url, json: body, headers: headers))
    }

    private func getAccount(_ url: String, device: GuangYaDevice, token: String) async throws -> LenientJSON {
        try Self.parse(try await http.get(url, headers: accountHeaders(device: device, token: token)))
    }

    /// executeJson: an empty body is an error either way; a body that is not JSON is reported with its status.
    private static func parse(_ response: HTTPResponse) throws -> LenientJSON {
        if response.body.isEmpty || String(decoding: response.body, as: UTF8.self).isBlankText {
            if !(200..<300).contains(response.statusCode) { throw DriveError.api(message: "请求失败（HTTP \(response.statusCode)）") }
            throw DriveError.api(message: "请求失败：响应为空")
        }
        guard let json = LenientJSON(data: response.body) else {
            throw DriveError.api(message: "响应解析失败（HTTP \(response.statusCode)）")
        }
        return json
    }

    // MARK: Parsing

    private static func firstNonBlank(_ values: String...) -> String {
        values.first(where: { !$0.isBlankText })?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func dataOf(_ json: LenientJSON) -> LenientJSON? { json.child("data") }

    private static func isSuccess(_ json: LenientJSON) -> Bool {
        if json.has("success"), !json.bool("success") { return false }
        if !json.string("error").isBlankText { return false }
        let code = json.string("code")
        return code.isBlankText || code == "0"
    }

    private static func isCaptchaFailure(_ code: String, _ error: String) -> Bool {
        ["captcha_required", "captcha_invalid"].contains(code) || ["captcha_required", "captcha_invalid"].contains(error)
    }

    private static func checkBusiness(_ json: LenientJSON, _ fallback: String) throws {
        if isSuccess(json) { return }
        let code = json.string("code")
        let serverMessage = firstNonBlank(json.string("msg"), json.string("message"), json.string("error_description"))
        let mapped: String?
        switch code {
        case "209": mapped = "光鸭分享提取码错误或缺失"
        case "200", "201", "202": mapped = "光鸭分享已取消、过期或不可访问"
        case "205", "206", "207", "504": mapped = "光鸭分享下载受限，请在官网确认该分享的下载权限"
        case "157": mapped = "光鸭网盘空间不足"
        default: mapped = nil
        }
        throw DriveError.api(message: mapped ?? serverMessage.ifBlank("\(fallback)（code=\(code)）"), code: Int(code) ?? 0)
    }

    private static func signinErrorMessage(_ json: LenientJSON, _ error: String) -> String {
        let code = json.string("code").ifBlank(error)
        let serverMessage = firstNonBlank(json.string("msg"), json.string("message"), json.string("error_description"))
        switch code {
        case "too_many_requests": return "光鸭登录尝试过于频繁，请稍后重试"
        case "invalid_password", "invalid_account_or_password", "invalid_credentials", "unauthenticated", "user_not_found":
            return "光鸭账号或密码不正确，请检查后重试"
        case "password_required", "password_not_set": return "该光鸭账号尚未设置密码，请切换网页登录"
        case "verification_required", "verification_code_required": return "光鸭需要短信验证，请切换网页登录继续"
        default: return serverMessage.ifBlank("光鸭登录失败，请检查账号密码，或切换网页登录")
        }
    }

    /// Account fields sit at the top level or under data; both shapes have been seen.
    private static func accountNode(_ json: LenientJSON) -> LenientJSON { json.child("data") ?? json }

    private static func accountString(_ json: LenientJSON, _ key: String) -> String {
        let nested = accountNode(json).string(key)
        if !nested.isBlankText { return nested }
        return json.child("data") != nil ? json.string(key) : ""
    }

    private static func accountBool(_ json: LenientJSON, _ key: String) -> Bool {
        let node = accountNode(json)
        return node.has(key) ? node.bool(key) : json.bool(key)
    }

    private static func accountInt(_ json: LenientJSON, _ key: String, _ fallback: Int) -> Int {
        Int(accountNode(json).string(key)) ?? Int(json.string(key)) ?? fallback
    }

    private static func ensureAccountSuccess(_ json: LenientJSON, fallback: String) throws {
        if isSuccess(json) { return }
        let code = json.string("code").ifBlank(json.string("error"))
        let serverMessage = firstNonBlank(json.string("msg"), json.string("message"), json.string("error_description"))
        let lower = code.lowercased()
        let mapped: String
        if serverMessage.lowercased().contains("captcha") || lower.contains("captcha") {
            mapped = "光鸭安全验证未通过，请重试或改用账号密码登录"
        } else if lower.contains("frequent") || code == "429" || serverMessage.contains("频繁") {
            mapped = "验证码请求过于频繁，请稍后重试"
        } else if lower.contains("verification") || lower.contains("code") || serverMessage.contains("验证码") {
            mapped = "短信验证码错误或已过期，请重新获取"
        } else {
            mapped = serverMessage.ifBlank(fallback)
        }
        throw DriveError.api(message: mapped)
    }

    private static func parseTokens(_ json: LenientJSON, now: Date) throws -> GuangYaTokens {
        let data = json.child("data") ?? json
        let access = firstNonBlank(data.string("access_token"), data.string("accessToken"))
        if access.isEmpty { throw DriveError.api(message: "光鸭登录失败，请检查账号密码，或切换网页登录") }
        let refresh = firstNonBlank(data.string("refresh_token"), data.string("refreshToken"))
        return GuangYaTokens(accessToken: access, refreshToken: refresh, expiresIn: expiresInSeconds(data, now: now))
    }

    /// Prefers expires_in; otherwise derives it from an absolute expire_time / expires_at (milliseconds or seconds).
    private static func expiresInSeconds(_ data: LenientJSON, now: Date) -> Int64 {
        let cap: Int64 = 31_536_000
        let direct = data.int64("expires_in")
        if direct > 0 { return min(direct, cap) }
        let absolute = data.has("expire_time") ? data.int64("expire_time") : data.int64("expires_at")
        if absolute <= 0 { return 0 }
        // Above 1e12 it is a millisecond timestamp, else seconds.
        let millis = absolute > 1_000_000_000_000 ? absolute : absolute * 1000
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        return min(max((millis - nowMillis) / 1000, 0), cap)
    }

    /// 11 digits become "+86 xxx"; a "+86" prefix is normalised; anything else is left alone.
    public static func normalizeAccount(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return text }
        let digits = text.filter(\.isNumber)
        if text.hasPrefix("+86") {
            return "+86 " + (digits.hasPrefix("86") ? String(digits.dropFirst(2)) : digits)
        }
        if text.count == 11, text.allSatisfy(\.isNumber) { return "+86 \(text)" }
        return text
    }

    private static func meta(for account: String) -> [String: Any] {
        if account.hasPrefix("+") { return ["phone_number": account] }
        if account.contains("@") { return ["email": account] }
        return ["username": account]
    }

    /// The array field is named list, items, files, records or content depending on the endpoint.
    private static func listArray(_ data: LenientJSON) -> [Any]? {
        for key in ["list", "items", "files", "records", "content"] {
            if let array = data.array(key) { return array }
        }
        return nil
    }

    private static func parseFileList(_ array: [Any]?) -> [DriveFile] {
        (array ?? []).compactMap { ($0 as? [String: Any]).map { parseFile(LenientJSON($0)) } }
    }

    private static func parseFile(_ item: LenientJSON) -> DriveFile {
        let id = firstNonBlank(item.string("fileId"), item.string("file_id"), item.string("id"), item.string("resId"), item.string("resourceId"))
        let name = firstNonBlank(item.string("fileName"), item.string("name"), item.string("filename"), item.string("dirName"), item.string("title"))
        let size = Int64(firstNonBlank(item.string("fileSize"), item.string("size"), item.string("file_size"))) ?? 0
        let dirType = item.string("dirType")
        let folderWords: Set<String> = ["folder", "dir", "directory", "0"]
        let isDirectory: Bool
        switch item.string("resType") {
        case "2": isDirectory = true
        case "1": isDirectory = false
        default:
            isDirectory = item.bool("isDir") || item.bool("isdir") || item.bool("dir") || item.bool("isFolder") || item.bool("folder")
                || !item.string("dirName").isBlankText
                || folderWords.contains(item.string("type").lowercased())
                || folderWords.contains(item.string("fileType").lowercased())
                || (!name.contains(".") && dirType == "1")
        }
        let parent = firstNonBlank(item.string("parentId"), item.string("parentFileId"), item.string("parent_id"))
        let time = firstNonBlank(item.string("updatedAt"), item.string("updateAt"), item.string("updated_at"), item.string("updateTime"),
                                 item.string("mtime"), item.string("utime"), item.string("createdAt"), item.string("createTime"), item.string("ctime"))
        return DriveFile(id: id, name: name, size: size, isDirectory: isDirectory, parentId: parent, fileToken: "", modifiedAt: time)
    }

    private static func downloadLink(_ json: LenientJSON, file: DriveFile) throws -> GuangYaDownloadLink? {
        guard let data = dataOf(json) else { return nil }
        let url = firstNonBlank(data.string("signedURL"), data.string("signedUrl"), data.string("downloadUrl"),
                                data.string("download_url"), data.string("url"), data.string("cdnUrl"))
        if url.isEmpty { throw DriveError.api(message: "光鸭未返回有效下载地址，请确认下载权限") }
        return GuangYaDownloadLink(fid: file.id, filename: file.name, downloadURL: url, size: Int64(data.string("size")) ?? file.size)
    }
}
