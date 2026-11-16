import Foundation
import ModuleKit

/// A module's source folder as `thermo dev` works with it (#48):
///
///     module.json        the manifest
///     src/module.wat     the module, in WebAssembly text
///     views/*.json       page and menu bar documents the module sends (`ModuleView`)
///     strings/*.txt      other byte strings the module needs (needles to search for, templates…)
///     fixtures/*.json    inputs and fake kernel answers for `thermo dev test`
///
/// `views/` and `strings/` are not read at run time: the build turns them into data segments, so the
/// module stays one self-contained `module.wasm` the sandboxed runner can load.
public struct ModuleSource: Sendable {
    public let folder: URL
    public init(_ folder: URL) { self.folder = folder.standardizedFileURL }

    public var manifestURL: URL { folder.appendingPathComponent("module.json") }
    public var watURL: URL { folder.appendingPathComponent("src/module.wat") }
    public var viewsURL: URL { folder.appendingPathComponent("views", isDirectory: true) }
    public var stringsURL: URL { folder.appendingPathComponent("strings", isDirectory: true) }
    public var fixturesURL: URL { folder.appendingPathComponent("fixtures", isDirectory: true) }
    /// Build output; also what the app's development directory points at while `thermo dev run` is on.
    public var outputRoot: URL { folder.appendingPathComponent(".thermo-build", isDirectory: true) }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    /// The manifest, checked the way the app checks a development module before loading it.
    public func manifest() throws -> ModuleManifest {
        guard let data = try? Data(contentsOf: manifestURL) else { throw Failure("\(manifestURL.path): missing") }
        let manifest: ModuleManifest
        do { manifest = try JSONDecoder().decode(ModuleManifest.self, from: data) }
        catch { throw Failure("module.json is not a module manifest: \(error)") }
        var problems = manifest.problems()
        if BuiltinModuleManifests.all.contains(where: { $0.id == manifest.id }) || manifest.id.hasPrefix("dev.thermo.") {
            problems.append("id \(manifest.id) is reserved for Thermo")
        }
        for entry in manifest.entries where entry.kind.showsUI {
            if entry.kind != .page && entry.kind != .menuBarItem { problems.append("entry \(entry.id): only pages and menu bar items can be described") }
            if entry.scene == nil { problems.append("entry \(entry.id) has no scene") }
        }
        guard problems.isEmpty else { throw Failure("module.json: " + problems.joined(separator: "; ")) }
        return manifest
    }

    /// Named byte strings from `views/` (validated as module views) and `strings/`.
    public func strings() throws -> [(name: String, bytes: Data)] {
        var result: [(String, Data)] = []
        for (dir, prefix, isView) in [(viewsURL, "view_", true), (stringsURL, "str_", false)] {
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { isView ? $0.pathExtension == "json" : $0.pathExtension == "txt" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                let stem = file.deletingPathExtension().lastPathComponent
                guard let name = WatExpansion.identifier(prefix + stem) else {
                    throw Failure("\(file.lastPathComponent): use letters, digits, _ and - in file names")
                }
                var bytes = try Data(contentsOf: file)
                if isView {
                    // Minified, and checked now rather than when the page fails to show. A view may hold
                    // `{{n}}` holes the module fills in at run time; check it with a number in place.
                    guard let object = try? JSONSerialization.jsonObject(with: bytes) else { throw Failure("\(file.lastPathComponent) is not JSON") }
                    bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
                    let probe = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: WatExpansion.hole, with: "0")
                    do { _ = try ModuleView.read(Data(probe.utf8)) }
                    catch { throw Failure("\(file.lastPathComponent) is not a valid module view: \(error)") }
                } else if bytes.last == 0x0A {
                    bytes.removeLast()   // Editors add a final newline; a needle must not contain it.
                }
                result.append((name, bytes))
            }
        }
        return result
    }
}

/// Fills the `;; @thermo-strings` line of a module's WAT with its memory, heap and string data.
public enum WatExpansion {
    public static let marker = ";; @thermo-strings"
    /// Where a module writes a number into a view: `{{n}}`.
    public static let hole = "{{n}}"
    static let firstOffset = 1024

    public static func identifier(_ raw: String) -> String? {
        let name = raw.replacingOccurrences(of: "-", with: "_")
        guard !name.isEmpty, name.count <= 64,
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" }) else { return nil }
        return name
    }

    /// Each string becomes `(global $name i32)` (its address) and `(global $name_len i32)`. The heap
    /// (`$heap`, starting at `$heap_base`) follows the last string; memory holds the strings plus
    /// `heapPages` of heap. Modules reset `$heap` to `$heap_base` in `thermo_alloc`, which the kernel
    /// calls once at the start of every call, so nothing piles up across calls.
    public static func expand(_ wat: String, strings: [(name: String, bytes: Data)], heapPages: Int = 16) throws -> String {
        guard wat.components(separatedBy: marker).count == 2 else {
            throw ModuleSource.Failure("src/module.wat must contain the line \(marker) exactly once")
        }
        var lines: [String] = [], offset = firstOffset
        for (name, bytes) in strings {
            lines.append("  (data (i32.const \(offset)) \"\(escape(bytes))\")")
            lines.append("  (global $\(name) i32 (i32.const \(offset)))")
            lines.append("  (global $\(name)_len i32 (i32.const \(bytes.count)))")
            offset += bytes.count
        }
        let heap = (offset + 15) / 16 * 16
        let pages = (heap + 65535) / 65536 + heapPages
        lines.insert("  (memory (export \"memory\") \(pages))", at: 0)
        lines.insert("  (global $heap (mut i32) (i32.const \(heap)))", at: 1)
        lines.insert("  (global $heap_base i32 (i32.const \(heap)))", at: 2)
        return wat.replacingOccurrences(of: marker, with: lines.joined(separator: "\n").trimmingCharacters(in: .whitespaces))
    }

    static func escape(_ bytes: Data) -> String {
        bytes.map { b -> String in
            if b >= 0x20 && b < 0x7F && b != 0x22 && b != 0x5C { return String(UnicodeScalar(b)) }
            return String(format: "\\%02x", b)
        }.joined()
    }
}
