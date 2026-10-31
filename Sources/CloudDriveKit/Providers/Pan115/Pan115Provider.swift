// Ported from YunX-Desktop (MIT): data/repository/Pan115ResolveRepository.kt,
// Pan115AccountRepository.kt and the 115 header branch of ResolveViewModel.enqueueDownload.
//
// Differences from the protocol's defaults, all 115 specific:
// - A share link needs the sharer's user id, which only the snap response has. `openShare` probes the root
//   and keeps `<receive_code>|<user_id>` in `ShareSession.accessToken`.
// - `share/receive` does not return the new file id, so a save lists the target directory and finds the file by name.
// - A personal file link needs the file's pickcode, which `listFiles` puts in `DriveFile.fileToken`. The protocol's
//   `resolveFile(id:)` carries only an id, so use `resolveFile(_ file:credential:)`.
import Foundation

public struct Pan115Provider: CloudDriveProvider {
    public let platform = DrivePlatform.pan115
    public let capabilities: DriveCapabilities = [.shareListing, .guestShareAccess, .ownFiles, .saveToDrive]
    /// 115 has no refresh endpoint: an invalid login must be redone.
    public let api: Pan115API

    private static let maxPages = 200
    private static let claimAttempts = 5
    private static let claimIntervalNanoseconds: UInt64 = 500_000_000

    private let sleep: DriveSleeper

    public init(api: Pan115API = Pan115API(), sleep: @escaping DriveSleeper = { try await Task.sleep(nanoseconds: $0) }) {
        self.api = api
        self.sleep = sleep
    }

    public func isWellFormed(credential: DriveCredential) -> Bool {
        Pan115Constants.hasLoginCookie(credential.value)
    }

    public func accountState(credential: DriveCredential?) async -> DriveAccountState {
        guard let credential, isWellFormed(credential: credential) else { return .signedOut }
        guard let nickname = await api.fetchNickname(cookie: credential.value) else { return .unverified }
        return .signedIn(nickname: nickname.ifBlank("115用户"))
    }

    public func quota(credential: DriveCredential) async -> DriveQuota? {
        await api.getQuota(cookie: credential.value)
    }

    public func openShare(_ link: ParsedShareLink, passcode: String?, credential: DriveCredential?) async throws -> ShareSession {
        // Typed passcode first, then the link's.
        let receiveCode = passcode?.nonBlank ?? link.passcode ?? ""
        // The probe both checks the passcode (4100012 / 4100008 become readable messages) and returns the sharer's id.
        let page = try await api.getSharePage(shareCode: link.shareId, receiveCode: receiveCode, cid: Pan115Constants.rootDirectoryId,
                                              cookie: credential?.value ?? "")
        return ShareSession(platform: .pan115, shareId: link.shareId,
                            accessToken: Pan115Constants.encodeShareToken(receiveCode: receiveCode, userId: page.userId),
                            title: page.title.ifBlank(link.shareId))
    }

    public func listShareFiles(session: ShareSession, directoryId: String?, credential: DriveCredential?) async throws -> [DriveFile] {
        let (receiveCode, _) = Pan115Constants.decodeShareToken(session.accessToken)
        let cid = directoryId?.nonBlank ?? Pan115Constants.rootDirectoryId
        var all = FileAccumulator()
        var offset = 0
        var pages = 0
        while pages < Self.maxPages {
            let page = try await api.getSharePage(shareCode: session.shareId, receiveCode: receiveCode, cid: cid,
                                                  cookie: credential?.value ?? "", offset: offset, limit: Pan115Constants.sharePageLimit)
            let added = all.add(page.files)
            offset += page.files.count
            pages += 1
            // Offsets are indexes: an empty or short page, or having reached `count`, is the end. A page that
            // adds nothing new stops a server that ignores the offset.
            if page.files.isEmpty || page.files.count < Pan115Constants.sharePageLimit || added == 0
                || (page.total > 0 && offset >= page.total) { break }
        }
        return all.files
    }

    public func listFiles(directoryId: String?, credential: DriveCredential) async throws -> [DriveFile] {
        let cid = directoryId?.nonBlank ?? Pan115Constants.rootDirectoryId
        var all = FileAccumulator()
        var offset = 0
        var pages = 0
        while pages < Self.maxPages {
            let page = try await api.listFiles(cid: cid, cookie: credential.value, offset: offset, limit: Pan115Constants.pageLimit)
            let added = all.add(page.files)
            offset += page.files.count
            pages += 1
            if page.files.isEmpty || page.files.count < Pan115Constants.pageLimit || added == 0
                || (page.total > 0 && offset >= page.total) { break }
        }
        return all.files
    }

