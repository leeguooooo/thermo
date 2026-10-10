import CSMC
import XCTest
@testable import ThermoKit

final class CodecTests: XCTestCase {
    func testFourCC() {
        XCTAssertEqual(FourCC("TC0P").description, "TC0P")
        XCTAssertEqual(FourCC("FS!").description, "FS! ")
        XCTAssertEqual(FourCC("flt").rawValue, FourCC("flt ").rawValue)
        XCTAssertEqual(smc_fourcc("ui8"), FourCC("ui8 ").rawValue)
        XCTAssertEqual(smc_fourcc(""), FourCC("    ").rawValue)
    }

    func testDecodeFixedPoint() {
        XCTAssertEqual(SMCCodec.decode([0x43, 0xC0], type: "sp78"), 67.75)
        XCTAssertEqual(SMCCodec.decode([0xFF, 0x00], type: "sp78"), -1)
        XCTAssertEqual(SMCCodec.decode([0x16, 0x80], type: "fpe2"), 1440)
        XCTAssertEqual(SMCCodec.decode([0x17, 0x53], type: "spf0"), 5971)
        XCTAssertEqual(SMCCodec.decode([0x07, 0xE0], type: "sp87"), 15.75)
        XCTAssertNil(SMCCodec.decode([0x01], type: "sp78"), "wrong size must not decode")
        XCTAssertNil(SMCCodec.decode([0x01, 0x02], type: "spzz"))
    }

    func testDecodeIntegersAndFloat() {
        XCTAssertEqual(SMCCodec.decode([0x02], type: "ui8 "), 2)
        XCTAssertEqual(SMCCodec.decode([0x01, 0x00], type: "ui16"), 256)
        XCTAssertEqual(SMCCodec.decode([0x00, 0x00, 0x04, 0x8C], type: "ui32"), 1164)
        XCTAssertEqual(SMCCodec.decode([0xFF, 0xFE], type: "si16"), -2)
        XCTAssertEqual(SMCCodec.decode([0x80], type: "si8 "), -128)
        XCTAssertEqual(SMCCodec.decode([0x01], type: "flag"), 1)
        XCTAssertEqual(SMCCodec.decode(withUnsafeBytes(of: Float(5612.5)) { Array($0) }, type: "flt "), 5612.5)
        XCTAssertNil(SMCCodec.decode([0, 0, 0], type: "flt "))
    }

    func testEncodeRoundTrip() throws {
        let cases: [(FourCC, Int, Double)] = [
            ("fpe2", 2, 2400), ("sp78", 2, 42.5), ("sp78", 2, -3.25), ("flt ", 4, 3500),
            ("ui8 ", 1, 1), ("ui16", 2, 1200), ("ui32", 4, 70000), ("si16", 2, -5), ("spf0", 2, 5000),
        ]
        for (type, size, value) in cases {
            let bytes = try SMCCodec.encode(value, type: type, size: size)
            XCTAssertEqual(bytes.count, size)
            XCTAssertEqual(SMCCodec.decode(bytes, type: type)!, value, accuracy: 0.01, "\(type)")
        }
    }

    func testEncodeRejectsOutOfRange() {
        XCTAssertThrowsError(try SMCCodec.encode(-1, type: "fpe2", size: 2))
        XCTAssertThrowsError(try SMCCodec.encode(20000, type: "fpe2", size: 2))
        XCTAssertThrowsError(try SMCCodec.encode(1, type: "ch8*", size: 4))
        XCTAssertThrowsError(try SMCCodec.encode(-1, type: "ui8 ", size: 1))
    }
}

final class CatalogTests: XCTestCase {
    func testKnownIntelKeys() {
        let r = Catalog.temperature("TC0P")
        XCTAssertTrue(r.known)
        XCTAssertEqual(r.entry.group, .cpu)
        XCTAssertEqual(Catalog.temperature("TC3C").entry.name, "CPU Core 3")
        XCTAssertEqual(Catalog.temperature("TCAC").entry.name, "CPU Core 10")
        XCTAssertEqual(Catalog.temperature("TB0T").entry.group, .battery)
    }

    func testAppleSiliconPatterns() {
        XCTAssertEqual(Catalog.temperature("Tp01").entry.group, .cpu)
        XCTAssertTrue(Catalog.temperature("Tp01").known)
        XCTAssertEqual(Catalog.temperature("Te05").entry.name, "CPU E-Core 05")
        XCTAssertEqual(Catalog.temperature("Tg0f").entry.group, .gpu)
        XCTAssertTrue(Catalog.isEssential("Tp09"))
    }

