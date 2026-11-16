import Foundation
import XCTest
@testable import ModuleKit

final class ModuleRecentAccessTests:XCTestCase {
    func testRecentRequestsIncludeRepeatedTargetsAndMergePrivateWorkers()throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-recent-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:home)}
        let log=ModuleAccessLog(home:home.path),module="com.example.module",worker="com.example.worker"
        log.record(.init(module:module,capability:"files.read",operation:"first",targets:["/fixture"],outcome:.allowed))
        log.record(.init(module:worker,capability:"files.read",operation:"worker",targets:["/fixture"],outcome:.denied))
        log.record(.init(module:module,capability:"files.read",operation:"again",targets:["/fixture"],outcome:.declined))
        XCTAssertEqual(log.recent(modules:[module,worker,module]).map(\.operation),["again","worker","first"])
        XCTAssertEqual(log.recent(modules:[module,worker],limit:2).map(\.outcome),[.declined,.denied])
        XCTAssertTrue(log.recent(modules:[module],limit:0).isEmpty)
    }
    func testForeignModuleRowInAStreamIsNotAttributedToItsFileOwner()throws {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-recent-owner-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:home)}
        let log=ModuleAccessLog(home:home.path),module="com.example.module"
        log.record(.init(module:module,capability:"files.read",targets:["/own"],outcome:.allowed))
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        var data=try encoder.encode(ModuleAccessRecord(module:"com.example.other",capability:"files.read",targets:["/foreign"],outcome:.allowed));data.append(10)
        let handle=try FileHandle(forWritingTo:log.url(module:module));_=try handle.seekToEnd();try handle.write(contentsOf:data);try handle.close()
        XCTAssertEqual(log.records(module:module).map(\.targets),[["/own"]])
        XCTAssertEqual(log.summary(module:module).read,["/own"])
        XCTAssertEqual(log.recent(modules:[module]).map(\.targets),[["/own"]])
    }
}
