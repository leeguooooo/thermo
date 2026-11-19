import AgentCore
import Darwin
import ThermoL10n
import XCTest
@testable import CleanKit

/// Issue #138: a leaking on-demand system XPC service can be restarted, and nothing else under
/// /System becomes reachable through that door.
final class SystemServiceTests: XCTestCase {
    let cursor = "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/CursorUIViewService.xpc/Contents/MacOS/CursorUIViewService"
    let me = getuid() == 0 ? UInt32(501) : getuid()

    override func setUp() { L10n.override = .english }
    override func tearDown() { L10n.override = nil }

    func restartable(_ executable: String?, pid: Int32 = 500, ppid: Int32 = 1, uid: UInt32? = nil) -> Bool {
        SystemService.restartable(executable: executable, pid: pid, ppid: ppid, uid: uid ?? me, user: me, me: 99)
    }

    // MARK: Which processes qualify

    func testOnDemandXPCServiceOfThisUserIsRestartable() {
        XCTAssertTrue(restartable(cursor))
        XCTAssertTrue(restartable("/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/ThemeWidgetControlViewService.xpc/Contents/MacOS/ThemeWidgetControlViewService"))
        XCTAssertTrue(restartable("/System/Library/Frameworks/Metal.framework/Versions/A/XPCServices/MTLCompilerService.xpc/Contents/MacOS/MTLCompilerService"))
    }

    func testOwnerParentAndSelfAreChecked() {
        XCTAssertFalse(restartable(cursor, uid: 0), "root's copy cannot be signalled and is not offered")
        XCTAssertFalse(restartable(cursor, uid: me + 1))
        XCTAssertFalse(restartable(cursor, ppid: 4242), "only a direct child of launchd comes back by itself")
        XCTAssertFalse(restartable(cursor, ppid: 0), "an unreadable parent fails the rule")
        XCTAssertFalse(restartable(cursor, pid: 99), "never Thermo's own pid")
        XCTAssertFalse(restartable(cursor, pid: 1))
        XCTAssertFalse(restartable(nil))
        XCTAssertFalse(SystemService.restartable(executable: cursor, pid: 500, ppid: 1, uid: 0, user: 0, me: 99), "never as root")
    }

    func testOtherSystemProcessesStayUntouchable() {
        for path in ["/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                     "/sbin/launchd",
                     "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
                     "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
                     "/usr/libexec/trustd",
                     "/usr/sbin/cfprefsd",
                     "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mds",
                     // An app's own XPC service is part of the app.
                     "/System/Library/CoreServices/Dock.app/Contents/XPCServices/com.apple.dock.extra.xpc/Contents/MacOS/com.apple.dock.extra",
                     // Not Apple's framework folders.
                     "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/SimulatorTrampoline.xpc/Contents/MacOS/SimulatorTrampoline",
                     "/Library/Apple/System/Library/PrivateFrameworks/RemotePairing.framework/Versions/A/XPCServices/remotepairingd.xpc/Contents/MacOS/remotepairingd",
                     "/Applications/Fake.app/Contents/Frameworks/X.framework/XPCServices/Y.xpc/Contents/MacOS/Y",
                     // Shaped like a service but not inside an .xpc bundle of a framework.
                     "/System/Library/PrivateFrameworks/Foo.framework/Versions/A/Resources/Helper",
                     "/System/Library/PrivateFrameworks/XPCServices/Bare.xpc/Contents/MacOS/Bare",
                     "/System/Library/PrivateFrameworks/Foo.framework/XPCServices/Foo.xpc/Contents/Resources/tool",
                     "/System/Library/PrivateFrameworks/Foo.framework/../../../../tmp/XPCServices/Foo.xpc/Contents/MacOS/Foo"] {
            XCTAssertFalse(restartable(path), path)
        }
    }

