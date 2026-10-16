import AgentCore
import Darwin
import Foundation

public struct AppInventoryIssue: Codable, Sendable, Equatable {
    public let message: String
    public let path: String
    /// False when the app's path/name is known but its metadata could not be verified.
    public let affectsScope: Bool
    public init(_ message: String, path: String, affectsScope: Bool = true) {
        self.message = message; self.path = path; self.affectsScope = affectsScope
    }
}

public struct InstalledAppsReport: Codable, Sendable {
    public let apps: [InstalledApp]
    public let roots: [String]
    public let issues: [AppInventoryIssue]
    public let issuesTruncated: Bool
    public let cancelled: Bool
    public let complete: Bool
    public let scopeComplete: Bool
    public init(apps: [InstalledApp], roots: [String], issues: [AppInventoryIssue] = [], issuesTruncated: Bool = false, cancelled: Bool = false) {
        self.apps = apps; self.roots = roots; self.issues = issues; self.issuesTruncated = issuesTruncated; self.cancelled = cancelled
        complete = !cancelled && issues.isEmpty && !issuesTruncated
        scopeComplete = !cancelled && !issuesTruncated && !issues.contains(where: \.affectsScope)
    }
}

extension AppUninstaller {
    /// Metadata only: real application folders and one suite-folder level. No network or size scan.
    public static func installedReport(home: String = NSHomeDirectory(), dirs: [String]? = nil,
                                       cancellation: ScanCancellation? = nil) -> InstalledAppsReport {
        installedReport(home: home, dirs: dirs, cancellation: cancellation, afterEnumeration: {})
    }
    static func installedReport(home: String, dirs: [String]?, cancellation: ScanCancellation?,
                                afterEnumeration: () -> Void) -> InstalledAppsReport {
        let token = cancellation ?? ScanCancellation.current
        let previous = ScanCancellation.current
        if let token { ScanCancellation.current = token }
        defer { ScanCancellation.current = previous }
        let roots = Array(Set(dirs ?? appDirs(home: home))).sorted()
        var seen = Set<String>(), apps: [InstalledApp] = [], issues: [AppInventoryIssue] = []
        var truncated = false, directories: [String: String?] = [:]
        func issue(_ message: String, _ path: String, affectsScope: Bool = true) {
            if issues.count < 128 { issues.append(.init(message, path: path, affectsScope: affectsScope)) } else { truncated = true }
        }
        func list(_ directory: String) -> [String] {
            directories.updateValue(AppDataReviewIdentity.of(directory), forKey: directory)
            return names(in: directory, onFailure: { issue("Could not inspect application directory", directory) }) ?? []
        }
        for dir in roots {
            if token?.isCancelled == true { break }
            var bundles: [String] = []
            for name in list(dir).sorted() where !name.hasPrefix(".") {
                if token?.isCancelled == true { break }
                let path = dir + "/" + name
                if name.hasSuffix(".app") { bundles.append(path); continue }
                guard dir != "/Applications/Utilities" else { continue }
                var info = stat()
                guard lstat(path, &info) == 0 else { issue("Application directory entry changed or could not be inspected", path); continue }
                guard info.st_mode & S_IFMT == S_IFDIR else { continue }
                bundles += list(path).filter { $0.hasSuffix(".app") && !$0.hasPrefix(".") }.map { path + "/" + $0 }
            }
            for path in bundles where seen.insert(path).inserted {
                if token?.isCancelled == true { break }
                guard var app = read(path) else { issue("Application disappeared or could not be inspected", path); continue }
                app.protected = protection(app, home: home)
                if app.inventoryIdentity == nil {
                    issue("Could not verify application metadata", path, affectsScope: false)
                    if app.protected == nil { app.protected = tr("Could not verify this app's file identity; inspect it in Finder") }
                } else if app.bundleID == nil { issue("Application metadata is missing or invalid", path, affectsScope: false) }
                app.cask = cask(for: app, cancellation: token)
                apps.append(app)
            }
        }
        afterEnumeration()
        for (path, before) in directories where AppDataReviewIdentity.of(path) != before {
            issue("Application directory changed during discovery", path)
        }
        return .init(apps: apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, roots: roots,
                     issues: issues, issuesTruncated: truncated, cancelled: token?.isCancelled == true)
    }
}

public struct NativeUpdateSourcesReport: Codable, Sendable {
    public let sources: [NativeUpdateSource]
    public let roots: [String]
    public let issues: [AppInventoryIssue]
    public let issuesTruncated: Bool
    public let cancelled: Bool
    public let complete: Bool
    public let scopeComplete: Bool
    public let discovered: Date
    public init(sources: [NativeUpdateSource], roots: [String] = [], issues: [AppInventoryIssue] = [],
                issuesTruncated: Bool = false, cancelled: Bool = false) {
        self.sources = sources; self.roots = roots; self.issues = issues; self.issuesTruncated = issuesTruncated; self.cancelled = cancelled
        complete = !cancelled && issues.isEmpty && !issuesTruncated
        scopeComplete = !cancelled && !issuesTruncated && !issues.contains(where: \.affectsScope)
        discovered = Date()
    }
}

extension NativeAppUpdates {
    public static func sourceReport(home: String = NSHomeDirectory(), dirs: [String]? = nil,
                                    cancellation: ScanCancellation? = nil) -> NativeUpdateSourcesReport {
        let inventory = AppUninstaller.installedReport(home: home, dirs: dirs, cancellation: cancellation)
        var sources: [NativeUpdateSource] = []
        for app in inventory.apps {
            if inventory.cancelled || cancellation?.isCancelled == true { break }
            sources += Self.sources(home: home, apps: [app])
        }
        var issues = inventory.issues, truncated = inventory.issuesTruncated
        for source in sources where source.app.inventoryIdentity != nil && AppReviewIdentity.capture(source.app.path) != source.app.inventoryIdentity {
            if issues.count < 128 { issues.append(.init("Application changed during source discovery", path: source.app.path, affectsScope: false)) } else { truncated = true }
        }
        return .init(sources: sources, roots: inventory.roots, issues: issues, issuesTruncated: truncated,
                     cancelled: inventory.cancelled || cancellation?.isCancelled == true)
    }
}
