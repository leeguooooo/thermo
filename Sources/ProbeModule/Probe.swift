import ExtensionFoundation
import ExtensionKit
import ModuleKit
import SwiftUI

// A module that exists only to exercise the kernel's module manager. Never shipped in Thermo.app.

final class ProbeService: NSObject, ModuleXPC {
    weak var connection: NSXPCConnection?
    func interface(reply: @escaping @Sendable (Int) -> Void) { reply(ModuleManifest.currentInterface) }
    func run(_ command: String, arguments: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        let input = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        switch command {
        case "ping":
            reply(try? JSONSerialization.data(withJSONObject: ["pid": getpid(), "home": NSHomeDirectory()]), nil)
        case "burn":
            let until = Date().addingTimeInterval(Double(input["ms"] as? Int ?? 200) / 1000)
            var x = 0.0
            while Date() < until { for i in 0..<10_000 { x += sin(Double(i)) } }
            reply(try? JSONSerialization.data(withJSONObject: ["x": x]), nil)
        case "exit":
            exit(3)
        case "peek":
            // What the module can read by itself, without the kernel.
            let path = input["path"] as? String ?? ""
            reply(try? JSONSerialization.data(withJSONObject: ["readable": FileManager.default.contents(atPath: path) != nil]), nil)
        case "ask":
            // Passes a request on to the kernel and answers with what the kernel said.
            guard let kernel = connection?.remoteObjectProxyWithErrorHandler({ reply(nil, "\($0)") }) as? KernelXPC else { reply(nil, "no kernel"); return }
            let payload = (try? JSONSerialization.data(withJSONObject: input["payload"] ?? [:])) ?? Data()
            kernel.request(input["capability"] as? String ?? "", payload: payload) { data, problem in
                var answer: [String: Any] = [:]
                if let data, let object = try? JSONSerialization.jsonObject(with: data) { answer["answer"] = object }
                if let problem { answer["problem"] = problem }
                reply(try? JSONSerialization.data(withJSONObject: answer), nil)
            }
        default:
            reply(nil, "unknown command \(command)")
        }
    }
}

func accept(_ connection: NSXPCConnection) -> Bool {
    connection.exportedInterface = ModuleXPCInterfaces.module
    let service = ProbeService(); service.connection = connection
    connection.exportedObject = service
    connection.remoteObjectInterface = ModuleXPCInterfaces.kernel
    connection.resume()
    return true
}

struct ProbeConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool { ProbeModule.accept(connection) }
}

struct ProbeView: View {
    var body: some View { Text("probe \(String(getpid()))").padding().frame(maxWidth: .infinity, maxHeight: .infinity) }
}

@main struct Probe: AppExtension {
    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(PrimitiveAppExtensionScene(id: "main") { ProbeView() } onConnection: { ProbeModule.accept($0) },
                                       configuration: ProbeConfiguration())
    }
}