    func testServicesWhoseLossIsNotJustARelaunchAreExcluded() {
        for path in ["/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
                     "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
                     "/System/Library/Frameworks/VideoToolbox.framework/Versions/A/XPCServices/VTEncoderXPCService.xpc/Contents/MacOS/VTEncoderXPCService",
                     "/System/Library/Frameworks/AudioToolbox.framework/XPCServices/com.apple.audio.SandboxHelper.xpc/Contents/MacOS/com.apple.audio.SandboxHelper",
                     "/System/Library/Frameworks/Security.framework/Versions/A/XPCServices/authd.xpc/Contents/MacOS/authd",
                     "/System/Library/PrivateFrameworks/SafariPlatformSupport.framework/Versions/A/XPCServices/com.apple.SafariPlatformSupport.Helper.xpc/Contents/MacOS/com.apple.SafariPlatformSupport.Helper",
                     "/System/Library/PrivateFrameworks/IMDPersistence.framework/XPCServices/IMDPersistenceAgent.xpc/Contents/MacOS/IMDPersistenceAgent",
                     "/System/Library/PrivateFrameworks/XprotectFramework.framework/Versions/A/XPCServices/XprotectService.xpc/Contents/MacOS/XprotectService",
                     "/System/Library/PrivateFrameworks/CascadeSets.framework/Versions/A/XPCServices/SetStoreUpdateService.xpc/Contents/MacOS/SetStoreUpdateService",
                     "/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/com.apple.appkit.xpc.openAndSavePanelService.xpc/Contents/MacOS/com.apple.appkit.xpc.openAndSavePanelService",
                     "/System/Library/PrivateFrameworks/StreamingZip.framework/Versions/A/XPCServices/com.apple.StreamingUnzipService.xpc/Contents/MacOS/com.apple.StreamingUnzipService",
                     "/System/Library/PrivateFrameworks/MobileInstallation.framework/XPCServices/com.apple.MobileInstallationHelperService.xpc/Contents/MacOS/com.apple.MobileInstallationHelperService"] {
            XCTAssertFalse(restartable(path), path)
        }
    }

    // MARK: Inventory and gate

