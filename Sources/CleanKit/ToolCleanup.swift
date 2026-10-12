import Foundation

/// Space only a tool may give back itself (Homebrew's old versions, Go's read-only module cache),
/// and caches found by looking rather than at a fixed place (editors' replaced extensions, the
/// Chromium caches of Electron apps).
enum ToolCleanup {
    static func scan(_ ctx: ScanContext) -> [CleanItem] {
        [homebrew(ctx), goModules(ctx), pnpmPrune(ctx)].compactMap { $0 } + obsoleteExtensions(ctx)
    }

    /// Absolute paths: an app opened from the Finder has no shell PATH.
    static func tool(_ name: String, ctx: ScanContext) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin", ctx.path("~/go/bin"), ctx.path("~/.local/bin"),
         ctx.path("~/Library/pnpm"), ctx.path("~/.local/share/pnpm")]
            .map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Homebrew

    static func homebrew(_ ctx: ScanContext) -> CleanItem? {
        guard let brew = tool("brew", ctx: ctx) else { return nil }
        let days = String(ctx.options.olderThanDays)
        let env = ["HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ENV_HINTS=1", "HOMEBREW_NO_ANALYTICS=1"]
        let (status, output) = Shell.exec(env + [brew, "cleanup", "--dry-run", "--prune=\(days)"], timeout: 60)
        guard status == 0 else { return nil }
        // The download cache is the Homebrew downloads rule's; count only what that leaves.
        let cache = ctx.path("~/Library/Caches/Homebrew")
        let found = parseBrewDryRun(output).filter { !$0.path.hasPrefix(cache + "/") && $0.path != cache }
        let bytes = found.reduce(Int64(0)) { $0 + $1.bytes }
        guard bytes > 0 else { return nil }
        let names = found.map { ($0.path as NSString).deletingLastPathComponent }
            .map { ($0 as NSString).lastPathComponent }
        let unique = Array(NSOrderedSet(array: names)) as? [String] ?? []
        return CleanItem(id: "homebrew-old-versions", category: .devCaches, title: tr("Homebrew old versions"),
                         detail: unique.prefix(5).joined(separator: ", ") + (unique.count > 5 ? "…" : ""),
                         safety: .safe, bytes: bytes, files: found.count,
                         note: tr("older versions of installed formulae and casks; the current ones stay"),
                         hint: "brew cleanup --prune=\(days)",
                         commands: [env + [brew, "cleanup", "--prune=\(days)"]])
    }

    /// `Would remove: /opt/homebrew/Cellar/node/22.1.0 (2,345 files, 81.2MB)` lines.
    static func parseBrewDryRun(_ output: String) -> [(path: String, bytes: Int64)] {
        output.split(separator: "\n").compactMap { line -> (String, Int64)? in
            guard line.hasPrefix("Would remove: "), let open = line.range(of: " (", options: .backwards) else { return nil }
            let path = String(line[line.index(line.startIndex, offsetBy: 14)..<open.lowerBound])
            let inside = line[open.upperBound...].dropLast()
            let size = inside.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return (path, parseSize(size))
        }
    }

    /// Homebrew's sizes: `81.2MB`, `512KB`, `1.5GB`, `12B` (decimal units).
    static func parseSize(_ s: String) -> Int64 {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (u, f) in units where s.hasSuffix(u) {
            guard let v = Double(s.dropLast(u.count).replacingOccurrences(of: ",", with: "")) else { return 0 }
            return Int64(v * f)
        }
        return 0
    }

    // MARK: Go

    /// Go keeps modules read-only, so deleting the folder fails half-way; `go clean -modcache` is the way.
    static func goModules(_ ctx: ScanContext) -> CleanItem? {
        guard let go = tool("go", ctx: ctx) else { return nil }
        let (status, output) = Shell.exec([go, "env", "GOMODCACHE"], timeout: 15)
        let dir = status == 0 && output.hasPrefix("/") ? output : ctx.path("~/go/pkg/mod")
        guard FS.isDirectory(dir) else { return nil }
        let s = FS.size(dir, trackNewest: true)
        guard s.bytes > 0 else { return nil }
        return CleanItem(id: "go-mod-cache", category: .devCaches, title: tr("Go module cache"), detail: ctx.tilde(dir),
                         safety: .review, bytes: s.bytes, files: s.files, lastUsed: s.newest,
                         note: tr("downloaded modules; Go fetches them again on the next build"),
                         blocked: ctx.processes.running(["go"]).map { tr("quit %1$@ first", $0) },
                         hint: "go clean -modcache", commands: [[go, "clean", "-modcache"]])
    }

    // MARK: pnpm

    /// `pnpm store prune` removes packages no project links to any more. It has no dry run, so the
    /// store's size is the upper bound and the cleanup reports what it measured afterwards.
    static func pnpmPrune(_ ctx: ScanContext) -> CleanItem? {
        guard let pnpm = tool("pnpm", ctx: ctx) else { return nil }
        let (status, output) = Shell.exec([pnpm, "store", "path"], timeout: 15)
        guard status == 0, let store = output.split(separator: "\n").last.map(String.init), store.hasPrefix("/"),
              FS.isDirectory(store) else { return nil }
        let s = FS.size(store, trackNewest: true)
        guard s.bytes > 0 else { return nil }
        return CleanItem(id: "pnpm-store-prune", category: .devCaches, title: tr("pnpm packages no project uses"),
                         detail: ctx.tilde(store), safety: .safe, bytes: s.bytes, files: s.files, lastUsed: s.newest,
                         note: tr("up to the store's size; pnpm keeps what your projects link to, and the result shows what it freed"),
                         blocked: ctx.processes.running(["pnpm"]).map { tr("quit %1$@ first", $0) },
                         hint: "pnpm store prune", commands: [[pnpm, "store", "prune"]], measure: [store])
    }

    // MARK: Browser updates

    static let oldVersionPrefix = "browser-old-version/"
    static let browsers: [(app: String, framework: String)] = [
        ("Google Chrome", "Google Chrome Framework"), ("Microsoft Edge", "Microsoft Edge Framework"),
        ("Brave Browser", "Brave Browser Framework"), ("Chromium", "Chromium Framework"),
    ]

    static func isBrowserOldVersion(_ item: CleanItem) -> Bool { item.id.hasPrefix(oldVersionPrefix) }

    static func versionsDir(_ b: (app: String, framework: String), appsRoot: String = "/Applications") -> String {
        "\(appsRoot)/\(b.app).app/Contents/Frameworks/\(b.framework).framework/Versions"
    }

    /// Chromium browsers keep the previous version inside the app after an update until they restart.
    /// Removing it leaves the app's signature valid (the framework seals only `Current`); the browser
    /// must be closed, and only a version folder `Current` does not point to is offered.
    static func browserOldVersions(_ ctx: ScanContext, appsRoot: String = "/Applications") -> [CleanItem] {
        browsers.compactMap { b in
            let old = oldVersions(versionsDir(b, appsRoot: appsRoot))
            let s = FS.size(old)
            guard s.bytes > 0 else { return nil }
            return CleanItem(id: oldVersionPrefix + b.app, category: .browsers,
                             title: tr("%1$@ previous version", b.app),
                             detail: old.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "),
                             safety: .review, bytes: s.bytes, files: s.files, paths: old,
                             note: tr("left inside the app by an update until the browser restarts; the version in use stays"),
                             blocked: ctx.processes.running([b.app]).map { tr("quit %1$@ first", $0) })
        }
    }

    static func oldVersions(_ versions: String) -> [String] {
        guard let current = try? FileManager.default.destinationOfSymbolicLink(atPath: versions + "/Current") else { return [] }
        let currentName = (current as NSString).lastPathComponent
        return FS.children(versions).filter {
            let n = ($0 as NSString).lastPathComponent
            return n != "Current" && n != currentName && !n.hasPrefix(".") && FS.isDirectory($0)
        }
    }

    /// The guard for this one place outside the home folder: a real version folder of a known
    /// browser in /Applications, not the one in use, not a symlink.
    static func oldVersionRefusal(_ path: String, appsRoot: String = "/Applications") -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        guard browsers.contains(where: { versionsDir($0, appsRoot: appsRoot) == parent }),
              realpath(parent, nil).map({ p in defer { free(p) }; return String(cString: p) == parent }) == true,
              oldVersions(parent).contains(path) else { return tr("not an old browser version") }
        return nil
    }

    // MARK: Editor extensions

    /// VS Code and its forks leave a replaced extension's folder behind and list it in `.obsolete`
    /// until the next restart removes it.
    static func obsoleteExtensions(_ ctx: ScanContext) -> [CleanItem] {
        let editors: [(id: String, title: String, dirs: [String], apps: [String])] = [
            ("code", "VS Code replaced extensions", ["~/.vscode/extensions", "~/.vscode-insiders/extensions"], ["Code", "Electron"]),
            ("cursor", "Cursor replaced extensions", ["~/.cursor/extensions"], ["Cursor"]),
            ("windsurf", "Windsurf replaced extensions", ["~/.windsurf/extensions"], ["Windsurf"]),
        ]
        return editors.compactMap { e in
            var paths: [String] = []
            for dir in e.dirs.map(ctx.path) {
                guard let data = FileManager.default.contents(atPath: dir + "/.obsolete"),
                      let list = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                for (name, flag) in list where (flag as? Bool) == true && !name.contains("/") && !name.hasPrefix(".") {
                    let p = dir + "/" + name
                    if FS.isDirectory(p) { paths.append(p) }
                }
            }
            let s = FS.size(paths, trackNewest: true)
            guard s.bytes > 0 else { return nil }
            return CleanItem(id: "editor-obsolete-extensions-" + e.id, category: .devCaches, title: tr(e.title),
                             detail: paths.map { ($0 as NSString).lastPathComponent }.sorted().prefix(4).joined(separator: ", "),
                             safety: .safe, bytes: s.bytes, files: s.files, lastUsed: s.newest, paths: paths.sorted(),
                             note: tr("versions the editor already replaced with newer ones"),
                             blocked: ctx.processes.running(e.apps).map { tr("quit %1$@ first", $0) })
        }
    }

    // MARK: Electron apps

    static let chromiumCacheNames = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache"]

    /// Apps built on Electron keep Chromium's caches in their Application Support folder. Folders a
    /// rule already covers, apps that are running and caches written in the last hour are left alone.
    static func electronCaches(_ ctx: ScanContext, claimed: Set<String>? = nil) -> CleanItem? {
        let root = ctx.path("~/Library/Application Support")
        let claimed = claimed ?? Set(Rules.paths.flatMap(\.paths).filter { !$0.contains("*") }.map(ctx.path))
        var paths: [String] = []
        var apps: [String] = []
        var size = TreeSize()
        for app in FS.children(root) {
            guard ScanCancellation.current?.isCancelled != true else { return nil }
            let name = (app as NSString).lastPathComponent
            // Chromium's own signature: both a compiled-script and a GPU cache.
            guard !name.hasPrefix("."), FS.isDirectory(app + "/Code Cache"), FS.isDirectory(app + "/GPUCache") else { continue }
            if ctx.processes.running([name]) != nil { continue }
            var found = false
            for cache in chromiumCacheNames.map({ app + "/" + $0 }) where FS.isDirectory(cache) && !claimed.contains(cache) {
                let s = FS.size(cache, trackNewest: true)
                guard s.bytes > 0, !s.denied, (s.newest ?? ctx.now) < ctx.now.addingTimeInterval(-3600) else { continue }
                paths.append(cache); size = size + s; found = true
            }
            if found { apps.append(name) }
        }
        guard size.bytes > 0 else { return nil }
        return CleanItem(id: "electron-app-caches", category: .system, title: tr("Electron app caches"),
                         detail: apps.sorted().prefix(5).joined(separator: ", ") + (apps.count > 5 ? "…" : ""),
                         safety: .safe, bytes: size.bytes, files: size.files, lastUsed: size.newest, paths: paths,
                         note: tr("browser caches inside desktop apps; running apps and caches used in the last hour are skipped"))
    }

    /// macOS clones an app into a per-user X folder to check its signature while it runs; Chrome
    /// leaves one behind on every relaunch. They share blocks with the installed app, so they cost
    /// almost nothing until the app updates; then each becomes a full copy (65 of Chrome were 90 GB).
    /// The newest clone of a running app is kept: that is the one it runs from.
    static func codeSignClones(_ ctx: ScanContext, root: String = (NSTemporaryDirectory() as NSString).deletingLastPathComponent + "/X") -> CleanItem? {
        let running = Set(ctx.processes.entries.compactMap { e -> String? in
            guard let exe = e.executable, let r = exe.range(of: ".app/Contents/") else { return nil }
            return Bundle(path: String(exe[..<r.lowerBound]) + ".app")?.bundleIdentifier
        })
        var paths: [String] = []
        var apps: [String] = []
        var size = TreeSize()
        var shared: Int64 = 0
        for group in FS.children(root) where group.hasSuffix(".code_sign_clone") {
            let bundle = String((group as NSString).lastPathComponent.dropLast(".code_sign_clone".count))
            var clones = FS.children(group).map { path -> (String, Date) in
                var st = stat()
                return (path, lstat(path, &st) == 0 ? Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)) : .distantPast)
            }.sorted { $0.1 > $1.1 }
            if running.contains(bundle) { clones = Array(clones.dropFirst()) }
            guard !clones.isEmpty else { continue }
            for (clone, _) in clones {
                guard ScanCancellation.current?.isCancelled != true else { return nil }
                let s = FS.size(clone, trackNewest: true)
                paths.append(clone); size = size + s; shared += s.allocated - s.bytes
            }
            apps.append(bundle)
        }
        guard !paths.isEmpty else { return nil }
        return CleanItem(id: "code-sign-clones", category: .system, title: tr("Leftover app code-sign clones"),
                         detail: trCount(paths.count, "%1$@ clone", "%1$@ clones") + " · " + apps.sorted().joined(separator: ", "),
                         safety: .safe, bytes: size.bytes, files: size.files, lastUsed: size.newest, paths: paths,
                         note: tr("copies macOS made to check a running app; they share space with the app now, but each becomes a full copy (%1$@ in all) when the app updates", ByteFormat.string(size.bytes + shared)))
    }
}
