import Foundation

// Validation only: no directory creation, deletion, or permission changes.
func reject(_ reason: String) -> Never {
    FileHandle.standardError.write(Data("unsafe build output: \(reason)\n".utf8))
    exit(2)
}
guard CommandLine.arguments.count == 2, !CommandLine.arguments[1].isEmpty else { reject("specify a dedicated directory") }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).resolvingSymlinksInPath().path
func within(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
if output == "/" || within(repository, output) { reject("repository or one of its ancestors") }
let reserved = [NSHomeDirectory(), "/tmp", "/private/tmp", URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path]
if reserved.contains(output) { reject("use a child directory, not a shared root") }
for root in ["/Applications", "/System", "/Library", "/usr", "/bin", "/sbin"] {
    if within(output, root) { reject("system or installed-app directory") }
}
for folder in ["Sources", "Tests", "Resources", "docs", "scripts", ".git", ".build", "releases"] {
    if within(output, repository + "/" + folder) { reject("source, build-cache or release-history directory") }
}
var isDirectory: ObjCBool = false
if FileManager.default.fileExists(atPath: output, isDirectory: &isDirectory), !isDirectory.boolValue {
    reject("output is a file")
}
