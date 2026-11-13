@testable import CleanKit
import Foundation
import XCTest

/// "AI pick": the AI's verdicts come back by key, and only items Thermo would let the user tick in
/// bulk, that are not risky and that the AI called "delete", get ticked.
final class LocalAICleanTests: XCTestCase {
    func item(_ id: String, safety: Safety = .safe, bytes: Int64 = 1_000, blocked: String? = nil) -> CleanItem {
        CleanItem(id: id, category: .projects, title: id, safety: safety, bytes: bytes, files: 1, lastUsed: nil,
                  paths: ["/Users/me/src/\(id)"], blocked: blocked)
    }

    func question(_ items: [CleanItem]) -> LocalAICleanQuestion {
        LocalAICleanQuestion(category: "Project build output", items: items.map(LocalAICleanQuestion.Item.init),
                             now: Date(timeIntervalSince1970: 1_000_000), home: "/Users/me")
    }

    func testFactsKeyEachItemBiggestFirstAndHideTheHomeFolder() {
        let q = question([item("small", bytes: 10), item("big", bytes: 5_000)])
        XCTAssertEqual(q.items.map(\.id), ["big", "small"])
        XCTAssertTrue(q.facts.contains("[k1] big"))
        XCTAssertTrue(q.facts.contains("[k2] small"))
        XCTAssertTrue(q.facts.contains("~/src/big"))
        XCTAssertFalse(q.facts.contains("/Users/me"))
    }

    func testVerdictsMapBackByKeyAndUnknownKeysAreDropped() throws {
        let q = question([item("a", bytes: 3), item("b", bytes: 2)])
        let raw = """
        Sure: {"summary": "ok", "items": [{"key": "k1", "verdict": "delete", "reason": "rebuilds"},
          {"key": "[K2]", "verdict": "Careful", "reason": "used today"}, {"key": "k9", "verdict": "delete", "reason": "made up"}]}
        """
        let a = try XCTUnwrap(LocalAI.parsePick(raw, question: q, source: "test"))
        XCTAssertEqual(a.verdicts["a"]?.verdict, .delete)
        XCTAssertEqual(a.verdicts["b"]?.verdict, .careful)
        XCTAssertEqual(a.verdicts.count, 2)
        XCTAssertNil(LocalAI.parsePick("no json here", question: q, source: "test"))
    }

    func testOnlySafeToDeleteBulkSelectableNonRiskyItemsAreTicked() throws {
        let items = [item("yes"), item("careful"), item("risky", safety: .risky), item("locked", blocked: "protected"),
                     CleanItem(id: "project/large/x", category: .projects, title: "x", safety: .review, bytes: 9, files: 1, lastUsed: nil, paths: ["/x"])]
        let q = question(items)
        let keys = Dictionary(uniqueKeysWithValues: q.items.enumerated().map { ($1.id, "k\($0 + 1)") })
        let verdict = { (id: String, v: String) in #"{"key": "\#(keys[id]!)", "verdict": "\#(v)", "reason": "r"}"# }
        let raw = #"{"items": ["# + [verdict("yes", "delete"), verdict("careful", "careful"), verdict("risky", "delete"),
                                    verdict("locked", "delete"), verdict("project/large/x", "delete")].joined(separator: ",") + "]}"
        let a = try XCTUnwrap(LocalAI.parsePick(raw, question: q, source: "test"))
        XCTAssertEqual(LocalAI.picks(a, items: items), ["yes"])
    }
}
