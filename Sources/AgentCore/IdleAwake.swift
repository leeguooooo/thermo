import Darwin
import Foundation
import IOKit.pwr_mgt
import IOKit.ps

public enum IdleAwakeMode: String, Codable, CaseIterable, Sendable {
    case display, tasks, both
    var kinds: [IdleAwakeKind] { self == .both ? [.tasks, .display] : [self == .display ? .display : .tasks] }
}
public enum IdleAwakeKind: String, Sendable, Hashable {
    case display, tasks
    var assertionType: String { self == .display ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep" }
}
public struct IdleAwakePower: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case external, battery, noBattery, unknown }
    public var source: Source
    public var percent: Int?
    public init(source: Source, percent: Int? = nil) { self.source = source; self.percent = percent }
    public var low: Bool { source == .battery && percent.map { (0...20).contains($0) } == true }
    public var known: Bool { source != .unknown && (source != .battery || percent.map { (0...100).contains($0) } == true) }
    public var allowsStart: Bool { known && !low }
    public var pluggedIn: Bool { source == .external || source == .noBattery }

    public static func read() -> Self {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return .init(source: .unknown) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        if providing == kIOPSACPowerValue { return .init(source: .external) }
        if list.isEmpty { return .init(source: .noBattery) }
        var percentages: [Int] = []
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let current = d[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = d[kIOPSMaxCapacityKey] as? NSNumber,
                  CFGetTypeID(current) != CFBooleanGetTypeID(), CFGetTypeID(maximum) != CFBooleanGetTypeID(),
                  current.doubleValue.isFinite, maximum.doubleValue.isFinite,
                  current.doubleValue >= 0, maximum.doubleValue > 0 else { continue }
            percentages.append(Int(min(100, current.doubleValue / maximum.doubleValue * 100)))
        }
        return percentages.min().map { .init(source: .battery, percent: $0) } ?? .init(source: .unknown)
    }
}

public enum IdleAwakeObservation: Equatable { case active, inactive, absent, unknown }
public struct IdleAwakeDriver {
    public var create: (IdleAwakeKind, String, Double) throws -> UInt32
    public var read: (UInt32, String, IdleAwakeKind) -> IdleAwakeObservation
    public var renew: (UInt32, String, IdleAwakeKind, Double) throws -> Void
    public var release: (UInt32, String, IdleAwakeKind) throws -> Void
    public init(create: @escaping (IdleAwakeKind, String, Double) throws -> UInt32,
                read: @escaping (UInt32, String, IdleAwakeKind) -> IdleAwakeObservation,
                renew: @escaping (UInt32, String, IdleAwakeKind, Double) throws -> Void,
                release: @escaping (UInt32, String, IdleAwakeKind) throws -> Void) {
        self.create = create; self.read = read; self.renew = renew; self.release = release
    }
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }
    public static var system: Self {
        .init(create: { kind, name, seconds in
            let properties: [String: Any] = [kIOPMAssertionTypeKey as String: kind.assertionType,
                kIOPMAssertionNameKey as String: name, kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn,
                kIOPMAssertionTimeoutKey as String: seconds,
                kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease]
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &id)
            guard result == kIOReturnSuccess, id != 0 else { throw Failure("Could not create idle-awake request (\(result)).") }
            return id
        }, read: observe, renew: { id, name, kind, seconds in
            guard observe(id, name, kind) == .active else { throw Failure("The idle-awake request is no longer confirmed active.") }
            let result = IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString, NSNumber(value: seconds))
            guard result == kIOReturnSuccess else { throw Failure("Could not renew idle-awake request (\(result)).") }
        }, release: { id, name, kind in
            switch observe(id, name, kind) {
            case .absent: return
            case .unknown: throw Failure("Could not verify ownership of the idle-awake request.")
            case .active, .inactive: break
            }
            let result = IOPMAssertionRelease(id)
            guard result == kIOReturnSuccess else { throw Failure("Could not release idle-awake request (\(result)).") }
        })
    }
    private static func observe(_ id: UInt32, _ name: String, _ kind: IdleAwakeKind) -> IdleAwakeObservation {
        if let d = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as NSDictionary? {
            guard let actual = d[kIOPMAssertionNameKey] as? String else { return .unknown }
            guard actual == name else { return .absent } // A recycled ID must never release a different request.
            guard d[kIOPMAssertionTypeKey] as? String == kind.assertionType,
                  let level = d[kIOPMAssertionLevelKey] as? NSNumber,
                  CFGetTypeID(level) != CFBooleanGetTypeID() else { return .unknown }
            if level.intValue == Int(kIOPMAssertionLevelOn) { return .active }
            if level.intValue == Int(kIOPMAssertionLevelOff) { return .inactive }
            return .unknown
        }
        // A nil properties result alone is not evidence of absence. Confirm against a
        // successful process inventory before accepting kernel timeout/automatic release.
        var copied: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&copied) == kIOReturnSuccess,
              let dictionary = copied?.takeRetainedValue() as NSDictionary? else { return .unknown }
        guard dictionary.allKeys.allSatisfy({ ($0 as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } == true }) else { return .unknown }
        guard let raw = dictionary[NSNumber(value: getpid())] else { return .absent }
        guard let rows = raw as? [NSDictionary], rows.count <= 4096 else { return .unknown }
        for row in rows {
            guard let actual = row[kIOPMAssertionNameKey] as? String else { return .unknown }
            if actual == name { return .unknown }
        }
        return .absent
    }
}

