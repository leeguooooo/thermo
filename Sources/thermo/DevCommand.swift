import Foundation
import ModuleDevKit

/// `thermo dev new|build|run|test`: write a third-party module and watch it in Thermo (#48).
struct DevCommand {
    let app: App

    func run(_ rest: [String]) throws {
        let verb = rest.first ?? ""
        let operands = Array(rest.dropFirst())
        func folder() throws -> ModuleSource {
            guard operands.count <= 1 else { throw CLIError("dev \(verb) takes at most one folder") }
            return ModuleSource(URL(fileURLWithPath: operands.first ?? FileManager.default.currentDirectoryPath))
        }
        switch verb {
        case "new":
            guard operands.count == 1, let id = operands.first else { throw CLIError("usage: thermo dev new ID [--dir DIR] [--name NAME]") }
            let parent = URL(fileURLWithPath: app.args.options["dir"] ?? FileManager.default.currentDirectoryPath)
            let made: URL
            do { made = try ModuleTemplate.create(id: id, in: parent, name: app.args.options["name"]) }
            catch { throw CLIError("\(error)") }
            print("created \(made.path)")
            print("next: cd \(made.lastPathComponent) && thermo dev run")
        case "build":
            let output = try build(try folder())
            print("built \(output.manifest.id) → \(output.folder.path) (module.wasm \(output.wasmBytes) bytes)")
        case "run":
            try watch(try folder())
        case "test":
            guard let thermoApp = DevTools.appExecutable() else {
                throw CLIError("Thermo.app not found: install Thermo 1.5.58 or later, or set THERMO_APP_EXECUTABLE")
            }
            let process = Process()
            process.executableURL = thermoApp
            process.arguments = ["--module-test", try folder().folder.path] + (app.args.has("update") ? ["--update"] : [])
            try process.run(); process.waitUntilExit()
            if process.terminationStatus != 0 { throw CLIError("", exitCode: process.terminationStatus) }
        default:
            throw CLIError("usage: thermo dev new ID | build [FOLDER] | run [FOLDER] | test [FOLDER] [--update]")
        }
    }

    func builder() throws -> ModuleBuilder {
        guard let tool = DevTools.wat2wasm() else {
            throw CLIError("thermo-wat2wasm not found: install Thermo 1.5.58 or later (it ships in Thermo.app/Contents/Helpers), or set THERMO_WAT2WASM")
        }
        return .tool(tool)
    }

    func build(_ source: ModuleSource) throws -> ModuleBuilder.Output {
        do { return try builder().build(source) } catch let error as CLIError { throw error } catch { throw CLIError("\(error)") }
    }

    /// Builds, points the running Thermo at the build, then rebuilds and reloads on every save.
    func watch(_ source: ModuleSource) throws {
        let session = DevSession(source: source, builder: try builder())
        let watcher = FolderWatcher(source)
        func report(_ result: Result<ModuleBuilder.Output, ModuleSource.Failure>) {
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            switch result {
            case .success(let output): print("[\(time)] reloaded \(output.manifest.id) (module.wasm \(output.wasmBytes) bytes)")
            case .failure(let failure): print("[\(time)] build failed, Thermo keeps the last good build: \(failure)")
            }
            fflush(stdout)
        }
        report(session.rebuild())
        print("watching \(source.folder.path) — open the module's page in Thermo; Ctrl-C stops. Thermo keeps the module until you switch it off.")
        fflush(stdout)
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            if watcher.changed() {
                Thread.sleep(forTimeInterval: 0.15)   // Let an editor finish writing.
                _ = watcher.changed()
                report(session.rebuild())
            }
        }
    }
}