    func testUnknownKeys() {
        let r = Catalog.temperature("TZ9Q")
        XCTAssertFalse(r.known)
        XCTAssertEqual(r.entry.group, .other)
        XCTAssertFalse(Catalog.temperature("TG7X").known)
        XCTAssertEqual(Catalog.temperature("TG7X").entry.group, .gpu)
    }

    func testHIDGroups() {
        XCTAssertEqual(Catalog.hidGroup("pACC MTR Temp Sensor2"), .cpu)
        XCTAssertEqual(Catalog.hidGroup("GPU MTR Temp Sensor1"), .gpu)
        XCTAssertEqual(Catalog.hidGroup("NAND CH0 temp"), .storage)
        XCTAssertEqual(Catalog.hidGroup("gas gauge battery"), .battery)
    }

    func testQuantityAndPlausibility() {
        XCTAssertEqual(Catalog.quantity(of: "PSTR"), .power)
        XCTAssertEqual(Catalog.quantity(of: "VD0R"), .voltage)
        XCTAssertNil(Catalog.quantity(of: "FNum"))
        XCTAssertFalse(Catalog.plausible(-0.004, .temperature))
        XCTAssertFalse(Catalog.plausible(.nan, .power))
        XCTAssertTrue(Catalog.plausible(-2.1, .current))
    }
}

final class CurveTests: XCTestCase {
    func testRejectsInvalidAndAmbiguousCurves() {
        for text in ["NaN:2000", "inf:2000", "50:inf", "50:nan", "50:2000,50:3000", "50:min,", ",50:min", "50:min,,70:max"] {
            XCTAssertThrowsError(try FanCurve(parsing: text), text)
        }
        XCTAssertThrowsError(try FanPolicy.fixed(rpm: .nan).validate())
        XCTAssertThrowsError(try FanPolicy.fixed(rpm: -.infinity).validate())
        XCTAssertNoThrow(try FanPolicy.fixed(rpm: .infinity).validate())
        XCTAssertThrowsError(try FanPolicy.curve(FanCurve(points: [.init(.nan, 3000)])).validate())
    }

    func testDecimalCurveSurvivesEditingRoundTrip() throws {
        let curve = try FanCurve(parsing: "50.125:min,70.75:3000.5,85.25:max", sensor: .gpu)
        XCTAssertEqual(try FanCurve(parsing: curve.pointsText, sensor: curve.sensor), curve)
        XCTAssertEqual(curve.rpm(at: 70.75, min: 1000, max: 6000), 3000.5)
    }

    func testParse() throws {
        let c = try FanCurve(parsing: "70:3000, 50:min,85:max", sensor: .gpu)
        XCTAssertEqual(c.points.map(\.temperature), [50, 70, 85], "points are sorted")
        XCTAssertEqual(c.points[0].rpm, 0)
        XCTAssertTrue(c.points[2].rpm.isInfinite)
        XCTAssertEqual(c.sensor, .gpu)
        XCTAssertNoThrow(try FanCurve(parsing: "60°C:2000"))
    }

    func testParseErrors() {
        XCTAssertThrowsError(try FanCurve(parsing: ""))
        XCTAssertThrowsError(try FanCurve(parsing: "50"))
        XCTAssertThrowsError(try FanCurve(parsing: "50:fast"))
        XCTAssertThrowsError(try FanCurve(parsing: "x:1000"))
        XCTAssertThrowsError(try FanCurve(parsing: "50:-100"))
    }

    func testInterpolation() throws {
        let c = try FanCurve(parsing: "50:min,70:3000,85:max")
        XCTAssertEqual(c.rpm(at: 30, min: 1800, max: 5600), 1800)
        XCTAssertEqual(c.rpm(at: 50, min: 1800, max: 5600), 1800)
        XCTAssertEqual(c.rpm(at: 60, min: 1800, max: 5600), 2400)
        XCTAssertEqual(c.rpm(at: 70, min: 1800, max: 5600), 3000)
        XCTAssertEqual(c.rpm(at: 77.5, min: 1800, max: 5600), 4300)
        XCTAssertEqual(c.rpm(at: 99, min: 1800, max: 5600), 5600)
    }

