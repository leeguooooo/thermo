import AgentCore
import CryptoKit
import Darwin
import Foundation

public struct NativeUpdateSource: Codable, Sendable, Identifiable {
    public var id: String { app.path }
    public var app: InstalledApp
    /// sparkle | appStore | application. Discovery never contacts a server.
    public var kind: String
    public var feedHost: String?
    public var feedFingerprint: String?
    public var installedBuild: String?
    public var blocked: String?
    public var canCheck: Bool { kind == "sparkle" && blocked == nil }
}

public struct SparkleRelease: Codable, Sendable {
    public var build: String
    public var version: String
    public var downloadHost: String?
    public var enclosureFingerprint: String
    public var signature: String?
    public var length: Int64?
    public var minimumOS: String?
    public var maximumOS: String?
    public var minimumUpdateBuild: String?
    public var hardware: [String]
    public var channel: String?
    public var os: String?
    public var architecture: String?
    public var installationType: String? = nil
    // Authenticated feed URLs and signed download query strings must not enter exported JSON.
    var downloadURL: URL? = nil
    enum CodingKeys: String, CodingKey {
        case build, version, downloadHost, enclosureFingerprint, signature, length, minimumOS, maximumOS
        case minimumUpdateBuild, hardware, channel, os, architecture, installationType
    }
}

public struct NativeUpdateCheck: Codable, Sendable, Identifiable {
    public var id: String { source.id }
    public var source: NativeUpdateSource
    /// available | noNewerCompatibleVersion | manual | changed | failed | cancelled
    public var status: String
    public var message: String
    public var release: SparkleRelease?
    public var skipped: [String] = []
    public var checked = Date()
}

public enum NativeAppUpdates {
    public typealias Fetcher = @Sendable (URL) async throws -> Data
    public static let feedLimit = 2 * 1024 * 1024
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func https(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil && url.absoluteString.utf8.count <= 8192
    }

    static func feed(_ path: String) -> URL? {
        guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
              let value = info["SUFeedURL"] as? String, let url = URL(string: value), https(url) else { return nil }
        return url
    }

    public static func sources(home: String = NSHomeDirectory(), apps: [InstalledApp]? = nil) -> [NativeUpdateSource] {
        guard let apps else { return sourceReport(home: home).sources }
        return apps.map { app in
            let info = NSDictionary(contentsOfFile: app.path + "/Contents/Info.plist")
            var source = NativeUpdateSource(app: app, kind: "application")
            if FS.exists(app.path + "/Contents/_MASReceipt/receipt") { source.kind = "appStore" }
            else if info?["SUFeedURL"] != nil {
                source.kind = "sparkle"
                source.installedBuild = info?["CFBundleVersion"] as? String
                if let url = feed(app.path) {
                    source.feedHost = url.host
                    source.feedFingerprint = digest(url.absoluteString)
                } else { source.blocked = "This app's update feed is not a supported HTTPS URL; use the app's updater" }
                if source.installedBuild.flatMap({ UpdateVersion.compare($0, $0) }) == nil {
                    source.blocked = "The app has no comparable build version; use its own updater"
                }
            }
            if app.inventoryIdentity == nil {
                source.blocked = "Could not verify this app's file identity; inspect it in Finder"
            } else if AppReviewIdentity.capture(app.path) != app.inventoryIdentity {
                source.blocked = "The app changed since the inventory; refresh the app list and review again"
            }
            return source
        }
    }

    /// Verify a source again before checking it or handing it to the original updater.
    public static func unchanged(_ source: NativeUpdateSource, requireFeed: Bool = true) -> Bool {
        guard source.app.inventoryIdentity != nil, let app = AppUninstaller.read(source.app.path),
              app.bundleID == source.app.bundleID, app.inventoryIdentity == source.app.inventoryIdentity else { return false }
        if requireFeed && source.kind == "sparkle" {
            guard let url = feed(app.path), digest(url.absoluteString) == source.feedFingerprint else { return false }
        }
        return true
    }

