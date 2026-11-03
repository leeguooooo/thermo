import XCTest
@testable import CleanKit

final class LocalAITests: XCTestCase {
    func testPicksSmallChatModel() {
        XCTAssertEqual(LocalAI.pickModel(["claude/claude-opus-5-5", "claude/claude-haiku-5-5", "codex/gpt-6-luna"]), "claude/claude-haiku-5-5")
        XCTAssertEqual(LocalAI.pickModel(["gpt-image-2", "text-embedding-3", "codex/gpt-6-luna"]), "codex/gpt-6-luna")
        XCTAssertEqual(LocalAI.pickModel(["llama3:8b"]), "llama3:8b")
        XCTAssertNil(LocalAI.pickModel(["nomic-embed-text"]))
    }

    func testParsesJSONEvenInsideFences() {
        let a = LocalAI.parse("```json\n{\"verdict\":\"keep\",\"reason\":\"Photos library.\",\"how\":\"\"}\n```", source: "x")
        XCTAssertEqual(a?.verdict, .keep)
        XCTAssertEqual(a?.reason, "Photos library.")
        XCTAssertNil(a?.how)
        let b = LocalAI.parse(#"{"verdict":"DELETE","reason":"Rebuilt.","how":"xcrun simctl delete unavailable"}"#, source: "x")
        XCTAssertEqual(b?.verdict, .delete)
        XCTAssertEqual(b?.how, "xcrun simctl delete unavailable")
    }

    func testPlainTextOrUnknownVerdictIsCautious() {
        XCTAssertEqual(LocalAI.parse("It depends on whether you still use it.", source: "x")?.verdict, .careful)
        XCTAssertEqual(LocalAI.parse(#"{"verdict":"maybe","reason":"?"}"#, source: "x")?.verdict, .careful)
        XCTAssertNil(LocalAI.parse("  \n", source: "x"))
    }

    func testFactsUseTildeAndCapNames() {
        let q = LocalAIQuestion(title: "Devices", path: "/Users/u/Library/Developer/CoreSimulator/Devices", bytes: 1_000_000,
                                note: "Old simulators", children: (1...25).map { "d\($0)" }, blocked: "in use", home: "/Users/u")
        let f = q.facts
        XCTAssertTrue(f.contains("Path: ~/Library/Developer/CoreSimulator/Devices"))
        XCTAssertFalse(f.contains("/Users/u/"))
        XCTAssertTrue(f.contains("d20, … (5 more)"))
        XCTAssertFalse(f.contains("d21"))
        XCTAssertTrue(f.contains("Thermo will not remove it: in use"))
    }

    func testDiscoveryOnlyAsksLoopback() async {
        StubProtocol.seen = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let found = await LocalAI.discover(home: "/nonexistent", session: URLSession(configuration: config))
        XCTAssertEqual(found, .http(name: "Ollama", base: URL(string: "http://127.0.0.1:11434/v1")!, model: "qwen3:4b"))
        XCTAssertFalse(StubProtocol.seen.isEmpty)
        XCTAssertTrue(StubProtocol.seen.allSatisfy { $0.host == "127.0.0.1" })
    }
}

/// magpie is not running; Ollama answers with one model.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var seen: [URL] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.seen.append(url)
        guard url.port == 11434 else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let body = Data(#"{"data":[{"id":"nomic-embed-text"},{"id":"qwen3:4b"}]}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