    func testClampsToFanRange() {
        let c = FanCurve(points: [.init(40, 500), .init(80, 9000)])
        XCTAssertEqual(c.rpm(at: 0, min: 1200, max: 5000), 1200)
        XCTAssertEqual(c.rpm(at: 100, min: 1200, max: 5000), 5000)
    }

    func testPresetsAreMonotonic() {
        for c in [FanCurve.quiet, .balanced, .performance] {
            var last = 0.0
            for t in stride(from: 20.0, through: 100, by: 1) {
                let r = c.rpm(at: t, min: 1500, max: 6000)
                XCTAssertGreaterThanOrEqual(r, last)
                last = r
            }
        }
    }
}

final class PolicyEngineTests: XCTestCase {
    func snapshot(cpu: Double, gpu: Double = 40) -> Snapshot {
        Snapshot(temperatures: [
            Reading(key: "TC0P", name: "CPU", group: .cpu, value: cpu),
            Reading(key: "TG0P", name: "GPU", group: .gpu, value: gpu),
            Reading(key: "TZZZ", name: "junk", group: .other, value: 120, known: false),
        ], fans: [
            FanReading(id: 0, name: "Fan 1", rpm: 2000, min: 1800, max: 5600, target: nil, manual: false),
            FanReading(id: 1, name: "Fan 2", rpm: 2000, min: 1700, max: 5200, target: nil, manual: false),
        ], power: [], voltages: [], currents: [], battery: nil)
    }

    func testInactiveDoesNothing() {
        var e = FanPolicyEngine()
        XCTAssertFalse(e.isActive)
        XCTAssertEqual(e.tick(snapshot(cpu: 99)), [], "no policies → never touches fans, even when hot")
    }

    func testFixedIsClamped() {
        var e = FanPolicyEngine()
        e.set(.fixed(rpm: 9000), for: 0)
        e.set(.fixed(rpm: .infinity), for: 1)
        XCTAssertEqual(e.tick(snapshot(cpu: 50)), [.manual(fan: 0, rpm: 5600), .manual(fan: 1, rpm: 5200)])
    }

    func testCurveUsesChosenSensor() {
        var e = FanPolicyEngine()
        e.set(.curve(FanCurve(points: [.init(40, 0), .init(80, .infinity)], sensor: .gpu)), for: 0)
        // GPU at 60 → halfway between 1800 and 5600.
        XCTAssertEqual(e.tick(snapshot(cpu: 30, gpu: 60)), [.manual(fan: 0, rpm: 3700)])
    }

    func testUnknownSensorsDoNotTriggerFailsafe() {
        var e = FanPolicyEngine()
        e.set(.fixed(rpm: 2000), for: 0)
        XCTAssertEqual(e.tick(snapshot(cpu: 50)), [.manual(fan: 0, rpm: 2000)])
    }

    func testASingleSpikeDoesNotTrip() {
        var e = FanPolicyEngine(limits: .intel)
        e.set(.fixed(rpm: 1800), for: 0)
        XCTAssertEqual(e.tick(snapshot(cpu: 97)), [.manual(fan: 0, rpm: 1800)], "one hot sample is not enough")
        XCTAssertEqual(e.tick(snapshot(cpu: 80)), [.manual(fan: 0, rpm: 1800)])
        XCTAssertEqual(e.tick(snapshot(cpu: 97)), [.manual(fan: 0, rpm: 1800)], "counter reset by the cool sample")
        XCTAssertFalse(e.suspended)
    }

    func testSustainedHeatSuspendsAndKeepsPolicies() {
        var e = FanPolicyEngine(limits: .intel)
        e.set(.fixed(rpm: 1800), for: 0)
        _ = e.tick(snapshot(cpu: 96))
        XCTAssertEqual(e.tick(snapshot(cpu: 96.5)), [.failsafe(temperature: 96.5)])
        XCTAssertTrue(e.suspended)
        XCTAssertTrue(e.isActive, "policies survive the failsafe")
        XCTAssertEqual(e.policies[0], .fixed(rpm: 1800))
        XCTAssertEqual(e.tick(snapshot(cpu: 99)), [], "nothing is written while suspended")
    }

