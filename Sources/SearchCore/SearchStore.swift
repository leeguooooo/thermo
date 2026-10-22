import Foundation
import CSQLite

public struct SearchFailure: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// One private, rebuildable local index. Each process has its own connection; WAL permits CLI readers.
public final class SearchStore: @unchecked Sendable {
    public let directory: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public static var defaultDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["THERMO_SEARCH_DATA_DIR"], path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Thermo/Search", isDirectory: true)
    }
    public init(directory: URL = SearchStore.defaultDirectory) throws {
        let directory = URL(fileURLWithPath: SearchPaths.canonical(directory.path), isDirectory: true)
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("index.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = errorText(); if let db { sqlite3_close(db) }; db = nil; throw SearchFailure(message)
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            sqlite3_busy_timeout(db, 1500)
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF;")
            // No virtual-table triggers: trusted_schema=OFF is kept for the entire connection.
            try execute("""
                CREATE TABLE IF NOT EXISTS entries(path TEXT PRIMARY KEY,root TEXT NOT NULL,name TEXT NOT NULL,
                    kind TEXT NOT NULL,alternate TEXT NOT NULL,modified REAL NOT NULL,name_key TEXT NOT NULL,
                    words TEXT NOT NULL,grams TEXT NOT NULL,seen TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS entries_root ON entries(root);
                CREATE INDEX IF NOT EXISTS entries_name ON entries(name_key);
                CREATE INDEX IF NOT EXISTS entries_kind ON entries(kind);
                CREATE TABLE IF NOT EXISTS roots(path TEXT PRIMARY KEY,indexed REAL NOT NULL DEFAULT 0,
                    count INTEGER NOT NULL DEFAULT 0,issue TEXT,available INTEGER NOT NULL DEFAULT 1);
                CREATE TABLE IF NOT EXISTS item_preferences(path TEXT PRIMARY KEY,alias TEXT,favorite INTEGER NOT NULL DEFAULT 0,
                    visits INTEGER NOT NULL DEFAULT 0,opened REAL NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS configuration(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                CREATE VIRTUAL TABLE IF NOT EXISTS filenames USING fts5(path UNINDEXED,words,grams,tokenize='unicode61 remove_diacritics 2');
                PRAGMA user_version=1;
                """)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { if let db { sqlite3_close(db) } }
    private func errorText() -> String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the search index." }
    private func synchronized<T>(_ action: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try action() }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SearchFailure(errorText()) }
    }
    private func statement(_ sql: String, _ values: [String?] = []) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw SearchFailure(errorText()) }
        for (i, value) in values.enumerated() {
            let result = value.map { sqlite3_bind_text(s, Int32(i + 1), $0, -1, transient) } ?? sqlite3_bind_null(s, Int32(i + 1))
            if result != SQLITE_OK { sqlite3_finalize(s); throw SearchFailure(errorText()) }
        }
        return s
    }
    private func run(_ sql: String, _ values: [String?] = []) throws {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw SearchFailure(errorText()) }
    }
    private func text(_ s: OpaquePointer, _ index: Int32) -> String { sqlite3_column_text(s, index).map { String(cString: $0) } ?? "" }
    private func transaction<T>(_ action: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try action(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    public func preferences() throws -> SearchPreferences {
        try synchronized {
            let s = try statement("SELECT value FROM configuration WHERE key='preferences'"); defer { sqlite3_finalize(s) }
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { return SearchPreferences() }
            guard rc == SQLITE_ROW else { throw SearchFailure(errorText()) }
            return try JSONDecoder().decode(SearchPreferences.self, from: Data(text(s, 0).utf8))
        }
    }
    public func savePreferences(_ preferences: SearchPreferences) throws {
        try synchronized {
            var preferences = preferences
            guard preferences.roots.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { throw SearchFailure("Choose an absolute folder path.") }
            preferences.roots = preferences.roots.map(SearchPaths.canonical)
            let roots = preferences.roots
            for (i, root) in roots.enumerated() {
                guard root.hasPrefix("/"), !root.contains("\0") else { throw SearchFailure("Choose an absolute folder path.") }
                if roots.enumerated().contains(where: { j, other in j != i && SearchPaths.isWithin(root, root: other) }) {
                    throw SearchFailure("These search folders overlap. Keep the outer folder or choose separate folders.")
                }
            }
            guard preferences.excludedPatterns.count <= 256, preferences.excludedPatterns.allSatisfy({ $0.count <= 512 }) else { throw SearchFailure("Too many or overly long exclusion patterns.") }
            try transaction {
                let old = try rootsReport()
                for root in old where !roots.contains(root.path) {
                    try removeEntries(root: root.path)
                    try run("DELETE FROM roots WHERE path=?", [root.path])
                }
                for root in roots { try run("INSERT OR IGNORE INTO roots(path) VALUES(?)", [root]) }
                try run("INSERT INTO configuration(key,value) VALUES('preferences',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)])
            }
        }
    }
    public func rootsReport() throws -> [SearchRoot] {
        try synchronized {
            let s = try statement("SELECT path,indexed,count,issue,available FROM roots ORDER BY path"); defer { sqlite3_finalize(s) }
            var result: [SearchRoot] = []
            while true {
                let rc = sqlite3_step(s); if rc == SQLITE_DONE { return result }; guard rc == SQLITE_ROW else { throw SearchFailure(errorText()) }
                result.append(SearchRoot(path: text(s, 0), indexedAt: sqlite3_column_double(s, 1), count: Int(sqlite3_column_int64(s, 2)),
                                         issue: sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : text(s, 3), available: sqlite3_column_int(s, 4) != 0))
            }
        }
    }
    public func markRoot(_ root: String, count: Int, issue: String?, available: Bool, completed: Bool) throws {
        let root = SearchPaths.canonical(root)
        try synchronized {
            let s = try statement("SELECT count(*) FROM entries WHERE root=?", [root]); defer { sqlite3_finalize(s) }
            guard sqlite3_step(s) == SQLITE_ROW else { throw SearchFailure(errorText()) }
            let indexedCount = sqlite3_column_int64(s, 0)
            try run("INSERT INTO roots(path,count,issue,available,indexed) VALUES(?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET count=excluded.count,issue=excluded.issue,available=excluded.available,indexed=CASE WHEN ?='1' THEN excluded.indexed ELSE roots.indexed END",
                    [root, String(indexedCount), issue, available ? "1" : "0", String(completed ? Date().timeIntervalSince1970 : 0), completed ? "1" : "0"])
        }
    }
    public func upsert(_ items: [SearchItem], root: String, generation: String) throws {
        let root = SearchPaths.canonical(root)
        try synchronized { try transaction {
            for item in items {
                let path = SearchPaths.entry(item.path)
                let key = SearchText.normalized(item.name), latin = SearchText.latin(item.name)
                let words = SearchText.normalized(item.name + " " + item.path) + (latin == key ? "" : " " + latin)
                let grams = SearchText.grams(item.name) + (latin == key ? "" : " " + SearchText.grams(latin))
                let old = try statement("SELECT name_key,words,grams FROM entries WHERE path=?", [path])
                let changed: Bool
                if sqlite3_step(old) == SQLITE_ROW { changed = text(old, 0) != key || text(old, 1) != words || text(old, 2) != grams } else { changed = true }
                sqlite3_finalize(old)
                let alternate = String(decoding: try JSONEncoder().encode(item.alternateNames), as: UTF8.self)
                try run("INSERT INTO entries(path,root,name,kind,alternate,modified,name_key,words,grams,seen) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET root=excluded.root,name=excluded.name,kind=excluded.kind,alternate=excluded.alternate,modified=excluded.modified,name_key=excluded.name_key,words=excluded.words,grams=excluded.grams,seen=excluded.seen",
                        [path, root, item.name, item.kind.rawValue, alternate, String(item.modified), key, words, grams, generation])
                if changed {
                    try run("DELETE FROM filenames WHERE rowid=(SELECT rowid FROM entries WHERE path=?)", [path])
                    if item.kind != .application { try run("INSERT INTO filenames(rowid,path,words,grams) SELECT rowid,path,words,grams FROM entries WHERE path=?", [path]) }
                }
            }
        } }
    }
    private func removeEntries(root: String, unseen: String? = nil, scope: String? = nil) throws {
        var whereClause = "root=?" + (unseen == nil ? "" : " AND seen!=?")
        var bindings: [String?] = [root] + (unseen.map { [$0] } ?? [])
        if let scope {
            whereClause += " AND (path=? OR (path>=? AND path<?))"
            let prefix = SearchPaths.childrenPrefix(scope)
            bindings += [scope, prefix, prefix + "\u{10ffff}"]
        }
        try run("DELETE FROM filenames WHERE rowid IN (SELECT rowid FROM entries WHERE \(whereClause))", bindings)
        try run("DELETE FROM entries WHERE \(whereClause)", bindings)
    }
    /// A failed/cancelled scan never deletes unseen entries. Reconcile deletion only with complete coverage.
    public func finishScan(root: String, generation: String, complete: Bool, scope: String? = nil) throws {
        try synchronized { if complete { try transaction { try removeEntries(root: SearchPaths.canonical(root), unseen: generation, scope: scope.map(SearchPaths.canonical)) } } }
    }
    public func replaceApplications(_ items: [SearchItem], complete: Bool) throws {
        let generation = UUID().uuidString
        try upsert(items, root: "@applications", generation: generation)
        try finishScan(root: "@applications", generation: generation, complete: complete)
        try synchronized {
            try run("INSERT INTO configuration(key,value) VALUES('applicationsComplete',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [complete ? "1" : "0"])
        }
    }
    public func setAlias(_ alias: String?, for path: String) throws {
        let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (alias?.count ?? 0) <= 80 else { throw SearchFailure("Use an alias of at most 80 characters.") }
        try synchronized { try run("INSERT INTO item_preferences(path,alias) VALUES(?,?) ON CONFLICT(path) DO UPDATE SET alias=excluded.alias", [path, alias?.isEmpty == true ? nil : alias]) }
    }
    public func setFavorite(_ favorite: Bool, for path: String) throws {
        try synchronized { try run("INSERT INTO item_preferences(path,favorite) VALUES(?,?) ON CONFLICT(path) DO UPDATE SET favorite=excluded.favorite", [path, favorite ? "1" : "0"]) }
    }
    public func recordOpen(_ path: String) throws {
        try synchronized { try run("INSERT INTO item_preferences(path,visits,opened) VALUES(?,1,?) ON CONFLICT(path) DO UPDATE SET visits=min(100000,item_preferences.visits+1),opened=excluded.opened", [path, String(Date().timeIntervalSince1970)]) }
    }
    public func clearHistory() throws { try synchronized { try run("UPDATE item_preferences SET visits=0,opened=0") } }
    public func query(_ query: String, limit: Int = 50, cancellation: SearchCancellation? = nil) throws -> SearchResponse {
        guard query.count <= 256, !query.contains("\0"), (1...200).contains(limit) else { throw SearchFailure("Use a query of at most 256 characters and a limit from 1 to 200.") }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var response = try synchronized {
            let roots = try rootsReport()
            let context = cancellation.map { Unmanaged.passRetained($0).toOpaque() }
            if let context {
                sqlite3_progress_handler(db, 1000, { pointer in
                    guard let pointer else { return 0 }
                    return Unmanaged<SearchCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled ? 1 : 0
                }, context)
            }
            defer {
                if let context { sqlite3_progress_handler(db, 0, nil, nil); Unmanaged<SearchCancellation>.fromOpaque(context).release() }
            }
            let state = try statement("SELECT value FROM configuration WHERE key='applicationsComplete'")
            let applicationsComplete = sqlite3_step(state) == SQLITE_ROW && text(state, 0) == "1"
            sqlite3_finalize(state)
            let columns = "e.path,e.name,e.kind,e.alternate,e.modified,p.alias,coalesce(p.favorite,0),coalesce(p.visits,0),coalesce(p.opened,0)"
            let join = " LEFT JOIN item_preferences p ON p.path=e.path LEFT JOIN roots r ON r.path=e.root "
            var sql = "SELECT \(columns) FROM entries e\(join)WHERE (e.root='@applications' OR r.available=1) AND (e.kind='application'"
            var bindings: [String?] = []
            if let expression = SearchText.matchExpression(q) {
                sql += " OR e.path IN (SELECT path FROM filenames WHERE filenames MATCH ?) OR p.alias IS NOT NULL)"
                bindings.append(expression)
            } else { sql += " OR p.favorite=1 OR p.visits>0)" }
            // Work bound is explicit in the response; exact/prefix intent is inspected before broader candidates.
            sql += " ORDER BY CASE WHEN p.alias=? COLLATE NOCASE THEN 0 WHEN e.name_key=? THEN 1 WHEN e.name_key>=? AND e.name_key<? THEN 2 WHEN p.alias IS NOT NULL THEN 3 WHEN e.kind='application' THEN 4 ELSE 5 END,p.favorite DESC,p.opened DESC,e.modified DESC LIMIT 20001"
            let key = SearchText.normalized(q); bindings += [key, key, key, key + "\u{10ffff}"]
            let s = try statement(sql, bindings); defer { sqlite3_finalize(s) }
            var items: [SearchItem] = [], truncated = false
            while true {
                if cancellation?.isCancelled == true { throw CancellationError() }
                let rc = sqlite3_step(s); if rc == SQLITE_DONE { break }
                if rc == SQLITE_INTERRUPT, cancellation?.isCancelled == true { throw CancellationError() }
                guard rc == SQLITE_ROW else { throw SearchFailure(errorText()) }
                if items.count == 20000 { truncated = true; break }
                let alternate = (try? JSONDecoder().decode([String].self, from: Data(text(s, 3).utf8))) ?? []
                items.append(SearchItem(path: text(s, 0), name: text(s, 1), kind: SearchItemKind(rawValue: text(s, 2)) ?? .file,
                                        alternateNames: alternate, modified: sqlite3_column_double(s, 4), alias: sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : text(s, 5),
                                        favorite: sqlite3_column_int(s, 6) != 0, visits: Int(sqlite3_column_int64(s, 7)), lastOpened: sqlite3_column_double(s, 8)))
            }
            var issues = roots.compactMap(\.issue)
            if !applicationsComplete { issues.append("Applications are not fully indexed. Refresh the search index.") }
            if truncated { issues.append("There are more matching files. Refine your search.") }
            return SearchResponse(query: query, items: items, roots: roots,
                                  complete: applicationsComplete && !truncated && roots.allSatisfy { $0.available && $0.indexedAt > 0 && $0.issue == nil }, issues: issues, limited: truncated)
        }
        response.items = SearchRanking.sorted(response.items, query: q, limit: limit, cancellation: cancellation)
        if cancellation?.isCancelled == true { throw CancellationError() }
        return response
    }
}
