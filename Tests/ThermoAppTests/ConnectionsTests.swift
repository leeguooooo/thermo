import XCTest
@testable import ThermoApp

final class ConnectionsTests: XCTestCase {
    /// The shape `system_profiler SPBluetoothDataType -json` prints; names are the object keys.
    let report = """
    {"SPBluetoothDataType": [{
      "controller_properties": {"controller_state": "attrib_on"},
      "device_connected": [
        {"Leo's AirPods Pro": {"device_address": "34:0E:22:9F:1A:10", "device_batteryLevelCase": "100%",
          "device_batteryLevelLeft": "98%", "device_batteryLevelRight": "97 %", "device_minorType": "Headphones"}},
        {"Magic Keyboard": {"device_address": "AC-90-85-C2-9C-1F", "device_batteryLevelMain": "64%", "device_minorType": "Keyboard"}}
      ],
      "device_not_connected": [
        {"iPhone": {"device_address": "28:D5:B1:6F:FA:43"}},
        {"Old Speaker": {"device_address": "50:bc:96:04:03:56", "device_minorType": "Speaker", "device_batteryLevelMain": "120%"}},
        {"Duplicate": {"device_address": "34-0e-22-9f-1a-10"}}
      ]
    }]}
    """

    func testParsesConnectedFirstWithBatteryLevels() throws {
        let r = try XCTUnwrap(BluetoothReport.parse(Data(report.utf8)))
        XCTAssertTrue(r.powerOn)
        XCTAssertEqual(r.devices.map(\.name), ["Leo's AirPods Pro", "Magic Keyboard", "iPhone", "Old Speaker"])
        let pods = r.devices[0]
        XCTAssertTrue(pods.connected)
        XCTAssertEqual(pods.symbol, "airpodspro")
        XCTAssertEqual(pods.levels.map(\.percent), [98, 97, 100])
        XCTAssertEqual(pods.levels.map(\.part), [.left, .right, .box])
    }

    func testAddressesAreNormalizedAndDeduplicated() throws {
        let r = try XCTUnwrap(BluetoothReport.parse(Data(report.utf8)))
        XCTAssertEqual(r.devices[1].address, "ac:90:85:c2:9c:1f")
        XCTAssertFalse(r.devices.contains { $0.name == "Duplicate" })
    }

    func testKindsAndInputDevices() throws {
        let r = try XCTUnwrap(BluetoothReport.parse(Data(report.utf8)))
        XCTAssertTrue(r.devices[1].isInput)
        XCTAssertEqual(r.devices[2].kind, .phone)
        XCTAssertFalse(r.devices[0].isInput)
        // An impossible level is dropped rather than shown.
        XCTAssertEqual(r.devices[3].kind, .speaker)
        XCTAssertTrue(r.devices[3].levels.isEmpty)
    }

    func testControllerOffAndMalformedReports() {
        let off = #"{"SPBluetoothDataType": [{"controller_properties": {"controller_state": "attrib_off"}}]}"#
        XCTAssertEqual(BluetoothReport.parse(Data(off.utf8))?.powerOn, false)
        XCTAssertNil(BluetoothReport.parse(Data("not json".utf8)))
    }

    func testShortComputerNameUsesSystemClassRatherThanGuessingFromItsName() {
        XCTAssertEqual(BluetoothDevice.kind(minorType: nil, name: "m5", majorClass: 1), .computer)
        XCTAssertEqual(BluetoothDevice.kind(minorType: nil, name: "m5", majorClass: nil), .other)
        XCTAssertEqual(BluetoothDevice.kind(minorType: "Headphones", name: "Mac speaker", majorClass: 4), .headphones)
    }

