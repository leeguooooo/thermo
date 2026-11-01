import AgentCore
import CleanKit
import Foundation

/// Reads one platform's cookies from the user's Chrome through chrome-use, read-only. `cookies export`
/// prints to stdout, so the values stay in this process's memory: no file, no argv, no log.
struct YunXChromeCookies: Sendable {
    /// One chrome-use run; nil when it could not run or failed.
    typealias Runner = @Sendable ([String]) -> String?
    /// Nil when chrome-use is missing or too old.
    let runner: @Sendable () -> Runner?

    /// `security` may wait on the Keychain prompt for Chrome Safe Storage, so this allows time to answer.
    static let timeout: TimeInterval = 60

    static let live = YunXChromeCookies {
        guard let tool = ChromeInspector.chromeUseDiagTool() else { return nil }
        return { args in
            let result = CommandRunner.run(tool, arguments: args, timeout: timeout, captureError: false)
            guard !result.timedOut, !result.cancelled, !result.truncated, result.status == 0 else { return nil }
            return result.output
        }
    }

    private struct Browsers: Decodable {
        struct Payload: Decodable { var browsers: [Profile] }
        struct Profile: Decodable { var dir: String; var connected: Bool?; var `default`: Bool? }
        var data: Payload
    }

    private struct Export: Decodable {
        struct Cookie: Decodable { var name: String; var value: String; var domain: String; var expires: Double? }
        var success: Bool
        var data: [Cookie]
    }

    /// The profile chrome-use works with. Other profiles may be other people's, so they are never read.
    static func profile(_ browsers: String) -> String? {
        guard let list = try? JSONDecoder().decode(Browsers.self, from: Data(browsers.utf8)).data.browsers else { return nil }
        return (list.first { $0.connected == true && $0.default == true } ?? list.first { $0.connected == true }
            ?? list.first { $0.default == true })?.dir
    }

    /// The export filter is a plain suffix ("115.com" also takes "x115.com"), so hosts are matched again here.
    static func belongs(_ host: String, to domains: [String]) -> Bool {
        let host = host.hasPrefix(".") ? String(host.dropFirst()) : host
        return domains.contains { domain in
            let domain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            return host == domain || host.hasSuffix("." + domain)
        }
    }

    /// The Cookie header when Chrome is logged in to these domains, else nil.
    func header(domains: [String], required: [String], anyOf: [String], now: Date = Date()) -> String? {
        guard let run = runner(), let browsers = run(["browsers", "--json"]), let profile = Self.profile(browsers) else { return nil }
        let filter = domains.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }.joined(separator: ",")
        guard let output = run(["cookies", "export", "--from", profile, "--domain", filter, "--json"]),
              let export = try? JSONDecoder().decode(Export.self, from: Data(output.utf8)), export.success else { return nil }
        let live = export.data.filter { cookie in
            Self.belongs(cookie.domain, to: domains) && (cookie.expires.map { $0 > now.timeIntervalSince1970 } ?? true)
        }
        return YunXLoginMethod.detect(live.map { ($0.domain, $0.name, $0.value) }, domains: domains, required: required, anyOf: anyOf)
    }
}

/// The embedded login page keeps a desktop viewport: sites lay out for this width, and a smaller
/// screen scales the page rather than cutting off its side panel.
enum YunXLoginLayout {
    static let viewport: CGFloat = 1180

    static func sheet(screen: CGSize) -> CGSize {
        CGSize(width: min(1240, screen.width - 80), height: min(780, screen.height - 80))
    }

    static func zoom(pageWidth: CGFloat) -> CGFloat { min(1, max(0.5, pageWidth / viewport)) }
}
