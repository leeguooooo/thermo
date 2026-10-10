import Foundation
import ThermoL10n

/// Everything the doctor reads from the machine, injectable so tests can run against a fixture home.
public struct DoctorEnvironment {
    public var home: URL
    public var uid: uid_t
    /// Directories searched for bare command names (hooks and MCP servers run with the agent's PATH, not ours).
    public var path: [String]
    /// Runs a tool and returns stdout; nil when it fails to launch or exits non-zero.
    public var run: (_ executable: String, _ args: [String]) -> String?
    /// Executable path of a running process (proc_pidpath).
    public var executablePath: (_ pid: Int32) -> String?
    public var now: Date
    /// Runs a tool for an action: exit status and combined output.
    public var execute: (_ executable: String, _ args: [String], _ cwd: String?) -> (status: Int32, output: String)
    public var trash: (URL) throws -> Void
    public var signal: (_ pid: Int32, _ signal: Int32) -> Bool
    /// Config files are copied here (one folder per action) before an action edits them.
    public var backupRoot: URL
    public var logFile: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                uid: uid_t = getuid(),
                path: [String]? = nil,
                run: @escaping (String, [String]) -> String? = DoctorEnvironment.runTool,
                executablePath: @escaping (Int32) -> String? = DoctorEnvironment.procPath,
                now: Date = Date()) {
        self.home = home
        execute = DoctorEnvironment.executeTool
        trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        signal = { kill($0, $1) == 0 }
        backupRoot = home.appendingPathComponent("Library/Application Support/Thermo/Backups")
        logFile = home.appendingPathComponent("Library/Logs/Thermo/fix.log")
        self.uid = uid
        self.run = run
        self.executablePath = executablePath
        self.now = now
        if let path {
            self.path = path
        } else {
            let env = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            // A GUI app inherits a bare PATH; agents usually run from a login shell with these added.
            let common = [".local/bin", ".cargo/bin", ".bun/bin", ".npm-global/bin", ".deno/bin", "go/bin"]
                .map { home.appendingPathComponent($0).path }
                + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            var seen = Set<String>()
            self.path = (env + common).filter { seen.insert($0).inserted }
        }
    }

    public static func runTool(_ executable: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func executeTool(_ executable: String, _ args: [String], _ cwd: String?) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    public static func procPath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    // MARK: file helpers

    func url(_ relative: String) -> URL { home.appendingPathComponent(relative) }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    func json(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// `~`, `$HOME` and `${HOME}` expanded; other variables substituted from `vars`.
    func expand(_ s: String, vars: [String: String] = [:]) -> String {
        var out = s
        if out == "~" || out.hasPrefix("~/") { out = home.path + out.dropFirst() }
        var all = vars
        all["HOME"] = home.path
        for (k, v) in all {
            out = out.replacingOccurrences(of: "${\(k)}", with: v).replacingOccurrences(of: "$\(k)", with: v)
        }
        return out
    }

    /// Resolves a command the way a shell would; nil if it can't be found or executed.
    func resolve(_ command: String) -> String? {
        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        for dir in path {
            let p = dir + "/" + command
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Display a path relative to home.
    func short(_ path: String) -> String {
        path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }
}

/// Splits a shell command into words, honouring quotes; enough to find the program a hook runs.
enum Shell {
    static func words(_ s: String) -> [String] {
        var words: [String] = []
        var cur = ""
        var quote: Character?
        var inWord = false
        var it = s.makeIterator()
        while let c = it.next() {
            if c == "$", quote != "'" {
                // $(…) stays one piece of the word, whatever quotes it contains.
                var look = it
                if look.next() == "(" {
                    it = look
                    cur += "$("
                    var depth = 1
                    var inner: Character?
                    while depth > 0, let d = it.next() {
                        cur.append(d)
                        if let q = inner { if d == q { inner = nil } }
                        else if d == "'" || d == "\"" { inner = d }
                        else if d == "(" { depth += 1 }
                        else if d == ")" { depth -= 1 }
                    }
                    inWord = true
                    continue
                }
            }
            if let q = quote {
                if c == q { quote = nil } else if c == "\\" && q == "\"", let n = it.next() { cur.append(n) } else { cur.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c; inWord = true
            } else if c == "\\" {
                if let n = it.next() { cur.append(n) }; inWord = true
            } else if c == " " || c == "\t" || c == "\n" {
                if inWord { words.append(cur); cur = ""; inWord = false }
            } else if ";|&()<>".contains(c) {
                if inWord { words.append(cur); cur = ""; inWord = false }
                words.append(String(c))
            } else {
                cur.append(c); inWord = true
            }
        }
        if inWord { words.append(cur) }
        return words
    }

    static let builtins: Set<String> = [
        "[", "[[", "test", "true", "false", "exit", "echo", "printf", "cd", "export", "if", "then", "else", "fi",
        "exec", "command", "eval", "set", "read", "return", "source", ".", "!", "{", "}", "do", "done", "while", "for",
    ]

    static let separators: Set<String> = [";", "|", "&", "(", ")", "<", ">"]

    /// Programs a command line starts, skipping `VAR=value` prefixes, builtins and `sh -c` wrappers (whose script is parsed recursively).
    static func programs(_ command: String) -> [String] {
        let w = words(command)
        var out: [String] = []
        var atStart = true
        var i = 0
        while i < w.count {
            let t = w[i]
            i += 1
            if t == ">" || t == "<" { i += 1; continue }  // redirect target is a file, not a program
            if separators.contains(t) { atStart = true; continue }
            guard atStart else { continue }
            if t.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil { continue }
            if builtins.contains(t) { if t != "exec" && t != "command" { atStart = false }; continue }
            if ["sh", "bash", "zsh", "/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/env"].contains(t) {
                if i < w.count && w[i] == "-c" && i + 1 < w.count {
                    out += programs(w[i + 1])
                    i += 2
                    atStart = false
                }
                continue
            }
            out.append(t)
            atStart = false
        }
        return out
    }

    /// A command that checks for its program before running it, or swallows failure.
    static func isGuarded(_ command: String) -> Bool {
        let c = command.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        return c.contains("[ -x") || c.contains("[ -f") || c.contains("[ -n") || c.contains("[ -e")
            || c.contains("command -v") || c.contains("|| true") || c.contains("|| :") || c.contains("exit 0")
    }
}
