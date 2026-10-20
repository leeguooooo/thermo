import CoreMediaIO
import Foundation

/// Device metadata only. Does not create a capture session or identify the process using a camera.
public struct CameraDevice: Equatable, Sendable {
    public var objectID: UInt32
    public var uid: String
    public var name: String
    public var active: Bool
    public init(objectID: UInt32, uid: String, name: String, active: Bool) {
        self.objectID = objectID; self.uid = uid; self.name = name; self.active = active
    }
}

public struct CameraObservation: Equatable, Sendable {
    public var devices: [CameraDevice]
    public var issues: [String]
    public var available: Bool
    public var sampled: Date
    public var complete: Bool { available && issues.isEmpty }
    public init(devices: [CameraDevice] = [], issues: [String] = [], available: Bool = true, sampled: Date = Date()) {
        self.devices = devices; self.issues = issues; self.available = available; self.sampled = sampled
    }
}

public enum CameraActivity {
    struct Reader {
        var objects: () -> [UInt32]?
        var streams: (UInt32) -> [UInt32]?
        var device: (UInt32) -> CameraDevice?
    }
    public static func read() -> CameraObservation { read(reader: live) }
    static func read(reader: Reader) -> CameraObservation {
        guard let roster = reader.objects(), roster.count <= 256, Set(roster).count == roster.count else {
            return .init(issues: ["Could not verify the camera device list"], available: false)
        }
        let began = ProcessInfo.processInfo.systemUptime
        var devices: [CameraDevice] = [], issues: [String] = [], identities = Set<String>()
        for id in roster.sorted() {
            guard ProcessInfo.processInfo.systemUptime - began < 2 else { issues.append("Camera metadata time budget exceeded"); break }
            guard let streams = reader.streams(id), streams.count <= 256, Set(streams).count == streams.count else {
                issues.append("Could not verify camera input streams"); continue
            }
            // Output-only media devices are outside this camera-input observation.
            guard !streams.isEmpty else {
                if reader.streams(id) != [] { issues.append("Video input stream layout changed during the check") }
                continue
            }
            guard let first = reader.device(id), first.objectID == id, !first.uid.isEmpty, !first.name.isEmpty,
                  first.uid.utf8.count <= 4096, first.name.utf8.count <= 4096,
                  reader.device(id) == first, reader.streams(id)?.sorted() == streams.sorted() else {
                issues.append("Camera identity or activity changed or could not be verified"); continue
            }
            guard identities.insert(first.uid).inserted else { issues.append("Camera identities were ambiguous"); continue }
            devices.append(first)
        }
        guard reader.objects()?.sorted() == roster.sorted() else {
            return .init(issues: ["Camera device list changed during the check"], available: false)
        }
        return .init(devices: devices, issues: Array(Set(issues)).sorted())
    }
    static func address(_ selector: UInt32, scope: UInt32 = UInt32(kCMIOObjectPropertyScopeGlobal)) -> CMIOObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: UInt32(kCMIOObjectPropertyElementMain))
    }
    static func list(_ object: UInt32, _ selector: UInt32, scope: UInt32 = UInt32(kCMIOObjectPropertyScopeGlobal)) -> [UInt32]? {
        var a = address(selector, scope: scope), size: UInt32 = 0
        guard CMIOObjectHasProperty(object, &a), CMIOObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr,
              size <= 256 * 4, size % 4 == 0 else { return nil }
        guard size > 0 else { return [] }
        let expected = size
        var result = [UInt32](repeating: 0, count: Int(size) / 4)
        let status = result.withUnsafeMutableBytes { CMIOObjectGetPropertyData(object, &a, 0, nil, expected, &size, $0.baseAddress!) }
        return status == noErr && size == expected ? result : nil
    }
    private static func flag(_ object: UInt32, _ selector: UInt32) -> Bool? {
        var a = address(selector), size: UInt32 = 0, value: UInt32 = 0
        guard CMIOObjectHasProperty(object, &a),
              CMIOObjectGetPropertyData(object, &a, 0, nil, 4, &size, &value) == noErr,
              size == 4, value <= 1 else { return nil }
        return value == 1
    }
    private static func string(_ object: UInt32, _ selector: UInt32) -> String? {
        // CMIOHardwareDevice/Object.h explicitly transfer ownership of these CFStrings to the caller.
        var a = address(selector), size: UInt32 = 0, value: Unmanaged<CFString>?
        guard CMIOObjectHasProperty(object, &a),
              CMIOObjectGetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<CFString?>.size), &size, &value) == noErr,
              size == MemoryLayout<CFString?>.size, let value else { return nil }
        return value.takeRetainedValue() as String
    }
    static var live: Reader {
        .init(objects: { list(UInt32(kCMIOObjectSystemObject), UInt32(kCMIOHardwarePropertyDevices)) },
              streams: { list($0, UInt32(kCMIODevicePropertyStreams), scope: UInt32(kCMIODevicePropertyScopeInput)) }, device: { id in
            guard flag(id, UInt32(kCMIODevicePropertyDeviceIsAlive)) == true,
                  let uid = string(id, UInt32(kCMIODevicePropertyDeviceUID)),
                  let name = string(id, UInt32(kCMIOObjectPropertyName)),
                  let active = flag(id, UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere)) else { return nil }
            return .init(objectID: id, uid: uid, name: name, active: active)
        })
    }
}

