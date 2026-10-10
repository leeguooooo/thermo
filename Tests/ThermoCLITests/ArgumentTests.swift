import XCTest
@testable import thermo

final class ArgumentTests: XCTestCase {
    func testFanRPMRejectsNonfiniteNumericInputButKeepsExplicitMax() throws {
        XCTAssertEqual(try App.fanRPM("MAX"), .infinity)
        XCTAssertEqual(try App.fanRPM("min"), 0)
        XCTAssertEqual(try App.fanRPM("3500.5"), 3500.5)
        for invalid in ["nan", "inf", "1e999", "-1", "invalid"] {
            XCTAssertThrowsError(try App.fanRPM(invalid))
        }
    }

    func testLargeFiniteRPMCanBeReportedWithoutIntegerOverflow() throws {
        let rpm = try App.fanRPM("1e100")
        XCTAssertEqual(App.fanRPMText(rpm), "1e+100 rpm")
        XCTAssertEqual(App.fanRPMText(3500.5), "3500.5 rpm")
    }
    func testBooleanFlagAssignmentsCannotAccidentallySkipConfirmation() {
        for flag in ["--yes=false", "--yes=true", "--trash=false", "--json=false"] {
            XCTAssertThrowsError(try Args([flag]), flag)
        }
        XCTAssertTrue(try Args(["--yes"]).has("yes"))
    }

    func testIntervalsMustBeFiniteAndPositive() throws {
        for value in ["inf", "nan", "1e999", "0", "-1"] {
            let args = try Args(["--interval", value])
            XCTAssertThrowsError(try args.double("interval"), value)
        }
        XCTAssertEqual(try Args(["-i", "0.5s"]).double("interval"), 0.5)
    }

    func testTerminalTimeoutHandlesHugeAndInvalidValues() {
        XCTAssertEqual(RawTerminal.pollTimeout(Double.greatestFiniteMagnitude), 100)
        XCTAssertEqual(RawTerminal.pollTimeout(.infinity), 100)
        XCTAssertEqual(RawTerminal.pollTimeout(.nan), 100)
        XCTAssertEqual(RawTerminal.pollTimeout(-1), 1)
        XCTAssertEqual(RawTerminal.pollTimeout(0.01), 10)
    }

    func testTinyTerminalsCannotProduceNegativeRowCounts() {
        XCTAssertEqual(Watch.contentRows(height: 1), 0)
        XCTAssertEqual(Watch.contentRows(height: 2), 0)
        XCTAssertEqual(Watch.contentRows(height: 24), 22)
    }

    func testAgentSettingsUseTheSameDefaultsKeysAsTheApp() throws {
        let slowdown = try XCTUnwrap(SettingsCommand.all.first { $0.key == "slowdown-alerts" })
        let unnamed = try XCTUnwrap(SettingsCommand.all.first { $0.key == "unnamed-sensors" })
        XCTAssertEqual(slowdown.defaultsKey, "slowdownAlerts")
        XCTAssertEqual(unnamed.defaultsKey, "unnamedSensors")
        XCTAssertEqual(slowdown.parse("off") as? Bool, false)
        XCTAssertEqual(unnamed.parse("on") as? Bool, true)
        XCTAssertNil(unnamed.parse("maybe"))
    }
}
