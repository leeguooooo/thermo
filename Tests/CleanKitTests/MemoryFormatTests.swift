import XCTest
import CleanKit

final class MemoryFormatTests: XCTestCase {
    func testInstalledMemoryUsesBinaryUnitsConsistently() {
        XCTAssertEqual(MemoryFormat.string(bytes: UInt64(16) << 30), "16.0 GiB")
        XCTAssertEqual(MemoryFormat.string(kibibytes: 16 * 1_048_576), "16.0 GiB")
        XCTAssertEqual(MemoryFormat.string(mebibytes: 16 * 1024), "16.0 GiB")
        XCTAssertEqual(MemoryFormat.string(kibibytes: 512 * 1024), "512 MiB")
    }

    func testBrowserHeapChangesPreserveFractionsAndSigns() {
        XCTAssertEqual(MemoryFormat.string(mebibytes: 12.5), "12.5 MiB")
        XCTAssertEqual(MemoryFormat.string(mebibytes: -12.5), "-12.5 MiB")
        XCTAssertEqual(MemoryFormat.string(mebibytes: Double.nan), "—")
        XCTAssertEqual(MemoryFormat.string(mebibytes: Double.greatestFiniteMagnitude), "—")
    }

    func testMissingAndExtremeCountersDoNotOverflow() {
        XCTAssertEqual(MemoryFormat.string(kibibytes: -1), "0 B")
        XCTAssertEqual(MemoryFormat.string(bytes: 0), "0 B")
        XCTAssertTrue(MemoryFormat.string(kibibytes: Int.max).hasSuffix("TiB"))
        XCTAssertTrue(MemoryFormat.string(mebibytes: Int.max).hasSuffix("TiB"))
    }
}
