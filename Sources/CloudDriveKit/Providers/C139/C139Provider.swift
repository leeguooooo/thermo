// Ported from YunX-Desktop (AGPL-3.0): data/repository/C139ResolveRepository.kt, C139AccountRepository.kt,
// and the 139 header branch of ResolveViewModel.enqueueDownload.
import Foundation

/// 139 Cloud (China Mobile). Listing a share is anonymous, so `openShare` and `listShareFiles` work without an account,
/// but every download and save needs one; that is why `.guestShareAccess` is absent from `capabilities`.
/// 139 shares resolve straight to a link and never need saving, so there is no temporary directory to clean up.
public struct C139Provider: CloudDriveProvider {
    public let platform = DrivePlatform.c139
    public let capabilities: DriveCapabilities = [.shareListing, .ownFiles, .saveToDrive]
    /// The full 139 surface: folders, rename, move, delete and share creation.
    public let api: C139API
    private let sleep: DriveSleeper

    private static let pageSize = 200
    private static let maxShareIndex = 20_000
    private static let transferAttempts = 30
    private static let maxCloudPages = 200

    public init(api: C139API = C139API(), sleep: @escaping DriveSleeper = { try await Task.sleep(nanoseconds: $0) }) {
        self.api = api
        self.sleep = sleep
    }

    /// Either login form: Os_SSo_Sid with RMKEY, or a web `authorization`.
    public func isWellFormed(credential: DriveCredential) -> Bool {
        C139Constants.isValidCookie(credential.value)
    }

    /// Read from the cookie, as YunX does when it saves an account; there is no verification request.
    public func accountState(credential: DriveCredential?) async -> DriveAccountState {
        guard let credential, isWellFormed(credential: credential) else { return .signedOut }
        return .signedIn(nickname: C139Constants.extractAccount(credential.value) ?? "139用户")
    }

    public func quota(credential: DriveCredential) async -> DriveQuota? {
        await api.getQuota(cookie: credential.value)
    }

    /// 139 has no share token: the session's `accessToken` is the passcode. A typed passcode wins over the link's,
    /// which wins over the one 139 echoes in clear (that one avoids a 9188 at download time). The title falls back
    /// to the link id.
    public func openShare(_ link: ParsedShareLink, passcode: String?, credential: DriveCredential?) async throws -> ShareSession {
        let general = try await api.getOutLinkGeneral(linkId: link.shareId)
        let effective = passcode?.nonBlank ?? link.passcode?.nonBlank ?? general.passcode ?? ""
        return ShareSession(platform: .c139, shareId: link.shareId, accessToken: effective, title: general.title ?? link.shareId)
    }

    /// Pages of 200 until a short page, as the source does.
    public func listShareFiles(session: ShareSession, directoryId: String?, credential: DriveCredential?) async throws -> [DriveFile] {
        let parent = directoryId.flatMap { $0 == "0" ? nil : $0.nonBlank } ?? C139Constants.rootShareDirectory
        var all = FileAccumulator()
        var begin = 1
        while begin <= Self.maxShareIndex {
            let batch = try await api.getShareFiles(linkId: session.shareId, parentId: parent, passcode: session.accessToken,
                                                    begin: begin, end: begin + Self.pageSize - 1)
            // A repeated page means the server ignored the range.
            if all.add(batch) == 0 || batch.count != Self.pageSize { break }
            begin += Self.pageSize
        }
        return all.files
    }

    public func listFiles(directoryId: String?, credential: DriveCredential) async throws -> [DriveFile] {
        let parent = directoryId?.nonBlank ?? C139Constants.rootDirectoryId
        var all = FileAccumulator()
        var cursor: String?
        for _ in 0..<Self.maxCloudPages {
            let page = try await api.listCloudFiles(parentId: parent, cookie: credential.value, cursor: cursor)
            let added = all.add(page.files)
            guard let next = page.nextCursor, added > 0, next != cursor else { break }
            cursor = next
        }
        return all.files
    }

    /// Creates the transfer task, then polls up to 30 times, 800 ms apart, for the new file id.
    public func saveToDrive(session: ShareSession, file: DriveFile, directoryId: String?, credential: DriveCredential, skipSpaceCheck: Bool) async throws -> String {
        let (account, authorization) = try Self.identity(credential)
        if !skipSpaceCheck {
            try await SpaceGuard.ensureEnoughSpace(required: file.size > 0 ? file.size : nil) { await api.getQuota(cookie: credential.value) }
        }
        guard let taskId = try await api.createTransferTask(coIds: [file.id], catalogIds: [], toFolderId: directoryId?.nonBlank ?? C139Constants.rootDirectoryId,
                                                           linkId: session.shareId, account: account, authorization: authorization) else {
            throw DriveError.api(message: "创建转存任务失败")
        }
        for _ in 0..<Self.transferAttempts {
            try await sleep(800_000_000)
            let result = try await api.queryTransferTask(taskId: taskId, account: account, authorization: authorization)
            if result.done {
                guard let saved = result.mapping[file.id] else { break }
                return saved
            }
        }
        throw DriveError.timedOut("转存超时或失败")
    }

    /// Checks a batch with one quota lookup. Returns true when per-file checks can be skipped.
    public func ensureBatchSpace(sizes: [Int64], credential: DriveCredential) async throws -> Bool {
        try await SpaceGuard.ensureEnoughSpaceForBatch(sizes: sizes) { await api.getQuota(cookie: credential.value) }
    }

    public func resolveFile(id: String, credential: DriveCredential) async throws -> ResolvedLink {
        guard let link = try await api.getDownloadLink(fileId: id, cookie: credential.value) else {
            throw DriveError.api(message: "获取下载链接失败")
        }
        return try resolved(link, filename: link.filename.ifBlank(id))
    }

    /// Straight from the share; nothing is saved, so `preferNoSave` and `skipSpaceCheck` do not apply.
    /// The response has no file name, so the listed one is used.
    public func resolveShareFile(session: ShareSession, file: DriveFile, credential: DriveCredential?, options: ShareResolveOptions) async throws -> ResolvedLink {
        guard let credential, !credential.isBlank else { throw DriveError.loginRequired }
        let (account, authorization) = try Self.identity(credential)
        guard let link = try await api.getShareDownloadLink(coId: file.id, linkId: session.shareId, account: account, authorization: authorization) else {
            throw DriveError.api(message: "获取下载链接失败")
        }
        return try resolved(link, filename: file.name.ifBlank(link.filename))
    }

    private static func identity(_ credential: DriveCredential) throws -> (account: String, authorization: String?) {
        guard let account = C139Constants.extractAccountFull(credential.value) else {
            throw DriveError.api(message: "登录态缺少账号信息，请重新登录")
        }
        return (account, C139Constants.extractAuthorization(credential.value))
    }

    /// The link is a signed CDN address; the only header YunX sends with it is the desktop UA.
    private func resolved(_ link: C139DownloadLink, filename: String) throws -> ResolvedLink {
        guard let url = URL(string: link.downloadURL), url.scheme != nil else { throw DriveError.api(message: "未返回下载链接") }
        return ResolvedLink(url: url, headers: ["User-Agent": C139Constants.pcUserAgent],
                            fileId: link.fid, filename: filename, size: link.size)
    }
}
