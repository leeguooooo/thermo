import Foundation

public enum VideoMediaKind: String, Sendable, Equatable {
    case video, image, audio
}

/// One selectable quality. `qn` is the platform's own number; only Bilibili fills these.
public struct VideoQuality: Sendable, Equatable {
    public var qn: Int
    public var label: String

    public init(qn: Int, label: String) {
        self.qn = qn
        self.label = label
    }
}

/// One downloadable media item.
///
/// `headers` and `audioHeaders` may hold the account Cookie, and `url` may carry signed query
/// tokens. The type is deliberately not `Codable`: whoever stores one must encrypt those fields.
public struct VideoMedia: Sendable, Equatable {
    public var url: String
    public var kind: VideoMediaKind
    public var fileName: String
    /// -1 when unknown.
    public var size: Int64
    public var isHls: Bool
    public var headers: [String: String]
    /// Display only, such as `720P` or `原图`.
    public var quality: String
    /// Non-empty when video and audio are separate tracks that must be muxed (Bilibili DASH).
    public var audioUrl: String
    public var audioHeaders: [String: String]
    /// Live Photo motion resource. The kind stays `.image`.
    public var motionUrl: String
    /// Same content in a form a player can open directly. Empty means preview `url`.
    public var previewUrl: String

    public init(
        url: String,
        kind: VideoMediaKind,
        fileName: String = "",
        size: Int64 = -1,
        isHls: Bool = false,
        headers: [String: String] = [:],
        quality: String = "",
        audioUrl: String = "",
        audioHeaders: [String: String] = [:],
        motionUrl: String = "",
        previewUrl: String = ""
    ) {
        self.url = url
        self.kind = kind
        self.fileName = fileName
        self.size = size
        self.isHls = isHls
        self.headers = headers
        self.quality = quality
        self.audioUrl = audioUrl
        self.audioHeaders = audioHeaders
        self.motionUrl = motionUrl
        self.previewUrl = previewUrl
    }
}

extension VideoMedia: CustomStringConvertible, CustomDebugStringConvertible {
    /// Omits URLs and headers so string interpolation cannot leak tokens or cookies into logs.
    public var description: String {
        "VideoMedia(kind: \(kind.rawValue), fileName: \(fileName), hls: \(isHls), quality: \(quality))"
    }

    public var debugDescription: String { description }
}

/// One parsed work. Lives in memory only.
public struct VideoParseResult: Sendable, Equatable {
    public var platform: VideoPlatform
    public var title: String
    public var author: String
    public var avatar: String
    public var cover: String
    public var text: String
    /// Seconds since the epoch; 0 when unknown.
    public var timestampSeconds: Int64
    public var url: String
    public var medias: [VideoMedia]
    /// Non-fatal degradation message; empty when all is well.
    public var notice: String
    public var qualities: [VideoQuality]
    /// 0 when unknown.
    public var selectedQn: Int

    public init(
        platform: VideoPlatform,
        title: String,
        author: String = "",
        avatar: String = "",
        cover: String = "",
        text: String = "",
        timestampSeconds: Int64 = 0,
        url: String = "",
        medias: [VideoMedia] = [],
        notice: String = "",
        qualities: [VideoQuality] = [],
        selectedQn: Int = 0
    ) {
        self.platform = platform
        self.title = title
        self.author = author
        self.avatar = avatar
        self.cover = cover
        self.text = text
        self.timestampSeconds = timestampSeconds
        self.url = url
        self.medias = medias
        self.notice = notice
        self.qualities = qualities
        self.selectedQn = selectedQn
    }

    public var videoCount: Int { medias.filter { $0.kind == .video }.count }
    public var imageCount: Int { medias.filter { $0.kind == .image }.count }
}

public enum VideoParseErrorKind: Sendable, Equatable {
    /// Stopped by platform risk control (403/418/429, captcha pages).
    case blocked
    /// Missing, deleted or private content.
    case notFound
    /// Timeout, DNS failure, refused connection.
    case network
    /// Unsupported link form, or the platform needs a login we do not have.
    case unsupported
    /// Anything else, such as a changed response format.
    case unknown
}

/// Every parser failure. `message` is for logs and never carries a URL query or Cookie.
public struct VideoParseException: Error, Sendable, Equatable, CustomStringConvertible {
    public var kind: VideoParseErrorKind
    public var message: String

    public init(_ kind: VideoParseErrorKind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { "VideoParseException(\(kind)): \(message)" }

    /// The one sentence to show the user.
    public var userMessage: String {
        switch kind {
        case .blocked: return "平台风控拦截了本次请求，请稍后重试"
        case .notFound: return "内容不存在、已删除或不可见"
        case .network: return "网络请求失败，请检查网络后重试"
        case .unsupported: return message.isBlank ? "暂不支持该链接" : message
        case .unknown: return message.isBlank ? "解析失败，请稍后重试" : message
        }
    }
}

extension StringProtocol {
    var isBlank: Bool { allSatisfy(\.isWhitespace) }
}

extension String {
    func ifBlank(_ fallback: @autoclosure () -> String) -> String { isBlank ? fallback() : self }
}