    public static func check(_ source: NativeUpdateSource, fetcher: Fetcher? = nil,
                             systemVersion: String? = nil, architecture: String? = nil) async -> NativeUpdateCheck {
        var result = NativeUpdateCheck(source: source, status: "manual", message: "Check for updates in this app or on its official website")
        guard unchanged(source, requireFeed: false) else {
            result.status = "changed"; result.message = "The app changed since the inventory; refresh the app list and review again"; return result
        }
        guard source.canCheck, let url = feed(source.app.path), let installed = source.installedBuild else {
            result.message = source.blocked ?? (source.kind == "appStore" ? "Continue in App Store updates" : "Check for updates in this app or on its official website")
            return result
        }
        guard digest(url.absoluteString) == source.feedFingerprint else {
            result.status = "changed"; result.message = "The app changed since the inventory; refresh the app list and review again"; return result
        }
        do {
            try Task.checkCancellation()
            let data = try await (fetcher ?? fetch)(url)
            try Task.checkCancellation()
            guard unchanged(source) else {
                result.status = "changed"; result.message = "The app changed during the update check; refresh and check again"; return result
            }
            let parsed = try SparkleFeed.parse(data, baseURL: url)
            result.skipped = parsed.issues
            let currentOS = ProcessInfo.processInfo.operatingSystemVersion
            let system = systemVersion ?? "\(currentOS.majorVersion).\(currentOS.minorVersion).\(currentOS.patchVersion)"
            let arch = architecture ?? hostArchitecture
            var candidates: [SparkleRelease] = []
            for release in parsed.releases {
                guard let order = UpdateVersion.compare(release.build, installed) else {
                    result.skipped.append("A release has an unsupported version; use the app's updater"); continue
                }
                if order != .orderedDescending { continue }
                if let reason = ineligible(release, installed: installed, system: system, arch: arch) {
                    result.skipped.append(reason); continue
                }
                candidates.append(release)
            }
            result.release = candidates.max { UpdateVersion.compare($0.build, $1.build) == .orderedAscending }
            result.skipped = Array(Set(result.skipped)).sorted()
            if result.release != nil {
                result.status = "available"; result.message = "The feed lists a newer compatible build; finish updating in the app"
            } else {
                result.status = result.skipped.isEmpty ? "noNewerCompatibleVersion" : "manual"
                result.message = result.skipped.isEmpty ? "This feed lists no newer compatible build" : "Some feed entries need the app's updater; no installable update was selected"
            }
        } catch is CancellationError { result.status = "cancelled"; result.message = "Update check stopped" }
        catch {
            result.status = Task.isCancelled ? "cancelled" : "failed"
            result.message = Task.isCancelled ? "Update check stopped" : "Could not verify this update feed; try the app's own updater"
        }
        return result
    }

    static var hostArchitecture: String {
        var value: Int32 = 0, size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1 ? "arm64" : "x86_64"
    }

    static func ineligible(_ release: SparkleRelease, installed: String, system: String, arch: String) -> String? {
        if let channel = release.channel, !channel.isEmpty { return "Non-default update channels are left to the app's updater" }
        if let os = release.os, os != "macos" { return "A release targets another operating system" }
        if let target = release.architecture, target != "universal", target != arch { return "A release targets another CPU architecture" }
        if release.hardware.contains(where: { $0 != "arm64" }) || (release.hardware.contains("arm64") && arch != "arm64") {
            return "A release has unsupported hardware requirements"
        }
        if let min = release.minimumOS, UpdateVersion.compare(system, min) != .orderedDescending && UpdateVersion.compare(system, min) != .orderedSame {
            return "A release requires a newer or unrecognized macOS version"
        }
        if let max = release.maximumOS, UpdateVersion.compare(system, max) != .orderedAscending && UpdateVersion.compare(system, max) != .orderedSame {
            return "A release does not support this macOS version"
        }
        if let min = release.minimumUpdateBuild, UpdateVersion.compare(installed, min) != .orderedDescending && UpdateVersion.compare(installed, min) != .orderedSame {
            return "A release requires an intermediate app update"
        }
        return nil
    }

    /// Ephemeral, cookie-free, bounded HTTPS. Redirects cannot downgrade TLS or add URL credentials.
    public static func fetch(_ url: URL) async throws -> Data {
        guard https(url) else { throw Failure(message: "Unsupported feed URL") }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: FeedRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Thermo-UpdateCheck", forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= Int64(feedLimit), response.url.map(https) == true else { throw Failure(message: "Unsupported feed response") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < feedLimit else { throw Failure(message: "Update feed is too large") }
            data.append(byte)
            if data.count & 2047 == 0 { try Task.checkCancellation() }
        }
        return data
    }

    final class FeedRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private var count = 0 // URLSession's default delegate queue is serial.
        private func respond(_ challenge: URLAuthenticationChallenge, completion: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Public feed checks must not silently use a keychain, SSO or client certificate.
            completion(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                       ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            respond(challenge, completion: completionHandler)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            respond(challenge, completion: completionHandler)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            count += 1
            completionHandler(count <= 5 && request.url.map(NativeAppUpdates.https) == true ? request : nil)
        }
    }
}

