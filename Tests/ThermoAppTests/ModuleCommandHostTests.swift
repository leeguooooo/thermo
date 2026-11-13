import AgentCore
import Foundation
import ModuleHost
import ModuleKit
import XCTest
@testable import ThermoApp

@MainActor final class ModuleCommandHostTests: XCTestCase {
    func fixture() async throws -> (ModuleCenter, URL, UserDefaults, String) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-module-command-"+UUID().uuidString)
        let contents=root.appendingPathComponent("Thermo.app/Contents/Extensions/Fixture.appex/Contents")
        try FileManager.default.createDirectory(at:contents.appendingPathComponent("Resources"),withIntermediateDirectories:true)
        let manifest=ModuleManifest(id:"com.example.command-fixture",name:"Command fixture",summary:"Never launched",symbol:"terminal",version:"1.0.0",enabledByDefault:true,
            commands:[.init(id:"echo",title:"Echo",summary:"Echo text",parameters:[.init(name:"value",kind:.string,required:true,summary:"Text"),.init(name:"dry-run",kind:.boolean,summary:"Validate only")])])
        try JSONEncoder().encode(manifest).write(to:contents.appendingPathComponent("Resources/module.json"))
        let plist:[String:Any]=["CFBundleIdentifier":manifest.id,"EXAppExtensionAttributes":["EXExtensionPointIdentifier":ModuleBundles.extensionPoint]]
        try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
        let suite="thermo-module-command-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        let center=ModuleCenter(manager:ModuleManager(app:root.appendingPathComponent("Thermo.app")),defaults:defaults)
        center.start()
        for _ in 0..<100 where !center.loaded { try? await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertTrue(center.loaded)
        return (center,root,defaults,suite)
    }
    func testDryRunAndInvalidCallsNeverStartTheModule() async throws {
        let (center,root,defaults,suite)=try await fixture()
        defer {defaults.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
        XCTAssertEqual(center.statuses.count,1)
        func request(_ command:String="echo",_ args:String="{\"value\":\"test\"}") -> AppControlRequest {
            .init(action:"modules.run",arguments:["module":"com.example.command-fixture","command":command,"arguments":args],dryRun:true)
        }
        let valid=await ModuleCommandHost.handle(request(),center:center)
        XCTAssertTrue(valid.succeeded,valid.issue ?? "")
        XCTAssertEqual(valid.values["moduleResult"],"{\"validated\":true,\"changesMade\":false}")
        let unknown=await ModuleCommandHost.handle(request("not-declared"),center:center)
        XCTAssertFalse(unknown.succeeded)
        let wrongType=await ModuleCommandHost.handle(request("echo","{\"value\":1}"),center:center)
        XCTAssertFalse(wrongType.succeeded)
        center.setEnabled("com.example.command-fixture",false)
        let off=await ModuleCommandHost.handle(request(),center:center)
        XCTAssertFalse(off.succeeded)
        XCTAssertTrue(off.issue?.contains("switched off") == true)
        XCTAssertNil(center.statuses.first?.pid)
    }
}
