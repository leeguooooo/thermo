import Foundation
import ModuleKit

// Build-time tool for the modules packed into an app bundle. Run by scripts/build.sh; not shipped.
//   ModuleCheck <Thermo.app> [expected module count]   every module carries a manifest this Thermo reads
//   ModuleCheck --entitlements <module.json>           prints the sandbox entitlements that manifest gives
//   ModuleCheck --signed <Thermo.app>                  every module is signed with exactly those

func fail(_ lines: [String]) -> Never {
    for line in lines { FileHandle.standardError.write(Data("module problem: \(line)\n".utf8)) }
    exit(1)
}
let arguments = Array(CommandLine.arguments.dropFirst())
guard let first = arguments.first else { FileHandle.standardError.write(Data("usage: ModuleCheck <app> [count] | --entitlements <module.json> | --signed <app>\n".utf8)); exit(2) }

if first == "--entitlements", arguments.count == 2 {
    guard let data = FileManager.default.contents(atPath: arguments[1]) else { fail(["cannot read \(arguments[1])"]) }
    do { FileHandle.standardOutput.write(try ModuleEntitlements.plist(for: try ModuleManifest.load(data))) }
    catch { fail(["\(arguments[1]): \(error)"]) }
    exit(0)
}

if first == "--signed", arguments.count == 2 {
    let found = ModuleBundles.installed(in: URL(fileURLWithPath: arguments[1]))
    var problems = found.problems
    for module in found.modules {
        let tool = Process(), out = Pipe()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        tool.arguments = ["-d", "--entitlements", "-", "--xml", module.url.path]
        tool.standardOutput = out; tool.standardError = Pipe()
        do { try tool.run() } catch { problems.append("\(module.manifest.id): cannot run codesign"); continue }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        tool.waitUntilExit()
        guard tool.terminationStatus == 0, let signed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            problems.append("\(module.manifest.id): no readable entitlements in its signature"); continue
        }
        problems += ModuleEntitlements.problems(signed: signed, manifest: module.manifest)
    }
    if !problems.isEmpty { fail(problems) }
    print("module entitlements match manifests: \(found.modules.count)")
    exit(0)
}

let found = ModuleBundles.installed(in: URL(fileURLWithPath: first))
var problems = found.problems
if arguments.count > 1, let expected = Int(arguments[1]), expected != found.modules.count + found.problems.count {
    problems.append("expected \(expected) modules, found \(found.modules.count + found.problems.count)")
}
for module in found.modules where module.manifest.interface != ModuleManifest.currentInterface {
    problems.append("\(module.manifest.id): written for interface \(module.manifest.interface), current is \(ModuleManifest.currentInterface)")
}
for module in found.modules { print("module \(module.manifest.id) \(module.manifest.version) interface \(module.manifest.interface) launch \(module.manifest.launch.rawValue)") }
if !problems.isEmpty { fail(problems) }
