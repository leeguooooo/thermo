// Production panel/model/coordinator; simulated SMC and private recovery/prefs only.
@testable import ThermoApp
import AppKit
import SwiftUI
@testable import ThermoKit
import ThermoL10n

@_silgen_name("$s9ThermoApp20installStandardMenusyyF")
@MainActor func fixtureStandardMenus() {}

final class FakeBattery: @unchecked Sendable {
    let root: URL, lock = NSLock()
    var bytes: [UInt8] = [0, 0, 0, 0]
    var allowRecovery = true, percent = 90.0
    var externalPower: Bool? = true
    var batteryPresence: BatteryPresence = .present, hasChargeKey = true, nativeAvailable = false
    init(_ root: URL) { self.root = root }
    func permit(_ value: Bool) { lock.lock(); allowRecovery = value; lock.unlock() }
    func mode(_ kind: Int) {
        lock.lock(); defer { lock.unlock() }
        batteryPresence = kind == 1 ? .notObserved : .present
        hasChargeKey = kind != 2; nativeAvailable = kind == 2
    }
    func presence() -> BatteryPresence { lock.lock(); defer { lock.unlock() }; return batteryPresence }
    func nativeEligible() -> Bool { lock.lock(); defer { lock.unlock() }; return nativeAvailable }
    func powerState(_ value: Double, plugged: Bool?) { lock.lock(); percent = value; externalPower = plugged; lock.unlock() }
    func controller() -> BatteryChargingGate {
        let info = SMCKeyInfo(key: "CHTE", type: "ui32", size: 4, attributes: 0xd4)
        return .init(io: .init(info: { key in
            self.lock.lock(); defer { self.lock.unlock() }; return key == "CHTE" && self.hasChargeKey ? info : nil
        }, read: { _ in
            self.lock.lock(); defer { self.lock.unlock() }; return .init(key: "CHTE", type: "ui32", bytes: self.bytes)
        }, write: { _, value in
            self.lock.lock(); defer { self.lock.unlock() }
            if value == [0, 0, 0, 0], !self.allowRecovery { throw BatteryGateError("恢复被测试夹具阻止") }
            self.bytes = value
            try JSONSerialization.data(withJSONObject: ["bytes": value]).write(to: self.root.appendingPathComponent("registers.json"), options: .atomic)
            print("FAKE_WRITE \(value)"); fflush(stdout)
        }), store: BatteryGateLeaseFile(directory: root.path, owner: getuid()).io,
            hardwareID: { "22222222-2222-2222-2222-222222222222" })
    }
    func power() -> BatteryChargePolicy.Observation? {
        lock.lock(); defer { lock.unlock() }
        return .init(percent: percent, externalPower: externalPower, observedAt: AWDLSystemClock.now())
    }
}
@MainActor final class UIDelegate: NSObject, NSApplicationDelegate {
    let model: BatteryCareModel
    init(_ model: BatteryCareModel) { self.model = model }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let blocked = model.requestQuit(); print("QUIT_BLOCKED \(blocked)"); fflush(stdout)
        return blocked ? .terminateCancel : .terminateNow
    }
}
struct QAHost: View {
    @ObservedObject var model: BatteryCareModel
    let fake: FakeBattery
    @State private var showing = true
    var body: some View {
        VStack {
            Text("独立验收：仅模拟充电，不写真实电池")
            Button("打开充电面板") { showing = true }
        }.padding(30).sheet(isPresented: $showing) {
            VStack {
                HStack {
                    Button("阻止模拟恢复") { fake.permit(false) }
                    Button("允许模拟恢复") { fake.permit(true) }
                    Button("模拟无电池") { fake.mode(1) }
                    Button("模拟系统保护") { fake.mode(2) }
                    Button("模拟 SMC 支持") { fake.mode(0) }
                }.padding(.top, 12)
                HStack {
                    Button("模拟 100%") { fake.powerState(100, plugged: true) }
                    Button("模拟断电") { fake.powerState(90, plugged: false) }
                    Button("模拟供电未知") { fake.powerState(90, plugged: nil) }
                    Button("恢复 90% 接电") { fake.powerState(90, plugged: true) }
                }
                BatteryCarePanel(model: model, configureHelper: { print("NO_HELPER_INSTALL"); fflush(stdout) }, openBatterySettings: { print("NO_SYSTEM_SETTINGS"); fflush(stdout) })
            }
        }
    }
}
@main struct BatteryUIAcceptance {
    @MainActor static func main() throws {
        let path = CommandLine.arguments.count == 2 ? CommandLine.arguments[1] : Bundle.main.object(forInfoDictionaryKey: "ThermoFixtureRoot") as? String
        guard let path, getuid() != 0 else { exit(2) }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("thermo-battery-ui-"), FileManager.default.fileExists(atPath: root.appendingPathComponent(".thermo-battery-ui-fixture").path) else { exit(3) }
        _ = freopen(root.appendingPathComponent("trace.log").path, "a", stdout)
        let fake = FakeBattery(root), owner = AWDLConnectionOwner()
        let manager = BatteryHelperCoordinator(make: { fake.controller() }, power: { fake.power() }, presence: { fake.presence() }, nativeEligible: { fake.nativeEligible() }, tickInterval: 0.1)
        let backend = BatteryCareBackend(read: {
            let data: Data = await withCheckedContinuation { c in manager.state(owner: owner) { c.resume(returning: $0) } }
            return try PolicyCoding.decoder().decode(BatteryChargeState.self, from: data)
        }, set: { policy, id in
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                manager.setPolicy(policy, owner: owner, sessionID: id) { error in
                    if let error { c.resume(throwing: BatteryGateError(error)) } else { c.resume() }
                }
            }
        }, reset: { manager.disconnected(owner: owner) }, record: { action, status, _ in print("HISTORY \(action) \(status)"); fflush(stdout) })
        let preferences = BatteryCarePreferences(load: {
            (try? Data(contentsOf: root.appendingPathComponent("preference.json"))) == Data("true".utf8)
        }, save: { try? Data(($0 ? "true" : "false").utf8).write(to: root.appendingPathComponent("preference.json"), options: .atomic) })
        let model = BatteryCareModel(backend: backend, preferences: preferences), delegate = UIDelegate(model)
        L10n.apply(preference: "zh-Hans")
        let app = NSApplication.shared; app.delegate = delegate; app.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
        submenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 680, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Thermo Battery UI QA"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: QAHost(model: model, fake: fake).preferredColorScheme(.dark))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        model.restoreSavedPreference()
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { fake.permit(true); app.terminate(nil) }
        withExtendedLifetime((window, delegate, manager, fake)) { app.run() }
    }
}
