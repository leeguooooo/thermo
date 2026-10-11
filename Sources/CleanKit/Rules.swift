import Foundation

/// A fixed-location rule: each existing path (or each child, for `.contents`) is removed when cleaned.
/// A `*` in a path matches one folder level (each Chrome profile, for instance).
public struct PathRule: Sendable {
    public enum Scope: Sendable {
        /// Remove the listed paths themselves.
        case whole
        /// Remove what is inside each listed directory, keep the directory.
        case contents
        /// Remove children older than the stale threshold.
        case staleContents
    }

    public let id: String
    public let category: CleanCategory
    public let title: String
    public let paths: [String]
    public let scope: Scope
    public let safety: Safety
    /// Process names / app names; while one runs the item is blocked.
    public let apps: [String]
    public let note: String?
    /// Child names matched by `fnmatch`, for `.contents`/`.staleContents` (nil = all).
    public let match: [String]?
    /// For `.contents`/`.staleContents`: the most recently used children of each folder that are kept.
    public let keepNewest: Int

    public init(_ id: String, _ category: CleanCategory, _ title: String, _ paths: [String], scope: Scope = .whole,
                safety: Safety = .safe, apps: [String] = [], note: String? = nil, match: [String]? = nil, keepNewest: Int = 0) {
        self.id = id; self.category = category; self.title = title; self.paths = paths; self.scope = scope
        self.safety = safety; self.apps = apps; self.note = note; self.match = match; self.keepNewest = keepNewest
    }
}

/// The built-in rule set. Locations come from the cleanup lists of Mole, mac-cleanup-py, BleachBit,
/// Pearcleaner and DevCleaner, plus AI tooling. Everything is under the user's home.
public enum Rules {
    static let appSupport = "~/Library/Application Support"

