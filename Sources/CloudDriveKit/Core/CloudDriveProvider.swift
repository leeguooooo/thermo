// The shared shape of YunX-Desktop's drive APIs (AGPL-3.0): QuarkApi.kt, UCApi.kt, Pan115Api.kt,
// LanzouApi.kt and repository/ShareResolveRepository.kt.
import Foundation

/// One drive. Credentials are passed on each call and never stored by a provider.
/// Pass nil to act as a guest where `capabilities` contains `.guestShareAccess`.
public protocol CloudDriveProvider: Sendable {
    var platform: DrivePlatform { get }
    var capabilities: DriveCapabilities { get }
    /// How often the host should call `refreshCredential`; nil when the drive needs no refresh.
    var credentialRefreshInterval: TimeInterval? { get }

    func parseShareLink(_ text: String) -> ParsedShareLink?

    func isWellFormed(credential: DriveCredential) -> Bool
    func accountState(credential: DriveCredential?) async -> DriveAccountState
    /// Returns the rotated credential, or nil when the refresh failed and the old one stands.
    func refreshCredential(_ credential: DriveCredential) async -> DriveCredential?
    func quota(credential: DriveCredential) async -> DriveQuota?

    func openShare(_ link: ParsedShareLink, passcode: String?, credential: DriveCredential?) async throws -> ShareSession
    /// Lists a share directory; nil means the share root.
    func listShareFiles(session: ShareSession, directoryId: String?, credential: DriveCredential?) async throws -> [DriveFile]

    /// Lists a directory in the account; nil means the drive root.
    func listFiles(directoryId: String?, credential: DriveCredential) async throws -> [DriveFile]

    /// Saves a shared file into the account and returns its new id.
    func saveToDrive(session: ShareSession, file: DriveFile, directoryId: String?, credential: DriveCredential, skipSpaceCheck: Bool) async throws -> String

    /// Resolves a file in the account.
    func resolveFile(id: String, credential: DriveCredential) async throws -> ResolvedLink
    /// Resolves a file taken from `listFiles`. Drives whose links need more than the id (Pan123 needs
    /// the hash and size) override this; the default resolves by id.
    func resolveFile(_ file: DriveFile, credential: DriveCredential) async throws -> ResolvedLink
    /// Resolves a shared file; a nil credential uses the guest path.
    func resolveShareFile(session: ShareSession, file: DriveFile, credential: DriveCredential?, options: ShareResolveOptions) async throws -> ResolvedLink
    /// Removes `ResolvedLink.cleanupDirectoryId` after the download ends. Best effort.
    func cleanup(directoryId: String, credential: DriveCredential) async
}

public extension CloudDriveProvider {
    var credentialRefreshInterval: TimeInterval? { nil }

    func parseShareLink(_ text: String) -> ParsedShareLink? {
        guard let link = ShareLinkRouter.parse(text), link.platform == platform else { return nil }
        return link
    }

    func refreshCredential(_ credential: DriveCredential) async -> DriveCredential? { nil }
    func quota(credential: DriveCredential) async -> DriveQuota? { nil }

    func listFiles(directoryId: String?, credential: DriveCredential) async throws -> [DriveFile] {
        throw DriveError.unsupported(platform: platform, feature: "浏览网盘文件")
    }

    func saveToDrive(session: ShareSession, file: DriveFile, directoryId: String?, credential: DriveCredential, skipSpaceCheck: Bool) async throws -> String {
        throw DriveError.unsupported(platform: platform, feature: "转存")
    }

    func resolveFile(id: String, credential: DriveCredential) async throws -> ResolvedLink {
        throw DriveError.unsupported(platform: platform, feature: "获取网盘文件直链")
    }

    func resolveFile(_ file: DriveFile, credential: DriveCredential) async throws -> ResolvedLink {
        try await resolveFile(id: file.id, credential: credential)
    }

    func cleanup(directoryId: String, credential: DriveCredential) async {}
}
