import CryptoKit
import AgentCore
import Darwin
import Foundation

/// Metadata at the selected path. This does not seal the recursive contents of a directory.
enum AppDataReviewIdentity {
    static func text(_ st: stat) -> String {
        "\(st.st_dev):\(st.st_ino):\(st.st_mode):\(st.st_size):\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec):\(st.st_ctimespec.tv_sec):\(st.st_ctimespec.tv_nsec):\(st.st_birthtimespec.tv_sec):\(st.st_birthtimespec.tv_nsec)"
    }
    static func of(_ path: String) -> String? {
        var st = stat()
        return lstat(path, &st) == 0 ? text(st) : nil
    }
}

/// Declared owners in the application directories, captured without measuring bundles or casks.
public struct AppOwnershipSnapshot: Codable, Sendable, Equatable {
    public struct Claim: Codable, Sendable, Equatable {
        public var path: String
        public var name: String
        public var bundleID: String?
        public var fingerprint: String
    }
    public var roots: [String]
    public var extraPaths: [String]
    var claims: [Claim] = []
    var nestedClaims: [Claim] = []
    public var issues: [String]
    public var fingerprint: String
    public var complete: Bool { issues.isEmpty }

    private enum CodingKeys: String, CodingKey { case roots, extraPaths, issues, fingerprint }

    public static func == (lhs: AppOwnershipSnapshot, rhs: AppOwnershipSnapshot) -> Bool {
        lhs.roots == rhs.roots && lhs.extraPaths == rhs.extraPaths && lhs.issues == rhs.issues && lhs.fingerprint == rhs.fingerprint
    }

    var apps: [InstalledApp] { claims.map { InstalledApp(path: $0.path, name: $0.name, bundleID: $0.bundleID) } }
    var declaredBundleIDs: Set<String> { Set((claims + nestedClaims).compactMap { $0.bundleID?.lowercased() }) }

    func dataOwners(excludingEmbeddedIn path: String) -> [InstalledApp] {
        apps + nestedClaims.filter { !$0.path.hasPrefix(path + "/") && $0.bundleID != nil }
            .map { InstalledApp(path: $0.path, name: $0.name, bundleID: $0.bundleID) }
    }

    static func supplementalPaths(_ processes: ProcessTable, directories: [String]) -> [String] {
        var paths = Set<String>()
        for process in processes.entries {
            guard let executable = process.executable, executable.hasPrefix("/") else { continue }
            var ancestors: [String] = []
            var start = executable.startIndex
            while let range = executable.range(of: ".app/", range: start..<executable.endIndex) {
                let path = String(executable[..<range.lowerBound]) + ".app"
                ancestors.append(path)
                start = range.upperBound
            }
            // A storage directory may itself end in .app (cmux helper containers do this).
            // Always inspect the innermost executable bundle; outer hosts need a declaration.
            for path in ancestors where path == ancestors.last || FS.exists(path + "/Contents/Info.plist") {
                if !isDiscovered(path, directories: directories) { paths.insert(path) }
            }
        }
        return paths.sorted()
    }

    static func isDiscovered(_ path: String, directories: [String]) -> Bool {
        directories.contains { root in
            guard path.hasPrefix(root + "/") else { return false }
            let parts = path.dropFirst(root.count + 1).split(separator: "/")
            return (parts.count == 1 || (parts.count == 2 && !parts[0].hasSuffix(".app") && root != "/Applications/Utilities")) && parts.last?.hasSuffix(".app") == true
        }
    }

    static func capture(directories: [String], additionalPaths: [String] = [], requiredPaths: [String] = []) -> AppOwnershipSnapshot {
        let roots = Set(directories).sorted()
        let extras = Set(additionalPaths).sorted()
        var issues: [String] = []
        func paths() -> [String] {
            var result = Set<String>()
            for root in roots {
                let names = AppUninstaller.names(in: root, onFailure: { issues.append(root) }) ?? []
                for name in names where !name.hasPrefix(".") {
                    let path = root + "/" + name
                    if name.hasSuffix(".app") { result.insert(path); continue }
                    guard root != "/Applications/Utilities", FS.isDirectory(path) else { continue }
                    for child in AppUninstaller.names(in: path, onFailure: { issues.append(path) }) ?? [] where child.hasSuffix(".app") {
                        result.insert(path + "/" + child)
                    }
                }
            }
            result.formUnion(extras.filter { FS.exists($0) })
            return result.sorted()
        }
        let before = paths()
        let nestedBefore = nestedDeclarations(in: before, issues: &issues)
        var claims: [Claim] = []
        for path in before {
            if ScanCancellation.current?.isCancelled == true { issues.append(path); break }
            if let claim = read(path) { claims.append(claim) } else { issues.append(path) }
        }
        var nestedClaims: [Claim] = []
        for declaration in nestedBefore {
            if ScanCancellation.current?.isCancelled == true { issues.append(declaration.path); break }
            if let claim = readDeclaration(declaration) { nestedClaims.append(claim) } else { issues.append(declaration.path) }
        }
        if paths() != before { issues += roots }
        if nestedDeclarations(in: before, issues: &issues) != nestedBefore { issues += roots }
        for claim in claims {
            if ScanCancellation.current?.isCancelled == true { issues.append(claim.path); break }
            if read(claim.path) != claim { issues.append(claim.path) }
        }
        let declarationsByPath = Dictionary(uniqueKeysWithValues: nestedBefore.map { ($0.path, $0) })
        for claim in nestedClaims {
            if ScanCancellation.current?.isCancelled == true { issues.append(claim.path); break }
            guard let declaration = declarationsByPath[claim.path], readDeclaration(declaration) == claim else {
                issues.append(claim.path); continue
            }
        }
        for path in requiredPaths where !claims.contains(where: { $0.path == path && $0.bundleID != nil }) { issues.append(path) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode([claims, nestedClaims]) }
        catch { data = Data(); issues += roots }
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return AppOwnershipSnapshot(roots: roots, extraPaths: extras, claims: claims, nestedClaims: nestedClaims,
                                    issues: Set(issues).sorted(), fingerprint: fingerprint)
    }

    static func read(_ path: String, metadata: String? = nil) -> Claim? {
        guard let root = AppDataReviewIdentity.of(path) else { return nil }
        let file = metadata ?? path + "/Contents/Info.plist"
        let fd = open(file, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard fd >= 0 else {
            guard errno == ENOENT, AppDataReviewIdentity.of(path) == root else { return nil }
            return Claim(path: path, name: name, bundleID: nil, fingerprint: root + ":missing-info")
        }
        defer { close(fd) }
        var before = stat(), after = stat(), visible = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= 1_048_576,
              let link = AppDataReviewIdentity.of(file),
              let bytes = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 1_048_577),
              bytes.count == before.st_size, fstat(fd, &after) == 0,
              AppDataReviewIdentity.text(before) == AppDataReviewIdentity.text(after),
              stat(file, &visible) == 0, AppDataReviewIdentity.text(visible) == AppDataReviewIdentity.text(after),
              AppDataReviewIdentity.of(path) == root, AppDataReviewIdentity.of(file) == link,
              let plist = (try? PropertyListSerialization.propertyList(from: bytes, format: nil)) as? [String: Any] else { return nil }
        let id = plist["CFBundleIdentifier"] as? String
        if plist["CFBundleIdentifier"] != nil, id.map(validDeclaredID) != true { return nil }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return Claim(path: path, name: name, bundleID: id, fingerprint: root + ":" + link + ":" + AppDataReviewIdentity.text(after) + ":" + hash)
    }
}
