import AgentCore
import AppKit
import CleanKit
import Darwin
import Foundation

/// A developer acceptance run, separate from the user's installed app and the menu-bar recorder.
@MainActor
enum WindowLifecycleCheck {
    struct Options: Codable {
        let output: String
        let cycles: Int
        let openSeconds: Double
        let idleSeconds: Double
        let foregroundActivity: Bool

        init(arguments: [String]) throws {
            func value(_ flag: String) throws -> String? {
                guard let index = arguments.firstIndex(of: flag) else { return nil }
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw failure("missing value for " + flag) }
                return arguments[index + 1]
            }
            guard arguments.contains("--offscreen"), let output = try value("--verify-lifecycle"), output.hasPrefix("/") else {
                throw failure("lifecycle verification requires --offscreen and an absolute report path")
            }
            let rawCycles = try value("--cycles") ?? "3"
            let rawOpen = try value("--open-seconds") ?? "3"
            let rawIdle = try value("--idle-seconds") ?? "4"
            guard let cycles = Int(rawCycles), (2...20).contains(cycles),
                  let open = Double(rawOpen), open.isFinite, (1...15).contains(open),
                  let idle = Double(rawIdle), idle.isFinite, (2...30).contains(idle) else {
                throw failure("cycles must be 2...20, open seconds 1...15, idle seconds 2...30")
            }
            self.output = output; self.cycles = cycles; openSeconds = open; idleSeconds = idle
            foregroundActivity = arguments.contains("--foreground-activity")
        }
    }

    struct Sample: Codable {
        var cycle: Int
        var page: String
        var phase: String
        var elapsed: Double
        var residentKB: Int?
        var footprintKB: Int?
        var cpuSeconds: Double?
        var threads: Int?
        var controllersAlive: Int
        var contentDetached: Bool
        var monitorWindowOpen: Bool
        var memoryTimer: Bool
        var memoryInFlight: Bool
        var computeTimer: Bool
        var computeInFlight: Bool
        var pulseTimer: Bool
        var pulseHolders: Int
        var memoryPublished: Date?
        var computePublished: Date?
        var pulsePublished: Date?
        var framePreserved: Bool
        var idlePublicationsStable: Bool?
        var activeSampleFresh: Bool?

        var stopped: Bool {
            contentDetached && controllersAlive == 0 && !monitorWindowOpen && !memoryTimer && !memoryInFlight &&
                !computeTimer && !computeInFlight && !pulseTimer && pulseHolders == 0 && framePreserved
        }
    }

    struct Report: Encodable {
        let schemaVersion = 3
        let mode = "offscreen AppKit with explicit watched visibility; helper interaction and menu-bar recorder disabled"
        let foregroundActivityHeld: Bool
        let started: Date
        let pid: Int32
        let options: Options
        let samples: [Sample]
        let functionalChecksPassed: Bool
        let transitionChecks: [String: Bool]
        let memoryGrowthAssessed = false
        let buildConfiguration: String
    }

    private final class WeakController {
        weak var value: NSViewController?
        init(_ value: NSViewController?) { self.value = value }
    }

    private nonisolated static func failure(_ text: String) -> NSError {
        NSError(domain: "ThermoLifecycleCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private static func pause(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    static func run(_ options: Options) async throws -> Report {
        // Opt-in diagnostic control: an offscreen window has no real foreground visibility.
        // Keep the ordinary run available for comparison and report which condition was used.
        let activity = options.foregroundActivity ? ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Thermo foreground lifecycle verification") : nil
        defer { if let activity { ProcessInfo.processInfo.endActivity(activity) } }
        AppModels.shared.monitor = Monitor(helperInteraction: false)
        let started = Date(), clock = DispatchTime.now().uptimeNanoseconds
        let pages: [(String, MainPage)] = [("overview", .overview), ("memory", .memory), ("cpu", .compute(false))]
        var retired: [WeakController] = []
        var samples: [Sample] = []
        var openChecksPassed = true
        var transitionChecks: [String: Bool] = [:]
        func reading(cycle: Int, page: String, phase: String, frame: NSRect?) -> Sample {
            let compute = page == "cpu" ? ComputeModel.cpu : ComputeModel.shared
            let memory = ProcessTable.memory(getpid())
            var usage = rusage(), task = proc_taskinfo()
            let gotCPU = getrusage(RUSAGE_SELF, &usage) == 0
            let gotTask = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) == MemoryLayout<proc_taskinfo>.size
            let cpu = gotCPU ? Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6 : nil
            let sample = Sample(cycle: cycle, page: page, phase: phase,
                elapsed: Double(DispatchTime.now().uptimeNanoseconds - clock) / 1e9,
                residentKB: memory.residentKB, footprintKB: memory.footprintKB, cpuSeconds: cpu,
                threads: gotTask ? Int(task.pti_threadnum) : nil, controllersAlive: retired.filter { $0.value != nil }.count,
                contentDetached: MainWindow.window?.contentViewController == nil,
                monitorWindowOpen: AppModels.shared.monitor.windowOpen,
                memoryTimer: MemoryModel.shared.samplingActive, memoryInFlight: MemoryModel.shared.sampleInFlight,
                computeTimer: ComputeModel.shared.samplingActive || ComputeModel.cpu.samplingActive,
                computeInFlight: ComputeModel.shared.sampleInFlight || ComputeModel.cpu.sampleInFlight,
                pulseTimer: SystemPulse.shared.samplingActive, pulseHolders: SystemPulse.shared.holderCount,
                memoryPublished: MemoryModel.shared.sampled, computePublished: compute.current?.sampled,
                pulsePublished: SystemPulse.shared.current?.sampled,
                framePreserved: frame.map { MainWindow.window?.frame == $0 } ?? true)
            print("lifecycle \(cycle) \(page) \(phase): RSS=\(sample.residentKB ?? -1)KB footprint=\(sample.footprintKB ?? -1)KB controllers=\(sample.controllersAlive)")
            fflush(stdout)
            return sample
        }
        samples.append(reading(cycle: 0, page: "none", phase: "baseline", frame: nil))
        for cycle in 1...options.cycles {
            for (name, page) in pages {
                let openedAt = Date()
                autoreleasepool { MainWindow.show(page); MainWindow.window?.contentView?.layoutSubtreeIfNeeded() }
                // Offscreen windows are occluded by macOS. Exercise the same watched model state
                // as a visible window after that initial notification has been delivered.
                try await pause(0.1)
                MainWindow.setSamplingVisibility(true)
                try await pause(options.openSeconds)
                let frame = MainWindow.window?.frame
                var opened = reading(cycle: cycle, page: name, phase: "open", frame: frame)
                let published = name == "overview" ? opened.pulsePublished : name == "memory" ? opened.memoryPublished : opened.computePublished
                let active = name == "overview" ? opened.pulseTimer : name == "memory" ? opened.memoryTimer : opened.computeTimer
                opened.activeSampleFresh = published.map { $0 >= openedAt } ?? false
                let checked = active && opened.activeSampleFresh == true
                openChecksPassed = openChecksPassed && checked
                if name == "overview" {
                    // A normal sidebar change keeps the host/window alive. Closing every page
                    // cannot catch a lost appearance lease during this transition.
                    MainWindow.state.page = .compute(false)
                    try await pause(options.openSeconds)
                    transitionChecks["cycle-\(cycle)-leave-overview"] = !SystemPulse.shared.samplingActive && SystemPulse.shared.holderCount == 0
                    let returnedAt = Date()
                    MainWindow.state.page = .overview
                    try await pause(options.openSeconds)
                    transitionChecks["cycle-\(cycle)-return-overview"] = SystemPulse.shared.samplingActive &&
                        (SystemPulse.shared.current?.sampled ?? .distantPast) >= returnedAt
                    samples.append(reading(cycle: cycle, page: name, phase: "returned", frame: frame))

                }
                // Pausing only Overview misses the detail-page timers that used to survive occlusion.
                MainWindow.setSamplingVisibility(false)
                try await pause(0.2)
                let untilHidden = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
                while (MemoryModel.shared.sampleInFlight || ComputeModel.cpu.sampleInFlight || ComputeModel.shared.sampleInFlight)
                    && DispatchTime.now().uptimeNanoseconds < untilHidden { try await pause(0.1) }
                let hiddenStart = reading(cycle: cycle, page: name, phase: "hidden-start", frame: frame)
                try await pause(options.idleSeconds)
                let hidden = reading(cycle: cycle, page: name, phase: "hidden", frame: frame)
                transitionChecks["cycle-\(cycle)-\(name)-hidden"] = !hidden.memoryTimer && !hidden.computeTimer &&
                    !hidden.pulseTimer && hidden.pulseHolders == 0 &&
                    hidden.memoryPublished == hiddenStart.memoryPublished && hidden.computePublished == hiddenStart.computePublished &&
                    hidden.pulsePublished == hiddenStart.pulsePublished
                samples += [hiddenStart, hidden]
                let visibleAt = Date()
                MainWindow.setSamplingVisibility(true)
                try await pause(options.openSeconds)
                let shown = reading(cycle: cycle, page: name, phase: "visible-again", frame: frame)
                let fresh = name == "overview" ? shown.pulsePublished : name == "memory" ? shown.memoryPublished : shown.computePublished
                transitionChecks["cycle-\(cycle)-\(name)-visible-again"] = fresh.map { $0 >= visibleAt } ?? false
                samples.append(shown)
                autoreleasepool {
                    retired.append(WeakController(MainWindow.window?.contentViewController))
                    MainWindow.window?.close()
                }
                // Let appearance callbacks and already-running reads finish before testing idle.
                try await pause(1)
                let until = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
                while (MemoryModel.shared.sampleInFlight || ComputeModel.cpu.sampleInFlight || ComputeModel.shared.sampleInFlight) && DispatchTime.now().uptimeNanoseconds < until {
                    try await pause(0.1)
                }
                let closed = reading(cycle: cycle, page: name, phase: "closed", frame: frame)
                try await pause(options.idleSeconds)
                var idle = reading(cycle: cycle, page: name, phase: "idle", frame: frame)
                idle.idlePublicationsStable = idle.memoryPublished == closed.memoryPublished &&
                    idle.computePublished == closed.computePublished && idle.pulsePublished == closed.pulsePublished
                samples += [opened, closed, idle]
            }
        }
        let passed = openChecksPassed && transitionChecks.values.allSatisfy { $0 } && samples.filter { $0.phase == "closed" || $0.phase == "idle" }.allSatisfy {
            $0.stopped && $0.idlePublicationsStable != false
        }
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        return Report(foregroundActivityHeld: activity != nil, started: started, pid: getpid(), options: options, samples: samples, functionalChecksPassed: passed, transitionChecks: transitionChecks, buildConfiguration: build)
    }
}
