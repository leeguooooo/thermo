import Foundation

/// The only place Lanzou is wired up, so branches for other drives merge without touching shared files.
/// Use it as `ShareLinkRouter(providers: [QuarkProvider(), .lanzou()])`.
public extension CloudDriveProvider where Self == LanzouProvider {
    static func lanzou(transport: any HTTPTransport = URLSessionTransport()) -> LanzouProvider {
        LanzouProvider(api: LanzouAPI(transport: transport))
    }
}
