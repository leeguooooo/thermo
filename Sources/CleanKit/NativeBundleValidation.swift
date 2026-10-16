import AgentCore
import CryptoKit
import Darwin
import Foundation
import Security

struct NativeBundleFacts: Codable, Sendable, Equatable {
    var bundleID: String
    var version: String
    var build: String
    var team: String?
    var architectures: [String]
    var seal: String
    var minimumOS: String? = nil
}

enum NativeBundleValidation {
    static func fail(_ message: String) -> ArchiveFailure { ArchiveFailure(message) }

    static func facts(_ path: String) throws -> NativeBundleFacts {
        guard let metadata = AppMetadata.read(path + "/Contents/Info.plist") else { throw fail("The update is not a complete application bundle") }
        let info = metadata.info
        guard let id = info["CFBundleIdentifier"] as? String, AppOwnershipSnapshot.validDeclaredID(id),
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String, UpdateVersion.compare(build, build) != nil,
              info["CFBundlePackageType"] as? String == "APPL",
              let name = info["CFBundleExecutable"] as? String, !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw fail("The update is not a complete application bundle")
        }
        guard info["LSMinimumSystemVersion"] == nil || info["LSMinimumSystemVersion"] is String else { throw fail("The update is not a complete application bundle") }
        let binary = path + "/Contents/MacOS/" + name
        var st = stat()
        guard lstat(binary, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_mode & 0o111 != 0 else {
            throw fail("The app executable is missing or is an unsupported link")
        }
        let architectures = try machArchitectures(binary)
        let seal = try treeSeal(path)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), nil) == errSecSuccess else {
            throw fail("The application's code signature is invalid")
        }
        var signing: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
              let signed = signing as? [String: Any], signed[kSecCodeInfoIdentifier as String] as? String == id else {
            throw fail("The signed identity does not match the application bundle")
        }
        guard let finalMetadata = AppMetadata.read(path + "/Contents/Info.plist"),
              finalMetadata.identity == metadata.identity, finalMetadata.digest == metadata.digest else {
            throw fail("The application changed while its metadata was being validated")
        }
        return NativeBundleFacts(bundleID: id, version: version, build: build, team: signed[kSecCodeInfoTeamIdentifier as String] as? String,
                                 architectures: architectures.sorted(), seal: seal, minimumOS: info["LSMinimumSystemVersion"] as? String)
    }

    /// Read only Mach-O headers, without executing a downloaded binary or relying on its filename.
    static func machArchitectures(_ path: String) throws -> Set<String> {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4096) ?? Data()
        func word(_ offset: Int, little: Bool) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { throw fail("Truncated Mach-O header") }
            let b = Array(data[offset..<offset + 4])
            return little ? UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                : UInt32(b[3]) | UInt32(b[2]) << 8 | UInt32(b[1]) << 16 | UInt32(b[0]) << 24
        }
        let magic = try word(0, little: false)
        var cpus: [UInt32] = []
        if [0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca].contains(magic) {
            let little = magic == 0xbebafeca || magic == 0xbfbafeca
            let count = Int(try word(4, little: little))
            guard count > 0, count <= 64 else { throw fail("Unsupported universal Mach-O header") }
            let stride = magic == 0xcafebabf || magic == 0xbfbafeca ? 32 : 20
            for i in 0..<count { cpus.append(try word(8 + i * stride, little: little)) }
        } else if magic == 0xcffaedfe || magic == 0xfeedfacf {
            cpus.append(try word(4, little: magic == 0xcffaedfe))
        } else { throw fail("The update has no supported 64-bit Mach-O executable") }
        let result = Set(cpus.compactMap { cpu -> String? in cpu == 0x0100000c ? "arm64" : cpu == 0x01000007 ? "x86_64" : nil })
        guard !result.isEmpty else { throw fail("The update has no supported CPU architecture") }
        return result
    }

    static func compatible(_ new: NativeBundleFacts, with old: NativeBundleFacts, release: SparkleRelease, host: String? = nil) throws {
        let host = host ?? NativeAppUpdates.hostArchitecture
        guard new.bundleID == old.bundleID, new.team == old.team else { throw fail("The update changes the application's signed publisher or bundle ID") }
        guard new.build == release.build, new.version == release.version,
              UpdateVersion.compare(new.build, old.build) == .orderedDescending else { throw fail("The downloaded app does not match the reviewed newer version") }
        if host == "x86_64" && !new.architectures.contains("x86_64") {
            throw fail("The update cannot run on this Intel Mac")
        }
        if host == "arm64" && old.architectures.contains("arm64") && !new.architectures.contains("arm64") {
            throw fail("An Intel-only update would replace this app's native Apple Silicon version")
        }
    }

    static func publisherMatches(original: String, replacement: String, team: String?) throws {
        // For ad-hoc apps the authenticated archive's embedded Ed25519 key is the publisher root.
        guard team != nil else { return }
        var old: SecStaticCode?, new: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: original) as CFURL, [], &old) == errSecSuccess,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: replacement) as CFURL, [], &new) == errSecSuccess,
              let old, let new, SecCodeCopyDesignatedRequirement(old, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(new, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw fail("The update does not satisfy the original publisher's signing requirement")
        }
    }

    /// A content seal survives copying and renaming. Every symlink must resolve inside the bundle.
    static func treeSeal(_ root: String) throws -> String {
        guard URL(fileURLWithPath: root).resolvingSymlinksInPath().path == root,
              let physical = realpath(root, nil) else { throw fail("The application path is an alias") }
        // Foundation can return /var for the system alias while realpath returns
        // /private/var. Compare link containment in one physical namespace.
        let physicalRoot = String(cString: physical)
        free(physical)
        var hash = SHA256(), count = 0
        var bytes: Int64 = 0
        func add(_ text: String) { hash.update(data: Data(text.utf8)); hash.update(data: Data([0])) }
        func visit(_ path: String) throws {
            count += 1
            guard count <= 100_000 else { throw fail("The application contains too many files") }
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & 0o6000 == 0 else { throw fail("Cannot inspect the application tree") }
            let kind = st.st_mode & S_IFMT
            add(String(path.dropFirst(root.count))); add(String(st.st_mode & 0o177777))
            if kind == S_IFDIR {
                for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted() { try visit(path + "/" + name) }
            } else if kind == S_IFREG {
                guard st.st_nlink == 1 else { throw fail("Hard-linked app files are not supported") }
                bytes += st.st_size
                guard st.st_size >= 0, bytes <= 8 * 1024 * 1024 * 1024 else { throw fail("The expanded app is too large") }
                let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
                add(String(st.st_size)); hash.update(data: Data(SHA256.hash(data: data)))
                var after = stat()
                guard lstat(path, &after) == 0, st.st_dev == after.st_dev, st.st_ino == after.st_ino,
                      st.st_size == after.st_size, st.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      st.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, st.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                      st.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw fail("The application changed while it was being verified") }
            } else if kind == S_IFLNK {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
                guard !target.hasPrefix("/"), let resolved = realpath(path, nil) else { throw fail("The app contains an unsupported symbolic link") }
                defer { free(resolved) }
                guard String(cString: resolved).hasPrefix(physicalRoot + "/") else { throw fail("A symbolic link leaves the application bundle") }
                add(target)
            } else { throw fail("The app contains a special file") }
        }
        try visit(root)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
