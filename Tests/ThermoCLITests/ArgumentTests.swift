import XCTest
import ThermoL10n
@testable import thermo

final class ArgumentTests: XCTestCase {
    func testMCPProtocolSelectionIsExplicitAndLimitedToInspections() throws {
        for arguments in [["agents","inspect","owned","--protocol","2026-07-28"],
                          ["doctor","inspect-all","--protocol=handshake","--dry-run"]] {
            let args = try Args(arguments)
            XCTAssertNoThrow(try CommandContract.validate(args))
        }
        for arguments in [["agents","context","--protocol","2026-07-28"],
                          ["agents","inspect","owned","--protocol","auto"],
                          ["agents","inspect","owned","--protocol"]] {
            XCTAssertThrowsError(try Args(arguments))
        }
        XCTAssertTrue(CommandHelp.text(for:["agents","inspect"]).contains("2026-07-28"))
    }
    func testUsageOrderingAcceptsBothFormsAndAliasesWithSelectedLogs() throws {
        for arguments in [["agents","usage","--sort","structured"], ["agents","usage","--sort=text"],
                          ["agent","usage","--sort","structured","--agent","codex","--log-file","/owned/log"],
                          ["doctor","usage","--sort=text"]] {
            let args = try Args(arguments)
            XCTAssertNotNil(args.options["sort"])
            XCTAssertNoThrow(try CommandContract.validate(args))
        }
    }
    func testUsageOrderingRejectsUnsupportedValuesAndOtherCommandsBeforeExecution() {
        for arguments in [["agents","usage","--sort"], ["agents","usage","--sort="],
                          ["agents","usage","--sort","bytes"], ["agents","context","--sort","structured"],
                          ["pulse","history","--sort","text"]] {
            XCTAssertThrowsError(try Args(arguments))
        }
    }
    func testUsageHelpAndCapabilityInventoryExposeOrderingAndJSONSemantics() throws {
        let help = CommandHelp.text(for:["agents","usage"])
        XCTAssertTrue(help.contains("--sort text|structured"))
        XCTAssertTrue(help.contains("Human output and JSON use the same order"))
        let capability = try XCTUnwrap(CommandHelp.capabilities.first { $0.command == "agents usage" })
        XCTAssertTrue(capability.usage.contains("--sort text|structured")); XCTAssertEqual(capability.execution,"cli")
    }
    func testBackgroundAuthorizationFlagCannotBeReusedForChangesOrDryRuns() throws {
        XCTAssertTrue(try Args(["apps", "startup", "list", "--authorize-background"]).has("authorize-background"))
        for arguments in [["apps", "startup", "enable", "fixture", "--authorize-background"], ["clean", "--authorize-background"], ["apps", "startup", "list", "--authorize-background", "--dry-run"], ["apps", "startup", "--authorize-background=false"]] {
            XCTAssertThrowsError(try Args(arguments))
        }
    }
    func testDataOnlyFlagIsAcceptedForAppRemovalAndRejectedForOtherActions() throws {
        let args = try Args(["apps", "uninstall", "Fixture", "--data-only", "--dry-run", "--json"])
        XCTAssertTrue(args.has("data-only"))
        XCTAssertEqual(args.positionals, ["apps", "uninstall", "Fixture"])
        for invalid in [["apps", "leftovers", "remove", "all", "--data-only"], ["space", "trash", "/fixture", "--data-only"],
                        ["apps", "uninstall", "Fixture", "--data-only=false"]] {
            XCTAssertThrowsError(try Args(invalid))
        }
    }

    func testHistoryRangeIsFinitePositiveAndCappedConsistently() {
        XCTAssertEqual(PulseCommand.hours("30m"), 0.5)
        XCTAssertEqual(PulseCommand.hours(" 6H "), 6)
        XCTAssertEqual(PulseCommand.hours("6"), 6)
        XCTAssertEqual(PulseCommand.hours("2880m"), 24)
        XCTAssertEqual(PulseCommand.hours("1e100m"), 24)
        for invalid in ["0", "-1", "-1h", "nan", "inf", "infm", "1e999m", "1d", ""] {
            XCTAssertNil(PulseCommand.hours(invalid), invalid)
        }
    }

    func testUptimeFormattingCannotOverflowAnInteger() {
        let previous = L10n.override
        defer { L10n.override = previous }
        L10n.override = .english
        XCTAssertEqual(PulseCommand.duration(.nan), "—")
        XCTAssertEqual(PulseCommand.duration(.infinity), "—")
        XCTAssertEqual(PulseCommand.duration(90000), "1d 1h")
        XCTAssertFalse(PulseCommand.duration(Double.greatestFiniteMagnitude).isEmpty)
    }
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

    func testPulseChromeFlagsParse() throws {
        let a = try Args(["pulse", "chrome", "--measure", "--json"])
        XCTAssertTrue(a.has("measure"))
        XCTAssertTrue(a.has("json"))
        let w = try Args(["pulse", "chrome", "--watch", "60", "--app", "Microsoft Edge"])
        XCTAssertEqual(w.options["watch"], "60")
        XCTAssertEqual(w.options["app"], "Microsoft Edge")
        XCTAssertThrowsError(try Args(["pulse", "chrome", "--measure=1"]))
    }
    func testTabWorkspaceScopeFlagsParse() throws {
        let args = try Args(["tabs", "archive", "--ids", "id1,id2", "--group", "Research", "--window", "12", "--name", "Later", "--all-windows", "--dry-run"])
        XCTAssertEqual(args.positionals, ["tabs", "archive"])
        XCTAssertEqual(args.options["ids"], "id1,id2")
        XCTAssertEqual(try args.int("window"), 12)
        XCTAssertTrue(args.has("all-windows"))
        XCTAssertTrue(args.has("dry-run"))
    }

}
