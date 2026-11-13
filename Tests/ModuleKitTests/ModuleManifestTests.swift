import XCTest
@testable import ModuleKit

final class ModuleManifestTests: XCTestCase {
    func testTextsFollowTheLanguageAndMisspeltKeysAreRefused() throws {
        var m = ModuleManifest(id: "dev.thermo.disk", name: "Disk Cleanup", summary: "Frees space.", symbol: "internaldrive", version: "1.0.0",
                               entries: [.init(id: "home", kind: .page, title: "Smart Scan", scene: "home")],
                               commands: [.init(id: "scan", title: "Scan", summary: "Looks for what can go.",
                                                parameters: [.init(name: "all", kind: .boolean, summary: "Every category.")])],
                               localizations: ["zh-Hans": ["name": "磁盘清理", "entry.home.title": "智能扫描", "command.scan.summary": "找出可以清掉的东西。",
                                                           "parameter.scan.all.summary": "所有类别。"]])
        XCTAssertEqual(m.problems(), [])
        let zh = m.localized("zh-Hans")
        XCTAssertEqual([zh.name, zh.summary, zh.entries[0].title, zh.commands[0].title, zh.commands[0].summary, zh.commands[0].parameters[0].summary],
                       ["磁盘清理", "Frees space.", "智能扫描", "Scan", "找出可以清掉的东西。", "所有类别。"])
        XCTAssertEqual(m.localized("ja"), m)
        XCTAssertEqual(m.localized("en").name, "Disk Cleanup")
        // Survives JSON, and a manifest without translations still loads.
        XCTAssertEqual(try ModuleManifest.load(JSONEncoder().encode(m)).localized("zh-Hans").name, "磁盘清理")
        var plain = m; plain.localizations = nil
        XCTAssertNil(try ModuleManifest.load(JSONEncoder().encode(plain)).localizations)

        m.localizations = ["zh-Hans": ["nmae": "磁盘清理", "entry.missing.title": "x", "summary": ""], "en": ["name": "Disk"]]
        let problems = m.problems().joined(separator: "\n")
        XCTAssertTrue(problems.contains("unknown key nmae") && problems.contains("unknown key entry.missing.title"), problems)
        XCTAssertTrue(problems.contains("leaves summary empty") && problems.contains("may not redefine the English texts"), problems)
    }

    let home = "/Users/someone"

    func disk() -> ModuleManifest {
        ModuleManifest(
            id: "dev.thermo.disk", name: "Disk Cleanup", summary: "Finds and removes what can be regenerated.", symbol: "internaldrive", version: "1.0.0",
            capabilities: [Capability(.filesRead, scope: "/"), Capability(.filesDelete, scope: "~/Library/Caches"), Capability(.networkConnect, scope: "*.leeguoo.com")],
            entries: [.init(id: "home", kind: .page, title: "Disk Cleanup", symbol: "internaldrive", scene: "main"),
                      .init(id: "scan-key", kind: .hotkey, title: "Scan", command: "scan")],
            commands: [.init(id: "scan", title: "Scan", summary: "Lists what can be removed.", capabilities: [Capability(.filesRead, scope: "/")]),
                       .init(id: "clean", title: "Clean", summary: "Removes the chosen items.", mutates: true,
                             parameters: [.init(name: "category", kind: .string, required: true, summary: "Which category to clean.")],
                             capabilities: [Capability(.filesDelete, scope: "~/Library/Caches/Homebrew")])])
    }

    func testAValidManifestSurvivesJSONAndCapabilitiesAreStrings() throws {
        let manifest = disk()
        XCTAssertEqual(manifest.problems(), [])
        let data = try JSONEncoder().encode(manifest)
        XCTAssertEqual(try ModuleManifest.load(data), manifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["capabilities"] as? [String], ["files.read:/", "files.delete:~/Library/Caches", "network.connect:*.leeguoo.com"])
    }

    func testCapabilityTextRoundTripsAndRejectsUnknownKinds() {
        XCTAssertEqual(Capability("sensors.read"), Capability(.sensorsRead))
        XCTAssertEqual(Capability("files.read:~/a:b")?.scope, "~/a:b")
        XCTAssertNil(Capability("files.write:/tmp"))
        XCTAssertNil(Capability("files.read:"))
        XCTAssertNil(Capability(""))
    }

    func testFileScopesCoverOnlyWhatIsInsideThem() {
        let caches = Capability(.filesDelete, scope: "~/Library/Caches")
        XCTAssertTrue(caches.covers(Capability(.filesDelete, scope: "~/Library/Caches/Homebrew/x"), home: home))
        XCTAssertTrue(caches.covers(Capability(.filesDelete, scope: "/Users/someone/Library/Caches"), home: home))
        // A sibling whose name merely starts the same is outside.
        XCTAssertFalse(caches.covers(Capability(.filesDelete, scope: "~/Library/CachesOld/x"), home: home))
        // Climbing out with `..` is never covered, and neither is another kind.
        XCTAssertFalse(caches.covers(Capability(.filesDelete, scope: "~/Library/Caches/../Mail"), home: home))
        XCTAssertFalse(caches.covers(Capability(.filesRead, scope: "~/Library/Caches/x"), home: home))
        XCTAssertFalse(caches.covers(Capability(.filesDelete, scope: "Library/Caches"), home: home))
        XCTAssertTrue(Capability(.filesRead, scope: "/").covers(Capability(.filesRead, scope: "/private/var/x"), home: home))
    }

