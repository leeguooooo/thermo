import XCTest
@testable import ModuleKit

final class ModuleAccessGroupTests: XCTestCase {
    func testFeatureActivityIncludesOnlyItsPrivateWorkersWithoutDuplicateTargetsOrRequests() throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:home)}
        let log=ModuleAccessLog(home:home.path),owner="com.example.search",worker="com.example.preview"
        log.record(.init(module:owner,capability:"files.read",targets:["/selected.md"],outcome:.allowed))
        log.record(.init(module:worker,capability:"files.read",targets:["/image.png","/selected.md"],outcome:.allowed))
        log.record(.init(module:worker,capability:"files.read",targets:["/outside.png"],outcome:.denied))
        log.record(.init(module:"com.example.other",capability:"files.read",targets:["/unrelated"],outcome:.allowed))
        let summary=log.summary(modules:[worker,owner,worker])
        XCTAssertEqual(summary.read,["/selected.md","/image.png"])
        XCTAssertEqual(summary.denied,1)
        XCTAssertEqual(log.summary(module:owner).read,["/selected.md"])
        XCTAssertEqual(log.summary(module:owner).denied,0)
    }
}
