import XCTest
@testable import CleanKit

final class ToolCleanupTests: XCTestCase {
    func testParsesHomebrewDryRun() {
        let out = """
        Warning: Skipping ttyd: most recent version 1.7.7_14 not installed
        Would remove: /opt/homebrew/Cellar/dnsmasq/2.92 (9 files, 572.4KB)
        Would remove: /opt/homebrew/Cellar/node/22.1.0 (2,345 files, 81.2MB)
        Would remove: /Users/me/Library/Caches/Homebrew/downloads/abc--x.tar.gz (1.5GB)
        Would remove (broken link): /opt/homebrew/bin/openapi-lark
        ==> This operation would free approximately 1.6GB of disk space.
        """
        let found = ToolCleanup.parseBrewDryRun(out)
        XCTAssertEqual(found.map(\.path), ["/opt/homebrew/Cellar/dnsmasq/2.92", "/opt/homebrew/Cellar/node/22.1.0",
                                           "/Users/me/Library/Caches/Homebrew/downloads/abc--x.tar.gz"])
        XCTAssertEqual(found.map(\.bytes), [572_400, 81_200_000, 1_500_000_000])
        XCTAssertEqual(ToolCleanup.parseSize("12B"), 12)
        XCTAssertEqual(ToolCleanup.parseSize("junk"), 0)
    }
}
