// Ported from YunX-Desktop (MIT): data/repository/Pan123ResolveRepository.kt,
// Pan123AccountRepository.kt, and the Pan123 header branch of ResolveViewModel.enqueueDownload.
import Foundation

/// 123 Pan. The credential is the sign-in JWT (`data.token`); there is no refresh endpoint,
/// so an expired token means signing in again with `api.passwordLogin`.
/// Share listing is anonymous. Getting a link or saving needs an account, so there is no guest access.
public struct Pan123Provider: CloudDriveProvider {
    public let platform = DrivePlatform.pan123
    public let capabilities: DriveCapabilities = [.shareListing, .ownFiles, .saveToDrive]
    /// The full 123 surface: sign-in, folders, rename, move, delete and share creation.
    public let api: Pan123API

    public init(api: Pan123API = Pan123API()) { self.api = api }

    public func isWellFormed(credential: DriveCredential) -> Bool {
        Pan123LoginSupport.isValidToken(credential.value) && !credential.isBlank
    }

    public func accountState(credential: DriveCredential?) async -> DriveAccountState {
        guard let credential, isWellFormed(credential: credential) else { return .signedOut }
        guard let nickname = await api.fetchNickname(token: credential.value) else { return .unverified }
        return .signedIn(nickname: nickname)
    }

    public func quota(credential: DriveCredential) async -> DriveQuota? {
        await api.getQuota(token: credential.value)
    }

    /// Checks the passcode by listing the share root. The title is the first entry's name, else the share id.
    public func openShare(_ link: ParsedShareLink, passcode: String?, credential: DriveCredential?) async throws -> ShareSession {
        let effective = passcode?.nonBlank ?? link.passcode ?? ""
        let (files, _) = try await api.getShareFiles(shareKey: link.shareId, sharePwd: effective, parentFileId: Pan123Constants.rootDirectoryId, next: "0", page: 1)
        let title = files.first?.name.nonBlank ?? link.shareId
        // The access token is the passcode: every later call sends it as SharePwd.
        return ShareSession(platform: .pan123, shareId: link.shareId, accessToken: effective, title: title)
    }

    /// `next` stays "0" and the page number advances. A page ends the list when it is empty or `Next == "-1"`.
    public func listShareFiles(session: ShareSession, directoryId: String?, credential: DriveCredential?) async throws -> [DriveFile] {
        var all: [DriveFile] = []
        var page = 1
        while true {
            let (files, next) = try await api.getShareFiles(shareKey: session.shareId, sharePwd: session.accessToken,
                                                            parentFileId: directoryId ?? Pan123Constants.rootDirectoryId, next: "0", page: page)
            all += files
            page += 1
            if files.isEmpty || next == nil || page >= Pan123Constants.maxSharePages { break }
        }
        return all
    }

    public func listFiles(directoryId: String?, credential: DriveCredential) async throws -> [DriveFile] {
        try await api.listCloudFiles(parentFileId: directoryId ?? Pan123Constants.rootDirectoryId, token: credential.value).files
    }

    public func saveToDrive(session: ShareSession, file: DriveFile, directoryId: String?, credential: DriveCredential, skipSpaceCheck: Bool) async throws -> String {
        let token = try requireToken(credential)
        if !skipSpaceCheck {
            try await SpaceGuard.ensureEnoughSpace(required: file.size > 0 ? file.size : nil) { await api.getQuota(token: token) }
        }
        guard let started = try await api.copySave(shareKey: session.shareId, sharePwd: session.accessToken, file: file,
                                                   toDirFid: directoryId?.nonBlank ?? Pan123Constants.rootDirectoryId, token: token) else {
            throw DriveError.api(message: "创建转存任务失败")
        }
        guard let saved = try await api.pollCopySave(taskId: started.taskId, shareId: started.shareId, token: token) else {
            throw DriveError.timedOut("转存超时或失败")
        }
        return saved
    }

    /// Checks a batch with one quota lookup. Returns true when per-file checks can be skipped.
    public func ensureBatchSpace(sizes: [Int64], credential: DriveCredential) async throws -> Bool {
        try await SpaceGuard.ensureEnoughSpaceForBatch(sizes: sizes) { await api.getQuota(token: credential.value) }
    }

    /// 123 links need the file's hash and size, which the id alone does not carry.
    public func resolveFile(id: String, credential: DriveCredential) async throws -> ResolvedLink {
        throw DriveError.unsupported(platform: platform, feature: "仅凭文件编号获取直链，请传入 listFiles 返回的文件")
    }

    public func resolveFile(_ file: DriveFile, credential: DriveCredential) async throws -> ResolvedLink {
        let token = try requireToken(credential)
        guard let link = try await api.getDownloadLink(file: file, token: token) else { throw DriveError.api(message: "获取下载链接失败") }
        return try resolved(link, name: file.name)
    }

    /// 123 shares download without saving, so `preferNoSave` and the temp directory do not apply.
    public func resolveShareFile(session: ShareSession, file: DriveFile, credential: DriveCredential?, options: ShareResolveOptions) async throws -> ResolvedLink {
        guard let credential, !credential.isBlank else { throw DriveError.loginRequired }
        let token = try requireToken(credential)
        guard let link = try await api.getShareDownloadLink(shareKey: session.shareId, file: file, token: token) else {
            throw DriveError.api(message: "获取下载链接失败")
        }
        return try resolved(link, name: file.name)
    }

    private func requireToken(_ credential: DriveCredential) throws -> String {
        guard !credential.isBlank else { throw DriveError.loginRequired }
        return credential.value
    }

    private func resolved(_ link: Pan123DownloadLink, name: String) throws -> ResolvedLink {
        guard let url = URL(string: link.downloadURL), url.scheme != nil else { throw DriveError.api(message: "未返回下载链接") }
        return ResolvedLink(url: url, headers: [
            "User-Agent": Pan123Constants.webUserAgent,
            "Referer": Pan123Constants.downloadReferer,
        ], fileId: link.fid, filename: name.ifBlank(link.filename), size: link.size)
    }
}
