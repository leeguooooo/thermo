import Foundation
import ThermoL10n

enum AgentCLILinks {
    static let names = ["thermo", "thermo-use"]

    static func usableCLI(_ cli: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: cli, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: cli)
    }

    static func ready(directory: String, cli: String) -> Bool {
        usableCLI(cli) && names.allSatisfy {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: directory + "/" + $0)) == cli
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func link(directory: String, cli: String,
                     createLink: ((String, String) throws -> Void)? = nil) throws {
        let fm = FileManager.default
        guard usableCLI(cli) else { throw Failure(message: tr("The bundled thermo command is missing or cannot run. Reinstall Thermo and try again.")) }
        let paths = names.map { directory + "/" + $0 }
        var originals: [String: String] = [:]
        // Validate both aliases before changing either of them.
        for path in paths {
            if let old = try? fm.destinationOfSymbolicLink(atPath: path) { originals[path] = old }
            else if fm.fileExists(atPath: path) {
                throw Failure(message: tr("%1$@ already exists and is not a link; remove it first", path))
            }
        }
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let create = createLink ?? { try fm.createSymbolicLink(atPath: $0, withDestinationPath: $1) }
        var changed: [String] = []
        do {
            for path in paths {
                let current = try? fm.destinationOfSymbolicLink(atPath: path)
                guard current == originals[path], current != nil || !fm.fileExists(atPath: path) else {
                    throw Failure(message: tr("%1$@ changed during setup; left it untouched.", path))
                }
                if originals[path] == cli { continue }
                if originals[path] != nil { try fm.removeItem(atPath: path) }
                changed.append(path)
                try create(path, cli)
            }
        } catch {
            var rollbackErrors: [String] = []
            for path in changed.reversed() {
                do {
                    if let current = try? fm.destinationOfSymbolicLink(atPath: path) {
                        guard current == cli else { throw Failure(message: tr("%1$@ changed during setup; left it untouched.", path)) }
                        try fm.removeItem(atPath: path)
                    } else if fm.fileExists(atPath: path) {
                        throw Failure(message: tr("%1$@ changed during setup; left it untouched.", path))
                    }
                    if let old = originals[path] { try fm.createSymbolicLink(atPath: path, withDestinationPath: old) }
                } catch { rollbackErrors.append(error.localizedDescription) }
            }
            if !rollbackErrors.isEmpty {
                throw Failure(message: ([error.localizedDescription] + rollbackErrors).joined(separator: "\n"))
            }
            throw error
        }
    }
}
