import AppKit
import Darwin
import ModuleHost
import ModuleKit

// Exercises ModuleManager against real module processes. Assembled and run by scripts/module-harness.sh;
// never shipped. Prints one line per check and exits 0 only when all passed.

setvbuf(stdout, nil, _IOLBF, 0)
let a = "dev.thermo.probe.a", b = "dev.thermo.probe.b"
var failures = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "ok    " : "FAIL  ") + what); if !ok { failures += 1 } }
func note(_ what: String) { print("      " + what) }
func alive(_ pid: pid_t?) -> Bool { pid.map { kill($0, 0) == 0 } ?? false }
func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

@MainActor func until(_ limit: Double, _ condition: () -> Bool) async -> Double? {
    let start = uptime()
    while uptime() - start < limit { if condition() { return uptime() - start }; await sleep(0.02) }
    return condition() ? uptime() - start : nil
}

@MainActor func scenario(_ window: NSWindow) async {
    let timing = ModuleLifecycle.Timing(idleTimeout: 2, firstBackoff: 0.5, longestBackoff: 4, stableRun: 60)
    let manager = ModuleManager(timing: timing)
    // The kernel side of the probe's requests: real file services, a yes to every confirmation, a throwaway log.
    let scratch = "/private/tmp/thermo-probe"
    try? FileManager.default.removeItem(atPath: scratch)
    for folder in ["/logs", "/open", "/bin"] { try? FileManager.default.createDirectory(atPath: scratch + folder, withIntermediateDirectories: true) }
    FileManager.default.createFile(atPath: scratch + "/open/note.txt", contents: Data("hello".utf8))
    FileManager.default.createFile(atPath: scratch + "/bin/old.txt", contents: Data("old".utf8))
    let outside = NSHomeDirectory() + "/.thermo-probe-outside.txt"
    FileManager.default.createFile(atPath: outside, contents: Data("private".utf8))
    let log = ModuleAccessLog(home: scratch + "/logs")
    manager.kernel = { manifest in
        BrokerKernel(broker: CapabilityBroker(manifest: manifest, log: log,
                                              handlers: [.filesRead: KernelServices.filesRead, .filesDelete: KernelServices.filesDelete],
                                              confirm: { _ in true }))
    }
    await manager.load { _ in false }
    note("problems: \(manager.problems); registrations: \(manager.registrations.sorted { $0.key < $1.key })")
    check(manager.modules.map(\.manifest.id) == [a, b], "finds the two modules inside this app: \(manager.modules.map(\.manifest.id))")
    check(manager.modules.allSatisfy { $0.pid == nil && !$0.scheduled } && manager.activeEntries.isEmpty, "off: no process, nothing scheduled, no entries")
    func pid(_ id: String) -> pid_t? { manager.status(id)?.pid }
    func phase(_ id: String) -> ModuleLifecycle.Phase? { manager.status(id)?.phase }
    func ping(_ id: String) async -> pid_t? {
        guard let data = try? await manager.run(id, command: "ping"), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let home = object["home"] as? String, id == a { note("module home: \(home)") }
        return (object["pid"] as? Int).map(pid_t.init)
    }

    do { _ = try await manager.run(a, command: "ping"); check(false, "a command to a module that is off is refused") }
    catch { check(error as? ModuleError == .off(a), "a command to a module that is off is refused") }

    manager.setEnabled(a, true); manager.setEnabled(b, true)
    check(manager.activeEntries.count == 2, "on: entries are listed")
    let started = await until(5) { phase(b) == .running }
    check(started != nil, "always module starts when switched on (\(started.map { String(format: "%.0f ms", $0 * 1000) } ?? "never"))")
    note("failures: \(manager.lastFailure)")
    check(pid(a) == nil && phase(a) == .stopped, "on-demand module has no process until used")

    let t0 = uptime()
    let first = await ping(a)
    check(first != nil && first == pid(a), "first use starts the on-demand module (\(String(format: "%.0f ms", (uptime() - t0) * 1000)), pid \(first ?? 0))")
    let bPID = pid(b)

    // Reaching the Mac only through the kernel.
    func call(_ command: String, _ arguments: [String: Any]) async -> [String: Any] {
        guard let data = try? await manager.run(a, command: command, arguments: JSONSerialization.data(withJSONObject: arguments)) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    // The manifest gives read access to open/ and delete access to bin/.
    let own = await call("peek", ["path": scratch + "/open/note.txt"])
    check(own["readable"] as? Bool == true, "the module reads what its manifest lets it read by itself")
    let poke = await call("poke", ["path": scratch + "/open"])
    check(poke["writable"] as? Bool == false && poke["listed"] as? Int == 1, "it can list that folder but cannot write into it")
    let bin = await call("peek", ["path": scratch + "/bin/old.txt"])
    let away = await call("peek", ["path": outside])
    check(bin["readable"] as? Bool == false && away["readable"] as? Bool == false, "it cannot read where it may only delete, nor anywhere else")
    let read = await call("ask", ["capability": "files.read:" + scratch + "/open/note.txt", "payload": ["op": "read"]])
    check(((read["answer"] as? [String: Any])?["base64"] as? String).flatMap { Data(base64Encoded: $0) } == Data("hello".utf8), "the kernel also reads it for the module, as its manifest allows")
    let stray = await call("ask", ["capability": "files.read:" + outside, "payload": ["op": "read"]])
    check((stray["problem"] as? String)?.hasPrefix("denied") == true && stray["answer"] == nil, "a file its manifest does not cover is refused: \(stray["problem"] ?? "")")
    let end = await call("ask", ["capability": "processes.end", "payload": [:]])
    check((end["problem"] as? String)?.hasPrefix("denied") == true, "a capability it did not declare is refused")
    let trash = await call("ask", ["capability": "files.delete:" + scratch + "/bin/old.txt", "payload": ["op": "trash"]])
    let trashed = ((trash["answer"] as? [String: Any])?["results"] as? [[String: Any]])?.first
    check(trashed?["status"] as? String == "done" && !FileManager.default.fileExists(atPath: scratch + "/bin/old.txt"), "a confirmed delete moves the file to the Trash")
    if let path = trashed?["trashed"] as? String { try? FileManager.default.removeItem(atPath: path) }
    let wrong = await call("ask", ["capability": "files.delete:" + scratch + "/open/note.txt", "payload": ["op": "trash"]])
    check((wrong["problem"] as? String)?.hasPrefix("denied") == true && FileManager.default.fileExists(atPath: scratch + "/open/note.txt"), "it cannot delete where it may only read")
    let summary = log.summary(module: a)
    check(summary.read == [scratch + "/open/note.txt"] && summary.deleted == [scratch + "/bin/old.txt"] && summary.denied == 3,
          "the access log shows what the kernel read and deleted for it and that three requests were denied")
    try? FileManager.default.removeItem(atPath: outside)

    // Exploration, not a check: what the module reaches by itself under the entitlements it was signed with.
    if let folders = ProcessInfo.processInfo.environment["THERMO_HARNESS_POKE"] {
        for folder in folders.split(separator: ":").map(String.init) {
            let poke = await call("poke", ["path": folder])
            note("poke \(folder): listed \(poke["listed"] ?? "?") entries, writable \(poke["writable"] ?? "?")")
        }
    }

    // Memory and energy.
    if let before = manager.usage(a) {
        _ = try? await manager.run(a, command: "burn", arguments: Data(#"{"ms":400}"#.utf8))
        let after = manager.usage(a)
        note("usage before: \(before)"); note("usage after:  \(after.map { "\($0)" } ?? "nil")")
        check(before.footprintBytes > 1 << 20, "memory is read (\(before.footprintBytes >> 10) KiB)")
        check((after?.cpuSeconds ?? 0) - before.cpuSeconds > 0.2, "CPU time grows with work")
        check((after?.energyJoules ?? 0) > before.energyJoules, "energy grows with work")
    } else { check(false, "usage is read") }

    // Idle exit.
    let idle = await until(8) { phase(a) == .stopped && !alive(first) }
    check(idle != nil, "idle on-demand module exits (\(idle.map { String(format: "%.1f s", $0) } ?? "never") after last use; stop: \(manager.lastStop[a] ?? "?"))")
    check(manager.status(a)?.scheduled == false && manager.status(a)?.crashes == 0, "after idle exit nothing is scheduled and it is not a crash")
    check(pid(b) == bPID && alive(bPID), "the other module was not touched")
    let second = await ping(a)
    check(second != nil && second != first, "next use starts it again (pid \(second ?? 0))")

    // An attached scene keeps it alive past the idle timeout.
    var activations = 0
    if let scene = try? manager.attach(a, scene: "main") {
        scene.onChange = { if $0 { activations += 1 } }
        window.contentView = scene.controller.view
        let shown = await until(5) { scene.active }
        check(shown != nil && pid(a) == second, "scene appears from the same process (\(shown.map { String(format: "%.0f ms", $0 * 1000) } ?? "never"))")
        await sleep(3)
        check(alive(second) && phase(a) == .running, "a module with a scene on screen is not idled out")

        // Crash with a scene attached: comes back by itself.
        if let second { kill(second, SIGKILL) }
        let back = await until(8) { scene.active && pid(a) != nil && pid(a) != second }
        check(back != nil && activations == 2, "killed module restarts and its scene returns (\(back.map { String(format: "%.1f s", $0) } ?? "never"), crashes \(manager.status(a)?.crashes ?? -1))")
        check(pid(b) == bPID && alive(bPID), "the other module kept its process")
        let third = pid(a)
        manager.detach(scene)
        window.contentView = NSView()
        let left = await until(8) { phase(a) == .stopped && !alive(third) }
        check(left != nil, "after the scene is detached the module idles out")
    } else { check(false, "scene attaches") }

    // Crashes of a module with no UI, with backoff.
    var waits: [Double] = []
    var last = bPID
    for _ in 0..<3 {
        guard let victim = last else { break }
        kill(victim, SIGKILL)
        let killed = uptime()
        _ = await until(3) { phase(b) == .waiting }
        let back = await until(10) { phase(b) == .running && pid(b) != victim }
        waits.append(uptime() - killed)
        if back == nil { break }
        last = pid(b)
    }
    note("restart delays after kill: \(waits.map { String(format: "%.2f s", $0) })")
    check(waits.count == 3 && waits[0] >= 0.5 && waits[1] >= 1 && waits[2] >= 2 && waits[2] < 4, "a module without UI is noticed and restarted after 0.5, 1 and 2 s")
    check(manager.status(b)?.crashes == 3, "three crashes in a row are counted")

    // A module that exits during a command.
    do { _ = try await manager.run(a, command: "exit"); check(false, "a command the module dies in fails") }
    catch { check(error as? ModuleError == .exited(a), "a command the module dies in fails with: \(error)") }
    check(phase(a) == .stopped && pid(a) == nil, "a crashed on-demand module is not restarted while unused")
    let t1 = uptime()
    let again = await ping(a)
    check(again != nil && uptime() - t1 >= 0.4, "the next use waits out the backoff, then works (\(String(format: "%.2f s", uptime() - t1)))")

    // A use that arrives while the idle module is being stopped gets the next process, not an error.
    let stopping = await until(8) { phase(a) == .stopping }
    let late = stopping == nil ? nil : await ping(a)
    check(late != nil && late != again, "a use during a planned stop is served by a fresh process (pid \(late ?? 0))")

    // Switching off.
    let pa = pid(a), pb = pid(b)
    manager.setEnabled(a, false); manager.setEnabled(b, false)
    let off = await until(8) { !alive(pa) && !alive(pb) && phase(a) == .stopped && phase(b) == .stopped }
    check(off != nil, "switched off: both processes are gone (\(off.map { String(format: "%.1f s", $0) } ?? "never"); stop: \(manager.lastStop))")
    check(manager.modules.allSatisfy { $0.pid == nil && !$0.scheduled } && manager.activeEntries.isEmpty, "switched off: nothing scheduled, no entries")
    await sleep(5)
    check(manager.modules.allSatisfy { $0.pid == nil && $0.phase == .stopped }, "switched off: stays off")

    try? FileManager.default.removeItem(atPath: scratch)
    print(failures == 0 ? "PASS" : "FAILED \(failures)")
    exit(failures == 0 ? 0 : 1)
}

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Thermo module harness"; window.center(); window.orderFront(nil)
        Task { @MainActor in await scenario(self.window) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 150) { print("FAILED timeout"); exit(2) }
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
