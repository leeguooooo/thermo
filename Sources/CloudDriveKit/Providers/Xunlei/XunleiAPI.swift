// Ported from YunX-Desktop (MIT): data/network/XunleiApi.kt, with the account flow from
// repository/XunleiAccountRepository.kt and the resolve flow from repository/XunleiResolveRepository.kt.
// Endpoints, parameters, signing and error handling follow those files.
//
// Differences from the source, all because credentials arrive with each call here:
// - there is no process-wide current token or user id; the user id comes from the JWT of the credential
//   in use, and a refreshed token is used for the retry and reported through `credentialUpdated`;
// - the headless-browser fallback for a rejected web signature is not available, so that case fails
//   with a re-login message;
// - rename (PATCH) is not ported, because the shared HTTP core has no PATCH method.
import Foundation

public struct XunleiShareResult: Sendable, Equatable {
    public let title: String
    public let files: [DriveFile]
    public let passCodeToken: String
    public let shareId: String
    public let nextPageToken: String
}

public struct XunleiFilePage: Sendable, Equatable {
    public let files: [DriveFile]
    public let nextPageToken: String
}

public struct XunleiDownloadLink: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let fid: String
    public let filename: String
    public let downloadURL: String
    public let size: Int64
    public var description: String { "XunleiDownloadLink(\(fid), \(filename), <redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: ["fid": fid, "filename": filename, "size": size]) }
}

public struct XunleiShareInfo: Sendable, Equatable {
    public let shareURL: String
    public let passcode: String
    public let shareId: String
    public let title: String
}

/// One step of the password or SMS login.
public struct XunleiLoginStep: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public var needSMS = false
    public var smsCreditKey = ""
    public var smsToken = ""
    /// The `sessionID` that `exchangeToken` turns into an access token.
    public var sessionId = ""
    public var nickname = ""
    public var userId = ""
    public var reviewURL = ""
    public var message = ""
    public var description: String { "XunleiLoginStep(needSMS: \(needSMS), \(message), <redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: ["needSMS": needSMS, "message": message]) }
}

