import Foundation
import ThermoL10n

/// One inspection owns one new HTTP session. No redirects, cookies, keychain login,
/// OAuth flows, legacy endpoint discovery or request retries are performed.
final class MCPHTTP: MCPTransport {
    var stateless = false
    let url: URL
    let headers: [String: String]
    let deadline: Double
    let cancelled: () -> Bool
    var sessionID: String?
    var version: String?
    var sequence = 0
    var received = 0
    var cleanupStatus: String?
    var cleanupDetails: MCPCleanupDetails?

    init(server: MCPServer, env: DoctorEnvironment, deadline: Double) throws {
        guard let value = server.url, let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw MCPInspector.Failure(state: .unsupported, message: tr("MCP requires an HTTP or HTTPS endpoint without embedded credentials or a fragment."))
        }
        self.url = url
        var headers = server.headers
        for (key, name) in server.headerEnv {
            guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
                throw MCPInspector.Failure(state: .authenticationRequired, message: tr("A configured HTTP header environment variable is unavailable."))
            }
            headers = headers.filter { $0.key.caseInsensitiveCompare(key) != .orderedSame }
            headers[key] = value
        }
        if let token = server.bearerTokenEnv {
            guard let value = ProcessInfo.processInfo.environment[token], !value.isEmpty else {
                throw MCPInspector.Failure(state: .authenticationRequired, message: tr("The configured bearer token environment variable is unavailable."))
            }
            headers = headers.filter { $0.key.caseInsensitiveCompare("Authorization") != .orderedSame }
            headers["Authorization"] = "Bearer " + value
        }
        if let token = headers.removeValue(forKey: "bearer_token") { headers["Authorization"] = "Bearer " + token }
        for (key, value) in headers {
            guard !["mcp-session-id", "mcp-protocol-version", "mcp-method", "mcp-name", "content-length", "host", "transfer-encoding", "connection"].contains(key.lowercased()) else {
                throw MCPInspector.Failure(message: tr("Configured HTTP headers override reserved transport fields."))
            }
            guard !key.contains("\r"), !key.contains("\n"), !value.contains("\r"), !value.contains("\n") else {
                throw MCPInspector.Failure(message: tr("Configured HTTP headers contain invalid characters."))
            }
        }
        self.headers = headers
        self.deadline = deadline
        cancelled = env.cancelled
    }

    func check() throws {
        if cancelled() { throw MCPInspector.Failure(state: .cancelled, message: tr("Inspection cancelled.")) }
        if MCPInspector.clock() >= deadline { throw MCPInspector.Failure(state: .timedOut, message: tr("Inspection timed out; tool definitions are incomplete.")) }
    }
    func negotiated(_ version: String) { self.version = version }

    func makeRequest(_ method: String, message: [String: Any]?, limit: Double) throws -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(0.01, limit - MCPInspector.clock()))
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !stateless, let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let version { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        if stateless, let method = message?["method"] as? String { request.setValue(method, forHTTPHeaderField: "Mcp-Method") }
        if let message { request.httpBody = Data(try MCPInspector.json(message).utf8) }
        return request
    }

    func exchange(_ message: [String: Any], id: String?) throws -> [String: Any]? {
        try check()
        let receiver = MCPHTTPReceiver()
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: receiver, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: try makeRequest("POST", message: message, limit: deadline))
        task.resume()
        var headerRead = false
        var responseStatus: Int?
        while true {
            try check()
            let state = receiver.take()
            received += state.newBytes
            guard received <= 16_777_216 else { throw MCPInspector.Failure(message: tr("MCP response exceeded the inspection size limit; results are incomplete.")) }
            if let response = state.response, !headerRead {
                headerRead = true
                responseStatus = response.statusCode
                if response.statusCode == 401 || response.statusCode == 403 {
                    throw MCPInspector.Failure(state: .authenticationRequired, message: tr("HTTP authentication failed; no automatic login was attempted."))
                }
                guard response.statusCode == (id == nil ? 202 : 200)
                        || (stateless && id != nil && [400, 404].contains(response.statusCode)) else {
                    throw MCPInspector.Failure(message: tr("MCP endpoint returned HTTP status %1$@. No request was retried.", String(response.statusCode)))
                }
                if message["method"] as? String == "initialize", let value = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
                    guard !value.isEmpty, value.utf8.count <= 4096, value.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
                        throw MCPInspector.Failure(message: tr("MCP endpoint returned an invalid session header."))
                    }
                    sessionID = value
                }
                if id != nil {
                    let mime = response.mimeType?.lowercased() ?? ""
                    guard ["application/json", "text/event-stream"].contains(mime) else {
                        throw MCPInspector.Failure(message: tr("MCP endpoint did not return JSON or an SSE stream."))
                    }
                }
            }
            if let error = state.failure { throw error }
            if id == nil, state.totalBytes > 0 { throw MCPInspector.Failure(message: tr("HTTP notification acknowledgement must have an empty body.")) }
            for incoming in state.messages {
                guard incoming["jsonrpc"] as? String == "2.0" else { throw MCPInspector.Failure(message: tr("Invalid HTTP JSON-RPC response.")) }
                if let method = incoming["method"] as? String {
                    if let serverID = incoming["id"] {
                        guard !stateless else { throw MCPInspector.Failure(state: .unsupported, message: tr("Stateless inspection does not accept server-initiated requests. No client response was sent.")) }
                        if method == "ping" { try send(["jsonrpc": "2.0", "id": serverID, "result": [String: Any]()]) }
                        else { try send(["jsonrpc": "2.0", "id": serverID, "error": ["code": -32601, "message": "Inspector does not support this method."]]) }
                    }
                    continue
                }
                let modernHeaderError = stateless && [400, 404].contains(responseStatus ?? 0)
                    && incoming["error"] is [String: Any] && (incoming["id"] == nil || incoming["id"] is NSNull)
                guard let id, incoming["id"] as? String == id || modernHeaderError else { throw MCPInspector.Failure(message: tr("MCP response id does not match the pending request.")) }
                if let error = incoming["error"] as? [String: Any] {
                    throw MCPInspector.rpcFailure(error["code"] as? Int ?? 0, method: message["method"] as? String ?? "", stateless: stateless)
                }
                guard responseStatus == 200 else { throw MCPInspector.Failure(message: tr("MCP endpoint returned HTTP status %1$@. No request was retried.", String(responseStatus ?? 0))) }
                guard incoming["error"] == nil, let result = incoming["result"] as? [String: Any] else { throw MCPInspector.Failure(message: tr("MCP response has no valid result object.")) }
                return result
            }
            if state.done {
                if id == nil, headerRead, state.totalBytes == 0 { return nil }
                throw MCPInspector.Failure(message: tr("HTTP response ended before a complete MCP result."))
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        sequence += 1
        let id = "thermo-\(sequence)"
        return try exchange(["jsonrpc": "2.0", "id": id, "method": method, "params": params], id: id) ?? [:]
    }
    func send(_ message: [String: Any]) throws { _ = try exchange(message, id: nil) }

    func close() {
        guard !stateless, sessionID != nil else {
            if cleanupStatus == nil {
                cleanupStatus = "not_needed"
                cleanupDetails = MCPCleanupDetails(reason: "notNeeded", elapsedSeconds: 0, budgetSeconds: 0)
            }
            return
        }
        // Best-effort termination of our own newly-created session, not the server.
        let started = MCPInspector.clock()
        let budget = 0.25
        var reason = "timedOut"
        var httpStatus: Int?
        let receiver = MCPHTTPReceiver()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: receiver, delegateQueue: nil)
        defer {
            session.invalidateAndCancel(); sessionID = nil
            cleanupDetails = MCPCleanupDetails(reason: reason, httpStatusCode: httpStatus,
                                              elapsedSeconds: max(0, MCPInspector.clock() - started), budgetSeconds: budget)
        }
        let limit = started + budget
        cleanupStatus = "unconfirmed"
        guard let request = try? makeRequest("DELETE", message: nil, limit: limit) else { reason = "invalidRequest"; return }
        session.dataTask(with: request).resume()
        while true {
            let state = receiver.take()
            if let response = state.response {
                httpStatus = response.statusCode
                cleanupStatus = (200..<300).contains(response.statusCode) ? "closed" : response.statusCode == 405 ? "server_retained" : "unconfirmed"
                reason = cleanupStatus == "closed" ? "closed" : cleanupStatus == "server_retained" ? "unsupported" : "httpError"
                break
            }
            if let failure = state.failure {
                reason = failure.state == .timedOut ? "timedOut" : failure.state == .authenticationRequired ? "authenticationRequired" : "transportError"
                break
            }
            if state.done { reason = "responseMissing"; break }
            if MCPInspector.clock() >= limit { break }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
}

