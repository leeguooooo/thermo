import AgentCore
import Darwin
import Foundation
import IOKit.pwr_mgt

public struct ProcessSleepAssertions: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case observed, noneObserved, unavailable }
    public struct Assertion: Codable, Sendable, Equatable {
        public enum Request: String, Codable, Sendable { case idleSystem, idleDisplayAndSystem, diskIdle, systemSleep, other }
        public var type: String
        public var name: String?
        public var level: UInt32?
        public var active: Bool?
        public var request: Request
    }
    public var state: State
    public var assertions: [Assertion]
    /// Snapshot decoding only; not a guarantee about whether the machine can sleep.
    public var queryComplete: Bool
    public var limited: Bool

    public static func capture(_ pid: Int32) -> ProcessSleepAssertions {
        guard pid > 0, let before=ProcessTable.identity(pid), before.uid == getuid() else { return unavailable }
        var copied: Unmanaged<CFDictionary>?
        let status=IOPMCopyAssertionsByProcess(&copied)
        let dictionary=copied?.takeRetainedValue()
        guard status == kIOReturnSuccess, let dictionary, ProcessTable.identity(pid) == before else { return unavailable }
        return parse(dictionary as NSDictionary,pid:pid)
    }

    static var unavailable: ProcessSleepAssertions { .init(state:.unavailable,assertions:[],queryComplete:false,limited:false) }
    static func parse(_ dictionary: NSDictionary?, pid: Int32, maximumAssertions: Int = 64) -> ProcessSleepAssertions {
        guard pid > 0, maximumAssertions > 0, maximumAssertions <= 256, let dictionary else { return unavailable }
        // The SDK contract uses CFNumber PID keys. Do not turn an unknown schema into absence.
        for key in dictionary.allKeys {
            guard let number=key as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let value=Int32(exactly:number.int64Value), value >= 0, number.doubleValue == Double(value) else { return unavailable }
        }
        guard let raw=dictionary.object(forKey:NSNumber(value:pid)) else {
            return .init(state:.noneObserved,assertions:[],queryComplete:true,limited:false)
        }
        guard let rows=raw as? NSArray else { return unavailable }
        var parsed: [Assertion]=[], complete=true, limited=rows.count > maximumAssertions
        for index in 0..<min(rows.count,maximumAssertions) {
            guard let row=rows[index] as? NSDictionary,
                  let type=row[kIOPMAssertionTypeKey] as? String, !type.isEmpty else { complete=false;continue }
            if let owner=row["AssertPID"] {
                guard let value=owner as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.int64Value == Int64(pid), value.doubleValue == Double(pid) else { complete=false;continue }
            }
            var level: UInt32?
            if let value=row[kIOPMAssertionLevelKey] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
               let integer=UInt32(exactly:value.int64Value), value.doubleValue == Double(integer) { level=integer }
            let active: Bool? = level == UInt32(kIOPMAssertionLevelOn) ? true : level == UInt32(kIOPMAssertionLevelOff) ? false : nil
            if active == nil { complete=false }
            let request: Assertion.Request
            switch type {
            case "PreventUserIdleSystemSleep": request = .idleSystem
            case "PreventUserIdleDisplaySleep": request = .idleDisplayAndSystem
            case "PreventDiskIdle": request = .diskIdle
            case "PreventSystemSleep": request = .systemSleep
            default: request = .other
            }
            var name: String?
            if let rawName=row[kIOPMAssertionNameKey] {
                if let value=rawName as? String {
                    let safe=ProcessExplanation.displayed(value)
                    if safe.count > 2048 { limited=true }
                    name=String(safe.prefix(2048))
                } else { complete=false }
            }
            let safeType=ProcessExplanation.displayed(type)
            if safeType.count > 128 { limited=true }
            parsed.append(.init(type:String(safeType.prefix(128)),name:name,level:level,active:active,request:request))
        }
        let state: State = !parsed.isEmpty ? .observed : rows.count == 0 ? .noneObserved : .unavailable
        return .init(state:state,assertions:parsed,queryComplete:complete && !limited,limited:limited)
    }
}