public struct CameraTransitions: Sendable {
    private var active: Set<String>?
    public init() {}
    public mutating func reset() { active = nil }
    public mutating func observe(_ value: CameraObservation) -> [CameraDevice] {
        guard value.complete else { active = nil; return [] }
        let current = value.devices.filter(\.active)
        defer { active = Set(current.map(\.uid)) }
        guard let active else { return [] }
        return current.filter { !active.contains($0.uid) }
    }
}

/// Public output omits hardware identities; noDevices is distinct from an observed idle input.
public struct CameraReport: Codable, Sendable {
    public struct Device: Codable, Sendable { public let name: String; public let active: Bool }
    public let schemaVersion: Int
    public let source: String
    public let scope: String
    public let recordsVideo: Bool
    public let processAttribution: String
    public let state: String
    public let sampled: Date?
    public let complete: Bool?
    public let fresh: Bool?
    public let available: Bool?
    public let enabled: Bool?
    public let eventCoverage: String?
    public let notificationAccess: String?
    public let notificationIssue: String?
    public let notificationIssueTruncated: Bool
    public let totalDevices: Int
    public private(set) var devices: [Device]
    public let totalIssues: Int
    public private(set) var issues: [String]
    public private(set) var outputTruncated: Bool
    public init(observation: CameraObservation?, source: String, enabled: Bool? = nil,
                eventCoverage: String? = nil, notificationAccess: String? = nil, notificationIssue: String? = nil, limit: Int = 64, now: Date = Date()) {
        schemaVersion = 1; self.source = source; scope = "systemReportedVideoInputs"
        recordsVideo = false; processAttribution = "unavailable"
        self.enabled = enabled; self.eventCoverage = eventCoverage; self.notificationAccess = notificationAccess
        self.notificationIssue = notificationIssue.map { String(decoding: $0.utf8.prefix(1024), as: UTF8.self) }
        notificationIssueTruncated = (notificationIssue?.utf8.count ?? 0) > 1024
        sampled = observation?.sampled.timeIntervalSinceReferenceDate.isFinite == true ? observation?.sampled : nil
        complete = observation?.complete; available = observation?.available
        fresh = observation.map { (0...15).contains(now.timeIntervalSince($0.sampled)) }
        if let observation {
            state = !observation.complete ? "unknown" : fresh == false ? "stale" : observation.devices.contains(where: \.active) ? "active" : observation.devices.isEmpty ? "noDevices" : "idle"
        } else { state = enabled == true ? "checking" : "notCollected" }
        totalDevices = observation?.devices.count ?? 0; totalIssues = observation?.issues.count ?? 0
        devices = Array((observation?.devices ?? []).prefix(max(0, min(256, limit)))).map { .init(name: $0.name, active: $0.active) }
        issues = observation?.issues ?? []; outputTruncated = devices.count < totalDevices || notificationIssueTruncated
        while ((try? JSONEncoder().encode(self).count) ?? Int.max) > 32_768 {
            if !devices.isEmpty { devices.removeLast() }
            else if !issues.isEmpty { issues.removeLast() }
            else { break }
            outputTruncated = true
        }
    }
}
