import Foundation

/// A second opinion from an AI already running on this Mac (magpie's relay, Ollama, LM Studio, or
/// Claude Code headless). Only facts about an item are sent — path, size, dates, Thermo's note and
/// the names inside — never file contents. The answer is advice: it never ticks or removes anything,
/// and Thermo's own guards still decide what can be cleaned.
public struct LocalAIQuestion: Sendable, Hashable, Identifiable {
    public var title: String
    public var path: String?
    public var bytes: Int64?
    public var modified: Date?
    /// What Thermo already says about it.
    public var note: String?
    /// Names inside the folder, or the paths of a multi-path item.
    public var children: [String]
    /// Why Thermo refuses to remove it, if it does; shown beside the answer, which cannot overrule it.
    public var blocked: String?
    public var home: String

    public init(title: String, path: String? = nil, bytes: Int64? = nil, modified: Date? = nil, note: String? = nil,
                children: [String] = [], blocked: String? = nil, home: String = NSHomeDirectory()) {
        self.title = title; self.path = path; self.bytes = bytes; self.modified = modified; self.note = note
        self.children = children; self.blocked = blocked; self.home = home
    }

    public var id: String { cacheKey }
    var cacheKey: String { [title, path ?? "", bytes.map(String.init) ?? "", modified.map { String(Int($0.timeIntervalSince1970)) } ?? ""].joined(separator: "|") }

    func tilde(_ p: String) -> String { p == home ? "~" : p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p }

    /// Exactly what is sent, shown to the user before the first question.
    public var facts: String {
        var lines = ["Item: \(title)"]
        if let path { lines.append("Path: \(tilde(path))") }
        if let bytes { lines.append("Size: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))") }
        if let modified { lines.append("Last changed: \(ISO8601DateFormatter.string(from: modified, timeZone: .current, formatOptions: [.withFullDate]))") }
        if let note, !note.isEmpty { lines.append("Thermo's note: \(note)") }
        if let blocked { lines.append("Thermo will not remove it: \(blocked)") }
        if !children.isEmpty {
            let shown = children.prefix(20).map(tilde)
            lines.append("Inside: " + shown.joined(separator: ", ") + (children.count > 20 ? ", … (\(children.count - 20) more)" : ""))
        }
        return lines.joined(separator: "\n")
    }

    /// Created by the UI from a folder on disk: the first names inside, biggest folders unknown.
    public static func names(in folder: String, limit: Int = 20) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted().prefix(limit).map { $0 }
    }
}

public struct LocalAIAnswer: Sendable, Equatable {
    public enum Verdict: String, Sendable, Codable { case delete, careful, keep }
    public var verdict: Verdict
    public var reason: String
    /// A command or step, when there is a better way than deleting the folder.
    public var how: String?
    public var source: String
}

public enum LocalAIBackend: Sendable, Equatable {
    case http(name: String, base: URL, model: String)
    case claudeCLI(path: String)

    public var label: String {
        switch self {
        case .http(let name, _, let model): return "\(name) · \(model)"
        case .claudeCLI: return "Claude Code · haiku"
        }
    }
}

public enum LocalAIError: Error, LocalizedError {
    case unreachable(String)
    case emptyAnswer

    public var errorDescription: String? {
        switch self {
        case .unreachable(let why): return why
        case .emptyAnswer: return tr("The AI gave no answer.")
        }
    }
}

public enum LocalAI {
    /// Local OpenAI-compatible servers, in the order they are tried. Loopback only.
    static let servers: [(name: String, port: Int)] = [("magpie", 3425), ("Ollama", 11434), ("LM Studio", 1234)]
    static let cliPaths = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.claude/local/claude"]

    static let system = """
    You help someone decide whether to delete something on their Mac to free disk space. \
    You get facts about one item (no file contents). Reply with ONLY a JSON object: \
    {"verdict": "delete" | "careful" | "keep", "reason": "<one or two sentences>", "how": "<a better command or step, or empty>"}. \
    "delete": safe to remove, it regenerates or is clearly leftover. "careful": depends on the person, say what to check. \
    "keep": needed by the system, an app, or holds personal data. If a tool should remove it instead \
    (xcrun simctl, brew cleanup, docker system prune, an app's own setting), put that in "how". \
    Never suggest deleting ~/.codex, ~/.claude or other agent data wholesale. Be concrete and brief.
    """