    func testResumesOnlyAfterStayingCool() {
        let limits = SafetyLimits(ceiling: 95, resumeBelow: 85, resumeTicks: 3, triggerTicks: 2)
        var e = FanPolicyEngine(limits: limits)
        e.set(.fixed(rpm: 2000), for: 0)
        _ = e.tick(snapshot(cpu: 96)); _ = e.tick(snapshot(cpu: 96))
        XCTAssertTrue(e.suspended)
        XCTAssertEqual(e.tick(snapshot(cpu: 84)), [])
        XCTAssertEqual(e.tick(snapshot(cpu: 90)), [], "warming again restarts the cool-down")
        XCTAssertEqual(e.tick(snapshot(cpu: 84)), [])
        XCTAssertEqual(e.tick(snapshot(cpu: 84)), [])
        XCTAssertEqual(e.tick(snapshot(cpu: 83)), [.resume(temperature: 83), .manual(fan: 0, rpm: 2000)])
        XCTAssertFalse(e.suspended)
    }

    func testAppleSiliconToleratesNormalCoreTemperatures() {
        // M4 under a heavy build, macOS in charge of the fan: cores at 103–115 °C.
        var e = FanPolicyEngine(limits: .forHardware(appleSilicon: true))
        e.set(.fixed(rpm: 3000), for: 0)
        for t in [104.0, 106.5, 108.6, 105.8] {
            XCTAssertEqual(e.tick(snapshot(cpu: t)), [.manual(fan: 0, rpm: 3000)], "\(t) °C is normal on Apple Silicon")
        }
        _ = e.tick(snapshot(cpu: 112))
        XCTAssertEqual(e.tick(snapshot(cpu: 113)), [.failsafe(temperature: 113)])
    }

    func testMaxSpeedIsNeverSuspended() {
        // The user's report: "max" did nothing because the failsafe handed the fan back to auto.
        var e = FanPolicyEngine(limits: .intel)
        e.set(.fixed(rpm: .infinity), for: 0)
        for t in [96.0, 104.7, 110.0, 99.0] {
            XCTAssertEqual(e.tick(snapshot(cpu: t)), [.manual(fan: 0, rpm: 5600)], "\(t) °C: max stays max")
        }
        XCTAssertFalse(e.suspended)
        e.set(.fixed(rpm: 5400), for: 0)   // within 5 % of 5600 counts as full cooling
        _ = e.tick(snapshot(cpu: 97))
        XCTAssertEqual(e.tick(snapshot(cpu: 97)), [.manual(fan: 0, rpm: 5400)])
    }

    func testFailsafeKeepsMaxFansAndSuspendsTheRest() {
        var e = FanPolicyEngine(limits: .intel)
        e.set(.fixed(rpm: .infinity), for: 0)
        e.set(.fixed(rpm: 1800), for: 1)
        _ = e.tick(snapshot(cpu: 96))
        XCTAssertEqual(e.tick(snapshot(cpu: 96.5)), [.failsafe(temperature: 96.5), .manual(fan: 0, rpm: 5600)],
                       "everything to auto, then fan 0 back to max")
        XCTAssertTrue(e.suspended)
        XCTAssertEqual(e.tick(snapshot(cpu: 99)), [.manual(fan: 0, rpm: 5600)], "while suspended only the max fan is driven")
    }

    func testAutoClearsSuspension() {
        var e = FanPolicyEngine(limits: .intel)
        e.set(.fixed(rpm: 1800), for: 0)
        _ = e.tick(snapshot(cpu: 96)); _ = e.tick(snapshot(cpu: 96))
        XCTAssertTrue(e.suspended)
        e.set(.auto, for: 0)
        XCTAssertFalse(e.suspended)
        XCTAssertEqual(e.tick(snapshot(cpu: 99)), [])
    }

    func testSettingAutoRemovesPolicy() {
        var e = FanPolicyEngine()
        e.set(.fixed(rpm: 3000), for: 0)
        e.set(.auto, for: 0)
        XCTAssertTrue(e.policies.isEmpty)
    }

    func testPolicyCodingHandlesInfinity() throws {
        let policies: [Int: FanPolicy] = [0: .fixed(rpm: .infinity), 1: .curve(.balanced)]
        let data = try PolicyCoding.encoder().encode(policies)
        let back = try PolicyCoding.decoder().decode([Int: FanPolicy].self, from: data)
        XCTAssertEqual(back, policies)
    }
}

