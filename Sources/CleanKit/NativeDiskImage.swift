import AgentCore
import Darwin
import Foundation

enum NativeDiskImage {
    struct CleanupFailure: LocalizedError {
        var errorDescription: String? { "The update image mount or cleanup could not be confirmed; its workspace was preserved for manual inspection" }
    }
    static func isUDIF(_ data: Data) -> Bool {
        data.count >= 512 && data[(data.count - 512)..<(data.count - 508)].elementsEqual([0x6b, 0x6f, 0x6c, 0x79])
    }
    static func plist(_ result: CommandRunner.Result) throws -> [String: Any] {
        guard result.status == 0, !result.timedOut, !result.cancelled, !result.truncated,
              let value = (try? PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil)) as? [String: Any] else {
            throw ArchiveFailure("The disk image could not be safely inspected or mounted")
        }
        return value
    }
    static func validateInfo(_ info: [String: Any]) throws -> Int64 {
        guard let properties = info["Properties"] as? [String: Any],
              properties["Encrypted"] as? Bool == false,
              properties["Software License Agreement"] as? Bool == false,
              properties["Checksummed"] as? Bool == true,
              let format = info["Format"] as? String, ["UDRO", "UDZO", "UDBZ", "ULFO", "ULMO"].contains(format),
              let sizes = info["Size Information"] as? [String: Any], let bytes = sizes["Total Bytes"] as? NSNumber,
              bytes.int64Value > 0, bytes.int64Value <= 8 * 1024 * 1024 * 1024 else {
            throw ArchiveFailure("Encrypted, licensed, oversized or unsupported disk images require the original updater")
        }
        return bytes.int64Value
    }
    static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    static func deviceEntries(_ info: [String: Any]) throws -> Set<String> {
        guard let images = info["images"] as? [[String: Any]] else { throw CleanupFailure() }
        var devices = Set<String>()
        for image in images {
            guard let entities = image["system-entities"] as? [[String: Any]] else { throw CleanupFailure() }
            devices.formUnion(entities.compactMap { $0["dev-entry"] as? String })
        }
        return devices
    }

    static func rootDevice(_ entities: [[String: Any]]) -> String? {
        let roots = entities.filter { ($0["dev-entry"] as? String)?.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil }
        let physical = roots.filter { ($0["content-hint"] as? String)?.hasSuffix("_partition_scheme") == true }
        if physical.count == 1 { return physical[0]["dev-entry"] as? String }
        if roots.count == 1 { return roots[0]["dev-entry"] as? String }
        return nil
    }

    static func imageInfo() throws -> [String: Any] {
        try plist(CommandRunner.run("/usr/bin/hdiutil", arguments: ["info", "-plist"], timeout: 15, captureError: false))
    }

    /// Bind cleanup to a newly attached device and the private mount, not just
    /// an image-path string which can differ when an attachment is reused.
    static func finishAttachment(payload: String, mount: String, mountIdentity: String, previousDevices: Set<String>,
                                 attachedDevices: Set<String>, query: () throws -> [String: Any] = imageInfo,
                                 detach: (String) -> Bool = { device in
                                     let result = CommandRunner.run("/usr/bin/hdiutil", arguments: ["detach", device], timeout: 30, captureError: false)
                                     return result.status == 0 && !result.timedOut && !result.cancelled
                                 }, identity: (String) -> String? = FileIdentity.of) -> Bool {
        func matches(_ image: [String: Any]) -> Bool {
            if (image["image-path"] as? String).map({ canonical($0) == canonical(payload) }) == true { return true }
            return (image["system-entities"] as? [[String: Any]])?.contains {
                ($0["mount-point"] as? String).map { canonical($0) == canonical(mount) } == true
            } == true
        }
        func hasReturnedDevice(_ image: [String: Any]) -> Bool {
            (image["system-entities"] as? [[String: Any]])?.contains {
                ($0["dev-entry"] as? String).map(attachedDevices.contains) == true
            } == true
        }
        guard let before = try? query(), let images = before["images"] as? [[String: Any]] else { return false }
        // A returned device at an unrecognized path/point is still unresolved;
        // do not detach it by device name alone or claim that cleanup finished.
        guard !images.contains(where: { !matches($0) && hasReturnedDevice($0) }) else { return false }
        let candidates = images.filter(matches)
        for image in candidates {
            guard let entities = image["system-entities"] as? [[String: Any]], let device = rootDevice(entities),
                  !previousDevices.contains(device) else { return false }
            let exactPayload = (image["image-path"] as? String).map { canonical($0) == canonical(payload) } == true
            guard exactPayload || attachedDevices.contains(device), detach(device) else { return false }
        }
        guard let after = try? query(), let remaining = after["images"] as? [[String: Any]],
              !remaining.contains(where: { matches($0) || hasReturnedDevice($0) }), identity(mount) == mountIdentity else { return false }
        return true
    }

    /// Re-discover devices by this exact private image path before detaching. Never force-detach
    /// another app's mount, and preserve the workspace if ownership or cleanup is uncertain.
    static func detachOwned(_ payload: String) -> Bool {
        guard let info = try? plist(CommandRunner.run("/usr/bin/hdiutil", arguments: ["info", "-plist"], timeout: 15, captureError: false)),
              let images = info["images"] as? [[String: Any]] else { return false }
        let matches = images.filter { image in (image["image-path"] as? String).map { canonical($0) == canonical(payload) } == true }
        if matches.isEmpty { return true }
        for image in matches {
            guard let entities = image["system-entities"] as? [[String: Any]],
                  let device = rootDevice(entities) else { return false }
            let detached = CommandRunner.run("/usr/bin/hdiutil", arguments: ["detach", device], timeout: 30, captureError: false)
            if detached.status != 0 || detached.timedOut { return false }
        }
        guard let after = try? plist(CommandRunner.run("/usr/bin/hdiutil", arguments: ["info", "-plist"], timeout: 15, captureError: false)),
              let remaining = after["images"] as? [[String: Any]] else { return false }
        return !remaining.contains { ($0["image-path"] as? String).map { canonical($0) == canonical(payload) } == true }
    }

    static func copyApplication(from payload: URL, workspace: String, to unpacked: String) throws {
        let info = try plist(CommandRunner.run("/usr/bin/hdiutil", arguments: ["imageinfo", "-plist", "-stdinpass", payload.path],
                                               timeout: 30, captureError: false))
        let expanded = try validateInfo(info)
        let free = (try FileManager.default.attributesOfFileSystem(forPath: workspace)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free > expanded * 2 + 16 * 1024 * 1024 else { throw ArchiveFailure("There is not enough space to prepare and preserve this update") }
        let mount = workspace + "/mounted"
        try NativeUpdateTransaction.privateDirectory(mount)
        guard let mountIdentity = FileIdentity.of(mount) else { throw CleanupFailure() }
        let before = try imageInfo()
        let previousDevices = try deviceEntries(before)
        guard let images = before["images"] as? [[String: Any]], !images.contains(where: { image in
            (image["image-path"] as? String).map { canonical($0) == canonical(payload.path) } == true ||
            (image["system-entities"] as? [[String: Any]])?.contains {
                ($0["mount-point"] as? String).map { canonical($0) == canonical(mount) } == true
            } == true
        }) else { throw CleanupFailure() }
        var problem: Error?
        var uncertainAttach = false
        var attachedDevices = Set<String>()
        do {
            let outcome = CommandRunner.run("/usr/bin/hdiutil", arguments: ["attach", "-readonly", "-nobrowse", "-noautoopen", "-noautofsck",
                "-verify", "-stdinpass", "-plist", "-mountpoint", mount, payload.path], timeout: 60, captureError: false)
            uncertainAttach = outcome.timedOut || outcome.cancelled
            let attached = try plist(outcome)
            guard let entities = attached["system-entities"] as? [[String: Any]] else { throw ArchiveFailure("The disk image has no recognized mount") }
            attachedDevices = Set(entities.compactMap { $0["dev-entry"] as? String })
            let mounted = entities.compactMap { $0["mount-point"] as? String }
            guard mounted.count == 1, canonical(mounted[0]) == mount else { throw ArchiveFailure("The disk image mounted outside its private mount point") }
            var filesystem = statfs()
            guard statfs(mount, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_RDONLY) != 0 else {
                throw ArchiveFailure("The update disk image was not mounted read-only")
            }
            try Task.checkCancellation()
            var apps: [String] = []
            func find(_ directory: String, depth: Int) throws {
                for name in try FileManager.default.contentsOfDirectory(atPath: directory) where !name.hasPrefix(".") {
                    let path = directory + "/" + name
                    var st = stat()
                    guard lstat(path, &st) == 0 else { throw ArchiveFailure("Cannot inspect the disk image contents") }
                    if st.st_mode & S_IFMT != S_IFDIR { continue }
                    if name.hasSuffix(".app") { apps.append(path) }
                    else if depth < 1 { try find(path, depth: depth + 1) }
                }
            }
            try find(mount, depth: 0)
            guard apps.count == 1, let app = apps.first else { throw ArchiveFailure("The archive must contain exactly one application") }
            let before = try NativeBundleValidation.facts(app)
            let copy = unpacked + "/" + (app as NSString).lastPathComponent
            try FileManager.default.copyItem(atPath: app, toPath: copy)
            guard try NativeBundleValidation.facts(copy).seal == before.seal else { throw ArchiveFailure("The copied app differs from the read-only disk image") }
        } catch { problem = error }
        guard finishAttachment(payload: payload.path, mount: mount, mountIdentity: mountIdentity,
                               previousDevices: previousDevices, attachedDevices: attachedDevices), !uncertainAttach else { throw CleanupFailure() }
        if let problem { throw problem }
    }
}
