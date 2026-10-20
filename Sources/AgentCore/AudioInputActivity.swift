import CoreAudio
import Darwin
import Foundation

/// Metadata only. Never creates a capture session, taps audio, or requests recording permission.
public struct AudioInputDevice: Codable, Sendable, Equatable {
    public var id: UInt32
    public var uid: String
    public var name: String
    public init(id: UInt32, uid: String, name: String) { self.id = id; self.uid = uid; self.name = name }
}

public struct AudioInputClient: Codable, Sendable, Equatable {
    public var objectID: UInt32
    public var process: ProcessIdentity
    public var bundleID: String?
    public var devices: [AudioInputDevice]

    public init(objectID: UInt32, process: ProcessIdentity, bundleID: String?, devices: [AudioInputDevice] = []) {
        self.objectID = objectID; self.process = process; self.bundleID = bundleID; self.devices = devices
    }
    public var name: String { URL(fileURLWithPath: process.executable).lastPathComponent }
    public var muteKey: String { bundleID ?? "executable:\(process.executable)" }
}

public struct AudioInputObservation: Codable, Sendable, Equatable {
    public var clients: [AudioInputClient]
    public var issues: [String]
    public var available: Bool
    public var sampled: Date
    public init(clients: [AudioInputClient] = [], issues: [String] = [], available: Bool = true, sampled: Date = Date()) {
        self.clients = clients; self.issues = issues; self.available = available; self.sampled = sampled
    }
    public var complete: Bool { available && issues.isEmpty }
}

public enum AudioInputActivity {
    struct Reader {
        var objects: () -> [UInt32]?
        var pid: (UInt32) -> Int32?
        var running: (UInt32) -> Bool?
        var bundle: (UInt32) -> String?
        var identity: (Int32) -> ProcessIdentity?
        var devices: (UInt32) -> [AudioInputDevice]?
    }

    public static func read() -> AudioInputObservation { read(reader: live, uid: getuid()) }

    static func read(reader: Reader, uid: UInt32) -> AudioInputObservation {
        guard let objects = reader.objects(), objects.count <= 4096, Set(objects).count == objects.count else {
            return .init(issues: ["Could not read audio process activity"], available: false)
        }
        let started = ProcessInfo.processInfo.systemUptime
        var clients: [AudioInputClient] = [], issues: [String] = []
        for object in objects {
            guard ProcessInfo.processInfo.systemUptime - started < 2 else {
                issues.append("Audio activity check exceeded its time budget"); break
            }
            guard let pid = reader.pid(object), pid > 0, let running = reader.running(object) else {
                issues.append("Could not verify an audio process"); continue
            }
            if !running {
                if reader.pid(object) != pid { issues.append("Audio process changed during the check") }
                continue
            }
            guard let before = reader.identity(pid), before.pid == pid,
                  before.started.timeIntervalSince1970.isFinite, before.started.timeIntervalSince1970 > 0,
                  before.executable.hasPrefix("/") else {
                issues.append("Could not verify an active input process"); continue
            }
            // Other accounts are outside this user's notification scope.
            guard before.uid == uid else {
                if reader.pid(object) != pid || reader.identity(pid) != before { issues.append("Audio process changed during the check") }
                continue
            }
            guard let devices = reader.devices(object), !devices.isEmpty else {
                issues.append("Could not verify the active input devices"); continue
            }
            let bundle = reader.bundle(object).flatMap { value -> String? in
                guard !value.isEmpty, value.utf8.count <= 255,
                      !value.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
                return value
            }
            guard reader.pid(object) == pid, reader.running(object) == true,
                  reader.identity(pid) == before, reader.devices(object) == devices else {
                issues.append("Active input process changed during the check"); continue
            }
            // Several HAL objects can refer to the same process. The process is the notification unit.
            if let index = clients.firstIndex(where: { $0.process == before }) {
                if clients[index].bundleID != bundle { issues.append("Audio process attribution changed during the check") }
                for device in devices where !clients[index].devices.contains(device) { clients[index].devices.append(device) }
                clients[index].devices.sort { $0.id < $1.id }
            } else {
                clients.append(.init(objectID: object, process: before, bundleID: bundle, devices: devices))
            }
        }
        guard reader.objects() == objects else {
            return .init(issues: ["Audio process list changed during the check"], available: false)
        }
        return .init(clients: clients.sorted { $0.process.pid < $1.process.pid }, issues: Array(Set(issues)).sorted())
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static func scalar(_ object: UInt32, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var a = address(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(object, &a),
              AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }
    private static func string(_ object: UInt32, _ selector: AudioObjectPropertySelector) -> String? {
        // These properties return retained CFStrings (AudioHardware.h).
        var a = address(selector), value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectHasProperty(object, &a),
              AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<CFString?>.size, let value else { return nil }
        return value.takeRetainedValue() as String
    }
    private static var live: Reader {
        Reader(objects: {
            var a = address(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
            guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &a),
                  AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr,
                  size <= 4096 * MemoryLayout<UInt32>.size, size % 4 == 0 else { return nil }
            if size == 0 { return [] }
            var ids = [UInt32](repeating: 0, count: Int(size) / 4)
            let expected = size
            let status = ids.withUnsafeMutableBytes {
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, $0.baseAddress!)
            }
            return status == noErr && size == expected ? ids : nil
        }, pid: { scalar($0, kAudioProcessPropertyPID).map { Int32(bitPattern: $0) } }, running: {
            scalar($0, kAudioProcessPropertyIsRunningInput).flatMap { $0 <= 1 ? $0 == 1 : nil }
        }, bundle: { string($0, kAudioProcessPropertyBundleID) }, identity: ProcessTable.identity, devices: { object in
            var a = address(kAudioProcessPropertyDevices); a.mScope = kAudioObjectPropertyScopeInput
            var size: UInt32 = 0
            guard AudioObjectHasProperty(object, &a),
                  AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr,
                  size > 0, size <= 256 * 4, size % 4 == 0 else { return nil }
            var ids = [UInt32](repeating: 0, count: Int(size) / 4); let expected = size
            let status = ids.withUnsafeMutableBytes {
                AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!)
            }
            guard status == noErr, size == expected, Set(ids).count == ids.count else { return nil }
            var result: [AudioInputDevice] = []
            for id in ids.sorted() {
                guard let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty,
                      let name = string(id, kAudioObjectPropertyName), !name.isEmpty,
                      string(id, kAudioDevicePropertyDeviceUID) == uid else { return nil }
                result.append(.init(id: id, uid: uid, name: name))
            }
            return result
        })
    }
}