final class DiscoveryCacheTests: XCTestCase {
    func testRoundTrip() throws {
        let d = Discovery(
            version: Discovery.version, model: "MacBookPro16,1", keyCount: 1164,
            sensors: [
                SensorDescriptor(info: SMCKeyInfo(key: "TC0P", type: "sp78", size: 2, attributes: 0x80),
                                 quantity: .temperature, name: "CPU Proximity", group: .cpu, known: true, essential: true),
                SensorDescriptor(info: SMCKeyInfo(key: "PSTR", type: "flt ", size: 4, attributes: 0xC4),
                                 quantity: .power, name: "System Total", group: .other, known: true, essential: false),
            ],
            fans: [FanDescriptor(index: 0, name: "Left Fan", hasModeKey: true)],
            fanForceKey: false, fanTestKey: true, hid: true)
        let back = try XCTUnwrap(Discovery(cache: d.cacheData))
        XCTAssertEqual(back.model, d.model)
        XCTAssertEqual(back.keyCount, d.keyCount)
        XCTAssertEqual(back.sensors, d.sensors)
        XCTAssertEqual(back.fans, d.fans)
        XCTAssertEqual(back.fanTestKey, true)
        XCTAssertEqual(back.hid, true)
    }

    func testRejectsGarbageAndOldVersions() {
        XCTAssertNil(Discovery(cache: Data("hello".utf8)))
        XCTAssertNil(Discovery(cache: Data("thermo-discovery 1 10 0 0 0\nmodel X\n".utf8)))
        XCTAssertNil(Discovery(cache: Data("thermo-discovery 2 10 0 0 0\ns zz\n".utf8)))
    }
}

final class BatteryTests: XCTestCase {
    func testInvalidRegistryValuesRemainUnknown() {
        let battery = Battery.parse(["CurrentCapacity": -1, "MaxCapacity": 100,
                                     "AppleRawMaxCapacity": -1, "DesignCapacity": 6000,
                                     "Temperature": NSNumber(value: Double.nan), "Voltage": -1,
                                     "Amperage": NSNumber(value: Double.infinity), "CycleCount": -1])
        XCTAssertNil(battery.percent)
        XCTAssertNil(battery.health)
        XCTAssertNil(battery.temperature)
        XCTAssertNil(battery.voltage)
        XCTAssertNil(battery.amperage)
        XCTAssertNil(battery.cycleCount)
        XCTAssertNil(battery.power)
    }

    func testOverfullChargeIsBoundedAndZeroChargeIsPreserved() {
        XCTAssertEqual(Battery.parse(["CurrentCapacity": 110, "MaxCapacity": 100]).percent, 100)
        XCTAssertEqual(Battery.parse(["CurrentCapacity": 0, "MaxCapacity": 100]).percent, 0)
        XCTAssertNil(Battery.parse(["CurrentCapacity": 50, "MaxCapacity": 0]).percent)
    }

    func testNestedPowerStateAndUnsignedDischargeAreSupported() {
        let battery = Battery.parse(["BatteryData": ["Amperage": NSNumber(value: UInt64(bitPattern: -1500)),
                                                      "Voltage": 12000, "ExternalConnected": true, "IsCharging": true]])
        XCTAssertEqual(battery.amperage, -1.5)
        XCTAssertEqual(battery.power, -18)
        XCTAssertTrue(battery.externalPower)
        XCTAssertTrue(battery.charging)
    }

    func testParse() {
        let b = Battery.parse([
            "CurrentCapacity": 50, "MaxCapacity": 100, "AppleRawMaxCapacity": 5600, "DesignCapacity": 6900,
            "Temperature": 3132, "Voltage": 11823, "Amperage": NSNumber(value: UInt64(bitPattern: -1500)),
            "CycleCount": 693, "IsCharging": false, "ExternalConnected": false,
        ])
        XCTAssertEqual(b.percent, 50)
        XCTAssertEqual(b.temperature, 31.32)
        XCTAssertEqual(b.amperage, -1.5)
        XCTAssertEqual(b.health!, 5600.0 / 6900, accuracy: 1e-9)
        XCTAssertEqual(b.power!, 11.823 * -1.5, accuracy: 1e-9)
        XCTAssertFalse(b.charging)
    }
}

final class BatteryNestedTests: XCTestCase {
    /// macOS 27 on Apple Silicon: capacities only inside BatteryData, no Temperature key.
    func testNestedBatteryData() {
        let b = Battery.parse([
            "CurrentCapacity": 79, "MaxCapacity": 100, "Voltage": 12365, "CycleCount": 62,
            "ExternalConnected": true,
            "BatteryData": ["DesignCapacity": 6249, "NominalChargeCapacity": 6390, "FullChargeCapacity": 6238],
        ])
        XCTAssertEqual(b.percent, 79)
        XCTAssertEqual(b.health, 1, "capped at 100 % when nominal exceeds design")
        XCTAssertNil(b.temperature)
        XCTAssertEqual(b.with(temperature: 26.6).temperature, 26.6)
    }
}

