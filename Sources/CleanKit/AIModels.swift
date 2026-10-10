import Foundation

/// Downloaded model weights. Always `review`: they are large to fetch again. One item per model.
enum AIModels {
    static func scan(_ ctx: ScanContext) -> [CleanItem] {
        ollama(ctx) + huggingFace(ctx) + lmStudio(ctx) + flatModelDirs(ctx)
    }

    static func modelItem(_ id: String, _ title: String, detail: String, paths: [String], ctx: ScanContext,
                          size: TreeSize? = nil, lastUsed: Date? = nil, note: String? = nil, app: String? = nil) -> CleanItem? {
        let s = size ?? FS.size(paths, trackNewest: true)
        guard s.bytes > 1_000_000 else { return nil }
        let used = lastUsed ?? s.newest
        var stale = ""
        if let used, used < ctx.staleBefore { stale = " · unused \(AgeFormat.string(used, now: ctx.now).replacingOccurrences(of: " ago", with: ""))" }
        return CleanItem(id: id, category: .aiModels, title: title + stale, detail: detail, safety: .review,
                         bytes: s.bytes, files: s.files, lastUsed: used, paths: paths, note: note,
                         blocked: app.flatMap { ctx.processes.running([$0]) }.map { "\($0) is running" })
    }

    // MARK: Ollama

    /// `~/.ollama/models/manifests/<registry>/<ns>/<model>/<tag>` list layer digests stored as
    /// `blobs/sha256-<hex>`. Blobs are shared between tags, so a model owns only the blobs no other
    /// manifest references; unreferenced blobs are leftovers of removed or interrupted pulls.
    static func ollama(_ ctx: ScanContext) -> [CleanItem] {
        let root = ProcessInfo.processInfo.environment["OLLAMA_MODELS"] ?? ctx.path("~/.ollama/models")
        let manifests = root + "/manifests"
        guard FS.isDirectory(manifests) else { return [] }
        var models: [(name: String, manifest: String, blobs: Set<String>)] = []
        if let e = FileManager.default.enumerator(atPath: manifests) {
            while let rel = e.nextObject() as? String {
                let f = manifests + "/" + rel
                guard !FS.isDirectory(f), let data = FileManager.default.contents(atPath: f),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                var digests = Set<String>()
                if let c = obj["config"] as? [String: Any], let d = c["digest"] as? String { digests.insert(d) }
                for case let l as [String: Any] in (obj["layers"] as? [Any]) ?? [] {
                    if let d = l["digest"] as? String { digests.insert(d) }
                }
                let parts = rel.split(separator: "/")
                // registry.ollama.ai/library/llama3/8b → llama3:8b; other namespaces keep their prefix.
                let name = parts.count >= 3
                    ? (parts[parts.count - 3] == "library" ? "" : parts[parts.count - 3] + "/") + parts[parts.count - 2] + ":" + parts[parts.count - 1]
                    : rel
                models.append((name, f, Set(digests.map { root + "/blobs/" + $0.replacingOccurrences(of: ":", with: "-") })))
            }
        }
        var refCount: [String: Int] = [:]
        for m in models { for b in m.blobs { refCount[b, default: 0] += 1 } }
        var items: [CleanItem] = []
        for m in models {
            let own = m.blobs.filter { refCount[$0] == 1 }
            let shared = m.blobs.count - own.count
            let s = FS.size(Array(own))
            if let item = modelItem("ollama/\(AISessions.slug(m.name))", "Ollama · \(m.name)", detail: FS.tilde(root, home: ctx.home),
                                    paths: [m.manifest] + own.sorted(), ctx: ctx, size: s, lastUsed: FS.mtime(m.manifest),
                                    note: shared > 0 ? "\(shared) layer\(shared == 1 ? "" : "s") shared with other models are kept" : nil) {
                items.append(item)
            }
        }
        let referenced = Set(refCount.keys)
        let orphans = FS.children(root + "/blobs").filter { !referenced.contains($0) && (FS.mtime($0) ?? ctx.now) < ctx.activeAfter }
        if !orphans.isEmpty {
            let s = FS.size(orphans)
            items.append(CleanItem(id: "ollama-orphan-blobs", category: .aiModels, title: "Ollama: unreferenced layers",
                                   detail: "left by removed models or interrupted pulls", safety: .safe,
                                   bytes: s.bytes, files: s.files, paths: orphans))
        }
        return items
    }

