import Foundation

/// A parser for one platform. Failures are always `VideoParseException`, or `CancellationError`.
public protocol VideoParser: Sendable {
    var platform: VideoPlatform { get }

    /// - Parameter cookie: the platform's full Cookie header, empty when logged out.
    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult

    /// Returns the nickname (empty if unavailable), or nil when the Cookie is invalid.
    func validateCookie(_ cookie: String) async throws -> String?
}

extension VideoParser {
    public func validateCookie(_ cookie: String) async throws -> String? {
        cookie.isBlank ? nil : ""
    }
}

/// A parser that can re-parse at a chosen quality. Links are signed per quality, so switching
/// quality means parsing again. A nil `qn` takes the platform default.
public protocol QualitySelectableParser: Sendable {
    func parseWithQuality(_ link: DetectedVideoLink, cookie: String, qn: Int?) async throws -> VideoParseResult
}
