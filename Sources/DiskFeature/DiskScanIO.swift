import CleanKit
import Foundation
import ThermoL10n

/// File-system preparation, cached report decoding and scanning run on DiskModel's
/// serial worker. UI state and the decision to accept their results stay on main.
struct DiskScanIO: Sendable {
    typealias Progress = @Sendable (String) -> Void
    typealias Items = @Sendable ([CleanItem]) -> Void
    var options: @Sendable (DiskModel.Scope, CleanCategory?, Int?) -> ScanOptions
    var cached: @Sendable (ScanOptions, String) -> ScanReport?
    var scan: @Sendable (ScanOptions, ScanCancellation, @escaping Progress, @escaping Items) -> ScanReport

    static let live = DiskScanIO(options: { DiskModel.scanOptions(scope: $0, category: $1, sessionRetentionDays: $2) }, cached: { options, language in
        guard var report = ScanReportCache.load(home: options.home, maxAge: 3600, matching: {
            $0.sessionPolicyVersion == ScanOptions.sessionPolicyVersion && $0.sessionRetentionDays == options.sessionRetentionDays &&
            $0.language == language && options.categories.isSubset(of: Set($0.categories ?? [])) &&
            $0.projectRoots == Array(Set(options.projectRoots)).sorted() &&
            $0.discoverProjectRoots == options.discoverProjectRoots && $0.olderThanDays == options.olderThanDays
        }) else { return nil }
        report.applyWhitelist(home: options.home)
        return report
    }, scan: { options, cancellation, progress, items in
        let scanner = DiskScanner(options: options, cancellation: cancellation)
        scanner.onProgress = progress
        scanner.onItems = items
        return scanner.scan()
    })
}
