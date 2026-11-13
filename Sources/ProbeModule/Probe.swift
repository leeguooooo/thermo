import ExtensionFoundation
import ExtensionKit
import ModuleKit
import ModuleSDK
import SwiftUI

// A module that exists only to exercise the kernel's module manager. Never shipped in Thermo.app.

struct ProbeView: View {
    var body: some View { Text("probe \(String(getpid()))").padding().frame(maxWidth: .infinity, maxHeight: .infinity) }
}

@main struct Probe: AppExtension {
    init() {
        let runtime = ModuleRuntime.shared
        runtime.command("ping") { _, _ in ["pid": Int(getpid()), "home": NSHomeDirectory()] }
        runtime.command("burn") { input, _ in
            let until = Date().addingTimeInterval(Double(input["ms"] as? Int ?? 200) / 1000)
            var x = 0.0
            while Date() < until { for i in 0..<10_000 { x += sin(Double(i)) } }
            return ["x": x]
        }
        runtime.command("exit") { _, _ in exit(3) }
        // What the module can read by itself, without the kernel.
        runtime.command("peek") { input, _ in
            ["readable": FileManager.default.contents(atPath: input["path"] as? String ?? "") != nil]
        }
        // Whether the module can list a folder and create a file in it by itself.
        runtime.command("poke") { input, _ in
            let path = input["path"] as? String ?? ""
            let listed = (try? FileManager.default.contentsOfDirectory(atPath: path))?.count
            let file = path + "/.thermo-probe-write"
            let wrote = FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
            if wrote { try? FileManager.default.removeItem(atPath: file) }
            return ["listed": listed ?? -1, "writable": wrote]
        }
        // Passes a request on to the kernel and answers with what the kernel said.
        runtime.command("ask") { input, kernel in
            do {
                return ["answer": try await kernel.request(input["capability"] as? String ?? "", input["payload"] as? [String: Any] ?? [:])]
            } catch { return ["problem": "\(error)"] }
        }
    }

    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(moduleScene("main") { ProbeView() }, configuration: ModuleConfiguration())
    }
}
