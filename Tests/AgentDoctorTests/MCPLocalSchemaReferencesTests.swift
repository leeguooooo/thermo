import XCTest
@testable import AgentDoctor

final class MCPLocalSchemaReferencesTests: XCTestCase {
    func testMissingTargetIsReportedWithoutRewritingOrExportingReferences() throws {
        let schema: [String: Any] = ["type": "object", "properties": ["value": ["$ref": "#/$defs/PRIVATE_TARGET"]]]
        let tool: [String: Any] = ["name": "owned", "description": "Owned fixture", "inputSchema": schema]
        let before = try MCPInspector.json(tool)
        let row = try MCPInspector.footprint(tool)
        XCTAssertEqual(MCPLocalSchemaReferences.unresolvedCount(in: schema), 1)
        XCTAssertEqual(row.issues.count, 1)
        XCTAssertEqual(row.definition.bytes, before.utf8.count)
        XCTAssertEqual(row.inputSchema.bytes, try MCPInspector.json(schema).utf8.count)
        XCTAssertEqual(try MCPInspector.json(tool), before)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(row), as: UTF8.self).contains("PRIVATE_TARGET"))
    }
    func testEscapedAndPercentEncodedPointersAndBooleanTargetsResolve() {
        let schema: [String: Any] = ["type": "object", "$defs": ["A/B~C": false, "你好": ["type": "string"], "~1": [:]],
            "properties": ["a": ["$ref": "#/$defs/A~1B~0C"], "b": ["$ref": "#/$defs/%E4%BD%A0%E5%A5%BD"], "c": ["$ref": "#/$defs/~01"], "d": ["$ref": "#"]]]
        XCTAssertEqual(MCPLocalSchemaReferences.unresolvedCount(in: schema), 0)
    }
    func testRecursiveAndArrayTargetsDoNotRequireReferenceExpansion() {
        let schema: [String: Any] = ["type": "object", "$defs": ["Node": ["$ref": "#/$defs/Node"]],
            "allOf": [["type": "object"]], "properties": ["a": ["$ref": "#/allOf/0"], "b": ["$ref": "#/allOf/01"], "c": ["$ref": "#/allOf/-"], "d": ["$ref": "#/allOf/9"]]]
        XCTAssertEqual(MCPLocalSchemaReferences.unresolvedCount(in: schema), 3)
    }
    func testPointerMemberNamesAreNotUnicodeNormalized() {
        let schema: [String: Any] = ["type": "object", "$defs": ["e\u{301}": ["type": "string"]],
            "properties": ["value": ["$ref": "#/$defs/é"]]]
        XCTAssertEqual(MCPLocalSchemaReferences.unresolvedCount(in: schema), 1)
    }
    func testAnnotationsAreDataNotSchemaLocationsAndBooleanSchemasStayLegal() throws {
        let data: [String: Any] = ["$ref": "#/MISSING", "$id": "urn:example:annotation"]
        let schema: [String: Any] = ["type": "object", "properties": ["forbidden": false], "additionalProperties": false,
            "default": data, "examples": [data], "enum": [data], "const": data]
        XCTAssertEqual(MCPLocalSchemaReferences.unresolvedCount(in: schema), 0)
        XCTAssertTrue(try MCPInspector.footprint(["name": "owned", "description": "Owned", "inputSchema": schema]).issues.isEmpty)
    }
    func testIdentifiersAnchorsRemoteAndMalformedPointersAreDeferred() {
        for key in ["$id", "id"] {
            let schema: [String: Any] = ["type": "object", "properties": ["value": ["$ref": "#/$defs/Missing"]], "$defs": ["other": [key: "urn:example:resource"]]]
            XCTAssertNil(MCPLocalSchemaReferences.unresolvedCount(in: schema))
        }
        for ref in ["#anchor", "https://example.invalid/schema.json#/Missing", "#/%ZZ", "#/bad~2escape", "#/trailing~"] {
            XCTAssertEqual(MCPLocalSchemaReferences.unresolvedCount(in: ["type": "object", "$ref": ref]), 0)
        }
    }
    func testSchemaLocationsAreVisitedIncludingOutputSchemaAndLegacyTuples() throws {
        let broken: [String: Any] = ["$ref": "#/missing"]
        let schema: [String: Any] = ["type": "object", "items": [broken], "if": broken, "then": broken,
            "dependentSchemas": ["x": broken], "dependencies": ["y": broken, "z": ["name"]]]
        XCTAssertEqual(MCPLocalSchemaReferences.unresolvedCount(in: schema), 5)
        let row = try MCPInspector.footprint(["name": "owned", "description": "Owned", "inputSchema": ["type": "object"], "outputSchema": schema])
        XCTAssertEqual(row.issues.count, 1)
        XCTAssertTrue(row.issues[0].contains("outputSchema"))
    }
    func testBudgetsSkipWholeCheckRatherThanClaimMissingTargetsAcrossUnknownScopes() {
        var deep: [String: Any] = ["$id": "urn:example:deep"]
        for _ in 0..<70 { deep = ["not": deep] }
        XCTAssertNil(MCPLocalSchemaReferences.unresolvedCount(in: ["$ref": "#/missing", "allOf": [deep]]))
        let many = (0..<130).map { _ in ["$ref": "#/missing"] }
        XCTAssertNil(MCPLocalSchemaReferences.unresolvedCount(in: ["allOf": many]))
        let nodes = (0..<4100).map { _ in ["type": "object"] }
        XCTAssertNil(MCPLocalSchemaReferences.unresolvedCount(in: ["allOf": nodes]))
    }
}
