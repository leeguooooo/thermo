import XCTest
import ModuleKit
@testable import WasmHost

final class ModuleViewTests: XCTestCase {
    func page(_ sections: String) -> Data { Data(#"{"version":1,"title":"T","sections":[\#(sections)]}"#.utf8) }

    func testEveryKindRoundTrips() throws {
        let view = ModuleView(title: "T", sections: [
            .list(id: "l", title: "L", rows: [.init(id: "a", title: "A", value: "1", symbol: "star", action: "open.a")]),
            .detail(title: nil, fields: [.init(label: "K", value: "V")]),
            .form(id: "f", title: nil, fields: [.init(id: "t", label: "Text", input: .text, value: .text("x")),
                                                 .init(id: "n", label: "N", input: .number, value: .number(2)),
                                                 .init(id: "b", label: "B", input: .toggle, value: .toggle(true)),
                                                 .init(id: "c", label: "C", input: .choice, value: .text("x"), options: [.init(id: "x", title: "X")])],
                  submit: .init(action: "save", title: "Save")),
            .card(title: "C", value: "3", caption: nil, symbol: "cpu", actions: [.init(action: "refresh", title: "Refresh")]),
        ])
        XCTAssertEqual(try ModuleView.read(try JSONEncoder().encode(view)), view)
        let item = ModuleView(menuBarItem: .init(title: "M", value: "1", symbol: "cpu", action: "tap"))
        XCTAssertEqual(try ModuleView.read(try JSONEncoder().encode(item)), item)
    }

    func testRefusesAnythingOutsideTheSchema() {
        let refused: [(String, Data)] = [
            ("unknown type", page(#"{"type":"html","id":"x"}"#)),
            ("newer version", Data(#"{"version":2,"sections":[]}"#.utf8)),
            ("page and item at once", Data(#"{"version":1,"sections":[],"menuBarItem":{"title":"x"}}"#.utf8)),
            ("neither", Data(#"{"version":1}"#.utf8)),
            ("uppercase id", page(#"{"type":"list","id":"Bad","rows":[]}"#)),
            ("url as action", page(#"{"type":"card","title":"x","actions":[{"action":"https://x","title":"go"}]}"#)),
            ("symbol with slash", page(#"{"type":"card","title":"x","symbol":"../etc"}"#)),
            ("control characters", page(#"{"type":"card","title":"a\u0007b"}"#)),
            ("bidi override", page(#"{"type":"card","title":"a‮b"}"#)),
            ("duplicate rows", page(#"{"type":"list","id":"l","rows":[{"id":"a","title":"x"},{"id":"a","title":"y"}]}"#)),
            ("choice value not an option", page(#"{"type":"form","id":"f","fields":[{"id":"c","label":"C","input":"choice","value":"z","options":[{"id":"x","title":"X"}]}],"submit":{"action":"s","title":"S"}}"#)),
            ("value of the wrong kind", page(#"{"type":"form","id":"f","fields":[{"id":"c","label":"C","input":"toggle","value":"yes"}],"submit":{"action":"s","title":"S"}}"#)),
            ("empty form", page(#"{"type":"form","id":"f","fields":[],"submit":{"action":"s","title":"S"}}"#)),
            ("too many actions", page(#"{"type":"card","title":"x","actions":[\#(Array(repeating: #"{"action":"a","title":"A"}"#, count: 5).joined(separator: ","))]}"#)),
            ("too many rows", page(#"{"type":"list","id":"l","rows":[\#((0...ModuleView.Limits.rows).map { #"{"id":"r\#($0)","title":"x"}"# }.joined(separator: ","))]}"#)),
            ("title too long", page(#"{"type":"card","title":"\#(String(repeating: "x", count: ModuleView.Limits.title + 1))"}"#)),
            ("oversized document", Data(repeating: 0x20, count: ModuleView.Limits.documentBytes + 1)),
            ("not JSON", Data("<html>".utf8)),
        ]
        for (what, data) in refused {
            XCTAssertThrowsError(try ModuleView.read(data), what) { XCTAssertTrue($0 is ModuleView.Invalid, what) }
        }
    }

    func manifest() -> ModuleManifest {
        ModuleManifest(id: "dev.example.views", name: "Views", summary: "", symbol: "cube", version: "1",
                       entries: [.init(id: "main", kind: .page, title: "Main", scene: "main"), .init(id: "menu", kind: .menuBarItem, title: "M", scene: "menu")])
    }

    func testModuleCallsUseSortedRequestsAndMatchTheEntryKind() async throws {
        let calls = Calls()
        let module = DeclarativeModule(manifest: manifest()) { function, input in
            await calls.add(function, input)
            if function == DeclarativeModule.action { return .init(status: 0, output: Data()) }
            let request = try JSONDecoder().decode(ModuleViewRequest.self, from: input)
            let body = request.scene == "menu" ? #"{"version":1,"menuBarItem":{"title":"M"}}"# : #"{"version":1,"sections":[]}"#
            return .init(status: 0, output: Data(body.utf8))
        }
        _ = try await module.render(scene: "main", language: "zh-Hans")
        let first = await calls.all.first
        XCTAssertEqual(first?.0, "thermo_render")
        XCTAssertEqual(first.map { String(decoding: $0.1, as: UTF8.self) }, #"{"language":"zh-Hans","scene":"main"}"#)
        XCTAssertNotNil(try await module.render(scene: "menu", language: "en").menuBarItem)
        // An empty action output means "render again".
        _ = try await module.perform("save", values: ["n": .number(1)], scene: "main", language: "en")
        let names = await calls.all.map(\.0)
        XCTAssertEqual(names.suffix(2), ["thermo_action", "thermo_render"])
    }

    func testWrongKindStatusAndMissingRendererAreReported() async {
        let wrong = DeclarativeModule(manifest: manifest()) { _, _ in .init(status: 0, output: Data(#"{"version":1,"menuBarItem":{"title":"M"}}"#.utf8)) }
        await assertFailure(try await wrong.render(scene: "main", language: "en")) { if case .invalid = $0 { true } else { false } }
        let failing = DeclarativeModule(manifest: manifest()) { _, _ in .init(status: 7, output: Data()) }
        await assertFailure(try await failing.render(scene: "main", language: "en")) { $0 == .status(7) }
        let missing = DeclarativeModule(manifest: manifest()) { _, _ in throw WasmHost.Failure.trapped("no command function thermo_render") }
        await assertFailure(try await missing.render(scene: "main", language: "en")) { $0 == .noRenderer }
        let gone = DeclarativeModule(manifest: manifest()) { _, _ in throw WasmHost.Failure.timedOut }
        await assertFailure(try await gone.render(scene: "main", language: "en")) { $0 == .host(.timedOut) }
    }

    func assertFailure(_ work: @autoclosure () async throws -> ModuleView, _ match: (DeclarativeModule.Failure) -> Bool, line: UInt = #line) async {
        do { _ = try await work(); XCTFail("expected a failure", line: line) }
        catch { XCTAssertTrue((error as? DeclarativeModule.Failure).map(match) ?? false, "\(error)", line: line) }
    }
}

actor Calls {
    var all: [(String, Data)] = []
    func add(_ f: String, _ d: Data) { all.append((f, d)) }
}
