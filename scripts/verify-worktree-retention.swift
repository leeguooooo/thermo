// Read-only acceptance against an owned fixture repository. No unlock, remove or GC.
@testable import CleanKit
import AgentCore
import Foundation

@main struct WorktreeRetentionProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let root = WorktreeCleanup.physical(CommandLine.arguments[1])
        let path = WorktreeCleanup.physical(CommandLine.arguments[2])
        guard FileManager.default.fileExists(atPath: root + "/.thermo-worktree-fixture"), path.hasPrefix(root + "/") else { exit(2) }
        var result: [String: Any] = ["accepted":false]
        do {
            if let registration = try WorktreeCleanup.registration(path, processes: .init(entries: [])) {
                result = ["accepted":true,"metadata":registration.metadata,"head":registration.head]
            }
        } catch { result["reason"] = String(describing: error) }
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
