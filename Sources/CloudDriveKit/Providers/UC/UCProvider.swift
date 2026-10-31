// Ported from YunX-Desktop (MIT): data/repository/UCResolveRepository.kt, UCAccountRepository.kt,
// and the UC header branch of ResolveViewModel.enqueueDownload.
import Foundation

public struct UCProvider: CloudDriveProvider {
    public let platform = DrivePlatform.uc
    public let capabilities: DriveCapabilities = [.shareListing, .guestShareAccess, .ownFiles, .saveToDrive]
    public let credentialRefreshInterval: TimeInterval? = UCConstants.puusRefreshInterval
    /// The full UC surface: folders, rename, move, delete, share creation and play streams.
    public let api: UCAPI

    private static let pageSize = 50
    private static let maxPages = 200
    private static let videoExtensions: Set<String> = ["mp4", "mkv", "mov", "avi", "webm", "flv", "ts", "m3u8", "wmv", "rmvb"]

    public init(api: UCAPI = UCAPI()) { self.api = api }

    public func isWellFormed(credential: DriveCredential) -> Bool {
        UCConstants.isValidCookie(credential.value)
    }

    public func accountState(credential: DriveCredential?) async -> DriveAccountState {
        guard let credential, isWellFormed(credential: credential) else { return .signedOut }
        guard let nickname = await api.fetchNickname(cookie: credential.value) else { return .unverified }
        return .signedIn(nickname: nickname)
    }

    public func refreshCredential(_ credential: DriveCredential) async -> DriveCredential? {
        await api.refreshSession(cookie: credential.value).map(DriveCredential.init)
    }

    public func quota(credential: DriveCredential) async -> DriveQuota? {
        await api.getQuota(cookie: credential.value)
    }

    public func openShare(_ link: ParsedShareLink, passcode: String?, credential: DriveCredential?) async throws -> ShareSession {
        let effective = passcode?.nonBlank ?? link.passcode
        let token = try await api.getShareToken(shareId: link.shareId, passcode: effective, cookie: credential?.value ?? "")
        return ShareSession(platform: .uc, shareId: link.shareId, accessToken: token.stoken, title: token.title)
    }

    /// Lists with transfer_share/detail: the `share_fid_token` it returns is bound to the stoken.
    public func listShareFiles(session: ShareSession, directoryId: String?, credential: DriveCredential?) async throws -> [DriveFile] {
        var all = FileAccumulator()
        var page = 1
        while page <= Self.maxPages {
            let batch = try await api.getTransferShareFiles(shareId: session.shareId, stoken: session.accessToken,
                                                            pdirFid: directoryId ?? UCConstants.rootDirectoryId,
                                                            cookie: credential?.value ?? "", page: page, size: Self.pageSize)
            if batch.isEmpty || all.add(batch) == 0 { break }
            page += 1
        }
        return all.files
    }

    public func listFiles(directoryId: String?, credential: DriveCredential) async throws -> [DriveFile] {
        try await api.listAllCloudFiles(pdirFid: directoryId ?? UCConstants.rootDirectoryId, cookie: credential.value)
    }

    public func saveToDrive(session: ShareSession, file: DriveFile, directoryId: String?, credential: DriveCredential, skipSpaceCheck: Bool) async throws -> String {
        try await checkSpace(file, credential, skip: skipSpaceCheck)
        return try await transfer(session, file, to: directoryId ?? UCConstants.rootDirectoryId, credential)
    }

    /// Checks a batch with one quota lookup. Returns true when per-file checks can be skipped.
    public func ensureBatchSpace(sizes: [Int64], credential: DriveCredential) async throws -> Bool {
        try await SpaceGuard.ensureEnoughSpaceForBatch(sizes: sizes) { await api.getQuota(cookie: credential.value) }
    }

