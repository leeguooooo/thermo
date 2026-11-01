import AgentCore
import CleanKit
import Foundation

/// Reads one platform's login from the user's Chrome through chrome-use, read-only. Output goes to
/// stdout, so the values stay in this process's memory: no file, no argv, no log.
struct YunXChromeCookies: Sendable {
    /// One chrome-use run; nil when it could not run or failed.
    typealias Runner = @Sendable ([String]) -> String?
    /// Nil when chrome-use is missing or too old.
    let runner: @Sendable () -> Runner?
    /// Opens a page in Chrome when chrome-use cannot.
    var openInChrome: @Sendable (String) -> Bool = { url in
        CommandRunner.run("/usr/bin/open", arguments: ["-a", "Google Chrome", url], timeout: 15).status == 0
    }

    /// `security` may wait on the Keychain prompt for Chrome Safe Storage, so this allows time to answer.
    static let timeout: TimeInterval = 60
    /// Thermo's own tab group, so it never reads whatever tab another session is on.
    static let session = "thermo-yunx"

    static let live = YunXChromeCookies(runner: {
        guard let tool = ChromeInspector.chromeUseDiagTool() else { return nil }
        return { args in
            let result = CommandRunner.run(tool, arguments: args, timeout: timeout, captureError: false)
            guard !result.timedOut, !result.cancelled, !result.truncated, result.status == 0 else { return nil }
            return result.output
        }
    })

    private struct Browsers: Decodable {
        struct Payload: Decodable { var browsers: [Profile] }
        struct Profile: Decodable { var dir: String; var connected: Bool?; var `default`: Bool?; var name: String? }
        var data: Payload
    }

    private struct Export: Decodable {
        var success: Bool
        var data: [Cookie]
    }

    private struct Live: Decodable {
        struct Payload: Decodable { var cookies: [Cookie] }
        var success: Bool
        var data: Payload
    }

    private struct Cookie: Decodable { var name: String; var value: String; var domain: String; var expires: Double? }

    private struct Evaluated: Decodable {
        struct Payload: Decodable { var result: String? }
        var success: Bool
        var data: Payload
    }

    /// The profile chrome-use works with. Other profiles may be other people's, so they are never read.
    static func profile(_ browsers: String) -> String? {
        guard let list = try? JSONDecoder().decode(Browsers.self, from: Data(browsers.utf8)).data.browsers else { return nil }
        return (list.first { $0.connected == true && $0.default == true } ?? list.first { $0.connected == true }
            ?? list.first { $0.default == true })?.dir
    }

    /// Whether a Chrome profile is connected, and the name `connect --browser` wants for the default one.
    static func connection(_ browsers: String) -> (connected: Bool, profile: String?) {
        guard let list = try? JSONDecoder().decode(Browsers.self, from: Data(browsers.utf8)).data.browsers else { return (false, nil) }
        let pick = list.first { $0.default == true } ?? list.first
        return (list.contains { $0.connected == true }, pick?.name ?? pick?.dir)
    }

    /// The export filter is a plain suffix ("115.com" also takes "x115.com"), so hosts are matched again here.
    static func belongs(_ host: String, to domains: [String]) -> Bool {
        let host = host.hasPrefix(".") ? String(host.dropFirst()) : host
        return domains.contains { domain in
            let domain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            return host == domain || host.hasSuffix("." + domain)
        }
    }

    var available: Bool { runner() != nil }

    /// The Cookie header when Chrome is logged in to these domains, else nil. `live` also asks the
    /// browser, for the tab `open` made: a login that just happened may not be on disk yet.
    func header(domains: [String], required: [String], anyOf: [String], live: Bool = false, now: Date = Date()) -> String? {
        guard let run = runner(), let browsers = run(["browsers", "--json"]), let profile = Self.profile(browsers) else { return nil }
        let filter = domains.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }.joined(separator: ",")
        func detect(_ cookies: [Cookie]) -> String? {
            let kept = cookies.filter { cookie in
                // The browser reports a session cookie as -1.
                let alive = cookie.expires.map { $0 <= 0 || $0 > now.timeIntervalSince1970 } ?? true
                return Self.belongs(cookie.domain, to: domains) && alive
            }
            return YunXLoginMethod.detect(kept.map { ($0.domain, $0.name, $0.value) }, domains: domains, required: required, anyOf: anyOf)
        }
        if let output = run(["cookies", "export", "--from", profile, "--domain", filter, "--json"]),
           let export = try? JSONDecoder().decode(Export.self, from: Data(output.utf8)), export.success,
           let found = detect(export.data) { return found }
        guard live, let output = run(["--session", Self.session, "cookies", "get", "--json"]),
              let current = try? JSONDecoder().decode(Live.self, from: Data(output.utf8)), current.success else { return nil }
        return detect(current.data.cookies)
    }

    /// Opens the login page in the connected Chrome, or plain Chrome if that fails.
    func open(_ url: String) -> Bool {
        if let run = runner(), run(["--session", Self.session, "open", url, "--new-tab"]) != nil { return true }
        return openInChrome(url)
    }

    /// Xunlei keeps its login in localStorage. The script refuses any other host.
    func xunleiLogin() -> String? {
        guard let run = runner() else { return nil }
        let script = Data(YunXXunleiWeb.readScript.utf8).base64EncodedString()
        guard let output = run(["--session", Self.session, "--json", "eval", "--base64", script]),
              let value = try? JSONDecoder().decode(Evaluated.self, from: Data(output.utf8)), value.success,
              let raw = value.data.result?.removingPercentEncoding, !raw.isEmpty else { return nil }
        return raw
    }
}
