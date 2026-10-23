import XCTest
@testable import thermo

final class CaptureCommandTests:XCTestCase {
    func testCommandParsingBuildsTypedRequestsWithoutRunningCode() throws {
        let args=try Args(["capture","run","--code","return 42;","--json","--dry-run"])
        try CommandContract.validate(args)
        let request=try CaptureCommand.request(rest:Array(args.positionals.dropFirst()),args:args)
        XCTAssertEqual(request.action,"capture.run");XCTAssertEqual(request.arguments,["source":"return 42;"]);XCTAssertTrue(request.dryRun)
        let cancel=try Args(["capture","cancel",UUID().uuidString]);XCTAssertNoThrow(try CaptureCommand.request(rest:Array(cancel.positionals.dropFirst()),args:cancel))
        XCTAssertThrowsError(try CaptureCommand.request(rest:["cancel"],args:Args([])))
        XCTAssertThrowsError(try CaptureCommand.request(rest:["status","wrong"],args:Args([])))
    }
    func testScriptFileAndArgumentExclusivityAreValidated() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("script.js");try Data("return true;".utf8).write(to:file)
        let args=try Args(["capture","run","--file",file.path]);XCTAssertEqual(try CaptureCommand.request(rest:["run"],args:args).arguments["source"],"return true;")
        XCTAssertThrowsError(try CaptureCommand.request(rest:["run"],args:Args(["--file",file.path,"--code","return 1;"])))
        XCTAssertThrowsError(try CaptureCommand.request(rest:["run"],args:Args(["--code",String(repeating:"a",count:16385)])))
        let link=root.appendingPathComponent("link.js");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        XCTAssertThrowsError(try CaptureCommand.request(rest:["run"],args:Args(["--file",link.path])))
    }
    func testHelpAndContractExposeCaptureAndRejectUnrelatedOptions() throws {
        XCTAssertTrue(CommandHelp.text(for:["capture"]).contains("capture run"));XCTAssertTrue(CommandHelp.text(for:["capture"]).contains("--file"))
        XCTAssertThrowsError(try CommandContract.validate(Args(["capture","status","--code","never"])))
        XCTAssertNoThrow(try CommandContract.validate(Args(["capture","action","status","--dry-run","--control-directory","/private/tmp/test"])))
    }
}
