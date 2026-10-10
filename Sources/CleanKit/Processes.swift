import Darwin
import Foundation

/// Running processes of the current user: name and working directory (via libproc).
public struct ProcessTable: Sendable {
    public struct Entry: Sendable {
        public let pid: pid_t
        public let name: String
        public let path: String
        public let cwd: String?
    }

    public let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    public static func current() -> ProcessTable {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return ProcessTable(entries: []) }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let uid = getuid()
        var out: [Entry] = []
        for pid in pids.prefix(Int(max(0, count))) where pid > 0 {
            var info = proc_bsdshortinfo()
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0,
                  info.pbsi_uid == uid else { continue }
            var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let path = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 ? String(cString: pathBuf) : ""
            let name = withUnsafeBytes(of: info.pbsi_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            var vp = proc_vnodepathinfo()
            var cwd: String?
            if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vp, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
                cwd = withUnsafeBytes(of: vp.pvi_cdir.vip_path) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
            }
            out.append(Entry(pid: pid, name: name, path: path, cwd: cwd))
        }
        return ProcessTable(entries: out)
    }

    /// True when a process whose executable name or bundle path matches one of `names` is running.
    public func running(_ names: [String]) -> String? {
        for n in names {
            let lower = n.lowercased()
            if let e = entries.first(where: {
                $0.name.lowercased() == lower || $0.path.lowercased().contains("/\(lower).app/")
            }) {
                return e.path.contains(".app/") ? n : e.name
            }
        }
        return nil
    }

    /// Working directories of processes that look like AI coding agents (claude, codex, gemini, node CLIs …).
    public func agentDirectories() -> Set<String> {
        let agents = ["claude", "codex", "gemini", "opencode", "aider", "amp", "cursor-agent", "qwen", "goose", "crush"]
        var dirs = Set<String>()
        for e in entries {
            let n = e.name.lowercased()
            let p = e.path.lowercased()
            let isAgent = agents.contains(n) || agents.contains { p.hasSuffix("/" + $0) || p.contains("/" + $0 + "/") }
                || (n == "node" || n == "bun") && agents.contains { p.contains($0) }
            if isAgent, let c = e.cwd, !c.isEmpty, c != "/" { dirs.insert(c) }
        }
        return dirs
    }
}
