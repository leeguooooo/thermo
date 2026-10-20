import CoreMediaIO
import Foundation

extension CameraActivity {
    public final class Watcher: @unchecked Sendable {
        struct Key: Hashable, Sendable {
            var object: UInt32
            var selector: UInt32
            var scope: UInt32 = UInt32(kCMIOObjectPropertyScopeGlobal)
            var address: CMIOObjectPropertyAddress { CameraActivity.address(selector, scope: scope) }
        }
        struct Operations {
            var objects: () -> [UInt32]?
            var add: (Key, @escaping @Sendable () -> Void) -> Bool
            var remove: (Key) -> Bool
        }
        private let queue = DispatchQueue(label: "dev.thermo.camera-events", qos: .utility)
        private let changed: @Sendable () -> Void
        private let coverage: @Sendable (Bool) -> Void
        private let operations: Operations?
        private var enabled = false
        private var registered = Set<Key>()
        private var blocks: [Key: CMIOObjectPropertyListenerBlock] = [:]
        private let root = Key(object: UInt32(kCMIOObjectSystemObject), selector: UInt32(kCMIOHardwarePropertyDevices))
        public convenience init(changed: @escaping @Sendable () -> Void, coverage: @escaping @Sendable (Bool) -> Void) {
            self.init(operations: nil, changed: changed, coverage: coverage)
        }
        init(operations: Operations?, changed: @escaping @Sendable () -> Void, coverage: @escaping @Sendable (Bool) -> Void) {
            self.operations = operations; self.changed = changed; self.coverage = coverage
        }
        deinit { for key in registered { _ = removeNative(key) } }
        public func start() { queue.async { [self] in enabled = true; reconcile() } }
        public func refresh() { queue.async { [self] in if enabled { reconcile() } } }
        public func stop() {
            queue.async { [self] in
                enabled = false
                for key in Array(registered) { remove(key) }
            }
        }
        private func removeNative(_ key: Key) -> Bool {
            if let operations { return operations.remove(key) }
            guard let block = blocks[key] else { return true }
            var a = key.address
            // A disappeared object has no remaining property registration to own.
            guard CMIOObjectHasProperty(key.object, &a) else { return true }
            return CMIOObjectRemovePropertyListenerBlock(key.object, &a, queue, block) == noErr
        }
        private func remove(_ key: Key) {
            if removeNative(key) { registered.remove(key); blocks.removeValue(forKey: key) }
        }
        private func install(_ key: Key) {
            guard !registered.contains(key) else { return }
            let callback: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                self.queue.async { [self] in
                    guard self.enabled, self.registered.contains(key) else { return }
                    if key == self.root { self.reconcile() }
                    self.changed()
                }
            }
            if let operations {
                if operations.add(key, callback) { registered.insert(key) }
            } else {
                var a = key.address
                let block: CMIOObjectPropertyListenerBlock = { _, _ in callback() }
                if CMIOObjectHasProperty(key.object, &a), CMIOObjectAddPropertyListenerBlock(key.object, &a, queue, block) == noErr {
                    blocks[key] = block; registered.insert(key)
                }
            }
        }
        private func reconcile() {
            install(root)
            let roster = operations.map { $0.objects() } ?? CameraActivity.live.objects()
            guard let roster, roster.count <= 256, Set(roster).count == roster.count else { coverage(false); return }
            var wanted: Set<Key> = [root]
            for object in roster {
                wanted.insert(.init(object: object, selector: UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere)))
                wanted.insert(.init(object: object, selector: UInt32(kCMIODevicePropertyDeviceIsAlive)))
                wanted.insert(.init(object: object, selector: UInt32(kCMIODevicePropertyStreams), scope: UInt32(kCMIODevicePropertyScopeInput)))
            }
            let began = ProcessInfo.processInfo.systemUptime
            for key in registered.subtracting(wanted) {
                guard ProcessInfo.processInfo.systemUptime - began < 2 else { break }; remove(key)
            }
            for key in wanted.subtracting(registered) {
                guard ProcessInfo.processInfo.systemUptime - began < 2 else { break }; install(key)
            }
            coverage(wanted == registered)
        }
    }
}
