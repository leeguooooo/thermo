// Ported from YunX-Desktop (AGPL-3.0): data/repository/QuarkResolveRepository.kt,
// QuarkAccountRepository.kt, and the Quark header branch of ResolveViewModel.enqueueDownload.
import Foundation

public struct QuarkProvider: CloudDriveProvider {
    public let platform = DrivePlatform.quark
    public let capabilities: DriveCapabilities = [.shareListing, .guestShareAccess, .ownFiles, .saveToDrive]
    public let credentialRefreshInterval: TimeInterval? = QuarkConstants.puusRefreshInterval
    /// The full Quark surface: folders, rename, move, delete and share creation.
    public let api: QuarkAPI

    private static let pageSize = 50
    private static let maxPages = 200

    public init(api: QuarkAPI = QuarkAPI()) { self.api = api }

    public func isWellFormed(credential: DriveCredential) -> Bool {
        QuarkConstants.isValidCookie(credential.value)
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
        return ShareSession(platform: .quark, shareId: link.shareId, accessToken: token.stoken, title: token.title)
    }

    public func listShareFiles(session: ShareSession, directoryId: String?, credential: DriveCredential?) async throws -> [DriveFile] {
        var all = FileAccumulator()
        var page = 1
        while page <= Self.maxPages {
            let batch = try await api.getShareFiles(shareId: session.shareId, stoken: session.accessToken,
                                                    pdirFid: directoryId ?? QuarkConstants.rootDirectoryId,
                                                    cookie: credential?.value ?? "", page: page, size: Self.pageSize)
            if batch.isEmpty || all.add(batch) == 0 { break }
            page += 1
        }
        return all.files
    }

    public func listFiles(directoryId: String?, credential: DriveCredential) async throws -> [DriveFile] {
        try await api.listAllCloudFiles(pdirFid: directoryId ?? QuarkConstants.rootDirectoryId, cookie: credential.value)
    }

    public func saveToDrive(session: ShareSession, file: DriveFile, directoryId: String?, credential: DriveCredential, skipSpaceCheck: Bool) async throws -> String {
        try await checkSpace(file, credential, skip: skipSpaceCheck)
        return try await transfer(session, file, to: directoryId ?? QuarkConstants.rootDirectoryId, credential)
    }

    /// Checks a batch with one quota lookup. Returns true when per-file checks can be skipped.
    public func ensureBatchSpace(sizes: [Int64], credential: DriveCredential) async throws -> Bool {
        try await SpaceGuard.ensureEnoughSpaceForBatch(sizes: sizes) { await api.getQuota(cookie: credential.value) }
    }

    public func resolveFile(id: String, credential: DriveCredential) async throws -> ResolvedLink {
        try resolved(try await api.getDownloadLink(fid: id, cookie: credential.value))
    }

    public func resolveShareFile(session: ShareSession, file: DriveFile, credential: DriveCredential?, options: ShareResolveOptions) async throws -> ResolvedLink {
        guard let credential, !credential.isBlank else {
            return try resolved(try await api.getGuestShareDownloadLink(fid: file.id, fidToken: file.fileToken, shareId: session.shareId, stoken: session.accessToken))
        }
        if options.preferNoSave {
            do {
                return try resolved(try await api.getShareDownloadLinkWithoutSave(fid: file.id, fidToken: file.fileToken, shareId: session.shareId, stoken: session.accessToken, cookie: credential.value))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Some share types only resolve after saving.
            }
        }
        return try await resolveBySaving(session, file, credential, skipSpaceCheck: options.skipSpaceCheck)
    }

    public func cleanup(directoryId: String, credential: DriveCredential) async {
        _ = try? await api.deleteFile(fid: directoryId, cookie: credential.value)
    }

    /// Saves into a new `tr_*` directory each time. Quark dedupes saves per target directory, and a
    /// repeat would return an already deleted fid (404, code 21001). The directory must outlive the download.
    private func resolveBySaving(_ session: ShareSession, _ file: DriveFile, _ credential: DriveCredential, skipSpaceCheck: Bool) async throws -> ResolvedLink {
        try await checkSpace(file, credential, skip: skipSpaceCheck)
        let base = try await ensureTempDirectory(credential)
        let name = "\(QuarkConstants.tempSubdirectoryPrefix)\(DispatchTime.now().uptimeNanoseconds)_\(Int.random(in: 0..<1_000_000))"
        let subdirectory = try await api.createFolder(name: name, parentFid: base, cookie: credential.value)
        let saved = try await transfer(session, file, to: subdirectory, credential)
        return try resolved(try await api.getDownloadLink(fid: saved, cookie: credential.value), cleanupDirectoryId: subdirectory)
    }

    private func ensureTempDirectory(_ credential: DriveCredential) async throws -> String {
        let root = try await api.getFileList(pdirFid: QuarkConstants.rootDirectoryId, cookie: credential.value)
        if let existing = root.first(where: { $0.isDirectory && $0.name == QuarkConstants.tempDirectoryName }) {
            return existing.id
        }
        return try await api.createFolder(name: QuarkConstants.tempDirectoryName, parentFid: QuarkConstants.rootDirectoryId, cookie: credential.value)
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

    /// The URL stays exactly as issued: rewriting the host can break its signature and cause a 412.
    private func resolved(_ link: QuarkDownloadLink, cleanupDirectoryId: String? = nil) throws -> ResolvedLink {
        guard let url = URL(string: link.downloadURL), url.scheme != nil else { throw DriveError.api(message: "未返回下载链接") }
        return ResolvedLink(url: url, headers: [
            "Cookie": link.guestCookie.nonBlank ?? link.cookie,
            "User-Agent": QuarkConstants.apiUserAgent,
            "Referer": QuarkConstants.downloadReferer,
        ], fileId: link.fid, filename: link.filename, size: link.size, cleanupDirectoryId: cleanupDirectoryId)
    }
}
