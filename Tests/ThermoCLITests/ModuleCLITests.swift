import Darwin
import Foundation
import MCP
import ModuleKit
import XCTest
@testable import thermo

final class ModuleCLITests: XCTestCase {
    func testCommandLeaseMapsLegacyRootsAndLeavesRecoveryAvailable() throws {
        XCTAssertEqual(ModuleCLI.builtinManifest(["history"])?.id,BuiltinModuleManifests.history.id)
        XCTAssertEqual(ModuleCLI.builtinManifest(["tabs"])?.id,BuiltinModuleManifests.browser.id)
        XCTAssertEqual(ModuleCLI.builtinManifest(["apps"])?.id,BuiltinModuleManifests.apps.id)
        XCTAssertEqual(ModuleCLI.builtinManifest(["app"])?.id,BuiltinModuleManifests.apps.id)
        XCTAssertEqual(ModuleCLI.builtinManifest(["clean","overview"])?.id,BuiltinModuleManifests.disk.id)
        XCTAssertEqual(ModuleCLI.builtinManifest(["w"])?.id,BuiltinModuleManifests.performance.id)
        XCTAssertNil(ModuleCLI.builtinManifest(["fan","auto"]))
        XCTAssertNil(ModuleCLI.builtinManifest(["search","give-back-command-space"]))
        let home=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:home)}
        let name="thermo-cli-lease-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(BuiltinModuleManifests.performance.id))
        XCTAssertNil(try ModuleCLI.commandLease(["fan","auto"],defaults:defaults,home:home.path))
        XCTAssertThrowsError(try ModuleCLI.commandLease(["watch"],defaults:defaults,home:home.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:home.path).isEmpty)
    }
    func testDisabledAgentDiagnosticsRefusesAllAliasesWithoutDisablingCleanup() throws {
        let name="thermo-agents-cli-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(BuiltinModuleManifests.agents.id))
        for root in ["agents","agent","doctor"] {
            XCTAssertThrowsError(try ModuleCLI.requireBuiltinFeature([root],defaults:defaults))
        }
        XCTAssertNoThrow(try ModuleCLI.requireBuiltinFeature(["clean","overview"],defaults:defaults))
    }
    func testDisabledHistoryRefusesItsCommandsWithoutDisablingCleanup() throws {
        let name="thermo-history-cli-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(BuiltinModuleManifests.history.id))
        for words in [["history"],["history","show","fixture"],["history","undo","fixture"]] {
            XCTAssertThrowsError(try ModuleCLI.requireBuiltinFeature(words,defaults:defaults))
        }
        XCTAssertNoThrow(try ModuleCLI.requireBuiltinFeature(["clean","overview"],defaults:defaults))
    }
    func testDisabledSpaceRefusesItsCommandsAndKeepsTheDiskFeatureIndependent() throws {
        let name="thermo-space-cli-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(BuiltinModuleManifests.space.id))
        for words in [["space"],["space","large"],["space","duplicates"],["space","trash"]] {
            XCTAssertThrowsError(try ModuleCLI.requireBuiltinFeature(words,defaults:defaults))
        }
        XCTAssertNoThrow(try ModuleCLI.requireBuiltinFeature(["clean","overview"],defaults:defaults))
    }
    func testDisabledSoftwareRefusesBothLegacyCommandAliases() throws {
        let name="thermo-apps-cli-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(BuiltinModuleManifests.apps.id))
        for words in [["apps"],["app","list"],["apps","uninstall"],["apps","startup"],["apps","updates"]] {
            XCTAssertThrowsError(try ModuleCLI.requireBuiltinFeature(words,defaults:defaults))
        }
    }
    func testDisabledSearchRejectsQueriesIndexingAndTakeoverButAllowsGivingSpotlightBack() throws {
        let name="thermo-search-cli-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(BuiltinModuleManifests.search.id))
        for words in [["search"],["search","query","selected"],["search","index"],["search","open"],["search","use-command-space"]] {
            XCTAssertThrowsError(try ModuleCLI.requireBuiltinFeature(words,defaults:defaults))
        }
        XCTAssertNoThrow(try ModuleCLI.requireBuiltinFeature(["search","give-back-command-space"],defaults:defaults))
    }
    func testDisabledPerformanceRefusesLegacyReadersAndFanWritesButKeepsRecoveryAvailable() throws {
        let name = "thermo-performance-cli-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: ModulePreferences.key(BuiltinModuleManifests.performance.id))
        for words in [[], ["temps"], ["t"], ["watch"], ["memory"], ["activity"], ["pulse"], ["status"], ["fan", "set", "all", "max"], ["fan", "curve", "0", "40:1000,80:4000"]] {
            XCTAssertThrowsError(try ModuleCLI.requireBuiltinFeature(words, defaults: defaults), words.joined(separator: " "))
        }
        for words in [["fan", "auto"], ["helper", "status"], ["helper", "uninstall"], ["battery"], ["history"], ["capabilities"]] {
            XCTAssertNoThrow(try ModuleCLI.requireBuiltinFeature(words, defaults: defaults))
        }
        defaults.set(true, forKey: ModulePreferences.key(BuiltinModuleManifests.performance.id))
        XCTAssertNoThrow(try ModuleCLI.requireBuiltinFeature(["memory"], defaults: defaults))
    }
    func testSharedDiskDeclarationIsValidAndAllRoutesAreUnique() throws {
        let catalog=try ModuleCommandCatalog(BuiltinModuleManifests.all,enabled:{_ in true})
        XCTAssertEqual(catalog.entries.count,10)
        XCTAssertEqual(Set(catalog.entries.map(\.toolName)).count,10)
        XCTAssertEqual(BuiltinModuleManifests.disk.problems(),[])
        for entry in catalog.entries {
            let tool=try JSONDecoder().decode(MCP.Tool.self,from:JSONEncoder().encode(entry.tool))
            XCTAssertEqual(tool.name,entry.toolName)
        }
        XCTAssertEqual(CommandHelp.capabilities.filter{$0.command.hasPrefix("clean")}.count,10)
    }
    func testOffModuleHasNoToolsAndExecutionRefusesBeforeRunningAnything() throws {
        let name="thermo-cli-module-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer {defaults.removePersistentDomain(forName:name)}
        let manifest=BuiltinModuleManifests.disk
        XCTAssertTrue(ModulePreferences.isEnabled(manifest,in:defaults))
        let entry=try XCTUnwrap(ModuleCLI.catalog(manifests:[manifest],defaults:defaults).entries.first)
        defaults.set(false,forKey:ModulePreferences.key(manifest.id))
        let off=try ModuleCLI.catalog(manifests:[manifest],defaults:defaults)
        XCTAssertTrue(off.entries.isEmpty)
        XCTAssertThrowsError(try ModuleCLI.requireEnabled(manifest,defaults:defaults))
        XCTAssertThrowsError(try ModuleCLI.execute(entry,arguments:[:],literalRoots:true,catalog:off)) { error in
            XCTAssertTrue(String(describing:error).contains("switched off"))
        }
    }
    func testReadOnlyToolCannotTurnItsCategoryIntoAMutatingSubcommand() throws {
        let catalog=try ModuleCommandCatalog(BuiltinModuleManifests.all,enabled:{_ in true})
        let scan=try XCTUnwrap(catalog.tool(named:"dev.thermo.disk.scan"))
        XCTAssertFalse(scan.command.mutates)
        XCTAssertThrowsError(try ModuleCLI.execute(scan,arguments:["categories":.array([.string("run"),.string("safe")])],literalRoots:true,catalog:catalog)) { error in
            XCTAssertTrue(String(describing:error).contains("category"),"\(error)")
        }
    }
    func testRoutingKeepsOptionValuesSeparateFromPathAndConfirmation() throws {
        let argv=["-j","clean","run","--targets","--yes","safe","-y"]
        let parsed=try Args(argv)
        XCTAssertEqual(parsed.positionals,["clean","run","safe"])
        XCTAssertEqual(parsed.positionalIndices,[1,2,5])
        let catalog=try ModuleCommandCatalog(BuiltinModuleManifests.all,enabled:{_ in true})
        let entry=try XCTUnwrap(catalog.command(matching:parsed.positionals))
        let indices=Set(parsed.positionalIndices.prefix(entry.cliPath.count))
        let remaining=argv.enumerated().filter{!indices.contains($0.offset)}.map(\.element)
        let values=try entry.parseCLI(remaining,aliases:Args.aliases)
        XCTAssertEqual(values["targets"],.array([.string("--yes"),.string("safe")]))
        XCTAssertEqual(values["yes"],.boolean(true))
        XCTAssertEqual(values["json"],.boolean(true))
    }
    func testSwitchChangedBeforeFirstPollNotifiesAndRefusesCalls() async throws {
        final class Fixture: @unchecked Sendable {
            let lock = NSLock()
            private var enabled = true
            func turnOff() { lock.lock(); enabled = false; lock.unlock() }
            func catalog() throws -> ModuleCommandCatalog {
                lock.lock(); let value = enabled; lock.unlock()
                return try ModuleCommandCatalog(BuiltinModuleManifests.all, enabled: { _ in value })
            }
        }
        let fixture = Fixture()
        let state = ModuleMCPState(readCatalog: { try fixture.catalog() })
        await state.didInitialize()
        let listed = try await state.tools()
        XCTAssertEqual(listed.count, 10)
        fixture.turnOff()
        let changed = try await state.takeListChange()
        XCTAssertTrue(changed)
        let repeated = try await state.takeListChange()
        XCTAssertFalse(repeated)
        do {
            _ = try await state.call(.init(name: "dev.thermo.disk.log", arguments: [:]))
            XCTFail("A disabled module must be refused before a child starts")
        } catch MCPError.invalidParams { }
    }
    func testMCPChildInputHasNoNameAndIsPrivate() throws {
        let payload=Data("{\"targets\":[\"--yes\",\"with spaces\"]}".utf8)
        let input=try ModuleMCPState.privateInput(payload)
        defer {try? input.close()}
        var st=stat();XCTAssertEqual(fstat(input.fileDescriptor,&st),0)
        XCTAssertEqual(st.st_nlink,0)
        XCTAssertEqual(st.st_mode & 0o077,0)
        XCTAssertEqual(try input.readToEnd(),payload)
    }
}
