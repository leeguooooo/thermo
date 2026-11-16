import Foundation
import Darwin
import ModuleKit

/// What the kernel does for modules with what it alone may touch. The broker has already checked
/// every target against the module's manifest; these only do the work.
public enum KernelServices {
    static func answer(_ object: Any, acted: [String]? = nil) throws -> BrokerAnswer {
        BrokerAnswer(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), acted: acted)
    }
    static func bad(_ message: String) -> BrokerError { BrokerError(.failed, message) }

    // MARK: Files

    public static let maxReadBytes = 8 * 1024 * 1024
    public static let maxListed = 50_000
    /// A measurement stops counting after this many entries and says so.
    public static let maxMeasured = 2_000_000

    /// `files.read`: `list` (one folder, one level), `measure` (size of each target, all the way down),
    /// `read` (the bytes of one file, base64).
    public static let filesRead: CapabilityBroker.Handler = readFiles(authorize:{_ in})

    /// Hosts apply their protected-path rules to each node, including recursive measurements.
    public static func readFiles(authorize:@escaping @Sendable (String)throws->Void)->CapabilityBroker.Handler {
      { request in
        for target in request.targets {try authorize(target)}
        switch request.operation {
        case "list":
            guard request.targets.count == 1 else { throw bad("list takes one folder") }
            let folder = URL(fileURLWithPath: request.targets[0])
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [], options: [])
            guard urls.count <= maxListed else { throw bad("more than \(maxListed) entries") }
            let entries: [[String: Any]] = try urls.map { url in
                try authorize(url.path)
                let values = try? url.resourceValues(forKeys: Set(keys))
                var entry: [String: Any] = ["name": url.lastPathComponent,
                                            "kind": values?.isSymbolicLink == true ? "link" : values?.isDirectory == true ? "folder" : "file"]
                if let size = values?.totalFileAllocatedSize ?? values?.fileSize { entry["bytes"] = size }
                if let date = values?.contentModificationDate { entry["modified"] = date.timeIntervalSince1970 }
                return entry
            }
            return try answer(["entries": entries.sorted { ($0["name"] as! String) < ($1["name"] as! String) }])
        case "measure":
            var results: [[String: Any]] = []
            var budget = maxMeasured
            for target in request.targets {
                let (bytes, count, complete) = try measure(target, budget: &budget,authorize:authorize)
                results.append(["path": target, "bytes": bytes, "items": count, "complete": complete])
            }
            return try answer(["results": results])
        case "read":
            guard request.targets.count == 1 else { throw bad("read takes one file") }
            let path = request.targets[0]
            let fd=try openRegularFile(path)
            let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            defer{try? file.close()}
            var statValue=stat()
            guard fstat(fd,&statValue)==0,statValue.st_mode&S_IFMT==S_IFREG else{throw bad("read takes a regular file")}
            guard statValue.st_size>=0,statValue.st_size<=maxReadBytes else{throw bad("file is larger than \(maxReadBytes) bytes")}
            let data=try file.read(upToCount:maxReadBytes+1) ?? Data()
            guard data.count<=maxReadBytes else{throw bad("file grew beyond \(maxReadBytes) bytes")}
            return try answer(["base64": data.base64EncodedString()])
        default:
            throw bad("files.read has no operation \(request.operation.isEmpty ? "(none)" : request.operation)")
        }
    }

    }

    /// Allocated bytes under `path`, links not followed. `complete` is false when the entry budget ran out.
    static func measure(_ path: String, budget: inout Int,authorize:(String)throws->Void) throws -> (bytes: Int64, items: Int, complete: Bool) {
        try authorize(path)
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return (0, 0, true) }
        if !isDirectory.boolValue {
            return (Int64((try? url.resourceValues(forKeys: Set(keys)))?.totalFileAllocatedSize ?? 0), 1, true)
        }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [], options: [], errorHandler: { _, _ in true }) else { return (0, 0, false) }
        var bytes: Int64 = 0, items = 0
        for case let item as URL in walker {
            guard budget > 0 else { return (bytes, items, false) }
            budget -= 1; items += 1
            try authorize(item.path)
            var info=stat()
            if lstat(item.path,&info)==0,info.st_mode&S_IFMT==S_IFLNK {walker.skipDescendants();continue}
            if let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                bytes += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return (bytes, items, true)
    }

    /// Resolve each component through directory descriptors. A link swapped in after broker
    /// validation cannot redirect a read; nonblocking open also keeps FIFOs from stalling a worker.
    private static func openRegularFile(_ path:String)throws->Int32 {
        let parts=path.split(separator:"/").map(String.init)
        guard path.hasPrefix("/"),!parts.isEmpty,!parts.contains("."),!parts.contains("..") else{throw bad("read takes an absolute file path")}
        var fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC)
        guard fd>=0 else{throw bad("cannot open filesystem root")}
        for (index,part) in parts.enumerated() {
            let last=index==parts.count-1
            let next=openat(fd,part,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK|(last ? 0:O_DIRECTORY))
            let code=errno;close(fd)
            guard next>=0 else {
                if code==ELOOP || code==ENOTDIR {throw BrokerError(.denied,"the path changed while reading")}
                throw bad("cannot open the requested file")
            }
            fd=next
        }
        return fd
    }

    /// `files.delete`: `trash` moves each target to the Trash. Nothing is ever removed outright here.
    /// Each target is looked at again just before it is moved: if the folder it sits in now resolves
    /// somewhere else than what was checked, it is left alone.
    public static let filesDelete: CapabilityBroker.Handler = { request in
        try trashFiles(request) { target in
            var destination: NSURL?
            try FileManager.default.trashItem(at: URL(fileURLWithPath: target), resultingItemURL: &destination)
            return (destination as URL?, nil)
        }
    }

    /// Synchronous move adapter lets the app journal the actual OS destination in the same request.
    /// A warning reports failed bookkeeping after a successful move, never a failed move.
    public static func trashFiles(_ request: BrokerRequest,
                                  move: (String) throws -> (destination: URL?, warning: String?)) throws -> BrokerAnswer {
        guard request.operation == "trash" else { throw bad("files.delete has no operation \(request.operation.isEmpty ? "(none)" : request.operation)") }
        var results: [[String: Any]] = []
        var moved = 0
        for target in request.targets {
            let url = URL(fileURLWithPath: target)
            var result: [String: Any] = ["path": target]
            let parent = url.deletingLastPathComponent().path
            if CapabilityBroker.resolved(parent) != parent { result["status"] = "failed"; result["detail"] = "the folder changed while deleting" }
            else if (try? url.checkResourceIsReachable()) != true, (try? FileManager.default.destinationOfSymbolicLink(atPath: target)) == nil {
                result["status"] = "skipped"; result["detail"] = "not there"
            } else {
                do {
                    let movedItem = try move(target)
                    result["status"] = "done"; moved += 1
                    if let trashed = movedItem.destination { result["trashed"] = trashed.path }
                    if let warning = movedItem.warning { result["detail"] = warning }
                } catch { result["status"] = "failed"; result["detail"] = error.localizedDescription }
            }
            results.append(result)
        }
        if moved == 0, !request.targets.isEmpty, results.contains(where: { $0["status"] as? String == "failed" }) {
            throw bad(results.compactMap { $0["detail"] as? String }.first ?? "nothing could be moved to the Trash")
        }
        // Only what really went to the Trash is logged as deleted.
        return try answer(["results": results], acted: results.filter { $0["status"] as? String == "done" }.compactMap { $0["path"] as? String })
    }

    // MARK: Network

    public static let maxResponseBytes = 16 * 1024 * 1024

    /// `network.connect`: `fetch` makes one HTTPS request for the module. The broker checked the host
    /// the module named; this checks that the URL really goes there, and refuses to follow a
    /// redirect to a host the module's manifest does not cover.
    public static func networkConnect(session: URLSessionConfiguration = .ephemeral) -> CapabilityBroker.Handler {
        { request in
            guard request.operation == "fetch" else { throw bad("network.connect has no operation \(request.operation.isEmpty ? "(none)" : request.operation)") }
            guard request.targets.count == 1, let text = request.payload["url"]?.string, let url = URL(string: text),
                  url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { throw bad("fetch takes one host and an https url") }
            guard host == request.targets[0] else { throw BrokerError(.denied, "the url goes to \(host), not \(request.targets[0])") }
            if let refusal = Self.egressRefusal(url) { throw BrokerError(.denied, refusal) }
            var call = URLRequest(url: url, timeoutInterval: 30)
            call.httpMethod = request.payload["method"]?.string ?? "GET"
            if case let .object(headers)? = request.payload["headers"] {
                for (name, value) in headers { if let value = value.string { call.setValue(value, forHTTPHeaderField: name) } }
            }
            if let body = request.payload["body"]?.string { call.httpBody = Data(body.utf8) }
            let guardian = RedirectGuard(manifest: request.manifest)
            let urlSession = URLSession(configuration: session)
            defer { urlSession.finishTasksAndInvalidate() }
            let (data, response) = try await urlSession.data(for: call, delegate: guardian)
            if let refused = guardian.refused { throw BrokerError(.denied, "redirect to \(refused), which \(request.manifest.id) did not declare") }
            guard data.count <= maxResponseBytes else { throw bad("response is larger than \(maxResponseBytes) bytes") }
            let http = response as? HTTPURLResponse
            return try answer(["status": http?.statusCode ?? 0, "base64": data.base64EncodedString(),
                               "headers": (http?.allHeaderFields as? [String: String]) ?? [:]])
        }
    }

    /// Rules every outgoing module request follows, whatever the manifest says: the default HTTPS port,
    /// a DNS name rather than an IP literal, no credentials in the URL, nothing on this Mac or the local network.
    public static func egressRefusal(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return "the url has no host" }
        if let port = url.port, port != 443 { return "port \(port) is not allowed; modules connect on 443 only" }
        if url.user != nil || url.password != nil { return "credentials in the url are not allowed" }
        if Capability.isIPLiteral(host) { return "\(host) is an IP address; modules connect to declared host names only" }
        if Capability.isLocalHost(host) { return "\(host) is on this Mac or the local network" }
        return nil
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let manifest: ModuleManifest
        var refused: String?
        init(manifest: ModuleManifest) { self.manifest = manifest }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let host = request.url?.host?.lowercased() ?? ""
            let allowed = request.url?.scheme?.lowercased() == "https" && request.url.map { KernelServices.egressRefusal($0) == nil } == true
                && manifest.capabilities.contains { $0.covers(Capability(.networkConnect, scope: host), home: "/") }
            if !allowed { refused = host }
            completionHandler(allowed ? request : nil)
        }
    }
}

/// The kernel end of a module's XPC connection: every message goes to that module's broker.
public final class BrokerKernel: NSObject, KernelXPC {
    private let broker: CapabilityBroker
    public init(broker: CapabilityBroker) { self.broker = broker }
    public func request(_ capability: String, payload: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        Task {
            switch await broker.request(capability, payload: payload) {
            case .success(let data): reply(data, nil)
            case .failure(let error): reply(nil, error.description)
            }
        }
    }
}
