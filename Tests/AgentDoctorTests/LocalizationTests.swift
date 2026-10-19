@testable import ThermoL10n
import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    /// Decode the simple escapes used by ordinary Swift string literals in the source scan.
    /// One pass keeps a literal backslash followed by n distinct from a newline escape.
    func literalKey(_ raw: String) throws -> String {
        var characters = raw.makeIterator(), key = ""
        while let character = characters.next() {
            guard character == "\\" else { key.append(character); continue }
            let escaped = try XCTUnwrap(characters.next(), "unfinished Swift escape")
            switch escaped {
            case "n": key.append("\n")
            case "r": key.append("\r")
            case "t": key.append("\t")
            case "0": key.append("\0")
            case "\\", "\"", "'": key.append(escaped)
            default: throw NSError(domain: "Unsupported Swift literal escape", code: 1)
            }
        }
        return key
    }

    func testLiteralKeyDecodesEscapesWithoutTurningLiteralBackslashNIntoNewline() throws {
        XCTAssertEqual(try literalKey(#"first\nsecond"#), "first\nsecond")
        XCTAssertEqual(try literalKey(#"first\\nsecond"#), #"first\nsecond"#)
        XCTAssertEqual(try literalKey(#"\"quoted\"\t\r\0"#), "\"quoted\"\t\r\0")
        XCTAssertThrowsError(try literalKey(#"\u{41}"#))
    }

    /// Every tr("…") literal in Sources/ must have a zh-Hans entry, or Chinese users see English mixed in.
    func testEveryKeyIsTranslated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let re = try NSRegularExpression(pattern: #"\btr\("((?:[^"\\]|\\.)*)""#)
        var missing: [String] = []
        var count = 0
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" && !url.path.contains("/ThermoL10n/") {
            let text = try String(contentsOf: url, encoding: .utf8)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                // Undo Swift escapes so the literal matches the runtime key.
                let raw = String(text[Range(m.range(at: 1), in: text)!])
                let key = try literalKey(raw)
                count += 1
                if zhHans[key] == nil { missing.append("\(url.lastPathComponent): \(key)") }
            }
        }
        XCTAssertGreaterThan(count, 100)
        XCTAssertEqual(missing, [], "add these to Sources/ThermoL10n/ZhHans.swift")
    }

    /// Translations keep the same placeholders, so String(format:) never reads a missing argument.
    func testPlaceholdersMatch() throws {
        let re = try NSRegularExpression(pattern: #"%(\d+\$)?[@%]"#)
        func placeholders(_ s: String) -> [String] {
            re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.sorted()
        }
        for (en, zh) in zhHans {
            XCTAssertEqual(placeholders(en), placeholders(zh), "placeholders differ for: \(en)")
        }
    }

    func testLanguageSelection() {
        XCTAssertEqual(L10n.parse("zh-Hans-CN"), .simplifiedChinese)
        XCTAssertEqual(L10n.parse("zh_TW"), .simplifiedChinese)
        XCTAssertEqual(L10n.parse("en-GB"), .english)
        XCTAssertNil(L10n.parse("fr"))
        L10n.override = .simplifiedChinese
        XCTAssertEqual(tr("%1$@ errors", "3"), "3 个错误")
        L10n.override = .english
        XCTAssertEqual(tr("%1$@ errors", "3"), "3 errors")
        L10n.override = nil
    }
}
