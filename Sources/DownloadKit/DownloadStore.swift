import Foundation

/// What survives an app restart. Headers, cookies and URL queries are deliberately absent:
/// signed links carry their token in the query, so callers pass the link again to
/// `DownloadEngine.restore` or supply a refresher.
public struct DownloadState: Codable, Sendable, Equatable {
    public var version = 2
    public var id: UUID
    public var url: URL
    public var destination: URL
    public var size: Int64?
    public var acceptsRanges: Bool
    public var validator: String?
    public var segments: [Segment]
    /// True when `url` lost a query or fragment and cannot be fetched as it stands.
    public var linkIsRedacted: Bool?

    public init(id: UUID, url: URL, destination: URL, size: Int64?, acceptsRanges: Bool, validator: String?, segments: [Segment]) {
        self.id = id
        let safe = Self.redact(url)
        self.url = safe.url
        self.linkIsRedacted = safe.changed ? true : nil
        self.destination = destination
        self.size = size
        self.acceptsRanges = acceptsRanges
        self.validator = validator
        self.segments = segments
    }

    static func redact(_ url: URL) -> (url: URL, changed: Bool) {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return (url, false) }
        let changed = parts.query != nil || parts.fragment != nil || parts.user != nil || parts.password != nil
        guard changed else { return (url, false) }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return (parts.url ?? url, true)
    }

    /// Also clears a version 1 file written before queries were removed.
    func redacted() -> DownloadState {
        var copy = self
        let safe = Self.redact(url)
        copy.url = safe.url
        if safe.changed { copy.linkIsRedacted = true }
        return copy
    }

    func validate() throws {
        for segment in segments {
            let ordered = segment.end.map { $0 >= segment.start } ?? true
            let inside = size.map { size in (segment.end ?? 0) <= size } ?? true
            guard segment.start >= 0, segment.written >= 0, ordered, inside else {
                throw DownloadError.stateCorrupt("segment \(segment.id) out of bounds")
            }
        }
        guard Set(segments.map(\.id)).count == segments.count else {
            throw DownloadError.stateCorrupt("duplicate segment id")
        }
    }
}

/// Owns `<root>/<task id>/{state.json,<segment id>.part}`: directories 0700, files 0600.
public struct DownloadStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func defaultRoot() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("Thermo/Downloads", isDirectory: true)
    }

    func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func stateURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("state.json")
    }

    func partURL(id: UUID, segment: Int) -> URL {
        directory(for: id).appendingPathComponent("\(segment).part")
    }

    func prepareDirectory(for id: UUID) throws {
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        for directory in [root, directory(for: id)] {
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
                try manager.setAttributes(attributes, ofItemAtPath: directory.path)
            } catch {
                throw DownloadError.io(error.localizedDescription)
            }
        }
    }

    /// Write to a 0600 temp file, flush, then rename over the old state.
    public func save(_ state: DownloadState) throws {
        try prepareDirectory(for: state.id)
        let target = stateURL(for: state.id)
        let temp = target.deletingLastPathComponent().appendingPathComponent(".state.\(UUID().uuidString).tmp")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state.redacted())
            guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw DownloadError.io("cannot create \(temp.lastPathComponent)")
            }
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard rename(temp.path, target.path) == 0 else {
                throw DownloadError.io(String(cString: strerror(errno)))
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error as? DownloadError ?? DownloadError.io(error.localizedDescription)
        }
    }

    public func load(id: UUID) throws -> DownloadState {
        let data: Data
        do {
            data = try Data(contentsOf: stateURL(for: id))
        } catch {
            throw DownloadError.stateNotFound(id)
        }
        do {
            let state = try JSONDecoder().decode(DownloadState.self, from: data)
            guard state.id == id else { throw DownloadError.stateCorrupt("id mismatch") }
            try state.validate()
            return state.redacted()
        } catch let error as DownloadError {
            throw error
        } catch {
            throw DownloadError.stateCorrupt(error.localizedDescription)
        }
    }

    /// Every readable saved task. Unreadable entries are left on disk and skipped.
    public func list() -> [DownloadState] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap(UUID.init(uuidString:)).compactMap { try? load(id: $0) }
    }

    /// What is really on disk: part lengths lead the state file, which is only saved now and then.
    public func receivedBytes(_ state: DownloadState) -> Int64 {
        let bytes = state.segments.reduce(Int64(0)) { sum, segment in
            let path = partURL(id: state.id, segment: segment.id).path
            let length = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
            return sum + max(segment.written, length)
        }
        return state.size.map { min($0, bytes) } ?? bytes
    }

    public func remove(id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }
}
