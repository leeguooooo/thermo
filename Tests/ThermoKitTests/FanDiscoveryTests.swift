import XCTest
@testable import ThermoKit

final class FanDiscoveryTests: XCTestCase {
    private enum Fault: Error { case unreadable }
    private func descriptor(_ index: Int, _ count: Int) -> FanDescriptor {
        FanDescriptor(index: index, name: "Fan \(index)", hasModeKey: true)
    }
    private func discovery(known: Bool, fans: [FanDescriptor] = []) -> Discovery {
        Discovery(version: Discovery.version, model: "Fixture", keyCount: 0, sensors: [], fans: fans,
                  fanForceKey: false, fanTestKey: true, hid: false, fanCountKnown: known)
    }

    func testFailedOrInvalidCountNeverBecomesZeroOrEnumeratesFans() {
        var descriptorCalls = 0
        let build: (Int, Int) -> FanDescriptor = { index, count in
            descriptorCalls += 1; return self.descriptor(index, count)
        }
        XCTAssertNil(Sampler.discoverFans(readCount: { throw Fault.unreadable }, descriptor: build))
        for count in [Double.nan, .infinity, -.infinity, -1, 0.5, 17, Double.greatestFiniteMagnitude] {
            XCTAssertNil(Sampler.discoverFans(readCount: { count }, descriptor: build))
        }
        XCTAssertEqual(descriptorCalls, 0)
        XCTAssertEqual(Sampler.discoverFans(readCount: { 0 }, descriptor: build)?.count, 0)
        XCTAssertEqual(Sampler.discoverFans(readCount: { 1 }, descriptor: build)?.map(\.index), [0])
        XCTAssertEqual(Sampler.discoverFans(readCount: { 16 }, descriptor: build)?.count, 16)
    }

    func testUnknownInventoryRetriesThenKeepsTheRecoveredDiscovery() {
        var value = discovery(known: false)
        var calls = 0
        value = value.recoveringFans { calls += 1; return nil }
        XCTAssertFalse(value.fansKnown)
        value = value.recoveringFans { calls += 1; return [descriptor(0, 1)] }
        XCTAssertTrue(value.fansKnown)
        XCTAssertEqual(value.fans.map(\.index), [0])
        value = value.recoveringFans { calls += 1; return [] }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(value.fans.count, 1)
    }

    func testUnknownDiscoveryCannotCreateOrOverwriteACache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache.txt")
        Sampler.saveDiscovery(discovery(known: false), to: cache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        Sampler.saveDiscovery(discovery(known: true), to: cache)
        let known = try Data(contentsOf: cache)
        XCTAssertTrue(try XCTUnwrap(Discovery(cache: known)).fansKnown)
        Sampler.saveDiscovery(discovery(known: false), to: cache)
        XCTAssertEqual(try Data(contentsOf: cache), known)
    }

    func testCacheDistinguishesKnownZeroFromUnknownAndRejectsMissingFanRecords() throws {
        let zero = try XCTUnwrap(Discovery(cache: discovery(known: true).cacheData))
        XCTAssertTrue(zero.fansKnown); XCTAssertTrue(zero.fans.isEmpty)
        let unknown = try XCTUnwrap(Discovery(cache: discovery(known: false).cacheData))
        XCTAssertFalse(unknown.fansKnown)
        func cache(_ count: String, _ fans: String) -> Data {
            Data("thermo-discovery \(Discovery.version) 0 0 0 0 \(count)\nmodel Fixture\n\(fans)end 0 \(fans.split(separator: "\n").count)\n".utf8)
        }
        let complete = String(decoding: discovery(known: true).cacheData, as: UTF8.self)
        XCTAssertNil(Discovery(cache: Data(complete.replacingOccurrences(of: "end 0 0\n", with: "").utf8)))
        XCTAssertNil(Discovery(cache: cache("1", "")))
        XCTAssertNil(Discovery(cache: cache("1", "f 1 1 Wrong index\n")))
        XCTAssertNil(Discovery(cache: cache("2", "f 0 1 Left\nf 0 1 Duplicate\n")))
        XCTAssertNil(Discovery(cache: cache("?", "f 0 1 Unknown\n")))
        XCTAssertNil(Discovery(cache: cache("18446744073709551616", "")))
        XCTAssertNil(Discovery(cache: Data("thermo-discovery 2 0 0 0 0\nmodel Fixture\n".utf8)))
    }

    func testLegacyJSONEmptyInventoryStaysUnknown() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(discovery(known: true))) as? [String: Any])
        object.removeValue(forKey: "fanCountKnown")
        let legacy = try JSONDecoder().decode(Discovery.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(legacy.fansKnown)
        object["fans"] = [["index": 0, "name": "Legacy fan", "hasModeKey": true]]
        XCTAssertTrue(try JSONDecoder().decode(Discovery.self,
            from: JSONSerialization.data(withJSONObject: object)).fansKnown)
        let snapshot = Snapshot(temperatures: [], fans: [], power: [], voltages: [], currents: [], battery: nil, fansAvailable: false)
        var exported = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        XCTAssertEqual(exported["fansAvailable"] as? Bool, false)
        exported.removeValue(forKey: "fansAvailable")
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: exported))
        XCTAssertFalse(decoded.hasFanReadings)
        exported["fans"] = [["id": 0, "name": "Legacy fan", "rpm": 2000, "min": 1000, "max": 6000, "manual": false]]
        XCTAssertTrue(try JSONDecoder().decode(Snapshot.self,
            from: JSONSerialization.data(withJSONObject: exported)).hasFanReadings)
    }

    func testUnknownDiscoveryCannotReportAutomaticRecoveryOrWriteUnlockKeys() {
        let smc = FanRecoveryTests.FakeSMC()
        let writer = FanWriter(smc: smc, discovery: discovery(known: false))
        XCTAssertThrowsError(try writer.setManual(0, rpm: 3000))
        let report = writer.setAllAuto()
        XCTAssertFalse(report.confirmed)
        XCTAssertTrue(report.unconfirmed.contains("fan discovery unavailable"))
        XCTAssertTrue(smc.writes.isEmpty)
        let fanless = FanWriter(smc: smc, discovery: discovery(known: true))
        XCTAssertTrue(fanless.setAllAuto().confirmed)
        XCTAssertTrue(smc.writes.isEmpty, "confirmed zero fans must not write a global unlock key")
    }
}
