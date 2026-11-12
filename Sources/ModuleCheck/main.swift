import Foundation
import ModuleKit

// Build-time check of the modules packed into an app bundle: every module must carry a manifest
// this Thermo can read, under the id it is signed with. Run by scripts/build.sh; not shipped.
//   ModuleCheck <Thermo.app> [expected module count]

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { FileHandle.standardError.write(Data("usage: ModuleCheck <app> [count]\n".utf8)); exit(2) }
let found = ModuleBundles.installed(in: URL(fileURLWithPath: arguments[1]))
var problems = found.problems
if arguments.count > 2, let expected = Int(arguments[2]), expected != found.modules.count + found.problems.count {
    problems.append("expected \(expected) modules, found \(found.modules.count + found.problems.count)")
}
for module in found.modules where module.manifest.interface != ModuleManifest.currentInterface {
    problems.append("\(module.manifest.id): written for interface \(module.manifest.interface), current is \(ModuleManifest.currentInterface)")
}
for module in found.modules { print("module \(module.manifest.id) \(module.manifest.version) interface \(module.manifest.interface) launch \(module.manifest.launch.rawValue)") }
for problem in problems { FileHandle.standardError.write(Data("module problem: \(problem)\n".utf8)) }
exit(problems.isEmpty ? 0 : 1)