    public func saveToDrive(session: ShareSession, file: DriveFile, directoryId: String?, credential: DriveCredential, skipSpaceCheck: Bool) async throws -> String {
        try requireLogin(credential)
        try await checkSpace(file, credential, skip: skipSpaceCheck)
        let (receiveCode, _) = Pan115Constants.decodeShareToken(session.accessToken)
        let target = directoryId?.nonBlank ?? Pan115Constants.rootDirectoryId
        try await api.receiveShare(shareCode: session.shareId, receiveCode: receiveCode, fileId: file.id, toCid: target, cookie: credential.value)
        guard let saved = try await claimSavedFile(in: target, named: file.name, credential) else {
            throw DriveError.api(message: "转存已完成，但未在目标目录找到文件，请到115网盘查看")
        }
        return saved.id
    }

    /// Checks a batch with one quota lookup. Returns true when per-file checks can be skipped.
    public func ensureBatchSpace(sizes: [Int64], credential: DriveCredential) async throws -> Bool {
        try await SpaceGuard.ensureEnoughSpaceForBatch(sizes: sizes) { await api.getQuota(cookie: credential.value) }
    }

    /// The protocol passes only an id, but a 115 link needs the pickcode in `DriveFile.fileToken`.
    public func resolveFile(id: String, credential: DriveCredential) async throws -> ResolvedLink {
        throw DriveError.unsupported(platform: platform, feature: "仅凭 ID 获取直链（115 需要 pickcode，请改用 resolveFile(_:credential:)）")
    }

    /// Resolves a file from `listFiles`, whose `fileToken` is its pickcode.
    public func resolveFile(_ file: DriveFile, credential: DriveCredential) async throws -> ResolvedLink {
        guard let link = try await api.getDownloadLink(file: file, cookie: credential.value) else {
            throw DriveError.api(message: "未返回下载链接")
        }
        return try await resolved(link, login: credential.value)
    }