    /// GPU, shader and compiled-script caches of a Chromium browser: in every profile and at the top.
    /// Pages, logins and history live elsewhere in the profile and are not touched.
    static func chromiumCaches(_ root: String) -> [String] {
        let r = "\(appSupport)/\(root)"
        return ["Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "Service Worker/ScriptCache"]
            .map { "\(r)/*/\($0)" } + ["GrShaderCache", "ShaderCache", "GraphiteDawnCache"].map { "\(r)/\($0)" }
    }

    public static let paths: [PathRule] = [
        // MARK: AI tool caches (regenerable)
        PathRule("claude-code-caches", .aiCaches, "Claude Code logs & snapshots",
                 ["~/.claude/debug", "~/.claude/shell-snapshots", "~/.claude/statsig", "~/.claude/telemetry",
                  "~/.claude/paste-cache", "~/.claude/cache", "~/Library/Caches/claude-cli-nodejs"],
                 scope: .staleContents, note: "debug logs, shell snapshots and telemetry; current ones are kept"),
        PathRule("claude-desktop-caches", .aiCaches, "Claude desktop caches",
                 ["\(appSupport)/Claude/Cache", "\(appSupport)/Claude/Code Cache", "\(appSupport)/Claude/GPUCache",
                  "\(appSupport)/Claude/DawnGraphiteCache", "\(appSupport)/Claude/DawnWebGPUCache",
                  "\(appSupport)/Claude/logs", "~/Library/Caches/com.anthropic.claudefordesktop",
                  "~/Library/Caches/com.anthropic.claudefordesktop.ShipIt", "~/Library/Logs/Claude"],
                 scope: .contents, apps: ["Claude"]),
        PathRule("claude-desktop-vm", .aiCaches, "Claude desktop VM images",
                 ["\(appSupport)/Claude/vm_bundles", "\(appSupport)/Claude/claude-code-vm"],
                 scope: .contents, safety: .review, apps: ["Claude"],
                 note: "sandbox VM used by Claude's code tools; downloaded again on next use"),
        PathRule("chatgpt-caches", .aiCaches, "ChatGPT / Codex app caches",
                 ["~/Library/Caches/com.openai.chat", "~/Library/Caches/com.openai.codex",
                  "\(appSupport)/Codex/Cache", "\(appSupport)/Codex/Code Cache", "\(appSupport)/Codex/GPUCache",
                  "~/.codex/log", "~/.codex/.tmp", "~/.codex/tmp"],
                 scope: .contents, apps: ["ChatGPT", "Codex"]),
        PathRule("cursor-caches", .aiCaches, "Cursor caches",
                 ["\(appSupport)/Cursor/Cache", "\(appSupport)/Cursor/CachedData", "\(appSupport)/Cursor/Code Cache",
                  "\(appSupport)/Cursor/GPUCache", "\(appSupport)/Cursor/CachedExtensionVSIXs", "\(appSupport)/Cursor/logs",
                  "\(appSupport)/Cursor/Crashpad", "~/Library/Caches/com.todesktop.230313mzl4w4u92",
                  "~/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt"],
                 scope: .contents, apps: ["Cursor"]),
        PathRule("windsurf-caches", .aiCaches, "Windsurf caches",
                 ["\(appSupport)/Windsurf/Cache", "\(appSupport)/Windsurf/CachedData", "\(appSupport)/Windsurf/Code Cache",
                  "\(appSupport)/Windsurf/GPUCache", "\(appSupport)/Windsurf/CachedExtensionVSIXs", "\(appSupport)/Windsurf/logs",
                  "~/.codeium/windsurf/cascade/.cache"],
                 scope: .contents, apps: ["Windsurf"]),
        PathRule("vscode-caches", .devCaches, "VS Code caches",
                 ["\(appSupport)/Code/Cache", "\(appSupport)/Code/CachedData", "\(appSupport)/Code/Code Cache",
                  "\(appSupport)/Code/GPUCache", "\(appSupport)/Code/CachedExtensionVSIXs", "\(appSupport)/Code/logs",
                  "~/Library/Caches/com.microsoft.VSCode.ShipIt"],
                 scope: .contents, apps: ["Code", "Electron"]),
        PathRule("gemini-cli-caches", .aiCaches, "Gemini CLI caches", ["~/.gemini/tmp/bin"], scope: .contents),
        PathRule("hf-download-cache", .aiCaches, "Hugging Face xet & download caches",
                 ["~/.cache/huggingface/xet", "~/.cache/huggingface/datasets/downloads"], scope: .contents),
        PathRule("playwright-browsers", .aiCaches, "Browsers for agents (Playwright / Puppeteer)",
                 ["~/Library/Caches/ms-playwright", "~/.cache/ms-playwright", "~/.cache/puppeteer",
                  "~/Library/Caches/ms-playwright-go"],
                 scope: .contents, safety: .review,
                 note: "browser builds downloaded by browser-using agents and tests; fetched again when needed"),
        PathRule("mcp-caches", .aiCaches, "MCP server package caches",
                 ["~/.npm/_npx"], scope: .staleContents,
                 note: "npx copies of MCP servers; reinstalled on next launch (uvx ones are in the uv cache)"),

        // MARK: Developer caches
        PathRule("npm-cache", .devCaches, "npm cache", ["~/.npm/_cacache", "~/.npm/_logs"], apps: ["npm"]),
        PathRule("yarn-cache", .devCaches, "Yarn cache", ["~/Library/Caches/Yarn", "~/.yarn/berry/cache"], scope: .contents),
        PathRule("pnpm-store", .devCaches, "pnpm store", ["~/Library/pnpm/store", "~/.local/share/pnpm/store", "~/.pnpm-store"],
                 safety: .review, note: "projects using pnpm hard-link from here; run pnpm install afterwards"),
        PathRule("bun-cache", .devCaches, "Bun cache", ["~/.bun/install/cache"], scope: .contents),
        PathRule("deno-cache", .devCaches, "Deno cache", ["~/Library/Caches/deno"], scope: .contents),
        PathRule("node-gyp", .devCaches, "node-gyp headers", ["~/Library/Caches/node-gyp", "~/.node-gyp"], scope: .contents),
        PathRule("corepack-cache", .devCaches, "Corepack package managers", ["~/.cache/node/corepack"], scope: .contents,
                 note: "pnpm and Yarn versions Corepack downloaded; fetched again when a project asks for them"),
        PathRule("electron-download-cache", .devCaches, "Electron downloads",
                 ["~/Library/Caches/electron", "~/Library/Caches/electron-builder"], scope: .contents),
        PathRule("typescript-cache", .devCaches, "TypeScript type cache", ["~/Library/Caches/typescript"], scope: .contents),
        PathRule("carthage-cache", .devCaches, "Carthage cache", ["~/Library/Caches/org.carthage.CarthageKit"], scope: .contents),
        PathRule("android-caches", .devCaches, "Android build caches", ["~/.android/cache", "~/.android/build-cache"],
                 scope: .contents, apps: ["studio"]),
        PathRule("pnpm-store-prune", .devCaches, "pnpm packages no project uses", [], apps: ["pnpm"]),
        PathRule("go-mod-cache", .devCaches, "Go module cache", [], safety: .review, apps: ["go"],
                 note: "downloaded modules; Go fetches them again on the next build"),
        PathRule("homebrew-old-versions", .devCaches, "Homebrew old versions", [], apps: ["brew"],
                 note: "older versions of installed formulae and casks; the current ones stay"),
        PathRule("editor-obsolete-extensions-code", .devCaches, "VS Code replaced extensions", [], apps: ["Code", "Electron"]),
        PathRule("editor-obsolete-extensions-cursor", .devCaches, "Cursor replaced extensions", [], apps: ["Cursor"]),
        PathRule("editor-obsolete-extensions-windsurf", .devCaches, "Windsurf replaced extensions", [], apps: ["Windsurf"]),
        PathRule("pip-cache", .devCaches, "pip cache", ["~/Library/Caches/pip", "~/.cache/pip"], scope: .contents),
        PathRule("uv-cache", .devCaches, "uv cache", ["~/.cache/uv", "~/Library/Caches/uv"], scope: .contents, apps: ["uv"]),
        PathRule("poetry-cache", .devCaches, "Poetry cache", ["~/Library/Caches/pypoetry"], scope: .contents),
        PathRule("conda-pkgs", .devCaches, "Conda package cache",
                 ["~/miniconda3/pkgs", "~/anaconda3/pkgs", "~/miniforge3/pkgs", "~/mambaforge/pkgs", "~/.conda/pkgs"],
                 scope: .contents),
        PathRule("homebrew-cache", .devCaches, "Homebrew downloads", ["~/Library/Caches/Homebrew"], scope: .contents,
                 apps: ["brew"]),
        PathRule("cargo-cache", .devCaches, "Cargo registry cache",
                 ["~/.cargo/registry/cache", "~/.cargo/registry/src", "~/.cargo/git/checkouts"],
                 scope: .contents, apps: ["cargo"]),
        PathRule("go-cache", .devCaches, "Go build cache", ["~/Library/Caches/go-build"], scope: .contents, apps: ["go"]),
        PathRule("gradle-cache", .devCaches, "Gradle caches", ["~/.gradle/caches", "~/.gradle/daemon", "~/.gradle/wrapper/dists"],
                 scope: .contents, apps: ["java"]),
        PathRule("maven-repo", .devCaches, "Maven repository", ["~/.m2/repository"], scope: .contents, safety: .review),
        PathRule("cocoapods-cache", .devCaches, "CocoaPods cache", ["~/Library/Caches/CocoaPods"], scope: .contents),
        PathRule("swiftpm-cache", .devCaches, "Swift Package Manager cache",
                 ["~/Library/Caches/org.swift.swiftpm", "~/Library/org.swift.swiftpm/collections.json"], scope: .contents),
        PathRule("flutter-cache", .devCaches, "Dart / Flutter pub cache", ["~/.pub-cache/hosted"], scope: .contents,
                 safety: .review),
        PathRule("jetbrains-caches", .devCaches, "JetBrains IDE caches & logs",
                 ["~/Library/Caches/JetBrains", "~/Library/Logs/JetBrains"], scope: .contents),
        PathRule("composer-cache", .devCaches, "Composer cache", ["~/Library/Caches/composer", "~/.composer/cache"],
                 scope: .contents),
        PathRule("docker-hint", .devCaches, "Docker images & build cache", [], safety: .review,
                 note: "Docker keeps everything in one disk image; reclaim space from Docker itself"),

        // MARK: Xcode
        PathRule("xcode-derived-data", .xcode, "Xcode DerivedData", ["~/Library/Developer/Xcode/DerivedData"],
                 scope: .contents, apps: ["Xcode"]),
        PathRule("xcode-device-support", .xcode, "iOS / watchOS device support",
                 ["~/Library/Developer/Xcode/iOS DeviceSupport", "~/Library/Developer/Xcode/watchOS DeviceSupport",
                  "~/Library/Developer/Xcode/tvOS DeviceSupport", "~/Library/Developer/Xcode/visionOS DeviceSupport"],
                 scope: .staleContents, safety: .safe, note: "symbols copied from devices; recreated when a device connects",
                 keepNewest: 2),
        PathRule("xcode-archives", .xcode, "Xcode archives", ["~/Library/Developer/Xcode/Archives"],
                 scope: .staleContents, safety: .review, note: "needed to symbolicate crash reports of shipped builds"),
        PathRule("xcode-caches", .xcode, "Xcode caches & previews",
                 ["~/Library/Caches/com.apple.dt.Xcode", "~/Library/Developer/Xcode/UserData/Previews",
                  "~/Library/Developer/CoreSimulator/Caches", "~/Library/Developer/Xcode/Products"],
                 scope: .contents, apps: ["Xcode", "Simulator"]),
        PathRule("simulator-logs", .xcode, "Simulator logs", ["~/Library/Logs/CoreSimulator"], scope: .contents),

        // MARK: Browsers
        PathRule("chrome-cache", .browsers, "Chrome cache",
                 ["~/Library/Caches/Google/Chrome", "~/Library/Caches/com.google.Chrome"], scope: .contents,
                 apps: ["Google Chrome"]),
        PathRule("edge-cache", .browsers, "Edge cache", ["~/Library/Caches/Microsoft Edge"], scope: .contents,
                 apps: ["Microsoft Edge"]),
        PathRule("brave-cache", .browsers, "Brave cache", ["~/Library/Caches/BraveSoftware"], scope: .contents,
                 apps: ["Brave Browser"]),
        PathRule("arc-cache", .browsers, "Arc cache", ["~/Library/Caches/Arc", "~/Library/Caches/company.thebrowser.Browser"],
                 scope: .contents, apps: ["Arc"]),
        PathRule("firefox-cache", .browsers, "Firefox cache", ["~/Library/Caches/Firefox"], scope: .contents,
                 apps: ["firefox"]),
        PathRule("chrome-profile-caches", .browsers, "Chrome GPU & script caches", chromiumCaches("Google/Chrome"),
                 scope: .contents, apps: ["Google Chrome"]),
        PathRule("edge-profile-caches", .browsers, "Edge GPU & script caches", chromiumCaches("Microsoft Edge"),
                 scope: .contents, apps: ["Microsoft Edge"]),
        PathRule("brave-profile-caches", .browsers, "Brave GPU & script caches", chromiumCaches("BraveSoftware/Brave-Browser"),
                 scope: .contents, apps: ["Brave Browser"]),
        PathRule("arc-profile-caches", .browsers, "Arc GPU & script caches", chromiumCaches("Arc/User Data"),
                 scope: .contents, apps: ["Arc"]),
        PathRule("chromium-profile-caches", .browsers, "Chromium GPU & script caches", chromiumCaches("Chromium"),
                 scope: .contents, apps: ["Chromium"]),
        PathRule("safari-cache", .browsers, "Safari cache", ["~/Library/Caches/com.apple.Safari"], scope: .contents,
                 apps: ["Safari"]),

        // MARK: System & apps
        PathRule("user-logs", .system, "App logs", ["~/Library/Logs"], scope: .staleContents,
                 note: "log files older than the age limit"),
        PathRule("trash", .system, "Trash", ["~/.Trash"], scope: .contents, safety: .review,
                 note: "emptying the Trash cannot be undone"),
        PathRule("old-installers", .system, "Old installers in Downloads", ["~/Downloads"], scope: .staleContents,
                 safety: .review, match: ["*.dmg", "*.pkg", "*.iso", "*.xip", "*.mpkg", "*.ipsw"]),
        PathRule("incomplete-downloads", .system, "Unfinished downloads", ["~/Downloads"], scope: .staleContents,
                 safety: .review, note: "downloads a browser never finished",
                 match: ["*.crdownload", "*.download", "*.part", "*.partial", "*.opdownload"]),
        PathRule("ios-backups", .system, "iPhone / iPad backups", ["~/Library/Application Support/MobileSync/Backup"],
                 scope: .staleContents, safety: .review, note: "old device backups; keep the latest one"),
        PathRule("ios-updates", .system, "iOS software updates",
                 ["~/Library/iTunes/iPhone Software Updates", "~/Library/iTunes/iPad Software Updates"], scope: .contents),
        PathRule("mail-downloads", .system, "Mail attachments cache",
                 ["~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"], scope: .contents, apps: ["Mail"]),
        PathRule("slack-cache", .system, "Slack / Discord / Teams caches",
                 ["\(appSupport)/Slack/Cache", "\(appSupport)/Slack/Service Worker/CacheStorage",
                  "\(appSupport)/discord/Cache", "\(appSupport)/discord/Code Cache",
                  "~/Library/Containers/com.microsoft.teams2/Data/Library/Caches"],
                 scope: .contents, apps: ["Slack", "Discord", "Microsoft Teams"]),
    ]

    /// `~/Library/Caches` children not claimed by any rule above become one "other app caches" item.
    static let otherCachesRoot = "~/Library/Caches"
}
