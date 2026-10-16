import AgentCore
import Darwin
import Foundation

public struct NativePreservedWorkspace: Codable, Sendable, Identifiable {
    public var id: String
    public var target: String
    public var path: String
    public var directoryIdentity: String
    public var reason: String
    public var created: Date
    public var kind: String? = nil
}

public struct NativeWorkspacePreservation: Codable, Sendable, Identifiable {
    public var id: String { workspace.id }
    public var workspace: NativePreservedWorkspace
    public var recorded: Bool
}

extension NativeUpdateTransaction {
    struct PreservedWorkspaceFailure: LocalizedError {
        let workspace: NativePreservedWorkspace
        let recorded: Bool
        var errorDescription: String? { workspace.reason + "\n" + workspace.path }
    }

    static func preserveWorkspace(_ path: String, identity: String, target: String, reason: String, home: String,
                                   kind: String? = nil) -> PreservedWorkspaceFailure {
        let name = (path as NSString).lastPathComponent
        let id = kind == "download" && name.hasPrefix("download-") ? String(name.dropFirst(9)) : name
        let record = NativePreservedWorkspace(id: id, target: target, path: path,
                                               directoryIdentity: identity, reason: reason, created: Date(), kind: kind)
        do {
            let root = try storage(home)
            try validateWorkspaceLocation(record, root: root)
            let file = root + "/workspace-" + record.id + ".json"
            var st = stat()
            if lstat(file, &st) == 0 {
                guard st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1 else { throw failure("The recovery record is unsafe or unreadable") }
            } else if errno != ENOENT { throw failure("The recovery record is unsafe or unreadable") }
            let data = try JSONEncoder().encode(record)
            guard data.count < 1_048_576 else { throw failure("The recovery record is unsafe or unreadable") }
            try data.write(to: URL(fileURLWithPath: file), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
            return .init(workspace: record, recorded: true)
        } catch { return .init(workspace: record, recorded: false) }
    }

    static func recoveryData(_ file: String, home: String) throws -> Data {
        guard !file.contains("/"), file.hasSuffix(".json") else { throw failure("The recovery record is unsafe or unreadable") }
        let path = try storage(home, create: false) + "/" + file
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw failure("The recovery record is unsafe or unreadable") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(), before.st_nlink == 1,
              before.st_size > 0, before.st_size < 1_048_576,
              let data = try handle.read(upToCount: 1_048_576), data.count == before.st_size,
              fstat(fd, &after) == 0, AppDataReviewIdentity.text(before) == AppDataReviewIdentity.text(after),
              FileIdentity.of(path) == "\(before.st_dev):\(before.st_ino)" else { throw failure("The recovery record is unsafe or unreadable") }
        return data
    }

    private static func validateWorkspaceLocation(_ record: NativePreservedWorkspace, root: String) throws {
        guard record.kind == nil || record.kind == "prepared" || record.kind == "download" else {
            throw failure("The preserved update workspace is missing or changed")
        }
        let name = (record.kind == "download" ? "download-" : "") + record.id
        guard UUID(uuidString: record.id) != nil, record.path == root + "/" + name,
              !record.directoryIdentity.isEmpty, record.directoryIdentity.utf8.count <= 128 else {
            throw failure("The preserved update workspace is missing or changed")
        }
    }

    static func loadPreservedWorkspace(_ id: String, home: String) throws -> NativePreservedWorkspace {
        guard UUID(uuidString: id) != nil else { throw failure("The recovery record is unsafe or unreadable") }
        let record = try JSONDecoder().decode(NativePreservedWorkspace.self, from: recoveryData("workspace-" + id + ".json", home: home))
        guard record.id == id else { throw failure("The recovery record is unsafe or unreadable") }
        try validateWorkspaceLocation(record, root: storage(home, create: false))
        return record
    }

    /// Read-only inspection only. This never unmounts, removes or restores files.
    public static func recoveryFolderURL(home: String = NSHomeDirectory()) throws -> URL {
        URL(fileURLWithPath: try storage(home, create: false))
    }

    public static func preservedWorkspaceURL(_ record: NativePreservedWorkspace, home: String = NSHomeDirectory()) throws -> URL {
        try validateWorkspaceLocation(record, root: storage(home, create: false))
        var st = stat()
        guard lstat(record.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o077 == 0,
              FileIdentity.of(record.path) == record.directoryIdentity,
              URL(fileURLWithPath: record.path).resolvingSymlinksInPath().path == record.path else {
            throw failure("The preserved update workspace is missing or changed")
        }
        return URL(fileURLWithPath: record.path)
    }

    static func preparationFailure(_ source: NativeUpdateSource, message: String, home: String,
                                   workspace: PreservedWorkspaceFailure? = nil) -> NativeInstallResult {
        let result = NativeInstallResult(outcome: "failed", message: message, preservedWorkspace: workspace?.workspace,
                                         workspaceRecordSaved: workspace?.recorded)
        var items = [OperationRecord.Item(target: source.app.path, status: "failed", detail: message)]
        if let workspace { items.append(.init(target: workspace.workspace.path, status: "partial", detail: workspace.workspace.reason)) }
        OperationJournal.record(OperationRecord(feature: "apps", action: "nativeUpdatePreparation", subject: source.app.name,
            outcome: workspace == nil ? "failed" : "partial", items: items,
            undo: workspace?.recorded == true ? .init(kind: "nativePreparation", ref: workspace!.workspace.id) : nil), home: home)
        return result
    }

    static func preparationFailure(_ source: NativeUpdateSource, error: Error, home: String) -> NativeInstallResult {
        if let workspace = error as? PreservedWorkspaceFailure {
            return preparationFailure(source, message: "The app was not replaced; preserved update files need inspection", home: home, workspace: workspace)
        }
        if error is CancellationError { return preparationFailure(source, message: "Update preparation stopped; the installed app was not replaced", home: home) }
        return preparationFailure(source, message: error.localizedDescription, home: home)
    }

    static func preservingCleanupFailure(_ original: NativeInstallResult, path: String, identity: String,
                                         source: NativeUpdateSource, reason: String, home: String, kind: String? = nil) -> NativeInstallResult {
        var result = original
        let preserved = preserveWorkspace(path, identity: identity, target: source.app.path, reason: reason, home: home, kind: kind)
        result.cleanupIssue = result.cleanupIssue ?? reason
        if result.preservedWorkspace == nil {
            result.preservedWorkspace = preserved.workspace; result.workspaceRecordSaved = preserved.recorded
        } else {
            result.additionalPreservedWorkspaces = (result.additionalPreservedWorkspaces ?? []) + [.init(workspace: preserved.workspace, recorded: preserved.recorded)]
        }
        OperationJournal.record(OperationRecord(feature: "apps", action: "nativeUpdateCleanup", subject: source.app.name,
            outcome: "partial", items: [.init(target: path, status: "partial", detail: reason)],
            undo: preserved.recorded ? .init(kind: "nativePreparation", ref: preserved.workspace.id) : nil), home: home)
        return result
    }
}
