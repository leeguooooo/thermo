import Foundation

/// Platform to parser registry. `all` is account-page order.
public struct VideoParsers: Sendable {
    public let all: [any VideoParser]

    public init(http: VideoHttp = VideoHttp(), headless: any HeadlessFetching = SharedHeadlessWebView()) {
        all = [
            DouyinParser(http: http, headless: headless),
            KuaishouParser(http: http),
            WeiboParser(http: http),
            AcFunParser(http: http),
            BilibiliParser(http: http),
            XhsParser(http: http),
            PixivParser(http: http),
        ]
    }

    public func of(_ platform: VideoPlatform) -> (any VideoParser)? {
        all.first { $0.platform == platform }
    }

    /// Anonymous platforms first, keeping `all`'s order within each group.
    public var supportedPlatforms: [VideoPlatform] {
        let platforms = all.map(\.platform)
        return platforms.filter { !$0.needsLogin } + platforms.filter(\.needsLogin)
    }
}