    /// Finds or creates the temporary save directory in the drive root and returns its id.
    public func ensureTempDirectory(credential: DriveCredential) async throws -> String {
        let root = try await api.getFileList(pdirFid: UCConstants.rootDirectoryId, cookie: credential.value)
        if let existing = root.first(where: { $0.isDirectory && $0.name == UCConstants.tempDirectoryName }) {
            return existing.id
        }
        return try await api.createFolder(name: UCConstants.tempDirectoryName, parentFid: UCConstants.rootDirectoryId, cookie: credential.value)
    }

    public func resolveFile(id: String, credential: DriveCredential) async throws -> ResolvedLink {
        try resolved(try await api.getDownloadLink(fid: id, cookie: credential.value), headers: Self.signedInHeaders(credential))
    }

    /// UC downloads straight from the share, with no save. `preferNoSave` and `skipSpaceCheck` have no
    /// effect because the source has no save path for downloads.
    public func resolveShareFile(session: ShareSession, file: DriveFile, credential: DriveCredential?, options: ShareResolveOptions) async throws -> ResolvedLink {
        guard let credential, !credential.isBlank else {
            // No video_preview here: that route needs a signed-in account.
            let link = try await api.getGuestShareDownloadLink(fid: file.id, fidToken: file.fileToken, stoken: session.accessToken, pwdId: session.shareId)
            var headers = [
                "User-Agent": UCConstants.guestUserAgent,
                "Sec-Ch-Ua": UCConstants.guestSecChUA,
                "Referer": UCConstants.downloadReferer,
                "Origin": UCConstants.webOrigin,
            ]
            if let guestCookie = link.guestCookie.nonBlank { headers["Cookie"] = guestCookie }
            return try resolved(link, headers: headers)
        }
        // Videos try the original-quality preview first, which avoids the promo clip.
        if Self.isVideo(file.name),
           let preview = await api.getVideoPreview(pwdId: session.shareId, stoken: session.accessToken, fid: file.id, fidToken: file.fileToken, cookie: credential.value) {
            let link = UCDownloadLink(fid: file.id, filename: file.name, downloadURL: preview.downloadURL, size: preview.size, guestCookie: "")
            return try resolved(link, headers: Self.signedInHeaders(credential))
        }
        let link = try await api.getShareDownloadLink(fid: file.id, fidToken: file.fileToken, stoken: session.accessToken, pwdId: session.shareId, cookie: credential.value)
        return try resolved(link, headers: Self.signedInHeaders(credential))
    }

    public func cleanup(directoryId: String, credential: DriveCredential) async {
        _ = try? await api.deleteFile(fid: directoryId, cookie: credential.value)
    }

    private static func isVideo(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        return videoExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// OSS links are throttled without the official Referer and Origin.
    private static func signedInHeaders(_ credential: DriveCredential) -> [String: String] {
        ["Cookie": credential.value, "User-Agent": UCConstants.userAgent,
         "Referer": UCConstants.downloadReferer, "Origin": UCConstants.webOrigin]
    }

    private func checkSpace(_ file: DriveFile, _ credential: DriveCredential, skip: Bool) async throws {
        if skip { return }
        try await SpaceGuard.ensureEnoughSpace(required: file.size > 0 ? file.size : nil) { await api.getQuota(cookie: credential.value) }
    }

    private func transfer(_ session: ShareSession, _ file: DriveFile, to directoryId: String, _ credential: DriveCredential) async throws -> String {
        guard let taskId = try await api.saveShareFile(shareId: session.shareId, stoken: session.accessToken, pdirFid: file.parentId, fid: file.id, fidToken: file.fileToken, toPdirFid: directoryId, cookie: credential.value) else {
            throw DriveError.api(message: "转存失败")
        }
        guard let saved = try await api.pollTask(taskId: taskId, cookie: credential.value) else {
            throw DriveError.timedOut("转存超时，请稍后重试")
        }
        return saved
    }

    /// The URL stays exactly as issued.
    private func resolved(_ link: UCDownloadLink, headers: [String: String]) throws -> ResolvedLink {
        guard let url = URL(string: link.downloadURL), url.scheme != nil else { throw DriveError.api(message: "未返回下载链接") }
        return ResolvedLink(url: url, headers: headers, fileId: link.fid, filename: link.filename, size: link.size)
    }
}
