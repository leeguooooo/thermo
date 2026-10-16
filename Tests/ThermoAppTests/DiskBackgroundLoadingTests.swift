import XCTest
import CleanKit
import ThermoL10n
@testable import ThermoApp

final class DiskBackgroundLoadingTests: XCTestCase {
    final class IO: @unchecked Sendable {
        let reports: [ScanReport?]
        let readGates: [Int: (XCTestExpectation, DispatchSemaphore)]
        let optionsGate: (XCTestExpectation, DispatchSemaphore)?
        let lock = NSLock()
        var reads = 0, preparations = 0, scans = 0, active = 0, peak = 0
        var categories: [Set<CleanCategory>] = []
        init(_ reports: [ScanReport?], readGates: [Int: (XCTestExpectation, DispatchSemaphore)] = [:],
             optionsGate: (XCTestExpectation, DispatchSemaphore)? = nil) {
            self.reports = reports; self.readGates = readGates; self.optionsGate = optionsGate
        }
        var stats: (reads: Int, preparations: Int, scans: Int, peak: Int) {
            lock.lock(); defer { lock.unlock() }; return (reads, preparations, scans, peak)
        }
        func begin() { XCTAssertFalse(Thread.isMainThread); lock.lock(); active += 1; peak = max(peak, active); lock.unlock() }
        func end() { lock.lock(); active -= 1; lock.unlock() }
        var dependency: DiskScanIO {
            .init(options: { scope, category, days in
                self.begin(); defer { self.end() }
                self.lock.lock(); self.preparations += 1; let index = self.preparations; self.lock.unlock()
                if index == 1, let (began, release) = self.optionsGate {
                    began.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                }
                var options = ScanOptions(projectRoots: [])
                options.categories = category.map { [$0] } ?? Set(CleanCategory.allCases.filter { scope == .all || $0.isAI })
                options.sessionRetentionDays = category == .aiSessions || (category == nil && scope == .ai) ? days : nil
                return options
            }, cached: { options, _ in
                self.begin(); defer { self.end() }
                self.lock.lock(); let index = self.reads; self.reads += 1; self.categories.append(options.categories); self.lock.unlock()
                if let (began, release) = self.readGates[index] {
                    began.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                }
                return self.reports[min(index, self.reports.count - 1)]
            }, scan: { options, cancellation, progress, items in
                self.begin(); defer { self.end() }
                self.lock.lock(); self.scans += 1; self.lock.unlock()
                XCTAssertFalse(cancellation.isCancelled)
                progress("fixture progress")
                var result = DiskBackgroundLoadingTests.report("fresh")
                result.categories = Array(options.categories)
                result.sessionRetentionDays = options.sessionRetentionDays
                items(result.items)
                return result
            })
        }
    }
    static func report(_ id: String) -> ScanReport {
        var r = ScanReport(items: [.init(id:id,category:.devCaches,title:id,safety:.safe,bytes:10,paths:["/fixture/"+id])],denied:[],started:Date(),duration:0)
        r.language = L10n.current.rawValue; r.sessionPolicyVersion = ScanOptions.sessionPolicyVersion
        return r
    }
    @MainActor func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("background operation did not reach expected state",file:file,line:line)
    }
    @MainActor func testCacheReadReturnsImmediatelyAndPageStormUsesOneReader() async {
        let began=expectation(description:"cache read"), release=DispatchSemaphore(value:0)
        defer { release.signal() }
        let io=IO([Self.report("cached")],readGates:[0:(began,release)])
        let model=DiskModel(scanIO:io.dependency,requestNotifications:{})
        model.loadSaved(); XCTAssertTrue(model.loadingSaved); XCTAssertNil(model.report)
        await fulfillment(of:[began],timeout:2)
        for _ in 0..<1000 { model.loadSaved() }
        XCTAssertEqual(io.stats.reads,1); XCTAssertEqual(io.stats.preparations,1)
        release.signal(); await eventually { model.report != nil && !model.loadingSaved }
        XCTAssertTrue(model.selected.isEmpty, "Development dependencies remain opt-in"); XCTAssertEqual(io.stats.peak,1)
    }
    @MainActor func testLatestCategorySupersedesAnOlderBlockedCache() async {
        let first=expectation(description:"old"), last=expectation(description:"latest")
        let releaseFirst=DispatchSemaphore(value:0), releaseLast=DispatchSemaphore(value:0)
        defer { releaseFirst.signal(); releaseLast.signal() }
        let io=IO([Self.report("old"),Self.report("latest")],readGates:[0:(first,releaseFirst),1:(last,releaseLast)])
        let model=DiskModel(scanIO:io.dependency,requestNotifications:{})
        model.loadSaved(category:.projects); await fulfillment(of:[first],timeout:2)
        for _ in 0..<100 { model.loadSaved(category:.xcode); model.loadSaved(category:.devCaches) }
        releaseFirst.signal(); await fulfillment(of:[last],timeout:2)
        XCTAssertNil(model.report); XCTAssertTrue(model.selected.isEmpty)
        releaseLast.signal(); await eventually { model.report?.items.first?.id == "latest" }
        XCTAssertEqual(io.stats.reads,2); XCTAssertEqual(io.stats.peak,1)
        XCTAssertEqual(io.categories,[Set([.projects]),Set([.devCaches])])
    }
    @MainActor func testRetentionAndProtectionInvalidationsRejectOldPlans() async {
        for changeRetention in [true,false] {
            let first=expectation(description:"old"), last=expectation(description:"new")
            let a=DispatchSemaphore(value:0), b=DispatchSemaphore(value:0)
            defer { a.signal(); b.signal() }
            let io=IO([Self.report("old"),Self.report("new")],readGates:[0:(first,a),1:(last,b)])
            let model=DiskModel(scanIO:io.dependency,requestNotifications:{})
            model.loadSaved(category:.aiSessions); await fulfillment(of:[first],timeout:2)
            if changeRetention { model.setSessionRetentionDays(90) } else { model.protectionRulesChanged() }
            model.loadSaved(category:.aiSessions)
            a.signal(); await fulfillment(of:[last],timeout:2)
            XCTAssertNil(model.report); XCTAssertTrue(model.selected.isEmpty)
            b.signal(); await eventually { model.report?.items.first?.id == "new" }
            XCTAssertEqual(io.stats.peak,1)
        }
    }
    @MainActor func testFreshScanWinsOverAnOlderCacheAndUsesTheSameWorker() async {
        let began=expectation(description:"old cache"), release=DispatchSemaphore(value:0)
        defer { release.signal() }
        let io=IO([Self.report("old")],readGates:[0:(began,release)])
        let model=DiskModel(scanIO:io.dependency,requestNotifications:{})
        model.loadSaved(); await fulfillment(of:[began],timeout:2)
        model.scan(category:.devCaches); XCTAssertTrue(model.scanning); XCTAssertFalse(model.loadingSaved)
        XCTAssertEqual(io.stats.scans,0)
        release.signal(); await eventually { !model.scanning && model.report?.items.first?.id == "fresh" }
        XCTAssertTrue(model.selected.isEmpty, "Development dependencies remain opt-in"); XCTAssertEqual(io.stats.scans,1); XCTAssertEqual(io.stats.peak,1)
    }
    @MainActor func testStopWhileWaitingForCacheSkipsEvenScanPreparation() async {
        let began=expectation(description:"cache"), release=DispatchSemaphore(value:0)
        defer { release.signal() }
        let io=IO([Self.report("old")],readGates:[0:(began,release)])
        let model=DiskModel(scanIO:io.dependency,requestNotifications:{})
        model.loadSaved(); await fulfillment(of:[began],timeout:2)
        model.scan(category:.aiSessions); model.stop()
        XCTAssertTrue(model.stopping); XCTAssertTrue(model.scanning)
        release.signal(); await eventually { !model.scanning }
        XCTAssertEqual(io.stats.preparations,1); XCTAssertEqual(io.stats.scans,0)
        XCTAssertEqual(model.report?.cancelled,true); XCTAssertEqual(model.report?.categories,[.aiSessions])
        XCTAssertTrue(model.selected.isEmpty); XCTAssertFalse(model.stopping)
    }
    @MainActor func testStopDuringDirectoryPreparationDoesNotStartScanner() async {
        let began=expectation(description:"directory preparation"), release=DispatchSemaphore(value:0)
        defer { release.signal() }
        let io=IO([nil],optionsGate:(began,release))
        let model=DiskModel(scanIO:io.dependency,requestNotifications:{})
        model.scan(); await fulfillment(of:[began],timeout:2)
        model.stop(); model.scan(); XCTAssertEqual(io.stats.preparations,1)
        release.signal(); await eventually { !model.scanning }
        XCTAssertEqual(io.stats.scans,0); XCTAssertEqual(model.report?.cancelled,true)
    }
    @MainActor func testCacheMissOnlyAutoScansWhenRequestedAndMergesIdenticalRequests() async {
        let began=expectation(description:"cache"), release=DispatchSemaphore(value:0)
        defer { release.signal() }
        let io=IO([nil],readGates:[0:(began,release)])
        let model=DiskModel(scanIO:io.dependency,requestNotifications:{})
        model.loadSaved(); await fulfillment(of:[began],timeout:2)
        model.loadSaved(scanIfMissing:true); model.loadSaved()
        release.signal(); await eventually { !model.scanning && model.report?.items.first?.id == "fresh" }
        XCTAssertEqual(io.stats.reads,1); XCTAssertEqual(io.stats.scans,1)
        let quiet=IO([nil]), passive=DiskModel(scanIO:quiet.dependency,requestNotifications:{})
        passive.loadSaved(); await eventually { !passive.loadingSaved }
        XCTAssertNil(passive.report); XCTAssertEqual(quiet.stats.scans,0)
    }
    @MainActor func testScopeChangeDiscardsCacheAndDoesNotAutoScan() async {
        let first=expectation(description:"old"), last=expectation(description:"new")
        let a=DispatchSemaphore(value:0), b=DispatchSemaphore(value:0)
        defer { a.signal(); b.signal() }
        let io=IO([Self.report("old"),Self.report("new")],readGates:[0:(first,a),1:(last,b)])
        let model=DiskModel(scanIO:io.dependency,requestNotifications:{})
        model.loadSaved(scanIfMissing:true); await fulfillment(of:[first],timeout:2)
        model.scope = .ai; model.loadSaved()
        a.signal(); await fulfillment(of:[last],timeout:2)
        XCTAssertNil(model.report)
        b.signal(); await eventually { model.report?.items.first?.id == "new" }
        XCTAssertEqual(io.stats.scans,0); XCTAssertEqual(io.stats.peak,1)
    }
}
