import Foundation
import Darwin

let parent = CommandLine.arguments[1]
guard let resolved = realpath(parent, nil) else { exit(2) }
let canonical = String(cString: resolved); free(resolved)
let original = URL(fileURLWithPath: canonical).appendingPathComponent("owned-fixture.txt")
let bytes = Data("owned volume fixture".utf8)
try bytes.write(to: original, options: .withoutOverwriting)
let native = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: original.deletingLastPathComponent(), create: true)
var destination: NSURL?
try FileManager.default.trashItem(at: original, resultingItemURL: &destination)
let target = destination! as URL
var info = stat(); guard lstat(target.path, &info) == 0 else { exit(3) }
let result: [String: Any] = ["original": original.path, "destination": target.path, "nativeQuery": native.path,
    "identity": "\(info.st_dev):\(info.st_ino)", "birthIdentity": "\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec):\(info.st_gen)", "bytes": bytes.count]
print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