    // MARK: Hugging Face

    /// `~/.cache/huggingface/hub/models--org--name/{blobs,snapshots,refs}`: snapshots are symlinks into
    /// blobs, so sizing the repo folder without following links counts each file once.
    static func huggingFace(_ ctx: ScanContext) -> [CleanItem] {
        let env = ProcessInfo.processInfo.environment
        let hub = env["HF_HUB_CACHE"] ?? env["HF_HOME"].map { $0 + "/hub" } ?? ctx.path("~/.cache/huggingface/hub")
        var items: [CleanItem] = []
        for repo in FS.children(hub) where FS.isDirectory(repo) {
            let name = (repo as NSString).lastPathComponent
            let kinds = ["models--": "model", "datasets--": "dataset", "spaces--": "space"]
            guard let (prefix, kind) = kinds.first(where: { name.hasPrefix($0.key) }) else { continue }
            let id = name.dropFirst(prefix.count).replacingOccurrences(of: "--", with: "/")
            // Snapshot folders are touched when a revision is resolved, refs when one is downloaded.
            let used = (FS.children(repo + "/snapshots") + FS.children(repo + "/refs")).compactMap(FS.mtime).max()
            if let item = modelItem("hf/\(AISessions.slug(id))", "Hugging Face \(kind) · \(id)", detail: FS.tilde(repo, home: ctx.home),
                                    paths: [repo], ctx: ctx, lastUsed: used) {
                items.append(item)
            }
        }
        return items
    }

    // MARK: LM Studio

    /// `~/.lmstudio/models/<publisher>/<model>/` (older installs: `~/.cache/lm-studio/models`).
    static func lmStudio(_ ctx: ScanContext) -> [CleanItem] {
        var items: [CleanItem] = []
        for base in ["~/.lmstudio/models", "~/.cache/lm-studio/models"].map(ctx.path) {
            for publisher in FS.children(base) where FS.isDirectory(publisher) {
                for model in FS.children(publisher) where FS.isDirectory(model) {
                    let name = (publisher as NSString).lastPathComponent + "/" + (model as NSString).lastPathComponent
                    if let item = modelItem("lmstudio/\(AISessions.slug(name))", "LM Studio · \(name)",
                                            detail: FS.tilde(model, home: ctx.home), paths: [model], ctx: ctx, app: "LM Studio") {
                        items.append(item)
                    }
                }
            }
        }
        return items
    }

    // MARK: Other model folders (one item per file or folder inside)

    static func flatModelDirs(_ ctx: ScanContext) -> [CleanItem] {
        let dirs: [(String, String, String?)] = [
            ("~/.cache/torch/hub/checkpoints", "PyTorch Hub", nil),
            ("~/.cache/whisper", "Whisper", nil),
            ("~/Library/Caches/llama.cpp", "llama.cpp", nil),
            ("~/.cache/llama.cpp", "llama.cpp", nil),
            ("~/Library/Application Support/nomic.ai/GPT4All", "GPT4All", "GPT4All"),
            ("~/Library/Application Support/Jan/data/models", "Jan", "Jan"),
            ("~/jan/models", "Jan", "Jan"),
            ("~/Library/Application Support/DiffusionBee/downloaded_assets", "DiffusionBee", "DiffusionBee"),
            ("~/Library/Containers/com.apple.mlx.mlx-swift-examples/Data/Library/Caches/models", "MLX", nil),
            ("~/.cache/mlx", "MLX", nil),
        ]
        var items: [CleanItem] = []
        for (dir, tool, app) in dirs {
            for f in FS.children(ctx.path(dir)) {
                let n = (f as NSString).lastPathComponent
                guard !n.hasPrefix("."), !n.hasSuffix(".json"), !n.hasSuffix(".ini") else { continue }
                if let item = modelItem("\(AISessions.slug(tool.lowercased()))/\(AISessions.slug(n))", "\(tool) · \(n)",
                                        detail: FS.tilde(f, home: ctx.home), paths: [f], ctx: ctx, app: app) {
                    items.append(item)
                }
            }
        }
        return items
    }
}