    /// Tries the web share link first (enough for small files and works as a guest). When 115 refuses it
    /// (50029 for big files) and the account is signed in, saves to a temporary directory and takes the
    /// desktop client link, which `cleanup` removes after the download.
    public func resolveShareFile(session: ShareSession, file: DriveFile, credential: DriveCredential?, options: ShareResolveOptions) async throws -> ResolvedLink {
        let (receiveCode, userId) = Pan115Constants.decodeShareToken(session.accessToken)
        let loggedIn = credential.map { Pan115Constants.hasLoginCookie($0.value) } ?? false
        let login = credential?.value ?? ""
        var webError: (any Error)?
        if options.preferNoSave || !loggedIn {
            do {
                if let link = try await api.getShareDownloadLink(shareCode: session.shareId, receiveCode: receiveCode, userId: userId, file: file, cookie: login) {
                    return try await resolved(link, login: login, filename: file.name)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                webError = error
            }
        }
        guard let credential, loggedIn else {
            // A guest can only use the web endpoint; its message (for example 50029) is passed on.
            throw webError ?? DriveError.api(message: "获取下载链接失败")
        }
        return try await resolveBySaving(session, file, receiveCode: receiveCode, credential, skipSpaceCheck: options.skipSpaceCheck)
    }

    public func cleanup(directoryId: String, credential: DriveCredential) async {
        if directoryId.isBlankText || !Pan115Constants.hasLoginCookie(credential.value) { return }
        guard let root = try? await api.listFiles(cid: Pan115Constants.rootDirectoryId, cookie: credential.value),
              let tempRoot = root.files.first(where: { $0.isDirectory && $0.name == Pan115Constants.tempDirectoryName }) else { return }
        try? await api.delete(ids: [directoryId], parentId: tempRoot.id, cookie: credential.value)
    }

    // MARK: Saving through a temporary directory

    /// Save, claim the new file (its pickcode), take the desktop client link. Any failure after the save removes
    /// the directory so nothing is left in the account.
    private func resolveBySaving(_ session: ShareSession, _ file: DriveFile, receiveCode: String, _ credential: DriveCredential, skipSpaceCheck: Bool) async throws -> ResolvedLink {
        try await checkSpace(file, credential, skip: skipSpaceCheck)
        let directory = try await ensureTempDirectory(credential)
        do {
            try await api.receiveShare(shareCode: session.shareId, receiveCode: receiveCode, fileId: file.id, toCid: directory, cookie: credential.value)
            guard let saved = try await claimSavedFile(in: directory, named: file.name, credential) else {
                throw DriveError.api(message: "分享文件转存后未取到下载链接，请稍后重试")
            }
            guard let link = try? await api.getAppDownloadLink(pickCode: saved.fileToken, cookie: credential.value) else {
                throw DriveError.api(message: "该分享文件暂时无法获取电脑端下载链接，请稍后重试")
            }
            let adjusted = Pan115DownloadLink(fid: saved.id, filename: file.name.ifBlank(link.filename), downloadURL: link.downloadURL,
                                              size: link.size > 0 ? link.size : saved.size, guestCookie: link.guestCookie)
            return try await resolved(adjusted, login: credential.value, cleanupDirectoryId: directory)
        } catch {
            await cleanup(directoryId: directory, credential: credential)
            throw error
        }
    }

    /// A fresh `tr_*` directory under the shared temporary root, so equal file names never collide.
    private func ensureTempDirectory(_ credential: DriveCredential) async throws -> String {
        let root = try await api.listFiles(cid: Pan115Constants.rootDirectoryId, cookie: credential.value)
        let tempRoot: String
        if let existing = root.files.first(where: { $0.isDirectory && $0.name == Pan115Constants.tempDirectoryName }) {
            tempRoot = existing.id
        } else {
            guard let created = try await api.createDirectory(parentId: Pan115Constants.rootDirectoryId, name: Pan115Constants.tempDirectoryName, cookie: credential.value) else {
                throw DriveError.api(message: "创建115临时目录失败")
            }
            tempRoot = created
        }
        let name = "\(Pan115Constants.tempSubdirectoryPrefix)\(DispatchTime.now().uptimeNanoseconds)"
        guard let subdirectory = try await api.createDirectory(parentId: tempRoot, name: name, cookie: credential.value) else {
            throw DriveError.api(message: "创建115临时转存目录失败")
        }
        return subdirectory
    }

    /// Lists lag behind a save: up to 5 tries, 500 ms apart. A duplicate name becomes `name(1).ext`, so the
    /// prefix and extension are matched together.
    private func claimSavedFile(in directoryId: String, named name: String, _ credential: DriveCredential) async throws -> DriveFile? {
        let base = name.lastIndex(of: ".").map { String(name[..<$0]) } ?? name
        let ext = name.lastIndex(of: ".").map { String(name[name.index(after: $0)...]) } ?? ""
        for attempt in 0..<Self.claimAttempts {
            if attempt > 0 { try await sleep(Self.claimIntervalNanoseconds) }
            guard let page = try? await api.listFiles(cid: directoryId, cookie: credential.value, offset: 0, limit: Pan115Constants.pageLimit) else { continue }
            if let hit = page.files.first(where: { Self.matches($0.name, name: name, base: base, ext: ext) }) { return hit }
        }
        return nil
    }

    private static func matches(_ candidate: String, name: String, base: String, ext: String) -> Bool {
        if candidate == name { return true }
        guard candidate.hasPrefix("\(base)(") else { return false }
        return ext.isEmpty ? candidate.hasSuffix(")") : candidate.hasSuffix(".\(ext)")
    }

    private func requireLogin(_ credential: DriveCredential) throws {
        if !Pan115Constants.hasLoginCookie(credential.value) { throw DriveError.loginRequired }
    }

    private func checkSpace(_ file: DriveFile, _ credential: DriveCredential, skip: Bool) async throws {
        if skip { return }
        try await SpaceGuard.ensureEnoughSpace(required: file.size > 0 ? file.size : nil) { await api.getQuota(cookie: credential.value) }
    }

    /// Download headers: login and CDN cookie joined, with the client UA the link was issued for.
    private func resolved(_ link: Pan115DownloadLink, login: String, filename: String? = nil, cleanupDirectoryId: String? = nil) async throws -> ResolvedLink {
        guard let url = URL(string: link.downloadURL), url.scheme != nil else { throw DriveError.api(message: "未返回下载链接") }
        let name = filename?.nonBlank ?? link.filename
        return ResolvedLink(url: url, headers: [
            "Cookie": Pan115Constants.mergeCookies(login, link.guestCookie),
            "User-Agent": await api.clientUserAgent,
            "Referer": Pan115Constants.downloadReferer,
        ], fileId: link.fid, filename: name, size: link.size, cleanupDirectoryId: cleanupDirectoryId)
    }
}
