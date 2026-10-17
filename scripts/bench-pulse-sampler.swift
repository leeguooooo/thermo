// Read-only developer microbenchmark. Run through bench-pulse.py after swift test.
import Foundation
import CleanKit
import AgentCore

func seconds(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 }
let qosName = CommandLine.arguments.dropFirst().first ?? "utility"
let submitted = DispatchTime.now().uptimeNanoseconds
let semaphore = DispatchSemaphore(value: 0)
DispatchQueue.global(qos: qosName == "userInitiated" ? .userInitiated : .utility).async {
    let delay = seconds(submitted), sampler = PulseSampler()
    var samples: [[String: Any]] = []
    for index in 0..<3 {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = sampler.sample()
        samples.append(["index": index, "seconds": seconds(start), "groups": value.hogs.count,
                        "countedProcesses": value.hogs.reduce(0) { $0 + $1.pids.count }])
    }
    var start = DispatchTime.now().uptimeNanoseconds
    let usage = ProcessTable.usage(uid: nil)
    let usageSeconds = seconds(start), mine = usage.filter { $0.uid == getuid() }
    start = DispatchTime.now().uptimeNanoseconds
    let identities = mine.compactMap { ProcessTable.identity($0.pid) }
    let identitySeconds = seconds(start)
    start = DispatchTime.now().uptimeNanoseconds
    let detailCount = mine.prefix(20).map { ProcessTable.details($0.pid) }.count
    let detailsSeconds = seconds(start)
    let output: [String: Any] = ["qos": qosName, "queueStartDelay": delay, "samples": samples,
        "processes": usage.count, "ownProcesses": mine.count, "usageSeconds": usageSeconds,
        "verifiedIdentities": identities.count, "allOwnIdentitySeconds": identitySeconds,
        "detailSampleCount": detailCount, "detailSampleSeconds": detailsSeconds,
        "scope": "Original production PulseSampler and AgentCore Debug objects; no helper, writes, or process actions. Stage sweeps run after the three full samples and are warm diagnostics, not a cold-time breakdown."]
    print(String(decoding: try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    fflush(stdout); semaphore.signal()
}
if semaphore.wait(timeout: .now() + 45) == .timedOut { fputs("benchmark timed out\n", stderr); exit(3) }
