import CryptoKit
import XCTest
@testable import ModuleKit

/// TEST KEYS ONLY. Derived from fixed bytes so the tests are repeatable; never listed in
/// `ModuleSigningKeys.production` and worthless outside these tests.
enum TestSigningKeys {
    static let pipeline = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
    static let other = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
    static let trusted = ["test-pipeline": pipeline.publicKey.rawRepresentation]
}

func moduleJSON(id: String = "com.example.weather", version: String = "1.0.0", capabilities: [String] = ["network.connect:api.example.com"]) -> Data {
    let object: [String: Any] = ["interface": 1, "id": id, "name": "Weather", "summary": "Shows the forecast.", "symbol": "cloud.sun",
                                 "version": version, "launch": "onDemand", "enabledByDefault": false, "capabilities": capabilities,
                                 "entries": [], "commands": []]
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
let wasmBytes = Data([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])

final class ModulePackageTests: XCTestCase {
    func signed(_ manifest: Data = moduleJSON(), wasm: Data = wasmBytes, key: Curve25519.Signing.PrivateKey = TestSigningKeys.pipeline) throws -> Data {
        try ModulePackage.sign(manifest: manifest, wasm: wasm, key: key, keyID: "test-pipeline").encoded()
    }

    func testSignedPackageVerifiesAndRoundTrips() throws {
        let manifest = try ModulePackage.decode(try signed()).verify(keys: TestSigningKeys.trusted)
        XCTAssertEqual(manifest.id, "com.example.weather")
        XCTAssertEqual(manifest.capabilities, [Capability(.networkConnect, scope: "api.example.com")])
    }

    func testTamperedWasmManifestWrongKeyAndUnknownKeyAreRefused() throws {
        var package = try ModulePackage.decode(try signed())
        var wasm = package; wasm.wasm.append(0x00)
        XCTAssertThrowsError(try wasm.verify(keys: TestSigningKeys.trusted)) { XCTAssertEqual($0 as? ModulePackage.Problem, .badSignature) }
        var manifest = package; manifest.manifestData = moduleJSON(capabilities: ["network.connect:api.example.com", "files.delete:~/Documents"])
        XCTAssertThrowsError(try manifest.verify(keys: TestSigningKeys.trusted)) { XCTAssertEqual($0 as? ModulePackage.Problem, .badSignature) }
        let foreign = try ModulePackage.decode(try signed(key: TestSigningKeys.other))
        XCTAssertThrowsError(try foreign.verify(keys: TestSigningKeys.trusted)) { XCTAssertEqual($0 as? ModulePackage.Problem, .badSignature) }
        package.keyID = "someone-else"
        XCTAssertThrowsError(try package.verify(keys: TestSigningKeys.trusted)) { XCTAssertEqual($0 as? ModulePackage.Problem, .unknownKey("someone-else")) }
        XCTAssertThrowsError(try ModulePackage.decode(try signed()).verify(keys: ModuleSigningKeys.production), "release builds never trust the test key")
    }

    func testSignedButUnsafeContentsAreStillRefused() throws {
        XCTAssertThrowsError(try ModulePackage.decode(try signed(moduleJSON(id: "dev.thermo.disk"))).verify(keys: TestSigningKeys.trusted)) {
            XCTAssertEqual($0 as? ModulePackage.Problem, .reservedID("dev.thermo.disk"))
        }
        XCTAssertThrowsError(try ModulePackage.decode(try signed(wasm: Data("#!/bin/sh".utf8))).verify(keys: TestSigningKeys.trusted)) {
            XCTAssertEqual($0 as? ModulePackage.Problem, .notWebAssembly)
        }
        for scope in ["network.connect:127.0.0.1", "network.connect:localhost", "network.connect:printer.local", "network.connect:api.example.com:8443"] {
            XCTAssertThrowsError(try ModulePackage.decode(try signed(moduleJSON(capabilities: [scope]))).verify(keys: TestSigningKeys.trusted), scope)
        }
        XCTAssertThrowsError(try ModulePackage.decode(Data(repeating: 0x20, count: ModulePackage.maxPackageBytes + 1))) {
            XCTAssertEqual($0 as? ModulePackage.Problem, .tooLarge)
        }
    }

    func testVersionOrdering() {
        XCTAssertTrue(ModuleVersion.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(ModuleVersion.isNewer("2.0", than: "1.99.99"))
        XCTAssertFalse(ModuleVersion.isNewer("1.0.0", than: "1.0"))
        XCTAssertFalse(ModuleVersion.isNewer("1.0.0-beta", than: "0.9.0"), "unknown formats never count as newer")
        XCTAssertFalse(ModuleVersion.isNewer("0.9.0", than: "1.0.0"))
    }
}

final class ModuleMarketStoreTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-market-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func package(_ version: String, capabilities: [String] = ["network.connect:api.example.com"]) throws -> (Data, ModuleRegistry.Listing) {
        let data = try ModulePackage.sign(manifest: moduleJSON(version: version, capabilities: capabilities), wasm: wasmBytes,
                                          key: TestSigningKeys.pipeline, keyID: "test-pipeline").encoded()
        let listing = ModuleRegistry.Listing(id: "com.example.weather", version: version, name: "Weather", summary: "Shows the forecast.",
                                             capabilities: capabilities.compactMap(Capability.init), size: data.count,
                                             sha256: ModulePackage.fileHash(data), url: URL(string: "https://modules.example.com/weather.thermomodule")!)
        return (data, listing)
    }

    func testInstallUpdateRefuseDowngradeAndUninstall() throws {
        let store = ModuleMarketStore(root: root, keys: TestSigningKeys.trusted)
        let (one, oneListing) = try package("1.0.0")
        try store.install(one, listing: oneListing)
        XCTAssertEqual(store.installed().map(\.manifest.version), ["1.0.0"])
        XCTAssertThrowsError(try store.install(one, listing: oneListing)) { XCTAssertEqual($0 as? ModuleMarketStore.Failure, .notNewer) }
        let (two, twoListing) = try package("1.1.0")
        XCTAssertEqual(store.updates(ModuleRegistry(modules: [twoListing])).map(\.version), ["1.1.0"])
        try store.install(two, listing: twoListing)
        XCTAssertEqual(store.installed().map(\.manifest.version), ["1.1.0"])
        XCTAssertTrue(store.updates(ModuleRegistry(modules: [twoListing])).isEmpty)
        XCTAssertThrowsError(try store.install(one, listing: oneListing)) { XCTAssertEqual($0 as? ModuleMarketStore.Failure, .notNewer) }
        var removed: URL?
        try store.uninstall("com.example.weather") { removed = $0; try FileManager.default.removeItem(at: $0) }
        XCTAssertEqual(removed?.lastPathComponent, "com.example.weather")
        XCTAssertTrue(store.installed().isEmpty)
        XCTAssertThrowsError(try store.uninstall("com.example.weather") { _ in }) { XCTAssertEqual($0 as? ModuleMarketStore.Failure, .notInstalled) }
    }

    func testDownloadMustMatchTheListingItWasReviewedFrom() throws {
        let store = ModuleMarketStore(root: root, keys: TestSigningKeys.trusted)
        let (data, listing) = try package("1.0.0")
        var wrongHash = listing; wrongHash.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try store.install(data, listing: wrongHash)) { XCTAssertEqual($0 as? ModuleMarketStore.Failure, .hashMismatch) }
        var fewer = listing; fewer.capabilities = []
        XCTAssertThrowsError(try store.install(data, listing: fewer)) { XCTAssertEqual($0 as? ModuleMarketStore.Failure, .listingMismatch("declared access")) }
        var version = listing; version.version = "9.0.0"
        XCTAssertThrowsError(try store.install(data, listing: version)) { XCTAssertEqual($0 as? ModuleMarketStore.Failure, .listingMismatch("version")) }
        XCTAssertTrue(store.installed().isEmpty, "a failed check writes nothing")
        // An installed copy that no longer verifies is not offered to the app.
        try store.install(data, listing: listing)
        XCTAssertTrue(ModuleMarketStore(root: root, keys: [:]).installed().isEmpty)
    }

    func testRegistryDropsUnsafeListings() throws {
        let (_, good) = try package("1.0.0")
        var http = good; http.id = "com.example.http"; http.url = URL(string: "http://modules.example.com/x")!
        var reserved = good; reserved.id = "dev.thermo.disk"
        var dup = good; dup.name = "Second copy"
        let data = try JSONEncoder().encode(ModuleRegistry(modules: [good, http, reserved, dup]))
        XCTAssertEqual(ModuleRegistry.decode(data)?.modules.map(\.name), ["Weather"])
        XCTAssertNil(ModuleRegistry.decode(Data("{}".utf8)))
    }
}
