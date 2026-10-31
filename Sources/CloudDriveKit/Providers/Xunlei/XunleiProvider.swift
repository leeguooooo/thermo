// Ported from YunX-Desktop (MIT): data/repository/XunleiResolveRepository.kt and
// XunleiAccountRepository.kt, and the Xunlei header branch of ResolveViewModel.enqueueDownload.
import Foundation

/// Xunlei pan. `DriveCredential.value` is the JSON bundle of `XunleiCredential`; build it with
/// `XunleiCredential.driveCredential`. Sharing can be browsed without an account, but saving and
/// resolving need one.
public struct XunleiProvider: CloudDriveProvider {
    public let platform = DrivePlatform.xunlei
    public let capabilities: DriveCapabilities = [.shareListing, .guestShareAccess, .ownFiles, .saveToDrive]
    /// The full Xunlei surface: folders, move, trash, share creation and share passwords.
    public let api: XunleiAPI

    private static let maxPages = 100

    public init(api: XunleiAPI = XunleiAPI()) { self.api = api }

    public func isWellFormed(credential: DriveCredential) -> Bool {
        XunleiCredential(credential) != nil
    }

    public func accountState(credential: DriveCredential?) async -> DriveAccountState {
        guard let credential, let account = XunleiCredential(credential), !account.accessToken.isEmpty else { return .signedOut }
        guard await api.verify(account) else { return .unverified }
        return .signedIn(nickname: account.nickname.ifBlank("迅雷用户"))
    }

    /// Exchanges the refresh token. The rotated credential is also reported through `credentialUpdated`.
    public func refreshCredential(_ credential: DriveCredential) async -> DriveCredential? {
        guard let account = XunleiCredential(credential) else { return nil }
        return await api.refresh(account)?.driveCredential
    }

    public func quota(credential: DriveCredential) async -> DriveQuota? {
        guard let account = XunleiCredential(credential) else { return nil }
        return await api.getQuota(credential: account)
    }

    public func openShare(_ link: ParsedShareLink, passcode: String?, credential: DriveCredential?) async throws -> ShareSession {
        let account = try optionalAccount(credential)
        let effective = passcode?.nonBlank ?? link.passcode ?? ""
        let result = try await api.getShare(shareId: link.shareId, passCode: effective, credential: account)
        return ShareSession(platform: .xunlei, shareId: link.shareId, accessToken: result.passCodeToken, title: result.title)
    }

    /// The root comes from `share` (with the passcode), sub-directories from `share/detail`.
    public func listShareFiles(session: ShareSession, directoryId: String?, credential: DriveCredential?) async throws -> [DriveFile] {
        let account = try optionalAccount(credential)
        let isRoot = directoryId.map { $0.isBlankText || $0 == "0" } ?? true
        let passcode = await api.passcode(forShare: session.shareId)
        var files: [DriveFile] = []
        var pageToken = ""
        var pages = 0
        repeat {
            let next: String
            if isRoot {
                let page = try await api.getShare(shareId: session.shareId, passCode: passcode, pageToken: pageToken, credential: account)
                files += page.files
                next = page.nextPageToken
            } else {
                let page = try await api.getShareDetail(shareId: session.shareId, parentId: directoryId ?? "", passCodeToken: session.accessToken,
                                                        pageToken: pageToken, credential: account)
                files += page.files
                next = page.nextPageToken
            }
            pageToken = next
            pages += 1
        } while !pageToken.isEmpty && pages < Self.maxPages
        return files
    }

    /// Follows `next_page_token`; the source reads only the first 50 entries.
    public func listFiles(directoryId: String?, credential: DriveCredential) async throws -> [DriveFile] {
        let account = try requiredAccount(credential)
        let parent = directoryId.flatMap { $0 == "0" ? nil : $0 } ?? XunleiConstants.rootDirectoryId
        var files: [DriveFile] = []
        var pageToken = ""
        var pages = 0
        repeat {
            let page = try await api.getFiles(parentId: parent, pageToken: pageToken, credential: account)
            files += page.files
            pageToken = page.nextPageToken
            pages += 1
        } while !pageToken.isEmpty && pages < Self.maxPages
        return files
    }

