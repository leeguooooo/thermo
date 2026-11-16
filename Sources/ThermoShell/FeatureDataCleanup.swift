import AgentCore
import CleanKit
import Foundation
import ModuleKit

/// The files a switched-off built-in feature left behind, and moving them to the Trash on request.
/// Every move is one undoable batch in operation history.
enum FeatureDataCleanup {
    struct Item: Equatable, Identifiable {
        var data: ModuleFootprint.Data
        var path: String
        var bytes: Int64
        var id: String { path }
    }

    /// Declared locations that exist now, with their size. Missing ones are left out.
    static func present(_ id: String, home: String = NSHomeDirectory()) -> [Item] {
        BuiltinModuleFootprints.footprint(id).data.compactMap { data in
            let path = (home as NSString).appendingPathComponent(data.path)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { return nil }
            return .init(data: data, path: path, bytes: size(path, directory: directory.boolValue))
        }
    }

    static func size(_ path: String, directory: Bool) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        func one(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0) }
        let url = URL(fileURLWithPath: path)
        guard directory else { return one(url) }
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walk where (try? file.resourceValues(forKeys: keys))?.isRegularFile == true { total += one(file) }
        return total
    }

    struct Result: Equatable { var moved: [String]; var failed: [String: String] }

    /// Moves the given items to the Trash and records them as one undoable batch.
    /// Only paths the feature declared are accepted, so a stale item can't point anywhere else.
    static func trash(_ id: String, _ items: [Item], home: String = NSHomeDirectory(),
                      move: (String) throws -> URL? = { path in
                          var destination: NSURL?
                          try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &destination)
                          return destination as URL?
                      }) -> Result {
        let allowed = Set(BuiltinModuleFootprints.footprint(id).data.map { (home as NSString).appendingPathComponent($0.path) })
        let batch = UUID().uuidString
        var records: [OperationRecord.Item] = [], result = Result(moved: [], failed: [:]), recorded = false
        for item in items {
            guard allowed.contains(item.path) else { result.failed[item.path] = "not declared by this feature"; continue }
            do {
                guard let destination = try move(item.path) else { throw CocoaError(.fileWriteUnknown) }
                var detail: String?
                do { try TrashBatches.recordMoved(original: item.path, destination: destination.path, id: batch, home: home); recorded = true }
                catch { detail = "Moved to Trash, but undo recording failed: " + error.localizedDescription }
                records.append(.init(target: item.path, bytes: item.bytes, status: detail == nil ? "done" : "partial", detail: detail))
                result.moved.append(item.path)
            } catch {
                records.append(.init(target: item.path, bytes: item.bytes, status: "failed", detail: error.localizedDescription))
                result.failed[item.path] = error.localizedDescription
            }
        }
        if !records.isEmpty {
            OperationJournal.record(OperationRecord(feature: "modules", action: "trash", subject: id, items: records,
                                                    undo: recorded ? .init(kind: "trashBatch", ref: batch) : nil), home: home)
        }
        return result
    }
}
