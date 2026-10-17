// Actual non-root SystemPulse model benchmark. No windows or helper. See bench-pulse.py.
import Foundation
import AppKit
import Combine
@testable import ThermoApp
import CleanKit

@_silgen_name("$s9ThermoApp20installStandardMenusyyF")
@MainActor func fixtureStandardMenus() {}

final class Meter: @unchecked Sendable {
    let sampler = PulseSampler(), lock = NSLock()
    let began = DispatchTime.now().uptimeNanoseconds
    var rows: [[String: Double]] = []
    func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9 }
    func read() -> MachinePulse {
        let start = now(), pulse = sampler.sample(), finish = now()
        lock.lock(); rows.append(["readStarted": start, "readFinished": finish, "readSeconds": finish - start, "sampled": pulse.sampled.timeIntervalSince1970]); lock.unlock()
        return pulse
    }
    func published(_ pulse: MachinePulse) -> [[String: Double]] {
        let finish = now()
        lock.lock(); defer { lock.unlock() }
        if let last = rows.firstIndex(where: { $0["sampled"] == pulse.sampled.timeIntervalSince1970 }) { rows[last]["published"] = finish; rows[last]["publicationGap"] = finish - rows[last]["readFinished"]! }
        return rows
    }
}
@main struct ModelBenchmark {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let meter = Meter(), model = SystemPulse(readSample: { meter.read() })
        var latest: [[String: Double]] = [], done = false
        let observation = model.$current.compactMap { $0 }.sink { pulse in
            latest = meter.published(pulse)
            if latest.filter({ $0["published"] != nil }).count == 3, !done {
                done = true
                DispatchQueue.main.async {
                    model.release()
                    let report: [String: Any] = ["samples": latest, "scope": "Actual production SystemPulse worker and main-thread publication, no window or helper. Same production PulseSampler via the injected reader. Debug objects; no UI rendering."]
                    print(String(decoding: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self)); fflush(stdout); exit(0)
                }
            }
        }
        model.hold()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { model.release(); fputs("model benchmark timed out\n", stderr); exit(3) }
        withExtendedLifetime((meter, model, observation)) { app.run() }
    }
}
