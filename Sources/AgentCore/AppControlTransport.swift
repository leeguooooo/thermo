import Foundation
import Darwin

public struct AppControlRequest: Codable, Sendable {
    public var schema = 1
    public let id: UUID
    public let action: String
    public let arguments: [String: String]
    public let dryRun: Bool
    public init(action: String, arguments: [String: String] = [:], dryRun: Bool = false) {
        id = UUID(); self.action = action; self.arguments = arguments; self.dryRun = dryRun
    }
}
public struct AppControlResponse: Codable, Sendable {
    public var schema = 1
    public let id: UUID
    public let succeeded: Bool
    public let values: [String: String]
    public let issue: String?
    public init(request: AppControlRequest, succeeded: Bool, values: [String: String] = [:], issue: String? = nil) {
        id = request.id; self.succeeded = succeeded; self.values = values; self.issue = issue
    }
}

/// A same-UID, private local channel. It accepts only a bounded typed request, never shell text.
/// A lost response is unconfirmed; clients must query state and never retry a mutation automatically.
public enum AppControlTransport {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }
    public static var directory: URL {
        // Foundation rewrites /private/tmp and /private/var home aliases. Canonicalize only
        // the trusted home root; explicit control-directory arguments still reject all links.
        let home = NSHomeDirectory()
        guard let pointer = realpath(home,nil) else { return URL(fileURLWithPath:home + "/Library/Application Support/Thermo/Control") }
        defer { free(pointer) }
        return URL(fileURLWithPath:String(cString:pointer) + "/Library/Application Support/Thermo/Control")
    }
    static let limit = 65_536
    // Capture results can contain bounded script logs; requests and all other operations retain 64 KiB.
    static func responseLimit(_ action:String)->Int { ["capture.run","capture.action","capture.status","capture.cancel","capture.actions"].contains(action) ? 4*1024*1024 : limit }
    static func path(_ directory: URL) -> String { directory.appendingPathComponent("app.sock").path }
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure("App control socket path is too long.") }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    static func owned(_ path: String, kind: mode_t) throws -> stat {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == kind,
              st.st_mode & 0o077 == 0 else { throw Failure("App control path has unsupported ownership, permissions or type.") }
        return st
    }
    static func secureDirectory(_ directory: URL, create: Bool) throws {
        let path = directory.path
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw Failure("Invalid control directory.") }
        // Never follow a replaced parent directory into another location.
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            var st = stat()
            if lstat(current, &st) == 0 {
                guard st.st_mode & S_IFMT == S_IFDIR else { throw Failure("Control directory ancestors must be real directories.") }
            } else {
                guard errno == ENOENT, create, mkdir(current, 0o700) == 0 else { throw Failure("A compatible Thermo.app is not running or its control directory is unavailable.") }
            }
        }
        _ = try owned(path, kind: mode_t(S_IFDIR))
    }
    static func descriptor(timeout: Int) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("Cannot create local control socket.") }
        var value = timeval(tv_sec: timeout, tv_usec: 0), noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }
    public static func peerAuditToken(_ fd: Int32) throws -> Data {
        var token = audit_token_t(), size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd,SOL_LOCAL,LOCAL_PEERTOKEN,&token,&size) == 0, size == MemoryLayout<audit_token_t>.size else { throw Failure("Cannot verify the local peer audit token.") }
        return withUnsafeBytes(of:&token) { Data($0) }
    }
    static func peer(_ fd: Int32) throws {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw Failure("App control peer is not the current user.") }
    }
    static func receive<T: Decodable>(_ type: T.Type, fd: Int32, timeout: TimeInterval = 3, maximum:Int = limit) throws -> T {
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while data.count <= maximum {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            var readiness = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
            guard remaining > 0, poll(&readiness,1,Int32(min(300_000,max(1,remaining * 1000)))) > 0 else { throw Failure("Control frame timed out; delivery is unconfirmed. Query status before another action.") }
            let n = recv(fd, &bytes, bytes.count, 0)
            guard n > 0 else { throw Failure("App control response is unavailable or timed out. Delivery may be unconfirmed; query status before another action.") }
            data.append(contentsOf: bytes.prefix(n))
            if let newline = data.firstIndex(of: 10) {
                guard newline == data.count - 1, data.count <= maximum else { throw Failure("Invalid control frame.") }
                return try JSONDecoder().decode(type, from: data.prefix(newline))
            }
        }
        throw Failure("Control frame exceeds its limit.")
    }
    static func send<T: Encodable>(_ value: T, fd: Int32, maximum:Int = limit) throws {
        var data = try JSONEncoder().encode(value); data.append(10)
        guard data.count <= maximum else { throw Failure("Control frame exceeds its limit.") }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                guard n > 0 else { throw Failure("Control response delivery is unconfirmed.") }; offset += n
            }
        }
    }
    public static func request(_ request: AppControlRequest, directory: URL = directory, timeout: Int = 15, authorizeServer: @Sendable (Data) -> Bool = { _ in true }) throws -> AppControlResponse {
        guard (1...300).contains(timeout) else { throw Failure("Control timeout must be 1…300 seconds.") }
        try secureDirectory(directory, create: false)
        let path = path(directory); _ = try owned(path, kind: mode_t(S_IFSOCK))
        let fd = try descriptor(timeout: timeout); defer { close(fd) }
        var addr = try address(path)
        let result = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw Failure("No compatible Thermo.app control listener is available. Start or update the App, then query status.") }
        try peer(fd)
        guard authorizeServer(try peerAuditToken(fd)) else { throw Failure("App server signature is not authorized. No request was sent.") }
        try send(request, fd: fd)
        let reply = try receive(AppControlResponse.self, fd: fd, timeout:TimeInterval(timeout),maximum:responseLimit(request.action))
        guard reply.schema == 1, reply.id == request.id else { throw Failure("App control reply does not match the request; outcome is unconfirmed.") }
        return reply
    }
}

