import XCTest
@testable import ModuleKit

final class ModuleEntitlementsTests: XCTestCase {
    func manifest(_ capabilities: [String]) -> ModuleManifest {
        ModuleManifest(id: "dev.thermo.disk", name: "Disk", summary: "Cleans.", symbol: "internaldrive", version: "1.0.0",
                       capabilities: capabilities.map { Capability($0)! })
    }

    func testEveryModuleIsSandboxedAndOnlyReadScopesOpenAnything() {
        let plain = ModuleEntitlements.values(for: manifest(["processes.read", "files.delete:~/Library/Caches", "network.connect:api.example.com"]))
        XCTAssertEqual(plain.keys.sorted(), [ModuleEntitlements.sandbox])
        XCTAssertEqual(plain[ModuleEntitlements.sandbox] as? Bool, true)

        let reading = ModuleEntitlements.values(for: manifest(["files.read:~/Library/Caches", "files.read:~/.npm/", "files.read:/private/var/folders",
                                                               "files.read:~", "files.delete:~/Library/Logs"]))
        XCTAssertEqual(reading[ModuleEntitlements.homeReadOnly] as? [String], ["/", "/.npm/", "/Library/Caches/"])
        XCTAssertEqual(reading[ModuleEntitlements.absoluteReadOnly] as? [String], ["/private/var/folders/"])
        // Nothing a manifest can say makes a folder writable or opens the network.
        XCTAssertFalse(reading.keys.contains { $0.contains("read-write") || $0.contains("network") })
    }

    func testTheSignatureMustMatchTheManifestExactly() throws {
        let m = manifest(["files.read:~/Library/Caches"])
        let signed = try XCTUnwrap(PropertyListSerialization.propertyList(from: ModuleEntitlements.plist(for: m), format: nil) as? [String: Any])
        XCTAssertEqual(ModuleEntitlements.problems(signed: signed, manifest: m), [])

        var wider = signed
        wider[ModuleEntitlements.homeReadOnly] = ["/", "/Library/Caches/"]
        XCTAssertEqual(ModuleEntitlements.problems(signed: wider, manifest: m).count, 1)
        var writable = signed
        writable["com.apple.security.temporary-exception.files.home-relative-path.read-write"] = ["/Library/Caches/"]
        XCTAssertTrue(ModuleEntitlements.problems(signed: writable, manifest: m).first?.contains("does not give it") == true)
        var network = signed
        network["com.apple.security.network.client"] = true
        XCTAssertEqual(ModuleEntitlements.problems(signed: network, manifest: m).count, 1)
        XCTAssertTrue(ModuleEntitlements.problems(signed: [:], manifest: m).contains { $0.contains("lacks " + ModuleEntitlements.sandbox) })
        XCTAssertEqual(ModuleEntitlements.problems(signed: [ModuleEntitlements.sandbox: true], manifest: m).count, 1)
    }
}
