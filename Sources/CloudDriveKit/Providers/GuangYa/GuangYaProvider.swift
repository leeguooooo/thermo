// Ported from YunX-Desktop (AGPL-3.0): data/repository/GuangYaResolveRepository.kt and
// GuangYaAccountRepository.kt, plus the GuangYa download headers of ResolveViewModel / GuangYaCloudViewModel.
import Foundation

/// GuangYa takes a `DriveCredential` holding a `GuangYaCredential` (access token, refresh token, device)
/// or just a bare access token. Tokens are refreshed on use and reported through `GuangYaAPI`'s
/// `credentialUpdated` handler, so the host can store the rotated credential in the Keychain.
public struct GuangYaProvider: CloudDriveProvider {
    public let platform = DrivePlatform.guangya
    public let capabilities: DriveCapabilities = [.shareListing, .guestShareAccess, .ownFiles, .saveToDrive]
    /// Tokens are rotated lazily on use, as in the source, so the host has no schedule to keep.
    public let credentialRefreshInterval: TimeInterval? = nil
    public let api: GuangYaAPI

    private static let maxSharePages = 1000
    private let sleep: DriveSleeper

    public init(api: GuangYaAPI = GuangYaAPI(), sleep: @escaping DriveSleeper = { try await Task.sleep(nanoseconds: $0) }) {
        self.api = api
        self.sleep = sleep
    }

    // MARK: Account

    public func isWellFormed(credential: DriveCredential) -> Bool {
        let parsed = GuangYaCredential(credential)
        return !parsed.accessToken.isBlankText || !parsed.refreshToken.isBlankText
    }

    public func accountState(credential: DriveCredential?) async -> DriveAccountState {
        guard let credential, isWellFormed(credential: credential) else { return .signedOut }
        guard let active = try? await api.activeCredential(credential),
              let info = await api.fetchAccountInfo(accessToken: active.accessToken, device: active.device ?? .make()) else { return .unverified }
        return .signedIn(nickname: info.nickname.ifBlank("光鸭用户"))
    }

    /// Rotates the token pair now. Nil when there is no refresh token or the server refused it.
    public func refreshCredential(_ credential: DriveCredential) async -> DriveCredential? {
        let current = GuangYaCredential(credential)
        guard !current.refreshToken.isBlankText else { return nil }
        let device = current.device ?? .make()
        guard let tokens = try? await api.refreshToken(current.refreshToken, device: device) else { return nil }
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        return GuangYaCredential(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken.ifBlank(current.refreshToken),
                                 device: device, accessExpiresAt: tokens.expiresIn > 0 ? nowMillis + tokens.expiresIn * 1000 : 0).driveCredential
    }

    public func quota(credential: DriveCredential) async -> DriveQuota? {
        guard let active = try? await api.activeCredential(credential) else { return nil }
        return await api.getQuota(accessToken: active.accessToken, deviceId: active.device?.deviceId)
    }

    // MARK: Login (the host owns the typed secrets; nothing is kept here)

    /// Password login. Pass the device of an existing credential to keep it, else a fresh one is made.
    public func login(account: String, password: String, device: GuangYaDevice = .make(), previous: DriveCredential? = nil) async throws -> DriveCredential {
        let tokens = try await api.signIn(username: account, password: password, device: device)
        return credential(from: tokens, device: device, previous: previous)
    }

    public func sendSmsCode(phoneNumber: String, device: GuangYaDevice) async throws -> GuangYaSmsChallenge {
        try await api.sendSmsCode(phoneNumber: GuangYaAPI.normalizeAccount(phoneNumber), device: device)
    }

    /// Verifies the code, then signs in an existing user or signs up a new one.
    public func smsLogin(phoneNumber: String, verificationId: String, code: String, isUser: Bool, device: GuangYaDevice, previous: DriveCredential? = nil) async throws -> DriveCredential {
        let normalized = GuangYaAPI.normalizeAccount(phoneNumber)
        let verificationToken = try await api.verifySmsCode(verificationId: verificationId, code: code, device: device)
        let tokens = isUser
            ? try await api.smsSignIn(phoneNumber: normalized, code: code, verificationToken: verificationToken, device: device)
            : try await api.smsSignUp(phoneNumber: normalized, name: Self.smsName(normalized), code: code, verificationToken: verificationToken, device: device)
        return credential(from: tokens, device: device, previous: previous)
    }