/// Serial delegate parses JSON/SSE incrementally; the inspection thread takes
/// batches under a lock. The byte cap applies even to comments or unfinished events.
final class MCPHTTPReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Snapshot {
        var response: HTTPURLResponse?
        var messages: [[String: Any]] = []
        var failure: MCPInspector.Failure?
        var done = false
        var totalBytes = 0
        var newBytes = 0
    }
    let lock = NSLock()
    var state = Snapshot()
    var pending = Data()
    var event = Data()
    var searchOffset = 0
    var skipLF = false

    func take() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let snapshot = state
        state.messages = []; state.newBytes = 0
        return snapshot
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            lock.lock()
            state.failure = MCPInspector.Failure(state: .authenticationRequired, message: tr("HTTP authentication failed; no automatic login was attempted."))
            lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); state.response = response as? HTTPURLResponse; lock.unlock()
        completionHandler(.allow)
    }
    func decode(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MCPInspector.Failure(message: tr("Invalid HTTP JSON-RPC response.")) }
        guard state.messages.count < 10_000 else { throw MCPInspector.Failure(message: tr("MCP response exceeded the inspection size limit; results are incomplete.")) }
        state.messages.append(object)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        state.totalBytes += data.count; state.newBytes += data.count
        guard state.totalBytes <= 8_388_608 else {
            state.failure = MCPInspector.Failure(message: tr("MCP response exceeded the inspection size limit; results are incomplete."))
            dataTask.cancel(); return
        }
        pending.append(data)
        guard state.response?.mimeType?.lowercased() == "text/event-stream" else { return }
        do {
            while !pending.isEmpty {
                if skipLF {
                    if pending.first == 10 { pending.removeFirst() }
                    skipLF = false
                    searchOffset = 0
                }
                guard let end = pending.dropFirst(searchOffset).firstIndex(where: { $0 == 10 || $0 == 13 }) else { break }
                let line = Data(pending.prefix(upTo: end))
                skipLF = pending[end] == 13
                pending.removeSubrange(...end); searchOffset = 0
                if line.isEmpty {
                    if !event.isEmpty { try decode(event); event.removeAll(keepingCapacity: true) }
                } else if line.starts(with: Data("data:".utf8)) {
                    var content = line.dropFirst(5)
                    if content.first == 32 { content = content.dropFirst() }
                    if !event.isEmpty { event.append(10) }
                    event.append(contentsOf: content)
                }
            }
            searchOffset = pending.count
        } catch {
            state.failure = MCPInspector.Failure(message: tr("Invalid HTTP JSON-RPC response.")); dataTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); defer { lock.unlock() }
        state.done = true
        guard state.failure == nil else { return }
        if let error {
            if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorTimedOut {
                state.failure = MCPInspector.Failure(state: .timedOut, message: tr("Inspection timed out; tool definitions are incomplete."))
            } else { state.failure = MCPInspector.Failure(message: tr("HTTP connection failed before a complete response.")) }
            return
        }
        if state.response?.mimeType?.lowercased() == "application/json", !pending.isEmpty {
            do { try decode(pending) }
            catch { state.failure = MCPInspector.Failure(message: tr("Invalid HTTP JSON-RPC response.")) }
        }
    }
}