public struct XunleiTokenPair: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let accessToken: String
    public let refreshToken: String
    public var description: String { "XunleiTokenPair(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// A captcha token with the time it stops being usable. A cached dead token would cost a failed
/// request on every call.
struct PanCaptcha: Sendable, Equatable {
    let token: String
    let expiresAt: Date
    func isValid(at now: Date) -> Bool { !token.isEmpty && expiresAt > now }
}

enum WebCaptchaInit {
    case ok(PanCaptcha)
    /// The client id was wrong. Another session would not help.
    case clientIDMismatch
    case failed
}

public actor XunleiAPI {
    private let transport: any HTTPTransport
    private let sleep: DriveSleeper
    private let now: @Sendable () -> Date
    private let credentialUpdated: CredentialUpdateHandler?

    /// Captchas by device id: accounts, and the app and web channels, must not share one.
    private var captchas: [String: PanCaptcha] = [:]
    /// Credentials this instance refreshed, by the access token they replaced, so later calls with the
    /// old value use the new one. The host still has to store what `credentialUpdated` reports.
    private var rotated: [String: XunleiCredential] = [:]
    /// Share passcodes by share id. A root listing needs the passcode again, and `ShareSession` only
    /// carries the pass_code_token. In memory only.
    private var passcodes: [String: String] = [:]
    private var fallbackDeviceId: String?

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        credentialUpdated: CredentialUpdateHandler? = nil,
        sleep: @escaping DriveSleeper = { try await Task.sleep(nanoseconds: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.credentialUpdated = credentialUpdated
        self.sleep = sleep
        self.now = now
    }

    // MARK: Login

    /// Captcha shield init for the login chain. Returns nil on any failure.
    public func initCaptcha(device: XunleiDevice, username: String, userId: String = "") async -> String? {
        let timestamp = String(Int64(now().timeIntervalSince1970 * 1000))
        let sign = XunleiSigner.appCaptchaSign(deviceId: device.deviceId, timestampMs: timestamp)
        let body: [String: Any] = [
            "action": "POST:/auth/signin/token",
            "captcha_token": "",
            "client_id": XunleiConstants.appClientID,
            "device_id": device.deviceId,
            "meta": [
                "username": username,
                "client_version": XunleiConstants.appClientVersion,
                "package_name": XunleiConstants.appPackageName,
                "timestamp": timestamp,
                "captcha_sign": sign,
                // An empty user_id yields a degraded token.
                "user_id": userId,
            ],
            "redirect_uri": XunleiConstants.captchaRedirectURI,
        ]
        return await requestCaptchaToken(body, headers: appHeaders(deviceId: device.deviceId))
    }

    /// First sign-in with a password. A new client always gets review_panel (1007) and must verify by SMS.
    public func loginWithPassword(username: String, password: String, device: XunleiDevice, checkCode: String = "") async throws -> XunleiLoginStep {
        var body = loginBody(device: device, clientVersion: "25.0.5.25", sdkVersion: "513006")
        body["userName"] = username
        body["passWord"] = password
        body["verifyKey"] = ""
        body["verifyCode"] = checkCode
        body["isMd5Pwd"] = "0"
        let json = try await loginCall(XunleiConstants.loginURL, body: body, userAgent: XunleiConstants.sdkLoginUserAgent)
        return Self.parseLogin(json)
    }

    public func sendSMS(mobile: String, device: XunleiDevice) async throws -> XunleiLoginStep {
        var body = loginBody(device: device, clientVersion: XunleiConstants.appClientVersion, sdkVersion: "231500")
        body["mobile"] = mobile
        body["register"] = "0"
        let json = try await loginCall(XunleiConstants.sendSMSURL, body: body, userAgent: XunleiConstants.sdkSMSUserAgent)
        var step = XunleiLoginStep()
        step.needSMS = true
        step.smsCreditKey = json.string("creditkey")
        step.smsToken = json.string("token")
        step.message = json.string("errorDesc").ifBlank("短信已发送")
        return step
    }

    public func smsLogin(mobile: String, smsCode: String, creditKey: String, smsToken: String, device: XunleiDevice) async throws -> XunleiLoginStep {
        var body = loginBody(device: device, clientVersion: XunleiConstants.appClientVersion, sdkVersion: "231500", creditKey: creditKey)
        body["mobile"] = mobile
        body["smsCode"] = smsCode
        body["token"] = smsToken
        body["register"] = "0"
        let json = try await loginCall(XunleiConstants.smsLoginURL, body: body, userAgent: XunleiConstants.sdkSMSUserAgent)
        return Self.parseLogin(json)
    }

    /// Trades a login `sessionID` for tokens. Needs the captcha token from `initCaptcha`, in that order:
    /// login, captcha init, token.
    public func exchangeToken(sessionId: String, device: XunleiDevice, captchaToken: String) async -> XunleiTokenPair? {
        var headers = appHeaders(deviceId: device.deviceId)
        if !captchaToken.isEmpty { headers["X-Captcha-Token"] = captchaToken }
        let body: [String: Any] = [
            "client_id": XunleiConstants.appClientID,
            "client_secret": XunleiConstants.appClientSecret,
            "provider": "access_end_point_token",
            "signin_token": sessionId,
        ]
        guard let response = try? await send(.post, XunleiConstants.tokenURL, headers: headers, body: Self.jsonData(body)) else { return nil }
        return Self.tokens(in: response)
    }

    /// Exchanges a refresh token. A web token only refreshes through the web client, as JSON, without a
    /// client secret and with desktop browser headers; an app token uses the app client as a form.
    public func refreshToken(_ refreshToken: String, deviceId: String, authType: String = "") async -> XunleiTokenPair? {
        let request: (headers: [String: String], body: Data)
        if authType == XunleiWebAuth.authType {
            request = ([
                "Content-Type": "application/json",
                "X-Device-Id": deviceId,
                "X-Client-Id": XunleiWebAuth.clientID,
                "Origin": XunleiConstants.panOrigin,
                "Referer": "\(XunleiConstants.panOrigin)/",
                "User-Agent": XunleiWebAuth.desktopUserAgent,
                "Sec-Ch-Ua": XunleiWebAuth.desktopSecChUA,
                "Sec-Ch-Ua-Mobile": XunleiWebAuth.desktopSecChUAMobile,
                "Sec-Ch-Ua-Platform": XunleiWebAuth.desktopSecChUAPlatform,
            ], Self.jsonData(["grant_type": "refresh_token", "client_id": XunleiWebAuth.clientID, "refresh_token": refreshToken]))
        } else {
            let form = "grant_type=refresh_token&client_id=\(XunleiConstants.appClientID)"
                + "&client_secret=\(XunleiConstants.appClientSecret)&refresh_token=\(HTTPClient.encodeQueryValue(refreshToken))"
            request = (["Content-Type": "application/x-www-form-urlencoded", "X-Device-Id": deviceId], Data(form.utf8))
        }
        guard let response = try? await send(.post, XunleiConstants.refreshURL, headers: request.headers, body: request.body) else { return nil }
        return Self.tokens(in: response)
    }

    /// Calls the drive's `about` endpoint with exactly this token. A web login page writes half-finished
    /// state into localStorage, so only a working call counts as logged in. Network errors are false.
    public func verifyAccessToken(_ accessToken: String, deviceId: String, captchaToken: String) async -> Bool {
        guard !accessToken.isEmpty else { return false }
        let headers = panHeaders(token: accessToken, deviceId: deviceId, captcha: captchaToken)
        guard let response = try? await send(.get, XunleiConstants.aboutURL, headers: headers, body: nil),
              (200..<300).contains(response.statusCode) else { return false }
        let json = LenientJSON(data: response.body)
        // The app channel wraps the result in `data`; the web channel answers at the top level.
        return json?.child("data") != nil || json?.string("kind") == "drive#about"
    }

    /// Checks a stored credential, using a newer one this instance already refreshed.
    public func verify(_ credential: XunleiCredential) async -> Bool {
        let current = resolve(credential)
        return await verifyAccessToken(current.accessToken, deviceId: deviceId(for: current), captchaToken: current.captchaToken)
    }

    /// Refreshes a credential and reports it through `credentialUpdated`. Nil when there is no refresh
    /// token or the exchange failed, in which case the old credential stands.
    public func refresh(_ credential: XunleiCredential) async -> XunleiCredential? {
        let current = resolve(credential)
        guard !current.refreshToken.isEmpty,
              let pair = await refreshToken(current.refreshToken, deviceId: deviceId(for: current), authType: current.authType),
              !pair.accessToken.isEmpty else { return nil }
        var updated = current
        updated.accessToken = pair.accessToken
        // A response without a new refresh token keeps the old one.
        updated.refreshToken = pair.refreshToken.nonBlank ?? current.refreshToken
        rotated[current.accessToken] = updated
        if credential.accessToken != current.accessToken { rotated[credential.accessToken] = updated }
        credentialUpdated?(updated.driveCredential, credential.driveCredential)
        return updated
    }

    // MARK: Own files

    public func getQuota(credential: XunleiCredential) async -> DriveQuota? {
        try? await panCall(credential, action: "GET:/drive/v1/about", request: { .get(XunleiConstants.aboutURL, $0) }) { data in
            let quota = data.child("quota")
            return DriveQuota(used: quota?.int64("usage") ?? 0, total: quota?.int64("limit") ?? 0)
        }
    }

    /// One page of a directory; an empty `parentId` is the root.
    public func getFiles(parentId: String, pageToken: String = "", credential: XunleiCredential) async throws -> XunleiFilePage {
        let filters = HTTPClient.encodeQueryValue(#"{"trashed":{"eq":false}}"#)
        let url = "\(XunleiConstants.filesURL)?parent_id=\(parentId)&page_token=\(HTTPClient.encodeQueryValue(pageToken))&limit=50&with_audit=true&filters=\(filters)"
        return try await panCall(credential, action: "GET:/drive/v1/files", request: { .get(url, $0) }) { data in
            XunleiFilePage(files: Self.files(data), nextPageToken: data.string("next_page_token"))
        }
    }

    /// New folder id.
    public func createFolder(name: String, parentId: String, credential: XunleiCredential) async throws -> String {
        // `space` must be a string; a number is rejected with 400.
        let body: [String: Any] = ["kind": "drive#folder", "name": name, "parent_id": parentId, "space": ""]
        let id = try await panCall(credential, action: "POST:/drive/v1/files", request: { .post(XunleiConstants.filesURL, $0, body) }) { $0.string("id").nonBlank }
        guard let id else { throw DriveError.api(message: "创建临时目录失败") }
        return id
    }

    public func getFileDetail(fileId: String, credential: XunleiCredential) async throws -> XunleiDownloadLink {
        let url = "\(XunleiConstants.filesURL)/\(fileId)?_magic=2021&usage=PLAY&thumbnail_size=SIZE_LARGE&with=hdr10&with=subtitle_files&with=task&with=public_share_tag"
        return try await panCall(credential, action: "GET:/drive/v1/files/\(fileId)", request: { .get(url, $0) }) { data in
            let direct = data.child("links")?.child("application/octet-stream")?.string("url").nonBlank
            return XunleiDownloadLink(fid: data.string("id"), filename: data.string("name"),
                                      downloadURL: direct ?? data.string("web_content_link"), size: data.int64("size"))
        }
    }

    /// Moves files; returns the task id.
    public func moveFiles(fileIds: [String], toParentId: String, credential: XunleiCredential) async throws -> String? {
        let body: [String: Any] = ["ids": fileIds, "to": ["parent_id": toParentId, "space": ""], "space": ""]
        return try await panCall(credential, action: "POST:/drive/v1/files:batchMove", request: { .post(XunleiConstants.moveURL, $0, body) }) { $0.string("task_id").nonBlank }
    }

    /// Moves files to the trash.
    @discardableResult
    public func deleteFiles(fileIds: [String], credential: XunleiCredential) async throws -> Bool {
        let body: [String: Any] = ["ids": fileIds, "space": ""]
        return try await panCall(credential, action: "POST:/drive/v1/files:batchTrash", request: { .post(XunleiConstants.trashURL, $0, body) }) { _ in true }
    }

    /// Finds or creates the temporary save directory in the account root. Looks at the first page only,
    /// as the source does.
    public func ensureTempDirectory(credential: XunleiCredential) async throws -> String {
        let root = try await getFiles(parentId: XunleiConstants.rootDirectoryId, credential: credential)
        if let existing = root.files.first(where: { $0.isDirectory && $0.name == XunleiConstants.tempDirectoryName }) { return existing.id }
        return try await createFolder(name: XunleiConstants.tempDirectoryName, parentId: XunleiConstants.rootDirectoryId, credential: credential)
    }

    /// `expirationDays`: "-1" for permanent, or "1", "7", "30". An empty `passCode` lets the server pick one.
    public func createShare(fileIds: [String], title: String, expirationDays: String, passCode: String = "", credential: XunleiCredential) async throws -> XunleiShareInfo {
        var params: [String: Any] = ["subscribe_push": "false", "WithPassCodeInLink": "true", "with_pass_code_in_link": "true"]
        if !passCode.isBlankText { params["pass_code"] = passCode }
        let body: [String: Any] = [
            "file_ids": fileIds, "share_to": "copy", "params": params,
            "title": title.ifBlank("分享文件"), "restore_limit": "-1", "expiration_days": expirationDays,
        ]
        return try await panCall(credential, action: "POST:/drive/v1/share", request: { .post(XunleiConstants.shareCreateURL, $0, body) }) { data in
            XunleiShareInfo(shareURL: data.string("share_url"), passcode: data.string("pass_code"),
                            shareId: data.string("share_id"), title: data.string("title").ifBlank(title))
        }
    }

    // MARK: Shares

    /// Opens a share. Without a credential the call is anonymous: no Authorization header and no captcha,
    /// because a stale bearer token gets an anonymous request rejected.
    public func getShare(shareId: String, passCode: String, pageToken: String = "", credential: XunleiCredential?) async throws -> XunleiShareResult {
        passcodes[shareId] = passCode
        let url = "\(XunleiConstants.shareURL)?share_id=\(shareId)&pass_code=\(HTTPClient.encodeQueryValue(passCode))"
            + "&limit=100&page_token=\(HTTPClient.encodeQueryValue(pageToken))&thumbnail_size=SIZE_SMALL"
        return try await panCall(credential, action: "GET:/drive/v1/share", request: { .get(url, $0) }) { data in
            // These three come back as HTTP 200 with no files, which would read as an empty folder.
            switch data.string("share_status") {
            case "PASS_CODE_EMPTY": throw DriveError.api(message: "请输入提取码")
            case "PASS_CODE_ERROR": throw DriveError.api(message: "提取码错误")
            case "PASS_CODE_NEED": throw DriveError.api(message: "该分享需要提取码")
            default: break
            }
            return XunleiShareResult(title: data.string("title"), files: Self.files(data), passCodeToken: data.string("pass_code_token"),
                                     shareId: shareId, nextPageToken: data.string("next_page_token"))
        }
    }

    /// The passcode given to `getShare` for this share, if any.
    public func passcode(forShare shareId: String) -> String { passcodes[shareId] ?? "" }

    public func getShareDetail(shareId: String, parentId: String, passCodeToken: String, pageToken: String = "", credential: XunleiCredential?) async throws -> XunleiFilePage {
        let url = "\(XunleiConstants.shareDetailURL)?share_id=\(shareId)&parent_id=\(parentId)"
            + "&pass_code_token=\(HTTPClient.encodeQueryValue(passCodeToken))"
            + "&limit=100&page_token=\(HTTPClient.encodeQueryValue(pageToken))&thumbnail_size=SIZE_SMALL"
        return try await panCall(credential, action: "GET:/drive/v1/share/detail", request: { .get(url, $0) }) { data in
            XunleiFilePage(files: Self.files(data), nextPageToken: data.string("next_page_token"))
        }
    }

    /// Saves shared files into a directory. The answer is synchronous: `params.trace_file_ids` maps each
    /// shared id to its new id. Returns the new id of the first requested file that appears there.
    public func restore(shareId: String, passCodeToken: String, parentFolderId: String, fileIds: [String], credential: XunleiCredential) async throws -> String? {
        let body: [String: Any] = [
            "share_id": shareId, "pass_code_token": passCodeToken, "parent_id": parentFolderId,
            "ancestor_ids": [String](), "file_ids": fileIds, "specify_parent_id": true,
        ]
        return try await panCall(credential, action: "POST:/drive/v1/share/restore", request: { .post(XunleiConstants.restoreURL, $0, body) }) { data in
            // trace_file_ids is a JSON object carried inside a string.
            let trace = data.child("params")?.string("trace_file_ids") ?? ""
            if let map = LenientJSON(data: Data(trace.utf8)),
               let key = fileIds.first(where: { map.has($0) }),
               let mapped = map.string(key).nonBlank { return mapped }
            return data.string("file_id").nonBlank
        }
    }

    /// Polls a task up to 15 times, one second apart. Not used by the save path, which is synchronous.
    public func pollTask(taskId: String, credential: XunleiCredential) async -> Bool {
        let url = "\(XunleiConstants.tasksURL)/\(taskId)?type=share"
        for _ in 0..<15 {
            let done = (try? await panCall(credential, action: "GET:/drive/v1/tasks/\(taskId)", request: { .get(url, $0) }) { data in
                let status = data.string("status").ifBlank(data.string("phase"))
                return status == "PHASE_TYPE_COMPLETE" || data.int("error_code") == 0
            }) ?? false
            if done { return true }
            try? await sleep(1_000_000_000)
        }
        return false
    }

    // MARK: Share passwords

    /// Share link with passcode for a Chinese share password. Needs no account.
    public func parseKouling(_ keyword: String) async throws -> String {
        let headers = ["User-Agent": XunleiKouling.userAgent, "Accept": "*/*", "Origin": XunleiKouling.origin,
                       "Referer": XunleiKouling.referer, "Accept-Language": "zh-CN"]
        let response = try await send(.get, XunleiKouling.jumpURL(keyword), headers: headers, body: nil)
        guard (200..<300).contains(response.statusCode) else { throw DriveError.api(message: "口令解析失败（HTTP \(response.statusCode)）") }
        guard let json = LenientJSON(data: response.body) else { throw DriveError.api(message: "口令解析失败：响应格式异常") }
        let none = DriveError.api(message: "口令「\(keyword)」没有对应的网盘分享")
        guard json.child("ext")?.string("kouling_type") == "share_page",
              let link = XunleiKouling.shareURL(fromLocation: json.string("location")) else { throw none }
        return link
    }

    // MARK: Request plumbing

    enum PanRequest {
        case get(String, [String: String])
        case post(String, [String: String], [String: Any])
    }

    private func panHeaders(token: String?, deviceId: String, captcha: String) -> [String: String] {
        var headers = [
            "User-Agent": XunleiConstants.webUserAgent,
            "X-Device-Id": deviceId,
            "X-Client-Version": XunleiConstants.appClientVersion,
            "Content-Type": "application/json",
            "Origin": XunleiConstants.panOrigin,
            "Referer": "\(XunleiConstants.panOrigin)/",
        ]
        if let token, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        if !captcha.isEmpty { headers["X-Captcha-Token"] = captcha }
        return headers
    }

    private func appHeaders(deviceId: String) -> [String: String] {
        ["User-Agent": XunleiConstants.appUserAgent, "Accept": "application/json;charset=UTF-8", "Content-Type": "application/json",
         "X-Client-Id": XunleiConstants.appClientID, "X-Device-Id": deviceId, "X-Client-Version": XunleiConstants.appClientVersion]
    }

    private func send(_ method: HTTPMethod, _ url: String, headers: [String: String], body: Data?) async throws -> HTTPResponse {
        guard let parsed = URL(string: url) else { throw DriveError.api(message: "请求地址无效") }
        return try await transport.send(HTTPRequest(method: method, url: parsed, headers: headers, body: body))
    }

    static func jsonData(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Issues a pan request and retries once. On 401 it refreshes the token, then gets a new captcha; on
    /// captcha_invalid it gets a new captcha. A nil credential is the anonymous path with no retry.
    private func panCall<T>(
        _ credential: XunleiCredential?,
        action: String,
        request build: (_ headers: [String: String]) -> PanRequest,
        parse: (LenientJSON) throws -> T
    ) async throws -> T {
        var account = try await freshened(credential)
        let device = account.map { deviceId(for: $0) } ?? guestDeviceId()
        var captcha = ""
        if let current = account {
            // A cached token that has expired is never reused: it would fail once per call.
            if let cached = captchas[device], cached.isValid(at: now()) { captcha = cached.token }
            else if let fresh = try await webCaptcha(current, deviceId: device, action: action) { captchas[device] = fresh; captcha = fresh.token }
            else { captcha = current.captchaToken }
        }
        for attempt in 0..<2 {
            let headers = panHeaders(token: account?.accessToken, deviceId: device, captcha: captcha)
            let response: HTTPResponse
            switch build(headers) {
            case .get(let url, let headers): response = try await send(.get, url, headers: headers, body: nil)
            case .post(let url, let headers, let body): response = try await send(.post, url, headers: headers, body: Self.jsonData(body))
            }
            guard let json = LenientJSON(data: response.body) else {
                throw DriveError.api(message: "响应解析失败（HTTP \(response.statusCode)）")
            }
            if (200..<300).contains(response.statusCode), !json.has("error") {
                return try parse(json.child("data") ?? json)
            }
            let error = json.string("error")
            if let current = account, attempt == 0 {
                if response.statusCode == 401 || error == "unauthenticated", let refreshed = await refresh(current) {
                    account = refreshed
                    if let next = try await newCaptcha(refreshed, deviceId: device, action: action, oldToken: captcha) {
                        captchas[device] = next
                        captcha = next.token
                    }
                    continue
                }
                if error == "captcha_invalid" {
                    // Without the right client id even a web session could not recover, so stop here.
                    if String(decoding: response.body, as: UTF8.self).contains("client_id not match") {
                        throw DriveError.api(message: "验证码与当前登录方式不匹配，请重新登录迅雷网页版")
                    }
                    if let next = try await newCaptcha(current, deviceId: device, action: action, oldToken: captcha) {
                        captchas[device] = next
                        captcha = next.token
                        continue
                    }
                }
            }
            let message = json.string("error_description").ifBlank(json.string("message")).ifBlank(error).ifBlank("请求失败")
            throw DriveError.api(message: message)
        }
        throw DriveError.api(message: "验证码刷新后仍失败")
    }

    /// Web accounts sign locally; app accounts re-sign through the app channel.
    private func newCaptcha(_ account: XunleiCredential, deviceId: String, action: String, oldToken: String) async throws -> PanCaptcha? {
        if let web = try await webCaptcha(account, deviceId: deviceId, action: action) { return web }
        guard let token = await initPanCaptcha(account, deviceId: deviceId, action: action, oldToken: oldToken) else { return nil }
        return PanCaptcha(token: token, expiresAt: .distantFuture)
    }

    /// Nil for app accounts. The source falls back to a headless browser session when the signature is
    /// rejected; that is not available here, so the user has to log in again.
    private func webCaptcha(_ account: XunleiCredential, deviceId: String, action: String) async throws -> PanCaptcha? {
        guard account.isWeb else { return nil }
        switch await initWebCaptcha(deviceId: deviceId, action: action, userId: account.effectiveUserId) {
        case .ok(let captcha): return captcha
        case .clientIDMismatch: throw DriveError.api(message: "验证码与当前登录方式不匹配，请重新登录迅雷网页版")
        case .failed: throw DriveError.api(message: "迅雷网页登录已过期，请在迅雷登录页重新登录")
        }
    }

    func initWebCaptcha(deviceId: String, action: String, userId: String) async -> WebCaptchaInit {
        let timestamp = Int64(now().timeIntervalSince1970 * 1000)
        let body: [String: Any] = [
            "client_id": XunleiWebAuth.clientID,
            "action": action,
            "device_id": deviceId,
            "meta": [
                "username": "", "phone_number": "", "email": "",
                "package_name": XunleiWebAuth.webPackageName,
                "client_version": XunleiWebAuth.webClientVersion,
                "captcha_sign": XunleiSigner.webCaptchaSign(deviceId: deviceId, timestampMs: timestamp),
                "timestamp": String(timestamp),
                "user_id": userId,
            ],
        ]
        // The web page posts JSON as text/plain.
        let headers = ["Accept": "*/*", "Content-Type": "text/plain;charset=UTF-8", "Origin": XunleiConstants.panOrigin,
                       "Referer": "\(XunleiConstants.panOrigin)/", "User-Agent": XunleiWebAuth.desktopUserAgent]
        guard let response = try? await send(.post, XunleiConstants.captchaInitURL, headers: headers, body: Self.jsonData(body)) else { return .failed }
        if String(decoding: response.body, as: UTF8.self).contains("client_id not match") { return .clientIDMismatch }
        guard let token = LenientJSON(data: response.body)?.string("captcha_token").nonBlank else { return .failed }
        return .ok(PanCaptcha(token: token, expiresAt: Date(timeIntervalSince1970: Double(timestamp) / 1000 + XunleiWebAuth.captchaTokenLifetime)))
    }

    /// App channel captcha init for a specific action.
    private func initPanCaptcha(_ account: XunleiCredential, deviceId: String, action: String, oldToken: String) async -> String? {
        let timestamp = String(Int64(now().timeIntervalSince1970 * 1000))
        let body: [String: Any] = [
            "client_id": XunleiConstants.appClientID,
            "action": action,
            "device_id": deviceId,
            "redirect_uri": XunleiConstants.captchaRedirectURI,
            "meta": [
                "client_version": XunleiConstants.appClientVersion,
                "package_name": XunleiConstants.appPackageName,
                "timestamp": timestamp,
                "captcha_sign": XunleiSigner.appCaptchaSign(deviceId: deviceId, timestampMs: timestamp),
                // An empty user_id yields a degraded token that POST calls reject.
                "user_id": account.effectiveUserId,
            ],
            "captcha_token": oldToken,
        ]
        return await requestCaptchaToken(body, headers: appHeaders(deviceId: deviceId))
    }

    private func requestCaptchaToken(_ body: [String: Any], headers: [String: String]) async -> String? {
        guard let response = try? await send(.post, XunleiConstants.captchaInitURL, headers: headers, body: Self.jsonData(body)) else { return nil }
        return LenientJSON(data: response.body)?.string("captcha_token").nonBlank
    }

    // MARK: Credential state

    /// The newest credential this instance knows for the one passed in.
    private func resolve(_ credential: XunleiCredential) -> XunleiCredential {
        var current = credential
        for _ in 0..<8 {
            guard let next = rotated[current.accessToken], next.accessToken != current.accessToken else { break }
            current = next
        }
        return current
    }

    /// Refreshes ahead of a call when the token expires within 60 seconds. A token without a readable
    /// expiry is used as it is, and the 401 path handles it.
    private func freshened(_ credential: XunleiCredential?) async throws -> XunleiCredential? {
        guard let credential else { return nil }
        let current = resolve(credential)
        let expiry = current.tokenExpiry
        if expiry <= 0 || Double(expiry) - now().timeIntervalSince1970 > 60 { return current }
        if !current.refreshToken.isEmpty, let refreshed = await refresh(current) { return refreshed }
        throw DriveError.api(message: "迅雷登录已过期，请重新登录")
    }

    private func deviceId(for credential: XunleiCredential) -> String {
        credential.deviceId.nonBlank ?? guestDeviceId()
    }

    /// Anonymous calls and credentials without a device id still need an X-Device-Id.
    private func guestDeviceId() -> String {
        if let fallbackDeviceId { return fallbackDeviceId }
        let created = XunleiDevice.generate().deviceId
        fallbackDeviceId = created
        return created
    }

    // MARK: Parsing

    private func loginBody(device: XunleiDevice, clientVersion: String, sdkVersion: String, creditKey: String = "") -> [String: Any] {
        [
            "protocolVersion": "301",
            "sequenceNo": String(Int64.random(in: 10_000_000..<99_999_999)),
            "platformVersion": "10",
            "isCompressed": "0",
            "appid": "40",
            "clientVersion": clientVersion,
            "peerID": device.peerId,
            "appName": "ANDROID-com.xunlei.downloadprovider",
            "sdkVersion": sdkVersion,
            "devicesign": device.deviceSign,
            "netWorkType": "WIFI",
            "providerName": "NONE",
            "deviceModel": "M2004J7AC",
            "deviceName": "Xiaomi_M2004j7ac",
            "OSVersion": "12",
            "creditkey": creditKey,
            "hl": "zh-CN",
        ]
    }

    private func loginCall(_ url: String, body: [String: Any], userAgent: String) async throws -> LenientJSON {
        let headers = ["User-Agent": userAgent, "Content-Type": "application/json"]
        let response = try await send(.post, url, headers: headers, body: Self.jsonData(body))
        return LenientJSON(data: response.body) ?? LenientJSON([:])
    }

    static func parseLogin(_ json: LenientJSON) -> XunleiLoginStep {
        var step = XunleiLoginStep()
        if json.string("errorCode") == "0" || json.string("error") == "success" {
            step.sessionId = json.string("sessionID")
            step.nickname = json.string("nickName")
            step.userId = json.string("userID")
            step.message = "登录成功"
            return step
        }
        // review_panel asks for SMS verification.
        step.needSMS = json.string("error") == "review_panel" || json.string("errorCode") == "1007"
            || !json.string("verifyType").isEmpty
        step.reviewURL = json.string("reviewurl")
        step.message = json.string("errorDesc").ifBlank(json.string("error_description"))
        return step
    }

    private static func tokens(in response: HTTPResponse) -> XunleiTokenPair? {
        guard let json = LenientJSON(data: response.body) else { return nil }
        let access = json.string("access_token").ifBlank(json.string("accessToken"))
        let refresh = json.string("refresh_token").ifBlank(json.string("refreshToken"))
        return access.isBlankText ? nil : XunleiTokenPair(accessToken: access, refreshToken: refresh)
    }

    private static func files(_ data: LenientJSON) -> [DriveFile] {
        data.objects("files").map { item in
            DriveFile(id: item.string("id"), name: item.string("name"), size: item.int64("size"),
                      isDirectory: item.string("kind") == "drive#folder", parentId: item.string("parent_id"),
                      fileToken: "", modifiedAt: item.string("modified_time"))
        }
    }
}