    /// First 3 digits + **** + last 4.
    static func smsName(_ normalizedPhone: String) -> String {
        var local = normalizedPhone.filter(\.isNumber)
        if local.hasPrefix("86") { local.removeFirst(2) }
        return local.count >= 11 ? local.prefix(3) + "****" + local.suffix(4) : "光鸭用户"
    }

    private func credential(from tokens: GuangYaTokens, device: GuangYaDevice, previous: DriveCredential?) -> DriveCredential {
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let oldRefresh = previous.map { GuangYaCredential($0).refreshToken } ?? ""
        return GuangYaCredential(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken.ifBlank(oldRefresh), device: device,
                                 accessExpiresAt: tokens.expiresIn > 0 ? nowMillis + tokens.expiresIn * 1000 : 0).driveCredential
    }

    // MARK: Shares

    public func openShare(_ link: ParsedShareLink, passcode: String?, credential: DriveCredential?) async throws -> ShareSession {
        let effective = passcode?.nonBlank ?? link.passcode ?? ""
        let token = try await api.getShareAccessToken(shareId: link.shareId, code: effective)
        let title = await api.getShareSummary(shareId: link.shareId) ?? "光鸭分享"
        return ShareSession(platform: .guangya, shareId: link.shareId, accessToken: token, title: title)
    }