public final class AppControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AppControlRequest, @escaping @Sendable (AppControlResponse) -> Void) -> Void
    private let fd: Int32
    private let socketPath: String
    private let identity: ino_t
    private var source: DispatchSourceRead?
    private let slots = DispatchSemaphore(value: 8)
    public init(directory: URL = AppControlTransport.directory, authorize: @escaping @Sendable (Data) -> Bool = { _ in true }, handler: @escaping Handler) throws {
        try AppControlTransport.secureDirectory(directory, create: true)
        socketPath = AppControlTransport.path(directory)
        var st = stat()
        if lstat(socketPath, &st) == 0 {
            _ = try AppControlTransport.owned(socketPath, kind: mode_t(S_IFSOCK))
            // Preserve an existing live server even in an isolated QA process.
            let probe = try AppControlTransport.descriptor(timeout: 1); defer { close(probe) }
            var addr = try AppControlTransport.address(socketPath)
            let result = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result != 0, errno == ECONNREFUSED else { throw AppControlTransport.Failure("An app control listener already exists or cannot be verified.") }
            let again = try AppControlTransport.owned(socketPath, kind: mode_t(S_IFSOCK))
            guard again.st_ino == st.st_ino, unlink(socketPath) == 0 else { throw AppControlTransport.Failure("Control socket changed; keep it.") }
        } else if errno != ENOENT { throw AppControlTransport.Failure("Cannot inspect the control socket.") }
        let listeningFD = try AppControlTransport.descriptor(timeout: 3)
        fd = listeningFD
        var addr = try AppControlTransport.address(socketPath)
        let result = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listeningFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { close(fd); throw AppControlTransport.Failure("Cannot bind app control socket.") }
        guard chmod(socketPath, 0o600) == 0, listen(fd, 8) == 0, lstat(socketPath, &st) == 0 else {
            close(fd); unlink(socketPath); throw AppControlTransport.Failure("Cannot protect app control socket.")
        }
        identity = st.st_ino
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let client = accept(self.fd, nil, nil)
            guard client >= 0 else { return }
            guard self.slots.wait(timeout: .now()) == .success else { close(client); return }
            DispatchQueue.global(qos: .userInitiated).async {
                defer { close(client); self.slots.signal() }
                var timeout = timeval(tv_sec: 3, tv_usec: 0), noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                do {
                    try AppControlTransport.peer(client)
                    let token = try AppControlTransport.peerAuditToken(client)
                    let request = try AppControlTransport.receive(AppControlRequest.self, fd: client)
                    guard request.schema == 1 else { throw AppControlTransport.Failure("Unsupported control schema.") }
                    guard authorize(token) else {
                        try AppControlTransport.send(AppControlResponse(request:request,succeeded:false,issue:"Caller signature does not match the companion Thermo CLI. Use a compatible signed CLI; no action executed."),fd:client)
                        return
                    }
                    let done = DispatchSemaphore(value: 0)
                    let box = ReplyBox()
                    handler(request) { response in box.set(response); done.signal() }
                    guard done.wait(timeout: .now() + 295) == .success, let reply = box.get() else { return }
                    try AppControlTransport.send(reply, fd: client,maximum:AppControlTransport.responseLimit(request.action))
                } catch { /* no mutation is retried after invalid or lost delivery */ }
            }
        }
        source.resume()
    }
    deinit {
        source?.cancel(); close(fd)
        var st = stat()
        if lstat(socketPath, &st) == 0, st.st_ino == identity { unlink(socketPath) }
    }
    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock(); private var value: AppControlResponse?
        func set(_ reply: AppControlResponse) { lock.lock(); defer { lock.unlock() }; if value == nil { value = reply } }
        func get() -> AppControlResponse? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