/// Exercises the real SMC; skipped when unavailable (CI VMs).
final class HardwareTests: XCTestCase {
    func testLiveSample() throws {
        guard let sampler = try? Sampler(useCache: false) else { throw XCTSkip("no AppleSMC") }
        let s = sampler.sample()
        XCTAssertFalse(s.temperatures.isEmpty)
        for r in s.temperatures { XCTAssertTrue(r.value > 0 && r.value < 130, "\(r.key)=\(r.value)") }
        for f in s.fans { XCTAssertGreaterThanOrEqual(f.max, f.min) }
        // Writing must be refused without root. Write the current value back so the test
        // is a no-op even if it unexpectedly succeeds; never run it as root.
        guard getuid() != 0, let current = try? sampler.smc.read("F0Md") else { return }
        XCTAssertThrowsError(try sampler.smc.write("F0Md", bytes: current.bytes)) { e in
            XCTAssertEqual(e as? SMCError, .notPrivileged)
        }
    }
}

final class HelperSelfUpdateTests: XCTestCase {
    func testSourceMustBeARealFileInApplications() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selfupdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("thermo-helper").path
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        XCTAssertNil(HelperSelfUpdate.acceptableSource(file), "outside Applications")
        let link = dir.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/Applications/Thermo.app/Contents/Helpers/thermo-helper")
        XCTAssertNil(HelperSelfUpdate.acceptableSource(link), "symlinks are refused")
        XCTAssertNil(HelperSelfUpdate.acceptableSource("/Applications/does-not-exist"))
    }

    func testRequirementPinsTeamAndIdentifier() {
        let r = HelperSelfUpdate.requirement(team: "6ZPXG4KVVS")
        XCTAssertTrue(r.contains(#"identifier "dev.thermo.helper""#))
        XCTAssertTrue(r.contains(#"certificate leaf[subject.OU] = "6ZPXG4KVVS""#))
        XCTAssertFalse(HelperSelfUpdate.satisfies("/bin/ls", team: "6ZPXG4KVVS"), "Apple's own binaries are not ours")
    }

    func testPlistCarriesSourceForSelfUpdate() {
        let p = HelperInstaller.plist(binary: "/Library/PrivilegedHelperTools/dev.thermo.helper",
                                      source: "/Applications/Thermo & Co.app/Contents/Helpers/thermo-helper")
        XCTAssertTrue(p.contains("<string>--source</string>"))
        XCTAssertTrue(p.contains("Thermo &amp; Co.app"), "escaped for XML")
        XCTAssertFalse(HelperInstaller.plist(binary: "/x").contains("--source"))
    }
}

final class PolicyStoreTests: XCTestCase {
    func testCorruptPoliciesAreSkippedWithoutLosingValidFans() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let policies: [String: FanPolicy] = ["0": .fixed(rpm: 3000), "00": .fixed(rpm: 4000), "1": .fixed(rpm: .nan),
                                           "2": .curve(FanCurve(points: [.init(50, 2000), .init(50, 3000)]))]
        try PolicyCoding.encoder().encode(policies).write(to: url)
        XCTAssertEqual(PolicyStore.load(from: url.path), [0: .fixed(rpm: 3000)])
        XCTAssertThrowsError(try PolicyStore.save([1: .fixed(rpm: .nan)], to: url.path))
    }

    func testPoliciesSurviveARoundTrip() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("policies-\(UUID().uuidString)/p.json").path
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        XCTAssertTrue(PolicyStore.load(from: path).isEmpty, "nothing saved yet")
        let curve = try FanCurve(parsing: "50:min,70:3000,85:max")
        try PolicyStore.save([0: .fixed(rpm: .infinity), 1: .curve(curve)], to: path)
        let back = PolicyStore.load(from: path)
        XCTAssertEqual(back[0], .fixed(rpm: .infinity), "max survives as infinity")
        XCTAssertEqual(back[1], .curve(curve))
        try "garbage".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(PolicyStore.load(from: path).isEmpty, "a broken file means no policies, never a crash")
    }
}

