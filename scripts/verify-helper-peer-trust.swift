// Isolated non-root XPC fixture. Build/run with verify-helper-peer-trust.py.
// Imports the production requirement, exports only ping, and never constructs hardware controllers.
import Foundation
#if SERVER
import ThermoKit
#endif

@objc protocol PeerProbe {
    func ping(reply: @escaping (String) -> Void)
}
#if SERVER
final class Probe: NSObject, PeerProbe {
    func ping(reply: @escaping (String) -> Void) { reply(Bundle.main.bundleIdentifier ?? "missing-service-id") }
}
final class ProbeDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if Bundle.main.object(forInfoDictionaryKey: "ThermoEnforceClientRequirement") as? Bool == true {
            connection.setCodeSigningRequirement(HelperConstants.clientRequirement)
        }
        connection.invalidationHandler = { exit(0) }
        connection.exportedInterface = NSXPCInterface(with: PeerProbe.self)
        connection.exportedObject = Probe()
        connection.resume()
        return true
    }
}
let delegate = ProbeDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
dispatchMain()
#else
final class Outcome: @unchecked Sendable {
    let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    var value: [String: String]?
    func snapshot() -> [String: String]? { lock.lock(); defer { lock.unlock() }; return value }
    func finish(_ result: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        guard value == nil else { return }; value = result; semaphore.signal()
    }
}
guard CommandLine.arguments.count == 2 else { exit(2) }
let name = CommandLine.arguments[1], outcome = Outcome()
let connection = NSXPCConnection(serviceName: name)
connection.remoteObjectInterface = NSXPCInterface(with: PeerProbe.self)
connection.invalidationHandler = { outcome.finish(["status": "invalidated"]) }
connection.resume()
if let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
    outcome.finish(["status": "error", "detail": String(describing: error)])
}) as? PeerProbe {
    proxy.ping { value in outcome.finish(["status": "reply", "service": value]) }
}
let timedOut = outcome.semaphore.wait(timeout: .now() + 8) == .timedOut
let result = outcome.snapshot() ?? ["status": "timeout"]
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
connection.invalidate()
exit(timedOut ? 5 : (result["service"] == name ? 0 : 3))
#endif
