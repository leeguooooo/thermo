// Ported from YunX-Desktop (MIT): data/repository/LanzouResolveRepository.kt and
// LanzouAccountRepository.kt, plus the Lanzou header branch of ResolveViewModel.enqueueDownload.
import CryptoKit
import Foundation

/// In-memory state shared by copies of a provider: parsed share pages (the source keeps them in a map keyed
/// by share URL) and the uid/vei of a credential, keyed by its digest so no credential text is retained.
actor LanzouProviderState {
    private var pages: [String: LanzouSharePage] = [:]
    private var loginParams: [String: LanzouLoginParams] = [:]

    func remember(_ page: LanzouSharePage) { pages[page.shareURL] = page }
    func page(for shareURL: String) -> LanzouSharePage? { pages[shareURL] }

    func params(for credential: DriveCredential, fetch: () async throws -> LanzouLoginParams) async throws -> LanzouLoginParams {
        let key = Self.digest(credential)
        if let cached = loginParams[key] { return cached }
        let fresh = try await fetch()
        loginParams[key] = fresh
        return fresh
    }

    func forget(_ credential: DriveCredential) { loginParams[Self.digest(credential)] = nil }

    private static func digest(_ credential: DriveCredential) -> String {
        SHA256.hash(data: Data(credential.value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct LanzouProvider: CloudDriveProvider {
    public let platform = DrivePlatform.lanzou
    /// Lanzou shares cannot be saved into an account; the source says to download and upload instead.
    public let capabilities: DriveCapabilities = [.shareListing, .guestShareAccess, .ownFiles]
    /// Folders, rename, move, delete and share creation, on top of the protocol.
    public let api: LanzouAPI
    private let state = LanzouProviderState()

    public init(api: LanzouAPI = LanzouAPI()) { self.api = api }

    // MARK: Links

    /// Lanzou mirrors differ by host, so the share id here is the whole normalised URL (the source passes the
    /// link itself to createSession). `ShareLinkRouter.route` only yields the path id; `openShare` then falls
    /// back to the default host.
    public func parseShareLink(_ text: String) -> ParsedShareLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let link = ShareLinkRouter.parse(text), link.platform == .lanzou,
              var url = LanzouText.match(#"https?://[^\s]+"#, in: trimmed)?.first.flatMap({ $0 }) else { return nil }
        while let last = url.last, "。，,；;)]}\"'".contains(last) { url.removeLast() }
        return ParsedShareLink(shareId: LanzouConstants.normalizeShareURL(url), passcode: link.passcode, platform: .lanzou)
    }

    // MARK: Account

    /// ylogin and phpdisk_info are both required.
    public func isWellFormed(credential: DriveCredential) -> Bool {
        !credential.isBlank && credential.value.contains("ylogin") && credential.value.contains("phpdisk_info")
    }

    /// The personal-drive API returns no nickname; the source shows this placeholder.
    public func accountState(credential: DriveCredential?) async -> DriveAccountState {
        guard let credential, isWellFormed(credential: credential) else { return .signedOut }
        guard (try? await loginParams(credential)) != nil else { return .unverified }
        return .signedIn(nickname: "蓝奏云用户")
    }

    /// Account and password login (accounts.woozooo.com). The result is validated against mydisk.php like the
    /// source's repository does; the caller stores it in the Keychain. Nothing is kept here.
    public func login(account: String, password: String) async throws -> DriveCredential {
        let cookie = try await api.login(account: account, password: password)
        let params = try await api.fetchLoginParams(cookie: cookie)
        if params.uid.isBlankText || params.vei.isBlankText { throw DriveError.api(message: "蓝奏云登录凭据无效，请重试") }
        return DriveCredential(cookie)
    }

    // MARK: Shares

    public func openShare(_ link: ParsedShareLink, passcode: String?, credential: DriveCredential?) async throws -> ShareSession {
        let effective = passcode?.nonBlank ?? link.passcode
        let url = link.shareId.contains("://") ? link.shareId : "\(LanzouConstants.defaultShareBase)/\(link.shareId)"
        let page = try await api.resolveShare(url, passcode: effective)
        if page.needsPasscode, effective == nil { throw DriveError.api(message: "此蓝奏分享需要提取码，请填写后重新解析") }
        await state.remember(page)
        return ShareSession(platform: .lanzou, shareId: page.shareURL, accessToken: effective ?? "", title: page.title)
    }

    public func listShareFiles(session: ShareSession, directoryId: String?, credential: DriveCredential?) async throws -> [DriveFile] {
        let page = try await sharePage(session)
        guard page.isFolder else { return page.singleFile.map { [$0] } ?? [] }
        return try await api.listShareFolder(page, passcode: session.accessToken.nonBlank)
    }

    public func resolveShareFile(session: ShareSession, file: DriveFile, credential: DriveCredential?, options: ShareResolveOptions) async throws -> ResolvedLink {
        let page = try await sharePage(session)
        return try resolved(try await api.getShareDownloadLink(page, file: file, passcode: session.accessToken.nonBlank))
    }

    public func saveToDrive(session: ShareSession, file: DriveFile, directoryId: String?, credential: DriveCredential, skipSpaceCheck: Bool) async throws -> String {
        throw DriveError.api(message: "蓝奏分享暂不支持直接转存，请下载后上传")
    }

    // MARK: Own files

    /// nil lists the drive root (folder_id -1). Folder ids carry "d:" and file ids "f:".
    public func listFiles(directoryId: String?, credential: DriveCredential) async throws -> [DriveFile] {
        let folder = LanzouConstants.folderId(fromListingId: directoryId ?? LanzouConstants.rootFolderId)
        return try await withParams(credential) { params in
            try await api.listCloudFiles(cookie: credential.value, params: params, folderId: folder)
        }
    }

    public func resolveFile(id: String, credential: DriveCredential) async throws -> ResolvedLink {
        let fileId = LanzouConstants.fileId(fromListingId: id)
        return try await withParams(credential) { params in
            try resolved(try await api.getPersonalDownloadLink(cookie: credential.value, params: params, fileId: fileId, fileName: ""))
        }
    }

    // MARK: Helpers

    /// uid and vei are fetched once per credential and reused; a failure drops them so the next call refetches.
    public func withParams<T>(_ credential: DriveCredential, _ body: (LanzouLoginParams) async throws -> T) async throws -> T {
        let params = try await loginParams(credential)
        do {
            return try await body(params)
        } catch {
            await state.forget(credential)
            throw error
        }
    }

    private func loginParams(_ credential: DriveCredential) async throws -> LanzouLoginParams {
        try await state.params(for: credential) { try await api.fetchLoginParams(cookie: credential.value) }
    }

    private func sharePage(_ session: ShareSession) async throws -> LanzouSharePage {
        guard let page = await state.page(for: session.shareId) else { throw DriveError.api(message: "蓝奏分享会话已失效，请重新解析") }
        return page
    }

    /// The node wants its own origin as Referer and the down_ip=1 cookie.
    private func resolved(_ link: LanzouDownloadLink) throws -> ResolvedLink {
        guard let url = URL(string: link.downloadURL), let scheme = url.scheme, let host = url.host else {
            throw DriveError.api(message: "未返回下载链接")
        }
        return ResolvedLink(url: url, headers: [
            "User-Agent": LanzouConstants.webUserAgent,
            "Referer": "\(scheme)://\(host)/",
            "Cookie": LanzouConstants.downIPCookie,
        ], fileId: link.fid, filename: link.filename, size: link.size)
    }
}
