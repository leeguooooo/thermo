import AppKit

/// Only immutable rendered CGImages cross the lock. Rendering itself stays on the caller's thread.
/// The shared budget is strict, including row padding; large images still render at full resolution.
final class CaptureRenderCache:@unchecked Sendable {
    static let shared=CaptureRenderCache()
    private struct Entry {let source:ObjectIdentifier;let revision:Int;let image:CGImage;let bytes:Int}
    private let lock=NSLock()
    private let byteLimit:Int
    private let entryLimit:Int
    private var entries:[UUID:Entry]=[:]
    private var order:[UUID]=[]
    private var used=0
    init(byteLimit:Int=128*1024*1024,entryLimit:Int=32) {self.byteLimit=max(0,byteLimit);self.entryLimit=max(0,entryLimit)}
    var cachedBytes:Int {lock.lock();defer{lock.unlock()};return used}
    var count:Int {lock.lock();defer{lock.unlock()};return entries.count}
    func remove(owner:UUID) {lock.lock();defer{lock.unlock()};removeLocked(owner)}
    private func removeLocked(_ owner:UUID) {
        if let previous=entries.removeValue(forKey:owner) {used-=previous.bytes}
        order.removeAll{$0 == owner}
    }
    func image(owner:UUID,source:ObjectIdentifier,revision:Int,render:()throws->CGImage) rethrows -> CGImage {
        lock.lock()
        if let value=entries[owner],value.source == source,value.revision == revision {
            order.removeAll{$0 == owner};order.append(owner);lock.unlock();return value.image
        }
        removeLocked(owner);lock.unlock()
        let image=try render()
        guard entryLimit > 0,image.bytesPerRow > 0,image.height <= byteLimit/image.bytesPerRow else {return image}
        let cost=image.bytesPerRow*image.height
        lock.lock();defer{lock.unlock()}
        removeLocked(owner)
        while used > byteLimit-cost || entries.count >= entryLimit {
            guard let oldest=order.first else {break};removeLocked(oldest)
        }
        entries[owner]=Entry(source:source,revision:revision,image:image,bytes:cost);order.append(owner);used+=cost
        return image
    }
}