    func testHostScopes() {
        let wildcard = Capability(.networkConnect, scope: "*.leeguoo.com")
        XCTAssertTrue(wildcard.covers(Capability(.networkConnect, scope: "app.leeguoo.com"), home: home))
        XCTAssertFalse(wildcard.covers(Capability(.networkConnect, scope: "leeguoo.com"), home: home))
        XCTAssertFalse(wildcard.covers(Capability(.networkConnect, scope: "evil-leeguoo.com"), home: home))
        XCTAssertFalse(wildcard.covers(Capability(.networkConnect, scope: "app.leeguoo.com.evil.io"), home: home))
        XCTAssertTrue(Capability(.networkConnect, scope: "API.example.com").covers(Capability(.networkConnect, scope: "api.example.com"), home: home))
    }

    func testTheKernelDeniesWhatWasNotDeclaredAndConfirmsWhatChangesTheMac() {
        let manifest = disk()
        XCTAssertEqual(CapabilityPolicy.decide(Capability(.filesRead, scope: "/Applications"), for: manifest, home: home), .allowed)
        XCTAssertEqual(CapabilityPolicy.decide(Capability(.filesDelete, scope: "~/Library/Caches/pip"), for: manifest, home: home), .needsConfirmation)
        XCTAssertEqual(CapabilityPolicy.decide(Capability(.filesDelete, scope: "~/Documents/x"), for: manifest, home: home),
                       .denied("dev.thermo.disk did not declare files.delete:~/Documents/x"))
        XCTAssertEqual(CapabilityPolicy.decide(Capability(.screenCapture), for: manifest, home: home),
                       .denied("dev.thermo.disk did not declare screen.capture"))
        XCTAssertEqual(CapabilityPolicy.decide(Capability(.filesRead), for: manifest, home: home), .denied("files.read needs a scope"))
        XCTAssertEqual(CapabilityPolicy.decide(Capability(.sensorsRead, scope: "x"), for: manifest, home: home), .denied("sensors.read takes no scope"))
    }

    func testProblemsNameWhatIsWrong() {
        var m = disk()
        m.interface = ModuleManifest.currentInterface + 1
        m.id = "Disk"
        m.version = "1.0"
        m.capabilities = [Capability(.filesDelete, scope: "~"), Capability(.filesRead), Capability(.sensorsRead, scope: "x"),
                          Capability(.networkConnect, scope: "*"), Capability(.filesRead, scope: "relative/path")]
        m.commands[1].mutates = false
        m.commands.append(m.commands[0])
        m.entries[0].scene = nil
        m.entries[1].command = "missing"
        let problems = m.problems()
        for expected in ["interface 2 is not supported", "id Disk must be lowercase reverse-DNS", "version 1.0 must look like 1.2.3",
                         "files.delete may not cover ~", "files.read needs a scope", "sensors.read takes no scope",
                         "network scope * must be a host", "file scope relative/path must be absolute",
                         "command scan uses files.read:/, which the module does not declare",
                         "command clean uses a confirmed capability and must be marked mutates",
                         "command scan is defined twice", "entry home shows UI and needs a scene",
                         "entry scan-key must name one of the module's commands"] {
            XCTAssertTrue(problems.contains { $0.contains(expected) }, "missing: \(expected) in \(problems)")
        }
    }

    func testLoadRefusesAnInvalidOrUnreadableManifestWhole() throws {
        var m = disk(); m.version = "one"
        XCTAssertThrowsError(try ModuleManifest.load(JSONEncoder().encode(m))) { error in
            XCTAssertEqual((error as? ModuleManifest.Invalid)?.problems, ["version one must look like 1.2.3"])
        }
        XCTAssertThrowsError(try ModuleManifest.load(Data("{\"id\":\"dev.thermo.disk\"}".utf8)))
        var text = try XCTUnwrap(String(data: JSONEncoder().encode(disk()), encoding: .utf8))
        text = text.replacingOccurrences(of: "files.read:\\/", with: "files.write:\\/")
        XCTAssertThrowsError(try ModuleManifest.load(Data(text.utf8)))
    }

    func testTheXPCProtocolNamesAreFixed() {
        XCTAssertEqual(NSStringFromProtocol(KernelXPC.self), "TMKernelXPC")
        XCTAssertEqual(NSStringFromProtocol(ModuleXPC.self), "TMModuleXPC")
        _ = ModuleXPCInterfaces.kernel; _ = ModuleXPCInterfaces.module
    }
}
