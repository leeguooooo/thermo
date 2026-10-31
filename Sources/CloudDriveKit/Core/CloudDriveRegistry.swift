import Foundation

/// Every drive, wired once. Tokens a drive rotates on its own reach `credentialUpdated`.
public struct CloudDriveRegistry: Sendable {
    public let providers: [any CloudDriveProvider]
    public let router: ShareLinkRouter

    /// A nil `transport` uses the production network stack, including Pan123's redirect probe.
    public init(transport: (any HTTPTransport)? = nil, credentialUpdated: CredentialUpdateHandler? = nil) {
        let http = transport ?? URLSessionTransport()
        let pan123 = transport.map { Pan123API(transport: $0) } ?? Pan123API()
        providers = [
            QuarkProvider(api: QuarkAPI(transport: http, credentialUpdated: credentialUpdated)),
            UCProvider(api: UCAPI(transport: http, credentialUpdated: credentialUpdated)),
            XunleiProvider(api: XunleiAPI(transport: http, credentialUpdated: credentialUpdated)),
            C139Provider(api: C139API(transport: http)),
            Pan123Provider(api: pan123),
            Pan115Provider(api: Pan115API(transport: http)),
            GuangYaProvider(api: GuangYaAPI(transport: http, credentialUpdated: credentialUpdated)),
            ILanzouProvider(api: ILanzouAPI(transport: http)),
            LanzouProvider(api: LanzouAPI(transport: http)),
        ]
        router = ShareLinkRouter(providers: providers)
    }

    /// A fixed set of providers, for hosts that test against their own.
    public init(providers: [any CloudDriveProvider]) {
        self.providers = providers
        router = ShareLinkRouter(providers: providers)
    }

    public func provider(_ platform: DrivePlatform) -> (any CloudDriveProvider)? {
        providers.first { $0.platform == platform }
    }
}
