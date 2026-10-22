import Foundation

public struct CaptureRecordingDraft: Codable, Identifiable, Sendable {
    public enum Mode:String,Codable,CaseIterable,Sendable { case quick, normal }
    public enum Status: String, Codable, Sendable { case recording, ready, interrupted }
    public let id: UUID
    public let createdAt: Date
    public var status: Status
    public var mode:Mode?
    public var effectiveMode:Mode { mode ?? .quick }
    public init(id: UUID = UUID(), createdAt: Date = Date(), status: Status = .recording, mode:Mode? = nil) { self.id = id; self.createdAt = createdAt; self.status = status; self.mode=mode }
}

/// Only UUID-named, non-symlink children are read. Movie paths are derived, never taken from JSON.
public struct CaptureRecordingDraftStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString,isDirectory:true) }
    public func movie(_ id: UUID) -> URL { directory(id).appendingPathComponent("recording.mp4") }
    public func archive(_ id:UUID) -> URL { directory(id).appendingPathComponent("frames",isDirectory:true) }
    public func create(mode:CaptureRecordingDraft.Mode = .quick) throws -> CaptureRecordingDraft {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let draft = CaptureRecordingDraft(mode:mode)
        try FileManager.default.createDirectory(at:directory(draft.id),withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do { try update(draft) } catch { try? FileManager.default.removeItem(at:directory(draft.id)); throw error }
        return draft
    }
    public func update(_ draft: CaptureRecordingDraft) throws {
        let url = directory(draft.id).appendingPathComponent("draft.json")
        try JSONEncoder().encode(draft).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    public func list() throws -> [CaptureRecordingDraft] {
        guard FileManager.default.fileExists(atPath:root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isSymbolicLinkKey,.isDirectoryKey],options:[.skipsHiddenFiles]).compactMap { folder in
            let attributes = try folder.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true, let id = UUID(uuidString:folder.lastPathComponent) else { return nil }
            let metadata = folder.appendingPathComponent("draft.json")
            guard let values = try? metadata.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey]), values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 16384, let data = try? Data(contentsOf:metadata),
                  let draft = try? JSONDecoder().decode(CaptureRecordingDraft.self,from:data), draft.id == id else { return nil }
            if draft.effectiveMode == .normal {
                let source=archive(id),values=try? source.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                guard values?.isDirectory == true,values?.isSymbolicLink != true,
                      (try? CaptureFrameArchiveSource.regular(source.appendingPathComponent("header.json"))) == true,
                      (try? CaptureFrameArchiveSource.regular(source.appendingPathComponent("frames.jsonl"))) == true else { return nil }
            } else {
                let movieAttributes = try? movie(id).resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                guard movieAttributes?.isRegularFile == true, movieAttributes?.isSymbolicLink != true else { return nil }
            }
            return draft
        }.sorted { $0.createdAt > $1.createdAt }
    }
    public func discard(_ id: UUID) throws { try FileManager.default.removeItem(at:directory(id)) }
}
