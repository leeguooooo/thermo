import Foundation

/// The only place Xunlei is wired up, so branches for other drives merge without touching shared files.
/// Use it as `ShareLinkRouter(providers: [QuarkProvider(), .xunlei()])`.
public extension CloudDriveProvider where Self == XunleiProvider {
    static func xunlei(transport: any HTTPTransport = URLSessionTransport(), credentialUpdated: CredentialUpdateHandler? = nil) -> XunleiProvider {
        XunleiProvider(api: XunleiAPI(transport: transport, credentialUpdated: credentialUpdated))
    }
}