    func testNearbyComputerRemainsVisibleWhenHeadphonesFillTheDefaultList() throws {
        var entries = (0..<8).map { ["AirPods \($0)": ["device_address": "00:00:00:00:00:0\($0)", "device_minorType": "Headphones"]] }
        entries.append(["m5": ["device_address": "00:00:00:00:01:00", "device_rssi": "-39"]])
        let bytes = try JSONSerialization.data(withJSONObject: ["SPBluetoothDataType": [[
            "controller_properties": ["controller_state": "attrib_on"], "device_not_connected": entries
        ]]])
        let report = try XCTUnwrap(BluetoothReport.parse(bytes, majorClasses: ["00:00:00:00:01:00": 1]))
        XCTAssertEqual(report.devices.first?.name, "m5")
        XCTAssertEqual(report.devices.first?.rssi, -39)
        XCTAssertTrue(report.defaultDevices.contains { $0.name == "m5" && $0.kind == .computer })
        XCTAssertLessThan(report.defaultDevices.count, report.devices.count)
    }

    func testSignalIsShownWithoutPretendingAnUnknownDeviceIsAComputer() throws {
        let bytes = Data(#"{"SPBluetoothDataType":[{"device_not_connected":[{"short-name":{"device_address":"00:00:00:00:00:01","device_rssi":-51}},{"invalid":{"device_address":"00:00:00:00:00:02","device_rssi":"127"}}]}]}"#.utf8)
        let report = try XCTUnwrap(BluetoothReport.parse(bytes))
        XCTAssertEqual(report.devices.first?.name, "short-name")
        XCTAssertEqual(report.devices.first?.kind, .other)
        XCTAssertEqual(report.devices.first?.rssi, -51)
        XCTAssertNil(report.devices.last?.rssi)
    }

    func testRepeatedAddressMergesConnectionAndBatteryWithoutMergingDifferentDevicesByName() throws {
        let bytes = Data(#"{"SPBluetoothDataType":[{"device_connected":[{"Pods":{"device_address":"AA:00:00:00:00:01"}}],"device_not_connected":[{"Pods":{"device_address":"aa-00-00-00-00-01","device_batteryLevelMain":"75%","device_minorType":"Headphones","device_rssi":"-45"}},{"Pods":{"device_address":"aa:00:00:00:00:02","device_minorType":"Headphones"}}]}]}"#.utf8)
        let report = try XCTUnwrap(BluetoothReport.parse(bytes))
        XCTAssertEqual(report.devices.count, 2)
        let connected = try XCTUnwrap(report.devices.first { $0.connected })
        XCTAssertEqual(connected.levels.map(\.percent), [75])
        XCTAssertEqual(connected.kind, .headphones)
        XCTAssertEqual(connected.rssi, -45)
    }

    func testNearbyKeepsStrongestPerNameAndSkipsCurrent() {
        let merged = WiFiNetwork.merge([
            WiFiNetwork(id: "a", ssid: "Home", rssi: -70, channel: 1, band: .ghz24, secure: true),
            WiFiNetwork(id: "b", ssid: "Home", rssi: -50, channel: 36, band: .ghz5, secure: true),
            WiFiNetwork(id: "c", ssid: "Cafe", rssi: -60, channel: 6, band: .ghz24, secure: false),
            WiFiNetwork(id: "d", ssid: nil, rssi: -80, channel: 11, band: .ghz24, secure: true),
            WiFiNetwork(id: "e", ssid: nil, rssi: -40, channel: 149, band: .ghz5, secure: true),
            WiFiNetwork(id: "f", ssid: "Mine", rssi: -30, channel: 44, band: .ghz5, secure: true),
        ], current: "Mine")
        XCTAssertEqual(merged.map(\.id), ["e", "b", "c", "d"])
    }

    func testSignalWording() {
        XCTAssertEqual(WiFiStatus.quality(rssi: -50), 1)
        XCTAssertEqual(WiFiStatus.quality(rssi: 0), 0)
        XCTAssertEqual(WiFiStatus.standard(phyMode: 6, band: .ghz6), "Wi-Fi 6E")
        XCTAssertEqual(WiFiStatus.standard(phyMode: 5, band: .ghz5), "Wi-Fi 5")
    }
}
