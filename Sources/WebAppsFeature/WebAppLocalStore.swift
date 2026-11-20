import Foundation
import WebKit

/// Answers the parts of Puter's SDK that Time Tracking uses (`fs` and `kv`) from a folder on this Mac.
/// The page sees a signed-in local user; nothing is sent anywhere.
@MainActor final class WebAppLocalStore: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "thermoStore"
    let directory: URL
    private var files: URL { directory.appendingPathComponent("files", isDirectory: true) }
    private var kvFile: URL { directory.appendingPathComponent("kv.json") }

    init(directory: URL) { self.directory = directory }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        do { replyHandler(try handle(message.body as? [String: Any] ?? [:]), nil) }
        catch { replyHandler(nil, (error as? StoreError)?.message ?? error.localizedDescription) }
    }

    struct StoreError: Error { let message: String }
    static let missing = StoreError(message: "subject_does_not_exist: no such file")

    func handle(_ body: [String: Any]) throws -> Any? {
        let op = body["op"] as? String ?? ""
        switch op {
        case "write":
            let file = try path(body["path"])
            let data: Data
            if let text = body["text"] as? String { data = Data(text.utf8) }
            else if let b64 = body["base64"] as? String, let decoded = Data(base64Encoded: b64) { data = decoded }
            else { throw StoreError(message: "Nothing to write") }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return nil
        case "read":
            let file = try path(body["path"])
            guard let data = try? Data(contentsOf: file) else { throw Self.missing }
            return data.base64EncodedString()
        case "delete":
            let file = try path(body["path"])
            guard FileManager.default.fileExists(atPath: file.path) else { throw Self.missing }
            try FileManager.default.removeItem(at: file)
            return nil
        case "mkdir":
            try FileManager.default.createDirectory(at: try path(body["path"]), withIntermediateDirectories: true)
            return nil
        case "readdir":
            let dir = try path(body["path"])
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { throw Self.missing }
            return names.sorted().map { name -> [String: Any] in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir)
                return ["name": name, "is_dir": isDir.boolValue]
            }
        case "stat":
            let file = try path(body["path"])
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { throw Self.missing }
            return ["name": file.lastPathComponent, "size": (attributes[.size] as? Int) ?? 0,
                    "is_dir": attributes[.type] as? FileAttributeType == .typeDirectory,
                    "modified": ((attributes[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970]
        case "kvGet":
            return try kv()[key(body["key"])] ?? NSNull()
        case "kvSet":
            var values = try kv()
            values[try key(body["key"])] = body["value"] ?? NSNull()
            try saveKV(values)
            return true
        case "kvDel":
            var values = try kv()
            values[try key(body["key"])] = nil
            try saveKV(values)
            return true
        default:
            throw StoreError(message: "Unsupported operation \(op)")
        }
    }

    /// Puter paths look like `~/AppData/…` or `/user/…`; all of them map inside the app's folder.
    func path(_ raw: Any?) throws -> URL {
        guard var value = raw as? String, !value.isEmpty else { throw StoreError(message: "Missing path") }
        if value.hasPrefix("~") { value.removeFirst() }
        let parts = value.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !parts.contains("..") else { throw StoreError(message: "Path leaves the app's folder") }
        return parts.reduce(files) { $0.appendingPathComponent($1) }
    }
    private func key(_ raw: Any?) throws -> String {
        guard let key = raw as? String, !key.isEmpty else { throw StoreError(message: "Missing key") }
        return key
    }
    private func kv() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: kvFile) else { return [:] }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    private func saveKV(_ values: [String: Any]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]).write(to: kvFile, options: .atomic)
    }

    /// Installed before the page's own scripts. The Puter SDK script itself is blocked as a network load.
    static let shim = #"""
    (() => {
      const call = (op, args) => window.webkit.messageHandlers.thermoStore.postMessage(Object.assign({ op }, args));
      const encode = async (data) => {
        if (typeof data === 'string') return { text: data };
        const blob = data instanceof Blob ? data : new Blob([data]);
        const bytes = new Uint8Array(await blob.arrayBuffer());
        let s = '';
        for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        return { base64: btoa(s) };
      };
      const decode = (b64) => {
        const bin = atob(b64), bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        return new Blob([bytes]);
      };
      const join = (dir, name) => dir.replace(/\/$/, '') + '/' + name;
      const fs = {
        async write(path, data) { await call('write', Object.assign({ path }, await encode(data))); return { path, name: path.split('/').pop() }; },
        async read(path) { return decode(await call('read', { path })); },
        async delete(path) { await call('delete', { path }); },
        async mkdir(path) { await call('mkdir', { path }); return { path }; },
        async readdir(path) { return (await call('readdir', { path })).map(e => ({ name: e.name, path: join(path, e.name), is_dir: e.is_dir })); },
        async stat(path) { return call('stat', { path }); },
      };
      const kv = {
        get: (key) => call('kvGet', { key }),
        set: (key, value) => call('kvSet', { key, value }),
        del: (key) => call('kvDel', { key }),
        MAX_KEY_SIZE: 1024, MAX_VALUE_SIZE: 400 * 1024,
      };
      const user = { uuid: 'thermo-local', username: 'local' };
      const puter = {
        env: 'web', appID: 'thermo-local', fs, kv,
        auth: { isSignedIn: () => true, getUser: async () => user, signIn: async () => user, signOut: () => {} },
        ui: {}, print: () => {},
      };
      Object.defineProperty(window, 'puter', { value: puter, writable: false, configurable: false });
    })();
    """#
}
