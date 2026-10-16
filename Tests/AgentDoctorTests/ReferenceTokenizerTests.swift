import XCTest
@testable import AgentDoctor

final class ReferenceTokenizerTests: XCTestCase {
    struct Corpus: Decodable {
        struct Vector: Decodable { var encoding: TextEncoding; var text: String; var tokens: [UInt32] }
        var vectors: [Vector]
    }
    func testMatchesOfficialOrdinaryTokenIDsAcrossLanguagesSchemasAndWhitespace() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tokenizer-reference-vectors.json")
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: file))
        let cl = try ReferenceTokenizer.cl100k.get(), o = try ReferenceTokenizer.o200k.get()
        for (index, vector) in corpus.vectors.enumerated() {
            XCTAssertEqual(try (vector.encoding == .cl100k ? cl : o).tokens(vector.text), vector.tokens, "vector \(index), \(vector.encoding)")
        }
    }
    func testOversizedInputsReturnUnknownInsteadOfAFakeExactCount() throws {
        let result = ReferenceTokenizer.measure(String(repeating: "x", count: 1_048_577), encoding: .o200k)
        XCTAssertNil(result.count)
        XCTAssertEqual(result.error, "input_limit")
        let longPiece = ReferenceTokenizer.measure(String(repeating: "a", count: 65_537), encoding: .o200k)
        XCTAssertNil(longPiece.count)
        XCTAssertEqual(longPiece.error, "piece_limit")
    }
}