    public func saveToDrive(session: ShareSession, file: DriveFile, directoryId: String?, credential: DriveCredential, skipSpaceCheck: Bool) async throws -> String {
        let account = try requiredAccount(credential)
        try await checkSpace(file, account, skip: skipSpaceCheck)
        return try await transfer(session, file, to: directoryId ?? XunleiConstants.rootDirectoryId, account)
    }

    /// Checks a batch with one quota lookup. Returns true when per-file checks can be skipped.
    public func ensureBatchSpace(sizes: [Int64], credential: DriveCredential) async throws -> Bool {
        let account = try requiredAccount(credential)
        return try await SpaceGuard.ensureEnoughSpaceForBatch(sizes: sizes) { await api.getQuota(credential: account) }
    }

    public func resolveFile(id: String, credential: DriveCredential) async throws -> ResolvedLink {
        let account = try requiredAccount(credential)
        return try resolved(try await api.getFileDetail(fileId: id, credential: account))
    }

    /// Xunlei has no direct share link: the file is saved into a temporary directory, its link is read,
    /// and the saved copy is trashed. The link carries its own signature, so trashing does not break it.
    /// `preferNoSave` has no effect for that reason, and no cleanup directory is left behind.
    public func resolveShareFile(session: ShareSession, file: DriveFile, credential: DriveCredential?, options: ShareResolveOptions) async throws -> ResolvedLink {
        guard let credential, !credential.isBlank else { throw DriveError.loginRequired }
        let account = try requiredAccount(credential)
        let directory = try await api.ensureTempDirectory(credential: account)
        try await checkSpace(file, account, skip: options.skipSpaceCheck)
        let saved = try await transfer(session, file, to: directory, account)
        let link = try await api.getFileDetail(fileId: saved, credential: account)
        // Best effort: a failed trash must not fail the download.
        _ = try? await api.deleteFiles(fileIds: [saved], credential: account)
        return try resolved(link)
    }

    // MARK: Private

    private func optionalAccount(_ credential: DriveCredential?) throws -> XunleiCredential? {
        guard let credential, !credential.isBlank else { return nil }
        guard let account = XunleiCredential(credential) else { throw DriveError.loginRequired }
        return account
    }

    private func requiredAccount(_ credential: DriveCredential) throws -> XunleiCredential {
        guard !credential.isBlank, let account = XunleiCredential(credential) else { throw DriveError.loginRequired }
        return account
    }

    private func checkSpace(_ file: DriveFile, _ account: XunleiCredential, skip: Bool) async throws {
        if skip { return }
        try await SpaceGuard.ensureEnoughSpace(required: file.size > 0 ? file.size : nil) { await api.getQuota(credential: account) }
    }

    private func transfer(_ session: ShareSession, _ file: DriveFile, to directoryId: String, _ account: XunleiCredential) async throws -> String {
        guard let saved = try await api.restore(shareId: session.shareId, passCodeToken: session.accessToken,
                                                parentFolderId: directoryId, fileIds: [file.id], credential: account) else {
            throw DriveError.api(message: "转存失败")
        }
        return saved
    }

    /// The URL stays exactly as issued. Xunlei's CDN needs the app UA: a browser UA gets the whole file
    /// back regardless of the Range header.
    private func resolved(_ link: XunleiDownloadLink) throws -> ResolvedLink {
        guard let url = URL(string: link.downloadURL), url.scheme != nil else { throw DriveError.api(message: "获取下载链接失败") }
        return ResolvedLink(url: url, headers: ["User-Agent": XunleiConstants.appUserAgent], fileId: link.fid, filename: link.filename, size: link.size)
    }
}