/// Starts from a quiet baseline. An unreadable interval cannot establish a stop/start transition.
public struct AudioInputTransitions: Sendable {
    private var previous: [AudioInputClient]?
    public init() {}
    public mutating func reset() { previous = nil }
    public mutating func observe(_ value: AudioInputObservation, muted: Set<String> = []) -> [AudioInputClient] {
        guard value.complete else { previous = nil; return [] }
        defer { previous = value.clients }
        guard let previous else { return [] }
        return value.clients.filter { client in
            !previous.contains { $0.process == client.process } && !muted.contains(client.muteKey)
        }
    }
}

extension AudioInputActivity {
    /// Event wakeups plus the app's independent polling fallback. Never opens an input stream.
    public final class Watcher: @unchecked Sendable {
        struct Key: Hashable, Sendable {
            var object: UInt32
            var selector: UInt32
            var scope: UInt32 = kAudioObjectPropertyScopeGlobal
            var address: AudioObjectPropertyAddress {
                .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            }
        }
        struct Operations {
            var objects: () -> [UInt32]?
            var add: (Key, @escaping @Sendable () -> Void) -> Bool
            var remove: (Key) -> Void
        }
        private let queue = DispatchQueue(label: "dev.thermo.audio-input-events", qos: .utility)
        private let changed: @Sendable () -> Void
        private let coverage: @Sendable (Bool) -> Void
        private let operations: Operations?
        private var enabled = false
        private var registered: Set<Key> = []
        private var blocks: [Key: AudioObjectPropertyListenerBlock] = [:]
        private let rosterKey = Key(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList)

        public convenience init(changed: @escaping @Sendable () -> Void, coverage: @escaping @Sendable (Bool) -> Void = { _ in }) {
            self.init(operations: nil, changed: changed, coverage: coverage)
        }
        init(operations: Operations?, changed: @escaping @Sendable () -> Void, coverage: @escaping @Sendable (Bool) -> Void = { _ in }) {
            self.operations = operations; self.changed = changed; self.coverage = coverage
        }
        deinit {
            // All queued operations retain self. No callback can acquire self once deinit begins.
            for key in registered {
                if let operations { operations.remove(key) }
                else if let block = blocks[key] {
                    var a = key.address
                    AudioObjectRemovePropertyListenerBlock(key.object, &a, queue, block)
                }
            }
        }
        public func start() {
            queue.async { [self] in
                guard !enabled else { return }
                enabled = true; install(rosterKey); reconcile()
            }
        }
        public func refresh() {
            queue.async { [self] in
                guard enabled else { return }
                install(rosterKey); reconcile()
            }
        }
        public func stop() {
            queue.async { [self] in
                enabled = false
                for key in Array(registered) { remove(key) }
            }
        }
        private func install(_ key: Key) {
            guard !registered.contains(key) else { return }
            let callback: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                self.queue.async { [self] in
                    guard self.enabled, self.registered.contains(key) else { return }
                    if key == self.rosterKey { self.reconcile() }
                    self.changed()
                }
            }
            if let operations {
                if operations.add(key, callback) { registered.insert(key) }
            } else {
                var a = key.address
                let block: AudioObjectPropertyListenerBlock = { _, _ in callback() }
                if AudioObjectHasProperty(key.object, &a),
                   AudioObjectAddPropertyListenerBlock(key.object, &a, queue, block) == noErr {
                    blocks[key] = block; registered.insert(key)
                }
            }
        }
        private func remove(_ key: Key) {
            if let operations { operations.remove(key) }
            else if let block = blocks[key] {
                var a = key.address
                AudioObjectRemovePropertyListenerBlock(key.object, &a, queue, block)
            }
            blocks.removeValue(forKey: key); registered.remove(key)
        }
        private func reconcile() {
            let objects: [UInt32]?
            if let operations { objects = operations.objects() }
            else { objects = AudioInputActivity.live.objects() }
            // An unreadable roster cannot be treated as the loss of every process.
            guard let objects, objects.count <= 4096, Set(objects).count == objects.count else { coverage(false); return }
            var wanted: Set<Key> = [rosterKey]
            for object in objects {
                wanted.insert(Key(object: object, selector: kAudioProcessPropertyIsRunningInput))
                wanted.insert(Key(object: object, selector: kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput))
            }
            let began = ProcessInfo.processInfo.systemUptime
            for key in registered.subtracting(wanted) {
                guard ProcessInfo.processInfo.systemUptime - began < 2 else { break }
                remove(key)
            }
            for key in wanted.subtracting(registered) {
                guard ProcessInfo.processInfo.systemUptime - began < 2 else { break }
                install(key)
            }
            coverage(wanted == registered)
        }
    }
}
