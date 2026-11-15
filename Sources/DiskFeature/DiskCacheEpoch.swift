import CleanKit
import Foundation

/// Only a scalar restore revision is shared with a cold callback/retiring generation.
/// After restoration, this launch bypasses persisted caches whose writes have no success proof.
final class DiskCacheEpoch:@unchecked Sendable {
    private let lock=NSLock()
    private var revision:UInt64=0
    private let clear:@Sendable ()->Void
    init(clear:@escaping @Sendable ()->Void = {ScanReportCache.invalidate();SpaceOverview.invalidate()}) {self.clear=clear}
    var current:UInt64 {lock.lock();defer{lock.unlock()};return revision}
    var permitsCache:Bool {current == 0}
    func invalidate(){lock.lock();revision &+= 1;lock.unlock();clear()}
    func clearFiles(){clear()}
}
