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

    /// Re-discover devices by this exact private image path before detaching. Never force-detach
    /// another app's mount, and preserve the workspace if ownership or cleanup is uncertain.
    static func detachOwned(_ payload: String) -> Bool {
        guard let info = try? plist(CommandRunner.run("/usr/bin/hdiutil", arguments: ["info", "-plist"], timeout: 15, captureError: false)),
              let images = info["images"] as? [[String: Any]] else { return false }
        let matches = images.filter { image in (image["image-path"] as? String).map { canonical($0) == canonical(payload) } == true }
        if matches.isEmpty { return true }
        for image in matches {
            guard let entities = image["system-entities"] as? [[String: Any]],
                  let device = entities.compactMap({ $0["dev-entry"] as? String }).first,
                  device.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil else { return false }
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
        var problem: Error?
        var uncertainAttach = false
        do {
            let outcome = CommandRunner.run("/usr/bin/hdiutil", arguments: ["attach", "-readonly", "-nobrowse", "-noautoopen", "-noautofsck",
                "-verify", "-stdinpass", "-plist", "-mountpoint", mount, payload.path], timeout: 60, captureError: false)
            uncertainAttach = outcome.timedOut || outcome.cancelled
            let attached = try plist(outcome)
            guard let entities = attached["system-entities"] as? [[String: Any]] else { throw ArchiveFailure("The disk image has no recognized mount") }
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
        guard detachOwned(payload.path), !uncertainAttach else { throw CleanupFailure() }
        if let problem { throw problem }
    }
}