    public func listShareFiles(session: ShareSession, directoryId: String?, credential: DriveCredential?) async throws -> [DriveFile] {
        var all = FileAccumulator()
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await api.listShareFiles(accessToken: session.accessToken, parentId: directoryId ?? GuangYaConstants.rootDirectoryId, cursor: cursor)
            all.add(page.files)
            // A server that keeps returning the same cursor would otherwise run to the page cap.
            if page.next == cursor { break }
            cursor = page.next
            pages += 1
        } while cursor != nil && pages < Self.maxSharePages
        return all.files
    }

    public func listFiles(directoryId: String?, credential: DriveCredential) async throws -> [DriveFile] {
        let active = try await requireActive(credential)
        return try await api.listCloudFiles(accessToken: active.accessToken, deviceId: active.device?.deviceId, parentId: directoryId ?? GuangYaConstants.rootDirectoryId)
    }

    /// Restores into `directoryId` and returns that directory's id: the restore response carries no new file id,
    /// which is what the source returns too. `skipSpaceCheck` is unused, as in the source; a full drive
    /// comes back as business code 157.
    public func saveToDrive(session: ShareSession, file: DriveFile, directoryId: String?, credential: DriveCredential, skipSpaceCheck: Bool) async throws -> String {
        let active = try await requireActive(credential)
        let target = directoryId ?? GuangYaConstants.rootDirectoryId
        try await api.restoreShare(accountToken: active.accessToken, deviceId: active.device?.deviceId, shareToken: session.accessToken, fileIds: [file.id], parentId: target)
        return target
    }

    // MARK: Direct links

    public func resolveFile(id: String, credential: DriveCredential) async throws -> ResolvedLink {
        let active = try await requireActive(credential)
        let stub = DriveFile(id: id, name: "", size: 0, isDirectory: false, parentId: "")
        guard let link = try await api.getDownloadLink(accessToken: active.accessToken, deviceId: active.device?.deviceId, file: stub) else {
            throw DriveError.api(message: "光鸭未返回有效下载地址，请确认下载权限")
        }
        return try resolved(link)
    }

    public func resolveShareFile(session: ShareSession, file: DriveFile, credential: DriveCredential?, options: ShareResolveOptions) async throws -> ResolvedLink {
        guard let credential, !credential.isBlank else {
            do {
                return try resolved(try await directShareLink(session, file))
            } catch is GuangYaShareRestrictedError {
                throw DriveError.api(message: GuangYaShareRestrictedError().errorDescription ?? "", code: 207)
            }
        }
        if options.preferNoSave {
            do {
                return try resolved(try await directShareLink(session, file))
            } catch is GuangYaShareRestrictedError {
                // The sharer did not allow download without login: restore, then fetch from the drive.
            }
        }
        return try await resolveBySaving(session, file, credential)
    }

    public func cleanup(directoryId: String, credential: DriveCredential) async {
        guard !directoryId.isEmpty, let active = try? await api.activeCredential(credential), !active.accessToken.isBlankText else { return }
        try? await api.deleteFiles(accessToken: active.accessToken, deviceId: active.device?.deviceId, fileIds: [directoryId])
    }

    private func directShareLink(_ session: ShareSession, _ file: DriveFile) async throws -> GuangYaDownloadLink {
        guard let link = try await api.getShareDownloadURL(file: file, accessToken: session.accessToken) else {
            throw DriveError.api(message: "光鸭未返回有效下载地址，请确认下载权限")
        }
        return link
    }

    /// Creates a temporary folder at the drive root, restores into it, waits for the copy to show up and
    /// fetches its link. The folder id is returned for `cleanup`; on any failure it is removed here.
    private func resolveBySaving(_ session: ShareSession, _ file: DriveFile, _ credential: DriveCredential) async throws -> ResolvedLink {
        let active = try await requireActive(credential)
        let token = active.accessToken, deviceId = active.device?.deviceId
        let folderId = try await api.createDir(accessToken: token, deviceId: deviceId, parentId: GuangYaConstants.rootDirectoryId,
                                               name: "\(GuangYaConstants.tempDirectoryPrefix)\(UUID().uuidString)")
        do {
            try await api.restoreShare(accountToken: token, deviceId: deviceId, shareToken: session.accessToken, fileIds: [file.id], parentId: folderId)
            let copy = try await pollCopiedFile(token, deviceId, folderId, source: file)
            guard let link = try await api.getDownloadLink(accessToken: token, deviceId: deviceId, file: copy) else {
                throw DriveError.api(message: "光鸭未返回有效下载地址，请确认下载权限")
            }
            return try resolved(GuangYaDownloadLink(fid: copy.id, filename: file.name, downloadURL: link.downloadURL, size: link.size), cleanupDirectoryId: folderId)
        } catch {
            try? await api.deleteFiles(accessToken: token, deviceId: deviceId, fileIds: [folderId])
            throw error
        }
    }

    /// Polls the folder up to 30 times, 750 ms apart, until the same-named file appears.
    private func pollCopiedFile(_ token: String, _ deviceId: String?, _ folderId: String, source: DriveFile) async throws -> DriveFile {
        for _ in 0..<30 {
            try await sleep(GuangYaConstants.taskDelayNanoseconds)
            let files = (try? await api.listCloudFiles(accessToken: token, deviceId: deviceId, parentId: folderId)) ?? []
            let matches = files.filter { !$0.isDirectory && $0.name == source.name }
            if matches.count > 1 { throw DriveError.api(message: "光鸭临时目录出现同名文件，无法确定下载目标") }
            if let target = matches.first {
                if source.size > 0, target.size > 0, source.size != target.size { throw DriveError.api(message: "光鸭转存文件大小不一致") }
                return target
            }
        }
        throw DriveError.api(message: "光鸭转存已提交，目标文件暂不可见，请稍后重试")
    }

    private func requireActive(_ credential: DriveCredential) async throws -> GuangYaCredential {
        let active = try await api.activeCredential(credential)
        if active.accessToken.isBlankText { throw DriveError.api(message: "请先登录光鸭云盘") }
        return active
    }

    /// The CDN wants the web User-Agent and Referer; no cookie.
    private func resolved(_ link: GuangYaDownloadLink, cleanupDirectoryId: String? = nil) throws -> ResolvedLink {
        guard let url = URL(string: link.downloadURL), url.scheme != nil else { throw DriveError.api(message: "未返回下载链接") }
        return ResolvedLink(url: url, headers: [
            "User-Agent": GuangYaConstants.webUserAgent,
            "Referer": GuangYaConstants.downloadReferer,
        ], fileId: link.fid, filename: link.filename, size: link.size, cleanupDirectoryId: cleanupDirectoryId)
    }
}
