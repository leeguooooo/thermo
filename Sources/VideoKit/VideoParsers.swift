import Foundation

/// Platform to parser registry.
///
/// Douyin, Weibo and XHS are not ported yet; `of` returns nil for them. YunX's order is
/// Douyin, Kuaishou, Weibo, AcFun, Bilibili, XHS, Pixiv, so insert them at those positions.
public struct VideoParsers: Sendable {
    public let all: [any VideoParser]

    public init(http: VideoHttp = VideoHttp()) {
        all = [
            KuaishouParser(http: http),
            AcFunParser(http: http),
            BilibiliParser(http: http),
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