    func testInventoryMarksTheServiceWithoutMakingItEndable() throws {
        var service = AgentProcess(pid: 500, ppid: 1, uid: getuid(), name: "CursorUIViewService", executable: cursor)
        service.memoryReading = ProcessMemoryReading(footprintKB: 2_097_152, residentKB: 5_800)
        var window = AgentProcess(pid: 501, ppid: 1, uid: getuid(), name: "WindowServer", executable: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer")
        window.memoryReading = ProcessMemoryReading(footprintKB: 900_000, residentKB: 400_000)
        let hogs = MachinePulse.group([service, window], limit: nil)
        let row = try XCTUnwrap(hogs.first { $0.name == "CursorUIViewService" })
        XCTAssertFalse(row.quittable, "no whole-row End, Quit or one-click cleanup reaches it")
        XCTAssertNil(row.parts?.first?.stop, "it is never ended like an ordinary process")
        if getuid() != 0 { XCTAssertEqual(row.parts?.first?.restartableService, true) }
        let other = try XCTUnwrap(hogs.first { $0.name == "WindowServer" })
        XCTAssertFalse(other.quittable)
        XCTAssertNil(other.parts?.first?.stop)
        XCTAssertNil(other.parts?.first?.restartableService)
    }

    func testGateOpensOnlyWithTheServiceCapabilityAndOnlyForServices() {
        let service = SlowdownProcess(pid: 500, ppid: 1, uid: me, name: "CursorUIViewService", executable: cursor)
        let tool = SlowdownProcess(pid: 501, ppid: 1, uid: me, name: "node", executable: "/opt/homebrew/bin/node")
        let window = SlowdownProcess(pid: 502, ppid: 1, uid: me, name: "WindowServer", executable: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer")
        XCTAssertFalse(ProcessActionGate.mayControl(service, allowApplication: true, allowAgentSession: true, uid: me, me: 99), "ordinary End never reaches it")
        XCTAssertTrue(ProcessActionGate.mayControl(service, allowApplication: false, allowSystemService: true, uid: me, me: 99))
        XCTAssertFalse(ProcessActionGate.mayControl(tool, allowApplication: true, allowSystemService: true, uid: me, me: 99), "the capability is not a wider End")
        XCTAssertFalse(ProcessActionGate.mayControl(window, allowApplication: true, allowSystemService: true, uid: me, me: 99))
    }

    func testGateReadsTheLiveParentBeforeEverySignal() {
        let identity = ProcessIdentity(pid: 500, uid: me, started: Date(timeIntervalSince1970: 1_000), executable: cursor)
        func validate(parent: Int32?, current: ProcessIdentity? = nil) -> ProcessActionGate.Validation {
            ProcessActionGate.validate(identity, allowApplication: false, allowSystemService: true, uid: me, me: 99,
                                       identity: { _ in current ?? identity }, details: { _ in ProcessDetails(executable: self.cursor) },
                                       parent: { _ in parent })
        }
        XCTAssertEqual(validate(parent: 1), .allowed(identity))
        XCTAssertEqual(validate(parent: 4242), .protected)
        XCTAssertEqual(validate(parent: nil), .protected)
        var reused = identity; reused.started = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(validate(parent: 1, current: reused), .changed, "a relaunched copy under the same PID is not the one that was confirmed")
    }

    // MARK: Restart

    final class World: @unchecked Sendable {
        var alive = true
        var signals: [Int32] = []
        var diesOn: Set<Int32> = [SIGKILL]
        var relaunchAs: Int32?
        var gate: ProcessActionGate.Outcome = .requested
    }

    func restart(_ world: World) -> SystemService.Result {
        let identity = ProcessIdentity(pid: 500, uid: me, started: Date(timeIntervalSinceNow: -3 * 86_400), executable: cursor)
        return SystemService.restart(identity, memoryKB: 2_097_152, grace: 0.3, relaunchWait: 0.3, record: false,
                                     attempt: { _, sig in
                                         guard world.gate == .requested else { return world.gate }
                                         world.signals.append(sig)
                                         if world.diesOn.contains(sig) { world.alive = false }
                                         return .requested
                                     },
                                     alive: { _ in world.alive },
                                     instances: { exe, uid in
                                         if world.alive { return [identity] }
                                         return world.relaunchAs.map { [ProcessIdentity(pid: $0, uid: uid, started: Date(), executable: exe)] } ?? []
                                     })
    }

    func testIgnoredSIGTERMEscalatesToSIGKILLAndReportsTheNewCopy() {
        let world = World(); world.relaunchAs = 777
        let result = restart(world)
        XCTAssertEqual(world.signals, [SIGTERM, SIGKILL])
        XCTAssertEqual(result.outcome, .relaunched)
        XCTAssertTrue(result.forced)
        XCTAssertEqual(result.newPID, 777)
        XCTAssertEqual(result.freedKB, 2_097_152)
        XCTAssertEqual(result.name, "CursorUIViewService")
        XCTAssertEqual(result.summary, "CursorUIViewService (PID 500) ignored the request to stop and was forced to quit (SIGKILL). macOS has started it again as PID 777. About 2.0 GiB freed.")
    }

    func testServiceThatObeysSIGTERMIsNotForcedAndNoNewCopyIsNotAFailure() {
        let world = World(); world.diesOn = [SIGTERM]
        let result = restart(world)
        XCTAssertEqual(world.signals, [SIGTERM])
        XCTAssertEqual(result.outcome, .exited)
        XCTAssertFalse(result.forced)
        XCTAssertNil(result.newPID)
        XCTAssertTrue(result.done)
        XCTAssertTrue(result.summary.contains("macOS starts it again the next time it is needed."), result.summary)
    }

    func testSurvivingBothSignalsIsReportedAsStillRunning() {
        let world = World(); world.diesOn = []
        let result = restart(world)
        XCTAssertEqual(world.signals, [SIGTERM, SIGKILL])
        XCTAssertEqual(result.outcome, .stillRunning)
        XCTAssertFalse(result.done)
        XCTAssertEqual(result.freedKB, 0)
        XCTAssertNil(result.newPID)
    }

    func testRefusedOrChangedProcessGetsNoSignal() {
        for (gate, outcome) in [(ProcessActionGate.Outcome.protected, SystemService.Outcome.refused), (.changed, .changed), (.declined, .notDelivered)] {
            let world = World(); world.gate = gate
            let result = restart(world)
            XCTAssertTrue(world.signals.isEmpty)
            XCTAssertEqual(result.outcome, outcome)
            XCTAssertFalse(result.done)
        }
    }

    // MARK: Leak verdict

    let now = Date()
    /// The readings from the issue: 223 MiB → 2.0 GiB over 21 hours, 5.7 MiB resident, started 3 days ago.
    var issueReadings: [Int] { (0...21).map { (223 + $0 * (2048 - 223) / 21) * 1024 } }

    func testGrowthThatOnlyWentUpInALongLivedSwappedOutProcessIsASuspectedLeak() throws {
        let leak = try XCTUnwrap(MemorySuspects.leak(points: issueReadings, residentKB: 5_837, started: now.addingTimeInterval(-3 * 86_400), now: now))
        XCTAssertEqual(leak.fromKB, 223 * 1024)
        XCTAssertEqual(leak.reclaimKB, 2048 * 1024)
        XCTAssertEqual(leak.residentKB, 5_837)
    }

    func testEachConditionIsNeeded() {
        let old = now.addingTimeInterval(-3 * 86_400)
        XCTAssertNil(MemorySuspects.leak(points: issueReadings, residentKB: 1_500 * 1024, started: old, now: now), "memory it still uses is not a leak signal")
        XCTAssertNil(MemorySuspects.leak(points: issueReadings, residentKB: nil, started: old, now: now))
        XCTAssertNil(MemorySuspects.leak(points: issueReadings, residentKB: 5_837, started: now.addingTimeInterval(-3_600), now: now), "a young process is still warming up")
        XCTAssertNil(MemorySuspects.leak(points: issueReadings, residentKB: 5_837, started: nil, now: now))
        var dipped = issueReadings; dipped.insert(400 * 1024, at: 15)
        XCTAssertNil(MemorySuspects.leak(points: dipped, residentKB: 5_837, started: old, now: now), "memory that came back down is a workload")
        var jitter = issueReadings; jitter[10] -= 8 * 1024
        XCTAssertNotNil(MemorySuspects.leak(points: jitter, residentKB: 5_837, started: old, now: now), "a few MiB of noise is not a dip")
    }

    func program(residentKB: Int?, started: Date) -> (MachinePulse.Hog, [ProgramMemoryRecord]) {
        let id = "program:cmd:cursoruiviewservice"
        let identity = ProcessIdentity(pid: 500, uid: me, started: started, executable: cursor)
        var h = MachinePulse.Hog(id: id, name: "CursorUIViewService", cpu: 0, memoryKB: 2048 * 1024, pids: [500], app: nil, quittable: false)
        h.residentKB = residentKB; h.memoryMetric = .footprint; h.processIdentities = [identity]
        let readings = issueReadings.dropLast()
        let history = readings.enumerated().map { i, kb -> ProgramMemoryRecord in
            var r = ProgramMemoryRecord(t: now.addingTimeInterval(-Double(readings.count - i) * 3600), programs: [id: kb], names: [id: h.name])
            r.identities = [id: [identity]]
            return r
        }
        return (h, history)
    }

    func testSuspectCarriesTheVerdictAndSaysWhatARestartFrees() throws {
        let (h, history) = program(residentKB: 5_837, started: now.addingTimeInterval(-3 * 86_400))
        let suspect = try XCTUnwrap(MemorySuspects.find(programs: [h], history: history, now: now).first)
        XCTAssertEqual(suspect.kind, .growing)
        XCTAssertEqual(suspect.leak?.reclaimKB, 2048 * 1024)
        XCTAssertEqual(suspect.text, suspect.leakText)
        XCTAssertEqual(suspect.leakText, "Suspected leak: it only grew for 21 h (223 MiB → 2.0 GiB) and almost none of it is in use (resident 5.7 MiB). Restarting it frees about 2.0 GiB.")
    }

    func testGrowthInMemoryStillInUseStaysOrdinaryGrowth() throws {
        let (h, history) = program(residentKB: 1_800 * 1024, started: now.addingTimeInterval(-3 * 86_400))
        let suspect = try XCTUnwrap(MemorySuspects.find(programs: [h], history: history, now: now).first)
        XCTAssertNil(suspect.leak)
        XCTAssertNil(suspect.leakText)
        XCTAssertTrue(suspect.text.contains("grew by"), suspect.text)
    }

    /// The series Thermo recorded for the process in the issue: already 1.1 GiB when the 24 hours
    /// kept begin, flat for hours, then up to 2.1 GiB. Less than 50 % above its lowest is still a leak.
    func testRecordedSeriesFromTheIssueIsALeakEvenBelowFiftyPercentGrowth() throws {
        let id = "program:cmd:cursoruiviewservice"
        let identity = ProcessIdentity(pid: 47092, uid: me, started: now.addingTimeInterval(-3 * 86_400), executable: cursor)
        let mib = [1500, 1532, 1532, 1533, 1533, 1533, 1533, 1533, 1533, 1533, 1676, 1949, 1990]
        var h = MachinePulse.Hog(id: id, name: "CursorUIViewService", cpu: 0, memoryKB: 2149 * 1024, pids: [47092], app: nil, quittable: false)
        h.residentKB = 5_837; h.memoryMetric = .footprint; h.processIdentities = [identity]
        let history = mib.enumerated().map { i, value -> ProgramMemoryRecord in
            var r = ProgramMemoryRecord(t: now.addingTimeInterval(-Double(mib.count - i) * 5_700), programs: [id: value * 1024], names: [id: h.name])
            r.identities = [id: [identity]]
            return r
        }
        let suspect = try XCTUnwrap(MemorySuspects.find(programs: [h], history: history, now: now).first)
        XCTAssertEqual(suspect.leak?.fromKB, 1500 * 1024)
        h.residentKB = 1_900 * 1024
        XCTAssertTrue(MemorySuspects.find(programs: [h], history: history, now: now).isEmpty, "the same curve in memory that is in use is neither a leak nor 50 % growth")
    }

    func testSuspectedLeakSurvivesEncodingAndOldRecordsStillDecode() throws {
        let (h, history) = program(residentKB: 5_837, started: now.addingTimeInterval(-3 * 86_400))
        let suspect = try XCTUnwrap(MemorySuspects.find(programs: [h], history: history, now: now).first)
        XCTAssertEqual(try JSONDecoder().decode(MemorySuspect.self, from: JSONEncoder().encode(suspect)), suspect)
        let legacy = #"{"id":"x","name":"x","kind":"growing","memoryKB":1}"#
        XCTAssertNil(try JSONDecoder().decode(MemorySuspect.self, from: Data(legacy.utf8)).leak)
        let part = #"{"pid":1,"role":"main","memoryKB":1,"cpu":0}"#
        XCTAssertNil(try JSONDecoder().decode(MachinePulse.Part.self, from: Data(part.utf8)).restartableService)
    }

    // MARK: Footprint against resident

    func testGapIsExplainedOnlyWhenMostOfTheFootprintIsOutOfRAM() {
        XCTAssertEqual(MemoryGap.outOfRAMKB(footprintKB: 2048 * 1024, residentKB: 5_837, metric: .footprint), 2048 * 1024 - 5_837)
        XCTAssertNil(MemoryGap.outOfRAMKB(footprintKB: 2048 * 1024, residentKB: 1024 * 1024, metric: .footprint))
        XCTAssertNil(MemoryGap.outOfRAMKB(footprintKB: 100 * 1024, residentKB: 1_000, metric: .footprint), "too small to explain")
        XCTAssertNil(MemoryGap.outOfRAMKB(footprintKB: 2048 * 1024, residentKB: nil, metric: .footprint))
        XCTAssertNil(MemoryGap.outOfRAMKB(footprintKB: 2048 * 1024, residentKB: 5_837, metric: .residentEstimate), "an estimate is not a footprint")
        XCTAssertNil(MemoryGap.outOfRAMKB(footprintKB: 2048 * 1024, residentKB: 5_837, metric: .mixed))
    }

    func testGapTextNamesBothColumnsAndSwap() {
        let text = MemoryGap.text(footprintKB: 2048 * 1024, residentKB: 5_837, swapUsed: 18 << 30, swapFiles: 19 << 30)
        XCTAssertTrue(text.hasPrefix("Footprint 2.0 GiB, resident 5.7 MiB: most of this memory is not resident."), text)
        XCTAssertTrue(text.hasSuffix("Swap in use now: 18.0 GiB of 19.0 GiB."), text)
        XCTAssertFalse(MemoryGap.text(footprintKB: 2048 * 1024, residentKB: 5_837).contains("Swap in use now"))
    }
}
