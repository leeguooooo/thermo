import ThermoUI
import AppKit
import Charts
import CleanKit
import SwiftUI
import ThermoL10n
import ModuleKit

/// The Memory page's readings: the breakdown, every program by memory, and the ones that look
/// like they leak. Sampled every 5 s while the page is open; nothing runs otherwise.
@MainActor
final class MemoryModel: ObservableObject {

    @Published private(set) var activity: MemoryActivity?
    @Published private(set) var breakdown: MemoryBreakdown?
    /// A program another page asked to show: the page searches for it and opens it, then clears this.
    @Published var inspect: String?
    @Published private(set) var programs: [MemoryProgram] = []
    @Published private(set) var unreadableCount = 0
    @Published private(set) var inventoryAvailable = false
    @Published private(set) var sampled: Date?
    @Published private(set) var suspects: [MemorySuspect] = []
    @Published private(set) var day: [PulseRecord] = []
    @Published private(set) var programReadings: [ProgramMemoryRecord] = []
    private var liveReadings: [ProgramMemoryRecord] = []
    private var historyReadings: [ProgramMemoryRecord] = []
    private var timer: Timer?
    private let samplingAllowed: () -> Bool
    private var sampling = false
    private var dayLoaded = Date.distantPast
    private var dayTask:Task<Void,Never>?
    private var generation = UUID()
    private var cancellation: ScanCancellation?
    private var visibility = SamplingLeases()
    struct Reading: Sendable {
        var breakdown: MemoryBreakdown?
        var inventory: MemoryInventory
        var history: [ProgramMemoryRecord]
    }
    private let read: @Sendable (ScanCancellation) -> Reading
    private let readDay: @Sendable () -> [PulseRecord]
    private let readHistory: @Sendable (ScanCancellation) -> [ProgramMemoryRecord]
    init(read: @escaping @Sendable (ScanCancellation) -> Reading = { MemoryModel.readLive($0) },
         readHistory: @escaping @Sendable (ScanCancellation) -> [ProgramMemoryRecord],
         readDay: @escaping @Sendable () -> [PulseRecord],
         samplingAllowed: @escaping () -> Bool = { true }) {
        self.read = read; self.readHistory = readHistory; self.readDay = readDay
        self.samplingAllowed = samplingAllowed
    }
    nonisolated private static func readLive(_ cancellation: ScanCancellation) -> Reading {
        let b = MemoryBreakdown.read()
        let inventory = MemoryInventory.collect(cancelled: { cancellation.isCancelled })
        return Reading(breakdown: b, inventory: inventory, history: [])
    }
    var samplingActive: Bool { timer != nil }
    var sampleInFlight: Bool { sampling || dayTask != nil }
    func setVisible(_ active: Bool, owner: UUID) {
        visibility.set(owner, active: active)
        if visibility.active { start() } else { stop() }
    }

    func start() {
        guard samplingAllowed(), timer == nil else { return }
        generation = UUID()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        sample()
    }

    func stop() { timer?.invalidate(); timer = nil; generation = UUID(); cancellation?.cancel();dayTask?.cancel() }

    func releaseReadingsIfIdle() {
        guard timer == nil, !sampleInFlight else { return }
        activity = nil; breakdown = nil; programs = []; suspects = []; day = []; programReadings = []
        liveReadings = []; historyReadings = []; sampled = nil; inventoryAvailable = false
    }

    func sample() {
        guard timer != nil, !sampling else { return }
        sampling = true
        let token = generation
        let cancellation = ScanCancellation()
        self.cancellation = cancellation
        let read = self.read, readHistory = self.readHistory
        if Date().timeIntervalSince(dayLoaded) >= 60 { loadDay() }
        Task.detached(priority: .userInitiated) {
            let reading = read(cancellation)
            let b = reading.breakdown, inventory = reading.inventory
            // Current readings must not wait behind historical file I/O or JSON decoding.
            let published = await MainActor.run {
                guard self.generation == token, !cancellation.isCancelled else { return false }
                // App action identity is captured for each original context, never for merged groups.
                let applications = NSWorkspace.shared.runningApplications
                let programs = inventory.programs.map { program in
                    let contexts = program.contexts.map { h -> MachinePulse.Hog in
                        var h = h
                        if let path = h.app, let app = applications.first(where: { $0.bundleURL?.standardizedFileURL.path == path }) {
                            h.applicationIdentity = ProcessTable.identity(app.processIdentifier)
                        }
                        return h
                    }
                    return MemoryProgram(id: program.id, name: program.name, contexts: contexts)
                }
                self.programs = programs
                self.unreadableCount = inventory.unreadableCount
                self.inventoryAvailable = inventory.available
                self.sampled = inventory.sampled
                let entries = programs.map(\.historyEntry)
                let now = inventory.sampled
                if inventory.available {
                    self.liveReadings.append(ProgramMemoryRecord(entries, at: now))
                    self.liveReadings.removeAll { now.timeIntervalSince($0.t) > 3600 }
                }
                if !reading.history.isEmpty { self.historyReadings = reading.history }
                self.updateHistory(programs: entries, now: now)
                self.activity = b.flatMap { MemoryActivity(previous: self.breakdown, current: $0) }
                self.breakdown = b
                return true
            }
            let history = published && !cancellation.isCancelled ? readHistory(cancellation) : nil
            await MainActor.run {
                self.sampling = false
                self.cancellation = nil
                guard self.generation == token, !cancellation.isCancelled else {
                    // Both inventory and history drain before a reopened page starts another read.
                    if self.timer != nil { self.sample() }
                    return
                }
                if let history {
                    self.historyReadings = reading.history + history
                    self.updateHistory(programs: self.programs.map(\.historyEntry), now: inventory.sampled)
                }
            }
        }
    }

    private func updateHistory(programs: [MachinePulse.Hog], now: Date) {
        historyReadings.removeAll { now.timeIntervalSince($0.t) > PulseHistory.keep }
        programReadings = (historyReadings + liveReadings).sorted { $0.t < $1.t }
        suspects = MemorySuspects.find(programs: programs, history: programReadings, now: now)
    }

    func loadDay() {
        guard timer != nil,samplingAllowed(),dayTask == nil else{return}
        let token = generation
        let readDay = self.readDay
        let physical=Task.detached(priority:.utility){readDay()}
        // Cancellation retires publication; the handle remains until actual IO returns.
        dayTask=Task {
            let records=await physical.value
            dayTask=nil
            guard generation==token,!Task.isCancelled,timer != nil,samplingAllowed() else{
                // A reopened page coalesces behind the old reader, then requests fresh history.
                if timer != nil,samplingAllowed(),generation != token{loadDay()}
                return
            }
            dayLoaded=Date();day=records
        }
    }
}

