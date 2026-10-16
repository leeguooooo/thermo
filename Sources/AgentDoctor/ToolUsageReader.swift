import Foundation

extension AgentDoctor {
    /// Explicit log analysis; ordinary diagnosis never reads conversation logs.
    public static func usage(since: Date? = nil, host: String? = nil, fileLimit: Int = 100,
                             env: DoctorEnvironment = DoctorEnvironment()) -> ToolUsageReport {
        let since = since ?? env.now.addingTimeInterval(-7 * 86400)
        var parser = ToolUsageParser(since: since, until: env.now)
        guard since <= env.now, (1...1000).contains(fileLimit), host == nil || ["claude", "codex"].contains(host!) else {
            parser.coverage.limitReached = true; return parser.report()
        }
        let started = MCPInspector.clock()
        let fm = FileManager.default
        var files: [(url: URL, host: String, modified: Date)] = []
        var remainingEntries = 20_000
        let roots = [(env.url(".claude/projects"), "claude"), (env.url(".codex/sessions"), "codex")]
        func stopped() -> Bool { env.cancelled() || MCPInspector.clock() - started >= 20 }
        for (root, source) in roots where host == nil || host == source {
            var stack: [(URL, Int)] = [(root, 0)]
            while let (directory, depth) = stack.popLast() {
                if stopped() { break }
                guard depth <= 6, remainingEntries > 0 else { parser.coverage.limitReached = true; continue }
                do {
                    let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
                    if children.count > remainingEntries { parser.coverage.limitReached = true }
                    for child in children.sorted(by: { $0.path < $1.path }).prefix(remainingEntries) {
                        remainingEntries -= 1
                        guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]) else { parser.coverage.unreadableFiles += 1; continue }
                        if values.isSymbolicLink == true { parser.coverage.limitReached = true; continue }
                        if values.isDirectory == true { stack.append((child, depth + 1)) }
                        else if child.pathExtension.lowercased() == "jsonl", values.isRegularFile == true {
                            if let modified = values.contentModificationDate, modified >= since { files.append((child, source, modified)) }
                        }
                    }
                } catch { if fm.fileExists(atPath: directory.path) { parser.coverage.unreadableFiles += 1 } }
            }
        }
        files.sort { $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified > $1.modified }
        parser.coverage.filesDiscovered = files.count
        if files.count > fileLimit { parser.coverage.limitReached = true }
        var identities = Set<String>()
        let maxBytes = 64 * 1024 * 1024
        for file in files.prefix(fileLimit) {
            if stopped() { break }
            let identity = ConfigChecks.skillFileIdentity(file.url)
            guard identities.insert(file.host + "|" + identity).inserted else { parser.coverage.duplicateRecords += 1; continue }
            guard parser.coverage.bytesRead < maxBytes else { parser.coverage.limitReached = true; break }
            do {
                let handle = try FileHandle(forReadingFrom: file.url)
                defer { try? handle.close() }
                let length = try handle.seekToEnd()
                let limit = min(4 * 1024 * 1024, maxBytes - parser.coverage.bytesRead)
                let start = length > UInt64(limit) ? length - UInt64(limit) : 0
                if start > 0 { parser.coverage.clippedFiles += 1 }
                try handle.seek(toOffset: start)
                var remaining = Int(length - start)
                var pending = Data()
                var skipFirst = start > 0
                var oversized = false
                let filename = file.url.deletingPathExtension().lastPathComponent
                // Standard filenames contain a stable session UUID; fallback identity is local only.
                let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
                let uuid = filename.range(of: pattern, options: .regularExpression).map { String(filename[$0]).lowercased() }
                let session = uuid ?? identity
                parser.coverage.filesRead += 1
                while remaining > 0 && !stopped() {
                    guard let data = try handle.read(upToCount: min(65_536, remaining)), !data.isEmpty else { parser.coverage.unreadableFiles += 1; break }
                    remaining -= data.count; parser.coverage.bytesRead += data.count
                    var offset = data.startIndex
                    while offset < data.endIndex {
                        let end = data[offset...].firstIndex(of: 10) ?? data.endIndex
                        if !skipFirst && !oversized {
                            if pending.count + (end - offset) > 1_048_576 {
                                pending.removeAll(keepingCapacity: true); oversized = true; parser.coverage.oversizedLines += 1
                            } else { pending.append(contentsOf: data[offset..<end]) }
                        }
                        if end < data.endIndex {
                            if !skipFirst && !oversized && !pending.isEmpty {
                                autoreleasepool {
                                    if let value = try? JSONSerialization.jsonObject(with: pending) as? [String: Any] {
                                        parser.consume(value, host: file.host, session: session)
                                    } else { parser.coverage.malformedLines += 1 }
                                }
                            }
                            pending.removeAll(keepingCapacity: true); skipFirst = false; oversized = false
                            offset = end + 1
                        } else { break }
                    }
                }
                // A writer may be in the middle of its final JSONL record. Do not invent an event.
                if !pending.isEmpty || oversized { parser.coverage.clippedFiles += 1 }
            } catch { parser.coverage.unreadableFiles += 1 }
        }
        parser.coverage.cancelled = env.cancelled()
        if MCPInspector.clock() - started >= 20 { parser.coverage.limitReached = true }
        return parser.report()
    }
}