enum SparkleFeed {
    static let namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    struct Parsed { var releases: [SparkleRelease]; var issues: [String] }
    static func parse(_ data: Data, baseURL: URL) throws -> Parsed {
        guard data.count <= NativeAppUpdates.feedLimit else { throw NativeAppUpdates.Failure(message: "Feed too large") }
        let delegate = Reader(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.rejected, delegate.sawRSS, delegate.sawChannel else { throw NativeAppUpdates.Failure(message: "Unsupported feed") }
        return Parsed(releases: delegate.releases, issues: delegate.issues)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        let baseURL: URL
        var releases: [SparkleRelease] = [], issues: [String] = []
        var depth = 0, itemDepth: Int?, fields: [String: String] = [:], enclosures: [[String: String]] = []
        var field: String?, text = "", fieldDepth = 0, itemCount = 0
        var namespaces: [String: [String]] = [:]
        var sawRSS = false, sawChannel = false, rejected = false
        var inChannel = false
        init(baseURL: URL) { self.baseURL = baseURL }
        func reject(_ parser: XMLParser) { rejected = true; parser.abortParsing() }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }
        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI uri: String) { namespaces[prefix, default: []].append(uri) }
        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { _ = namespaces[prefix]?.popLast() }
        func normalized(_ attributes: [String: String]) -> [String: String] {
            var out: [String: String] = [:]
            for (key, value) in attributes {
                let pair = key.split(separator: ":", maxSplits: 1)
                if pair.count == 2, namespaces[String(pair[0])]?.last == SparkleFeed.namespace { out[String(pair[1])] = value }
                else if pair.count == 1, ["url", "length"].contains(key) { out[key] = value }
            }
            return out
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI uri: String?, qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            if depth > 32 || Task.isCancelled { reject(parser); return }
            if depth == 1 { sawRSS = name == "rss" }
            if sawRSS, depth == 2, name == "channel" {
                guard !sawChannel else { reject(parser); return }
                sawChannel = true; inChannel = true
            }
            if sawRSS && inChannel && depth == 3 && name == "item" {
                itemCount += 1
                guard itemCount <= 256 else { reject(parser); return }
                itemDepth = depth; fields = [:]; enclosures = []; return
            }
            guard let start = itemDepth, depth == start + 1 else { return }
            if name == "enclosure", uri != SparkleFeed.namespace { enclosures.append(normalized(attributes)) }
            else if uri == SparkleFeed.namespace, ["version", "shortVersionString", "minimumSystemVersion", "maximumSystemVersion", "minimumUpdateVersion", "hardwareRequirements", "channel"].contains(name) {
                field = name; fieldDepth = depth; text = ""
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if field != nil { text += string; if text.utf8.count > 8192 { reject(parser) } }
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self)) }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if depth == fieldDepth, let field { fields[field] = text.trimmingCharacters(in: .whitespacesAndNewlines); self.field = nil }
            if depth == itemDepth {
                finishItem(); itemDepth = nil
            }
            if depth == 2, name == "channel" { inChannel = false }
            depth -= 1
        }
        func finishItem() {
            if enclosures.isEmpty { issues.append("Some feed entries require the app's own updater"); return }
            for enclosure in enclosures {
                if enclosure["deltaFrom"] != nil { issues.append("Delta updates are left to the app's updater"); continue }
                guard let build = enclosure["version"] ?? fields["version"], UpdateVersion.compare(build, build) != nil,
                      let rawURL = enclosure["url"], let url = URL(string: rawURL, relativeTo: baseURL)?.absoluteURL, NativeAppUpdates.https(url) else {
                    issues.append("Some feed entries require the app's own updater"); continue
                }
                let stable = (try? JSONSerialization.data(withJSONObject: enclosure, options: [.sortedKeys])) ?? Data()
                let fingerprint = SHA256.hash(data: stable).map { String(format: "%02x", $0) }.joined()
                let hardware = Array(Set((fields["hardwareRequirements"] ?? "").split { $0.isWhitespace || $0 == "," }.map { $0.lowercased() })).sorted()
                let version = enclosure["shortVersionString"] ?? fields["shortVersionString"] ?? build
                guard version.utf8.count <= 128, !version.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    issues.append("Some feed entries require the app's own updater"); continue
                }
                let rawSignature = enclosure["edSignature"] ?? ""
                let signature = rawSignature.utf8.count <= 128 && Data(base64Encoded: rawSignature)?.count == 64 ? rawSignature : nil
                var release = SparkleRelease(build: build, version: version,
                    downloadHost: url.host, enclosureFingerprint: fingerprint, signature: signature, length: enclosure["length"].flatMap(Int64.init),
                    minimumOS: fields["minimumSystemVersion"], maximumOS: fields["maximumSystemVersion"], minimumUpdateBuild: fields["minimumUpdateVersion"],
                    hardware: hardware, channel: fields["channel"], os: enclosure["os"], architecture: enclosure["arch"])
                release.downloadURL = url
                release.installationType = enclosure["installationType"]
                releases.append(release)
            }
        }
    }
}
