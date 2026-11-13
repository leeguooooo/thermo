import ExtensionFoundation
import ExtensionKit
import Foundation
import ModuleKit
import SwiftUI

/// Why the kernel did not do what the module asked.
public struct KernelRefusal: Error, Equatable, CustomStringConvertible {
    /// `denied`, `declined`, `failed`, or `unreachable` when the kernel could not be asked at all.
    public var outcome: String
    public var message: String
    public var description: String { "\(outcome): \(message)" }
    public var declined: Bool { outcome == "declined" }
}

/// The module's only way to change anything on the Mac: ask the kernel. The kernel checks the
/// request against the module's manifest, asks the person where it must, and keeps the record.
public struct Kernel: Sendable {
    let connection: @Sendable () -> NSXPCConnection?

    /// One request. `capability` is a kind (`files.delete`) or a kind with one target
    /// (`files.read:~/Library/Caches`); more targets go in `payload["targets"]`.
    @discardableResult
    public func request(_ capability: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: payload)
        guard let connection = connection() else { throw KernelRefusal(outcome: "unreachable", message: "no connection to Thermo") }
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<[String: Any], Error>) in
            let once = Once()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.run { k.resume(throwing: KernelRefusal(outcome: "unreachable", message: "\(error.localizedDescription)")) }
            } as? KernelXPC
            guard let proxy else { once.run { k.resume(throwing: KernelRefusal(outcome: "unreachable", message: "no kernel")) }; return }
            proxy.request(capability, payload: body) { data, problem in
                once.run {
                    if let data {
                        k.resume(returning: ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
                    } else {
                        // "<outcome>: <message>", as the kernel's broker words it.
                        let text = problem ?? "failed: no answer"
                        let parts = text.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                        k.resume(throwing: KernelRefusal(outcome: parts.first ?? "failed", message: parts.count > 1 ? parts[1] : text))
                    }
                }
            }
        }
    }

    /// Moves `paths` to the Trash after the person confirms. Answers one result per path.
    public func trash(_ paths: [String]) async throws -> [[String: Any]] {
        try await request("files.delete", ["op": "trash", "targets": paths])["results"] as? [[String: Any]] ?? []
    }

    /// Reads a file the module cannot read by itself (a place behind the system's privacy protection).
    public func read(_ path: String) async throws -> Data {
        let answer = try await request("files.read", ["op": "read", "targets": [path]])
        return (answer["base64"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
    }
}

/// What every module process has one of: its commands and its connection to the kernel.
public final class ModuleRuntime: @unchecked Sendable {
    public static let shared = ModuleRuntime()
    public typealias Command = @Sendable (_ arguments: [String: Any], _ kernel: Kernel) async throws -> Any

    private let lock = NSLock()
    private var commands: [String: Command] = [:]
    private var kernelConnection: NSXPCConnection?

    public var kernel: Kernel { Kernel(connection: { [weak self] in self?.current() }) }

    private func current() -> NSXPCConnection? { lock.lock(); defer { lock.unlock() }; return kernelConnection }

    /// Registers the code behind one of the manifest's commands. The answer must be JSON-encodable.
    public func command(_ id: String, _ run: @escaping Command) {
        lock.lock(); commands[id] = run; lock.unlock()
    }

    func run(_ id: String, arguments: Data) async -> (Data?, String?) {
        lock.lock(); let command = commands[id]; lock.unlock()
        guard let command else { return (nil, "unknown command \(id)") }
        let input = ((try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any]) ?? [:]
        do {
            let answer = try await command(input, kernel)
            let object: Any = JSONSerialization.isValidJSONObject(answer) ? answer : ["value": answer]
            guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else {
                return (nil, "command \(id) answered with something that is not JSON")
            }
            return (data, nil)
        } catch { return (nil, "\(error)") }
    }

    /// Takes the kernel's connection: exports this module's commands on it and keeps it for requests.
    public func accept(_ connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = ModuleXPCInterfaces.module
        connection.exportedObject = Service(runtime: self)
        connection.remoteObjectInterface = ModuleXPCInterfaces.kernel
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self else { return }
            self.lock.lock(); if self.kernelConnection === connection { self.kernelConnection = nil }; self.lock.unlock()
        }
        lock.lock(); kernelConnection = connection; lock.unlock()
        connection.resume()
        return true
    }

    private final class Service: NSObject, ModuleXPC {
        let runtime: ModuleRuntime
        init(runtime: ModuleRuntime) { self.runtime = runtime }
        func interface(reply: @escaping @Sendable (Int) -> Void) { reply(ModuleManifest.currentInterface) }
        func run(_ command: String, arguments: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
            Task { let (data, problem) = await runtime.run(command, arguments: arguments); reply(data, problem) }
        }
    }
}

/// The process-level configuration every module returns from its `AppExtension`.
public struct ModuleConfiguration: AppExtensionConfiguration {
    public init() {}
    public func accept(connection: NSXPCConnection) -> Bool { ModuleRuntime.shared.accept(connection) }
}

/// One scene of the module, named as in the manifest's entries.
@MainActor public func moduleScene<Content: View>(_ id: String, @ViewBuilder content: @escaping () -> Content) -> some AppExtensionScene {
    PrimitiveAppExtensionScene(id: id) { content() } onConnection: { connection in
        // The kernel talks over the process connection; a scene connection carries nothing yet.
        connection.resume()
        return true
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { body() }
    }
}
