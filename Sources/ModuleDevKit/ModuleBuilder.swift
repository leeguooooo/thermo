import Foundation
import ModuleKit

/// `thermo dev build`: WAT + views → `.thermo-build/<id>/{module.json,module.wasm}`, the layout the
/// app's development directory expects.
public struct ModuleBuilder: Sendable {
    /// Turns WebAssembly text into a binary module.
    public let compile: @Sendable (_ wat: String) throws -> Data

    public init(compile: @escaping @Sendable (String) throws -> Data) { self.compile = compile }

    /// Uses `thermo-wat2wasm` (shipped in Thermo.app's Helpers, needs macOS 15).
    public static func tool(_ executable: URL) -> ModuleBuilder {
        ModuleBuilder { wat in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-dev-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let input = dir.appendingPathComponent("module.wat"), output = dir.appendingPathComponent("module.wasm")
            try Data(wat.utf8).write(to: input)
            let process = Process(), errors = Pipe()
            process.executableURL = executable
            process.arguments = [input.path, output.path]
            process.standardError = errors; process.standardOutput = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0, let wasm = try? Data(contentsOf: output) else {
                throw ModuleSource.Failure("src/module.wat does not compile: " + message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return wasm
        }
    }

    public struct Output: Sendable, Equatable {
        public var manifest: ModuleManifest
        public var folder: URL
        public var wasmBytes: Int
    }

    public func build(_ source: ModuleSource) throws -> Output {
        let manifest = try source.manifest()
        guard let wat = try? String(contentsOf: source.watURL, encoding: .utf8) else { throw ModuleSource.Failure("src/module.wat: missing") }
        let wasm = try compile(try WatExpansion.expand(wat, strings: try source.strings()))
        guard wasm.starts(with: [0x00, 0x61, 0x73, 0x6D]) else { throw ModuleSource.Failure("the compiler did not produce WebAssembly") }
        // Replace the whole output so a renamed module never leaves its old id loaded.
        let out = source.outputRoot, folder = out.appendingPathComponent(manifest.id, isDirectory: true)
        let staging = out.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source.manifestURL, to: staging.appendingPathComponent("module.json"))
        try wasm.write(to: staging.appendingPathComponent("module.wasm"))
        for old in (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [] where old != staging {
            try? FileManager.default.removeItem(at: old)
        }
        try FileManager.default.moveItem(at: staging, to: folder)
        return Output(manifest: manifest, folder: folder, wasmBytes: wasm.count)
    }
}

/// Where the tools Thermo ships live.
public enum DevTools {
    public static let appHelpers = URL(fileURLWithPath: "/Applications/Thermo.app/Contents/Helpers")

    /// `name` from the environment variable, next to this executable, or in /Applications/Thermo.app.
    public static func locate(_ name: String, environment: String, env: [String: String] = ProcessInfo.processInfo.environment,
                              executable: URL? = Bundle.main.executableURL) -> URL? {
        var candidates: [URL] = []
        if let path = env[environment], !path.isEmpty { candidates.append(URL(fileURLWithPath: path)) }
        if let executable {
            // Contents/Helpers/thermo finds its neighbours; Contents/MacOS/Thermo finds them in ../Helpers.
            let dir = executable.resolvingSymlinksInPath().deletingLastPathComponent()
            candidates.append(dir.appendingPathComponent(name))
            candidates.append(dir.deletingLastPathComponent().appendingPathComponent("Helpers").appendingPathComponent(name))
        }
        candidates.append(appHelpers.appendingPathComponent(name))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    public static func wat2wasm() -> URL? { locate("thermo-wat2wasm", environment: "THERMO_WAT2WASM") }
    /// The app binary, which runs fixtures with its own renderer (`--module-test`).
    public static func appExecutable(env: [String: String] = ProcessInfo.processInfo.environment,
                                     executable: URL? = Bundle.main.executableURL) -> URL? {
        var candidates: [URL] = []
        if let path = env["THERMO_APP_EXECUTABLE"], !path.isEmpty { candidates.append(URL(fileURLWithPath: path)) }
        if let executable {
            candidates.append(executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("MacOS/Thermo"))
        }
        candidates.append(appHelpers.deletingLastPathComponent().appendingPathComponent("MacOS/Thermo"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
