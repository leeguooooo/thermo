import Foundation
import ModuleKit

/// The data side of a declarative module page (#47): asks the module for its view, validates it, and
/// sends actions back. Drawing is the kernel's (ModuleKernelCore). Anything an action needs from the
/// Mac still goes through the module's capability broker inside `WasmHost`.
///
/// ABI on top of #46: the module exports `thermo_render` and, if it has actions, `thermo_action`. Both
/// receive a `ModuleViewRequest` as JSON (sorted keys) and set a `ModuleView` document as their output.
/// `thermo_action` may leave the output empty; the page is then rendered again.
public actor DeclarativeModule {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noRenderer
        case status(Int)
        case invalid(String)
        case host(WasmHost.Failure)
        public var description: String {
            switch self {
            case .noRenderer: return "the module does not describe any pages"
            case .status(let s): return "the module reported an error (\(s))"
            case .invalid(let reason): return "the module's page could not be shown: \(reason)"
            case .host(let failure): return failure.description
            }
        }
    }

    public static let render = "thermo_render"
    public static let action = "thermo_action"

    public nonisolated let manifest: ModuleManifest
    private let call: @Sendable (String, Data) async throws -> WasmHost.Result

    public init(host: WasmHost) {
        manifest = host.manifest
        call = { try await host.call($0, input: $1) }
    }

    /// For tests: anything that answers like a runner.
    public init(manifest: ModuleManifest, call: @escaping @Sendable (String, Data) async throws -> WasmHost.Result) {
        self.manifest = manifest; self.call = call
    }

    public func render(scene: String, language: String) async throws -> ModuleView {
        try await run(Self.render, ModuleViewRequest(scene: scene, language: language), scene: scene)
    }

    /// Runs an action and returns the page that follows it.
    public func perform(_ action: String, values: [String: ModuleView.Value] = [:], scene: String, language: String) async throws -> ModuleView {
        try ModuleView.identifier(action, "action")
        let request = ModuleViewRequest(scene: scene, language: language, action: action, values: values.isEmpty ? nil : values)
        return try await run(Self.action, request, scene: scene, emptyMeansRender: true)
    }

    private func run(_ function: String, _ request: ModuleViewRequest, scene: String, emptyMeansRender: Bool = false) async throws -> ModuleView {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let result: WasmHost.Result
        do { result = try await call(function, try encoder.encode(request)) }
        catch let failure as WasmHost.Failure {
            if case .trapped(let message) = failure, message.contains(function) { throw Failure.noRenderer }
            throw Failure.host(failure)
        }
        guard result.status == 0 else { throw Failure.status(result.status) }
        if result.output.isEmpty, emptyMeansRender {
            return try await run(Self.render, ModuleViewRequest(scene: scene, language: request.language), scene: scene)
        }
        do {
            let view = try ModuleView.read(result.output)
            // A menu bar entry asks for a menu bar item; a page entry for sections.
            let wantsItem = manifest.entries.first { $0.scene == scene }?.kind == .menuBarItem
            guard (view.menuBarItem != nil) == wantsItem else {
                throw ModuleView.Invalid(wantsItem ? "a menu bar entry needs a menuBarItem" : "a page needs sections")
            }
            return view
        } catch let invalid as ModuleView.Invalid {
            throw Failure.invalid(invalid.reason)
        }
    }
}