    /// Picks a small, fast chat model: the question is short and the answer is a verdict.
    public static func pickModel(_ ids: [String]) -> String? {
        let chat = ids.filter { id in !["image", "embed", "tts", "whisper", "rerank", "video", "audio"].contains { id.lowercased().contains($0) } }
        for want in ["haiku", "luna", "mini", "flash", "small", "lite"] {
            if let m = chat.first(where: { $0.lowercased().contains(want) }) { return m }
        }
        return chat.first
    }

    public static func discover(home: String = NSHomeDirectory(), session: URLSession = .shared) async -> LocalAIBackend? {
        let override = UserDefaults.standard.string(forKey: "localAI.model")
        for s in servers {
            let base = URL(string: "http://127.0.0.1:\(s.port)/v1")!
            var req = URLRequest(url: base.appendingPathComponent("models"), timeoutInterval: 1.5)
            req.httpMethod = "GET"
            guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["data"] as? [[String: Any]] else { continue }
            let ids = list.compactMap { $0["id"] as? String }
            if let o = override, ids.contains(o) { return .http(name: s.name, base: base, model: o) }
            if let m = pickModel(ids) { return .http(name: s.name, base: base, model: m) }
        }
        for p in cliPaths {
            let path = p.hasPrefix("~/") ? home + p.dropFirst(1) : p
            if FileManager.default.isExecutableFile(atPath: path) { return .claudeCLI(path: path) }
        }
        return nil
    }

    private static let cache = AnswerCache()

    public static func ask(_ q: LocalAIQuestion, using backend: LocalAIBackend, session: URLSession = .shared) async throws -> LocalAIAnswer {
        if let hit = await cache.get(q.cacheKey) { return hit }
        let lang = Locale.preferredLanguages.first ?? "en"
        let user = q.facts + "\n\nAnswer in the language with code \(lang)."
        let raw: String
        switch backend {
        case .http(let name, let base, let model):
            var req = URLRequest(url: base.appendingPathComponent("chat/completions"), timeoutInterval: 90)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model, "max_tokens": 1500,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            ])
            let data: Data, resp: URLResponse
            do { (data, resp) = try await session.data(for: req) } catch { throw LocalAIError.unreachable(tr("%1$@ did not answer: %2$@", name, error.localizedDescription)) }
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                let msg = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
                throw LocalAIError.unreachable(tr("%1$@ did not answer: %2$@", name, msg))
            }
            raw = (((obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
        case .claudeCLI(let path):
            raw = try await runCLI(path, ["-p", "--model", "haiku", system + "\n\n" + user])
        }
        guard var answer = parse(raw, source: backend.label) else { throw LocalAIError.emptyAnswer }
        answer.source = backend.label
        await cache.put(q.cacheKey, answer)
        return answer
    }

    /// The model is asked for JSON; anything else is kept as a cautious plain-text answer.
    public static func parse(_ raw: String, source: String) -> LocalAIAnswer? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        struct Wire: Decodable { var verdict: String; var reason: String; var how: String? }
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
           let w = try? JSONDecoder().decode(Wire.self, from: Data(text[a...b].utf8)) {
            let how = w.how?.trimmingCharacters(in: .whitespacesAndNewlines)
            return LocalAIAnswer(verdict: LocalAIAnswer.Verdict(rawValue: w.verdict.lowercased()) ?? .careful,
                                 reason: w.reason, how: how?.isEmpty == false ? how : nil, source: source)
        }
        return LocalAIAnswer(verdict: .careful, reason: String(text.prefix(600)), how: nil, source: source)
    }

    static func runCLI(_ path: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                // Outside any project, so no project instructions or tools are loaded.
                p.currentDirectoryURL = FileManager.default.temporaryDirectory
                let out = Pipe(); p.standardOutput = out; p.standardError = Pipe(); p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(throwing: LocalAIError.unreachable(error.localizedDescription)); return }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit(); timer.cancel()
                guard p.terminationStatus == 0 else {
                    cont.resume(throwing: LocalAIError.unreachable(tr("Claude Code exited with status %1$@", String(p.terminationStatus)))); return
                }
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}

private actor AnswerCache {
    var answers: [String: LocalAIAnswer] = [:]
    func get(_ k: String) -> LocalAIAnswer? { answers[k] }
    func put(_ k: String, _ a: LocalAIAnswer) { answers[k] = a }
}