public struct IdleAwakeState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case idle, active, pausedLowBattery, pausedPowerUnknown, ending }
    public var phase: Phase = .idle
    public var mode: IdleAwakeMode?
    public var expiresAt: Date?
    public var observedAt: Date = .distantPast
    public var power = IdleAwakePower(source: .unknown)
    public var lastEndReason: String?
    public var issue: String?
    public var requestCount = 0
    public var requested: Bool { mode != nil }
    public init() {}
}

/// User-process assertions only. No pmset, helper RPC, lid-close setting or persisted activation.
@MainActor public final class IdleAwakeController {
    public private(set) var state = IdleAwakeState()
    private struct Owned { var id: UInt32; var name: String; var kind: IdleAwakeKind }
    private var owned: [Owned] = []
    private var token = UUID()
    private var lastRenewed = Date.distantPast
    private var lowBatteryLatch = false
    private let driver: IdleAwakeDriver
    public init(driver: IdleAwakeDriver? = nil) { self.driver = driver ?? .system }
    deinit { for item in owned { try? driver.release(item.id, item.name, item.kind) } }
    nonisolated public static func validDuration(_ seconds: Double?) -> Bool {
        seconds.map { $0.isFinite && (1...604_800).contains($0) } ?? true
    }
    public func start(mode: IdleAwakeMode, seconds: Double?, power: IdleAwakePower, now: Date = Date()) throws {
        guard Self.validDuration(seconds) else { throw IdleAwakeDriver.Failure("Duration must be 1…604800 seconds or manual.") }
        guard !state.requested, owned.isEmpty else { throw IdleAwakeDriver.Failure("Stop the existing idle-awake session before starting another.") }
        guard power.allowsStart else { throw IdleAwakeDriver.Failure("Idle awake needs known power status and more than 20% battery, or external power.") }
        token = UUID(); lowBatteryLatch = false
        state = IdleAwakeState(); state.mode = mode; state.expiresAt = seconds.map { now.addingTimeInterval($0) }; state.power = power
        do { try activate(now: now) }
        catch {
            let original = error.localizedDescription
            stop(reason: "startFailed", now: now)
            state.issue = state.issue.map { original + " " + $0 } ?? original
            throw IdleAwakeDriver.Failure(state.issue!)
        }
    }
    private func leaseSeconds(_ now: Date) -> Double { min(30, state.expiresAt.map { max(0, $0.timeIntervalSince(now)) } ?? 30) }
    private func activate(now: Date) throws {
        guard let mode = state.mode else { return }
        for kind in mode.kinds {
            let name = "Thermo keep-awake \(token.uuidString) \(kind.rawValue)"
            // Record intent before calling the OS. A failed create can have an uncertain
            // outcome; name-based absence must be confirmed even if no ID was returned.
            owned.append(.init(id: 0, name: name, kind: kind))
            let id = try driver.create(kind, name, leaseSeconds(now))
            owned[owned.count - 1].id = id
            guard id != 0 else { throw IdleAwakeDriver.Failure("Idle-awake creation returned no request identity.") }
            guard driver.read(id, name, kind) == .active else { throw IdleAwakeDriver.Failure("Idle-awake activation was not confirmed.") }
        }
        guard owned.allSatisfy({ driver.read($0.id, $0.name, $0.kind) == .active }) else {
            throw IdleAwakeDriver.Failure("Idle-awake activation was not confirmed.")
        }
        lastRenewed = now; state.phase = .active; state.issue = nil; publish(now)
    }
    private func publish(_ now: Date) { state.observedAt = now; state.requestCount = owned.count }
    /// A status read checks current facts without renewing, releasing or creating requests.
    public func inspect(power: IdleAwakePower, now: Date = Date()) -> IdleAwakeState {
        var observed = state; observed.power = power; observed.observedAt = now
        if state.requested, let end = state.expiresAt, now >= end {
            observed.phase = .ending; observed.issue = "The duration elapsed; session release is awaiting confirmation."
        } else if state.phase == .active, !owned.allSatisfy({ driver.read($0.id, $0.name, $0.kind) == .active }) {
            observed.phase = .ending; observed.issue = "The current idle-awake requests are not confirmed active."
        }
        return observed
    }
    private func releaseAll() -> Bool {
        var remaining: [Owned] = []
        for item in owned {
            switch driver.read(item.id, item.name, item.kind) {
            case .absent: continue
            case .unknown: remaining.append(item); continue
            case .active, .inactive: try? driver.release(item.id, item.name, item.kind)
            }
            if driver.read(item.id, item.name, item.kind) != .absent { remaining.append(item) }
        }
        owned = remaining
        return remaining.isEmpty
    }
    public func stop(reason: String = "stopped", now: Date = Date()) {
        if releaseAll() {
            state.mode = nil; state.expiresAt = nil; state.phase = .idle; state.issue = nil; state.lastEndReason = reason
        } else {
            state.phase = .ending; state.issue = "Idle-awake release is unconfirmed. Checking again; no new session can start."
            state.lastEndReason = reason
        }
        publish(now)
    }
    public func tick(power: IdleAwakePower, now: Date = Date()) {
        state.power = power
        guard state.requested else { publish(now); return }
        if state.phase == .ending { stop(reason: state.lastEndReason ?? "stopped", now: now); return }
        if let end = state.expiresAt, now >= end { stop(reason: "expired", now: now); return }
        if power.low { lowBatteryLatch = true }
        let pause = !power.known || lowBatteryLatch && !power.pluggedIn
        if pause {
            if releaseAll() {
                state.phase = power.known ? .pausedLowBattery : .pausedPowerUnknown; state.issue = nil
            } else { state.phase = .ending; state.lastEndReason = "pauseFailed"; state.issue = "Idle-awake pause is unconfirmed; checking release." }
            publish(now); return
        }
        if state.phase == .pausedLowBattery || state.phase == .pausedPowerUnknown {
            lowBatteryLatch = false
            do { try activate(now: now) } catch { stop(reason: "resumeFailed", now: now); state.issue = error.localizedDescription }
            return
        }
        guard owned.allSatisfy({ driver.read($0.id, $0.name, $0.kind) == .active }) else {
            stop(reason: "requestLost", now: now); return
        }
        if now.timeIntervalSince(lastRenewed) >= 5 {
            do {
                for item in owned { try driver.renew(item.id, item.name, item.kind, leaseSeconds(now)) }
                guard owned.allSatisfy({ driver.read($0.id, $0.name, $0.kind) == .active }) else { throw IdleAwakeDriver.Failure("Idle-awake renewal was not confirmed.") }
                lastRenewed = now
            } catch { stop(reason: "renewFailed", now: now); state.issue = error.localizedDescription }
        }
        publish(now)
    }
}
