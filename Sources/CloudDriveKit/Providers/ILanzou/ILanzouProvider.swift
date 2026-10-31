// Ported from YunX-Desktop (MIT): data/repository/ILanzouResolveRepository.kt,
// ILanzouAccountRepository.kt and the iLanzou branches of ILanzouCloudViewModel / ResolveViewModel.
import Foundation

/// 蓝奏云优享版. Shares list and resolve without an account; saving and own files need an
/// `ILanzouCredential` (pass `.credential`). The password never reaches the provider: sign in with
/// `ILanzouAPI.signIn` and keep only the returned credential.
public struct ILanzouProvider: CloudDriveProvider {
    public let platform = DrivePlatform.ilanzou
    public let capabilities: DriveCapabilities = [.shareListing, .guestShareAccess, .ownFiles, .saveToDrive]
    /// Folders, rename, move and delete live on the API, as with Quark.
    public let api: ILanzouAPI

    public init(api: ILanzouAPI = ILanzouAPI()) { self.api = api }

    public func isWellFormed(credential: DriveCredential) -> Bool {
        ILanzouCredential(credential) != nil
    }

    public func accountState(credential: DriveCredential?) async -> DriveAccountState {
        guard let credential, let parsed = ILanzouCredential(credential) else { return .signedOut }
        guard let info = await api.fetchAccountInfo(appToken: parsed.appToken, uuid: parsed.uuid) else { return .unverified }
        return .signedIn(nickname: info.nickname)
    }

    public func quota(credential: DriveCredential) async -> DriveQuota? {
        guard let parsed = ILanzouCredential(credential) else { return nil }
        return await api.getQuota(appToken: parsed.appToken, uuid: parsed.uuid)
    }

    /// There is no share token step: the share id doubles as the access token.
    public func openShare(_ link: ParsedShareLink, passcode: String?, credential: DriveCredential?) async throws -> ShareSession {
        guard !link.shareId.isBlankText else { throw DriveError.api(message: "无法识别蓝奏云优享版分享链接") }
        return ShareSession(platform: .ilanzou, shareId: link.shareId, accessToken: link.shareId, title: "蓝奏云优享版分享")
    }

    public func listShareFiles(session: ShareSession, directoryId: String?, credential: DriveCredential?) async throws -> [DriveFile] {
        try await api.shareList(shareId: session.accessToken, folderId: Self.shareFolderId(directoryId), uuid: try await uuid(credential))
    }

    public func listFiles(directoryId: String?, credential: DriveCredential) async throws -> [DriveFile] {
        let parsed = try parse(credential)
        let folder = Self.numeric(directoryId ?? "", prefix: ILanzouConstants.folderPrefix).ifBlank(ILanzouConstants.rootFolderId)
        return try await api.listFiles(appToken: parsed.appToken, uuid: parsed.uuid, folderId: folder)
    }

    public func saveToDrive(session: ShareSession, file: DriveFile, directoryId: String?, credential: DriveCredential, skipSpaceCheck: Bool) async throws -> String {
        let parsed = try parse(credential)
        let target = Self.numeric(directoryId ?? "", prefix: ILanzouConstants.folderPrefix).ifBlank(ILanzouConstants.rootFolderId)
        let fileIds = file.isDirectory ? [] : [Self.numeric(file.id, prefix: ILanzouConstants.filePrefix)]
        let folderIds = file.isDirectory ? [Self.numeric(file.id, prefix: ILanzouConstants.folderPrefix)] : []
        let key = try await api.transferShare(appToken: parsed.appToken, uuid: parsed.uuid, shareId: session.accessToken,
                                              fileIds: fileIds, folderIds: folderIds, targetFolderId: target)
        // A non-empty key means an asynchronous save.
        if !key.isEmpty, try await !api.waitForTransfer(appToken: parsed.appToken, uuid: parsed.uuid, transferKey: key) {
            throw DriveError.timedOut("蓝奏优享仍在处理转存，请稍后刷新列表")
        }
        return target
    }

    public func resolveFile(id: String, credential: DriveCredential) async throws -> ResolvedLink {
        var parsed = try parse(credential)
        if parsed.userId.isEmpty, let info = await api.fetchAccountInfo(appToken: parsed.appToken, uuid: parsed.uuid) {
            parsed = parsed.with(userId: info.userId)
        }
        let link = try await api.getDownloadLink(appToken: parsed.appToken, uuid: parsed.uuid,
                                                 fileId: Self.numeric(id, prefix: ILanzouConstants.filePrefix), userId: parsed.userId)
        return try resolved(link, name: "", size: 0)
    }

    /// Always resolves without saving: the share redirect works anonymously, and a signed-in user id only goes into the download id.
    public func resolveShareFile(session: ShareSession, file: DriveFile, credential: DriveCredential?, options: ShareResolveOptions) async throws -> ResolvedLink {
        if file.isDirectory { throw DriveError.api(message: "文件夹无法直接下载") }
        let userId = credential.flatMap(ILanzouCredential.init)?.userId ?? ""
        let link = try await api.shareDownload(shareId: session.accessToken, fileId: Self.numeric(file.id, prefix: ILanzouConstants.filePrefix),
                                               userId: userId, uuid: try await uuid(credential))
        return try resolved(link, name: file.name, size: file.size)
    }

    // MARK: Helpers

    private func parse(_ credential: DriveCredential) throws -> ILanzouCredential {
        guard let parsed = ILanzouCredential(credential) else { throw DriveError.loginRequired }
        return parsed
    }

    /// The credential's device id when there is one, else an anonymous one.
    private func uuid(_ credential: DriveCredential?) async throws -> String {
        if let credential, let parsed = ILanzouCredential(credential) { return parsed.uuid }
        return try await api.anonymousUUID()
    }

    static func numeric(_ id: String, prefix: String) -> String {
        id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
    }

    /// Blank, "0" and "d:" ids map to the numeric id the share list wants; the root is nil.
    static func shareFolderId(_ directoryId: String?) -> String? {
        guard let directoryId, !directoryId.isBlankText else { return nil }
        let id = numeric(directoryId, prefix: ILanzouConstants.folderPrefix)
        return id.isBlankText || id == ILanzouConstants.rootFolderId ? nil : id
    }

    /// The CDN checks User-Agent, Referer and Origin, and wants no cookie.
    private func resolved(_ link: ILanzouDownloadLink, name: String, size: Int64) throws -> ResolvedLink {
        guard let url = URL(string: link.downloadURL), url.scheme != nil else { throw DriveError.api(message: "未返回下载链接") }
        return ResolvedLink(url: url, headers: [
            "User-Agent": ILanzouConstants.webUserAgent,
            "Referer": ILanzouConstants.downloadReferer,
            "Origin": ILanzouConstants.downloadOrigin,
        ], fileId: link.fid, filename: name, size: size)
    }
}
