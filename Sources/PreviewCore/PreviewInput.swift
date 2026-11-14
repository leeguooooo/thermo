import Darwin
import Foundation

/// Only a display name and selected input cross to the renderer; no authority to open user paths.
public struct PreviewInput: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case file, directory, asset, render, retire }
    public struct Entry: Codable, Sendable, Equatable {
        public let name: String
        public let directory: Bool
        public let bytes: Int64?
        public init(name: String, directory: Bool, bytes: Int64?) { self.name = name; self.directory = directory; self.bytes = bytes }
    }
    public let id: UUID
    public let kind: Kind
    public let name: String
    public let entries: [Entry]
    public let originalURL: String?
    public let resourceURL: String?
    public let language: String?
    public let sequence: UInt64?
    public init(id: UUID = UUID(), kind: Kind, name: String, entries: [Entry] = [], originalURL: String? = nil,
                resourceURL: String? = nil, language: String? = nil, sequence: UInt64? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.entries = entries
        self.originalURL = originalURL; self.resourceURL = resourceURL; self.language = language; self.sequence = sequence
    }
    public func data() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 262_144 else { throw PreviewFailure.invalidInput }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 262_144 else { throw PreviewFailure.invalidInput }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard !value.name.isEmpty, value.name.utf8.count <= 4096, value.entries.count <= 256,
              value.entries.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 4096 && ($0.bytes ?? 0) >= 0 }),
              value.kind == .directory || value.entries.isEmpty,
              (value.originalURL?.utf8.count ?? 0) <= 4096, (value.resourceURL?.utf8.count ?? 0) <= 4096,
              (value.language?.utf8.count ?? 0) <= 32,
              value.kind != .asset || value.resourceURL != nil else { throw PreviewFailure.invalidInput }
        return value
    }
}

public enum PreviewFailure: Error, LocalizedError {
    case invalidInput, readOnlyFileRequired, cancelled, copyFailed(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidInput: return "Invalid preview input."
        case .readOnlyFileRequired: return "Preview requires a read-only regular file."
        case .cancelled: return "Preview was cancelled."
        case let .copyFailed(code): return String(cString: strerror(code))
        }
    }
}

/// Lives inside the renderer's own sandbox container. APFS clones avoid a full copy for large local files.
public struct PreviewInputCache: Sendable {
    public let root: URL
    private let cloneEnabled: Bool
    public init(root: URL, cloneEnabled: Bool = true) { self.root = root; self.cloneEnabled = cloneEnabled }
    public func prepare(_ input: PreviewInput, file: FileHandle?, cancelled: @Sendable () -> Bool = { false }) throws -> URL? {
        guard input.kind == .file || input.kind == .asset else {
            guard file == nil else { throw PreviewFailure.invalidInput }
            return nil
        }
        guard let file else { throw PreviewFailure.readOnlyFileRequired }
        let flags = fcntl(file.fileDescriptor, F_GETFL)
        var info = stat()
        guard flags >= 0, flags & O_ACCMODE == O_RDONLY, fstat(file.fileDescriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw PreviewFailure.readOnlyFileRequired }
        if input.kind == .asset, info.st_size > 8 * 1024 * 1024 { throw PreviewFailure.invalidInput }
        guard !cancelled() else { throw PreviewFailure.cancelled }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let ext = (input.name as NSString).pathExtension
        let safeExtension = !ext.isEmpty && ext.utf8.count <= 32 && ext.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        let name = UUID().uuidString + (safeExtension ? "." + ext : "")
        let destination = root.appendingPathComponent(name)
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw PreviewFailure.copyFailed(errno) }
        defer { close(directory) }
        let cloned = cloneEnabled && name.withCString { fclonefileat(file.fileDescriptor, directory, $0, 0) == 0 }
        if !cloned {
            let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw PreviewFailure.copyFailed(errno) }
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try file.seek(toOffset: 0)
                var remaining = info.st_size
                while remaining > 0 {
                    if cancelled() { throw PreviewFailure.cancelled }
                    guard let chunk = try file.read(upToCount: Int(min(remaining, 1_048_576))), !chunk.isEmpty else { throw PreviewFailure.copyFailed(ESTALE) }
                    try output.write(contentsOf: chunk)
                    remaining -= Int64(chunk.count)
                }
                try output.close()
            } catch {
                try? output.close(); try? FileManager.default.removeItem(at: destination); throw error
            }
        }
        if cancelled() { try? FileManager.default.removeItem(at: destination); throw PreviewFailure.cancelled }
        return destination
    }
}
