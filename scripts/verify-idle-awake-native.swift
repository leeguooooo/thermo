// Explicit native acceptance: creates only this process's short-lived user-level requests.
// Run after building AgentCore; never launched by ordinary tests or the production CLI.
import AgentCore
import Darwin
import Foundation
import IOKit.pwr_mgt

@main struct VerifyIdleAwakeNative {
    struct Failure: Error { let message: String }
    static func ownedActiveTypes() throws -> [String] {
        var result: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&result) == kIOReturnSuccess,
              let all = result?.takeRetainedValue() as NSDictionary? else { throw Failure(message: "Assertion inventory unavailable") }
        guard let raw = all[NSNumber(value: getpid())] else { return [] }
        guard let rows = raw as? [NSDictionary] else { throw Failure(message: "Unknown assertion inventory shape") }
        return try rows.compactMap { row in
            guard let name = row[kIOPMAssertionNameKey] as? String else { throw Failure(message: "Unknown assertion name") }
            guard name.hasPrefix("Thermo keep-awake ") else { return nil }
            guard let level = row[kIOPMAssertionLevelKey] as? NSNumber,
                  let type = row[kIOPMAssertionTypeKey] as? String else { throw Failure(message: "Unknown owned assertion shape") }
            return level.intValue == Int(kIOPMAssertionLevelOn) ? type : nil
        }.sorted()
    }
    /// With no controller tick, the kernel lease may outlive the requested deadline
    /// by less than two seconds because powerd quantizes both timestamps and timeouts.
    /// Preserve samples and fail an observation whose bound cannot be established.
    @MainActor static func observeKernelExpiry(deadline: Date, expected: [String]) async throws -> [String: Any] {
        var samples: [[String: Any]] = []
        while true {
            let before = Date()
            let active = try ownedActiveTypes()
            let after = Date()
            let sample: [String: Any] = ["readStartedRelativeToDeadline": before.timeIntervalSince(deadline),
                                         "readEndedRelativeToDeadline": after.timeIntervalSince(deadline), "types": active]
            samples.append(sample)
            if let data = try? JSONSerialization.data(withJSONObject: ["kernelLeaseSample": sample], options: [.sortedKeys]) {
                FileHandle.standardError.write(data); FileHandle.standardError.write(Data([10]))
            }
            if after < deadline, active != expected {
                throw Failure(message: "Owned request disappeared before the requested deadline")
            }
            if active.isEmpty {
                guard before >= deadline, after.timeIntervalSince(deadline) < 2 else {
                    throw Failure(message: "Observation did not prove expiry within the final lease rounding grace")
                }
                return ["samples": samples, "firstAbsentUpperBoundAfterRequestedEnd": after.timeIntervalSince(deadline),
                        "noControllerTicksDuringObservation": true, "roundingGraceLimitSeconds": 2]
            }
            guard after.timeIntervalSince(deadline) < 2 else {
                throw Failure(message: "Owned requests still observed beyond the final lease rounding grace")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/") else {
            fputs("Usage: verify-idle-awake-native ABSOLUTE_NEW_REPORT_PATH\n", stderr); exit(2)
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath: output.path), FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path) else {
            fputs("Report exists or parent is unavailable; no requests created.\n", stderr); exit(2)
        }
        let controller = IdleAwakeController()
        var report: [String: Any] = ["scope":"Owned user-process assertions only; no helper, pmset, charging, AWDL or lid-close change", "pid":getpid(), "nativeRequestsCreated":false, "schemaVersion":2, "kernelRoundingGraceLimitSeconds":2]
        var passed = false
        do {
            let power = IdleAwakePower.read()
            guard power.pluggedIn else { throw Failure(message: "Native acceptance requires external power or a known battery-free Mac") }
            guard try ownedActiveTypes().isEmpty else { throw Failure(message: "Unexpected existing owned requests") }
            try controller.start(mode:.both,seconds:2,power:power)
            report["nativeRequestsCreated"] = true
            let both = try ownedActiveTypes()
            guard both == ["PreventUserIdleDisplaySleep","PreventUserIdleSystemSleep"] else { throw Failure(message: "Both mode was not visible in OS inventory") }
            report["bothTypesConfirmed"] = both
            guard let firstEnd = controller.state.expiresAt else { throw Failure(message: "Requested deadline unavailable") }
            report["initialLeaseObservation"] = try await observeKernelExpiry(deadline: firstEnd, expected: both)
            report["kernelExpiryWithoutTickConfirmed"] = true
            controller.tick(power:IdleAwakePower.read())
            guard controller.state.phase == .idle else { throw Failure(message: "Controller did not confirm expired requests ended") }

            let nextPower = IdleAwakePower.read()
            guard nextPower.pluggedIn else { throw Failure(message: "Power changed; renewal acceptance not started") }
            try controller.start(mode:.tasks,seconds:15,power:nextPower)
            guard let end = controller.state.expiresAt else { throw Failure(message: "Requested end time is unavailable") }
            let requestedEnd = controller.state.expiresAt
            try await Task.sleep(nanoseconds:5_200_000_000)
            guard Date() < end.addingTimeInterval(-1) else { throw Failure(message: "Renewal observation missed its timing window") }
            controller.tick(power:IdleAwakePower.read())
            guard controller.state.phase == .active, controller.state.expiresAt == requestedEnd,
                  try ownedActiveTypes() == ["PreventUserIdleSystemSleep"] else { throw Failure(message: "Renewal did not preserve the original active session") }
            report["renewalConfirmed"] = true
            report["renewedLeaseObservation"] = try await observeKernelExpiry(deadline: end, expected: ["PreventUserIdleSystemSleep"])
            guard controller.state.expiresAt == requestedEnd else { throw Failure(message: "Renewal changed the requested deadline") }
            controller.tick(power:IdleAwakePower.read())
            guard controller.state.phase == .idle else { throw Failure(message: "Final release remains unconfirmed") }
            report["renewalPreservedRequestedDeadline"] = true
            passed = true
        } catch {
            report["issue"] = (error as? Failure)?.message ?? error.localizedDescription
        }
        controller.stop()
        do {
            let remaining = try ownedActiveTypes().count
            report["remainingOwnedActiveRequests"] = remaining
            if remaining != 0 { passed = false }
        }
        catch { report["cleanupInventoryUnavailable"] = true; passed = false }
        if controller.state.requested { report["controllerCleanupUnconfirmed"] = true; passed = false }
        report["passed"] = passed
        do {
            let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            try data.write(to:output,options:.withoutOverwriting)
        } catch { fputs("Could not preserve native acceptance report.\n",stderr);exit(1) }
        print(passed ? "Owned native idle-awake acceptance passed" : "Owned native idle-awake acceptance failed; inspect the report")
        exit(passed ? 0 : 1)
    }
}
