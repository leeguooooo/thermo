import XCTest
@testable import ModuleKit

final class ModuleCommandCatalogTests: XCTestCase {
    func manifest(_ id: String = "dev.thermo.disk") -> ModuleManifest {
        .init(id:id,name:"Disk",summary:"Disk commands",symbol:"disk",version:"1.0.0",commands:[
            .init(id:"scan",title:"Scan",summary:"Scan files",parameters:[.init(name:"root",kind:.path,summary:"Roots",repeats:true)],cli:["clean"]),
            .init(id:"run",title:"Clean",summary:"Clean selected files",mutates:true,parameters:[
                .init(name:"ids",kind:.string,required:true,summary:"Item IDs",repeats:true),
                .init(name:"budget",kind:.integer,summary:"Time budget"),
                .init(name:"exact",kind:.boolean,summary:"Exact sizes")],cli:["clean","run"])])
    }
    func testDisabledModulesDisappearAndCallsMustResolveAgain() throws {
        let m=manifest(),on=try ModuleCommandCatalog([m],enabled:{_ in true}),off=try ModuleCommandCatalog([m],enabled:{_ in false})
        XCTAssertEqual(on.entries.count,2)
        XCTAssertEqual(on.command(matching:["clean","run","safe"])?.command.id,"run")
        XCTAssertNil(off.command(matching:["clean","run"]))
        XCTAssertNil(off.tool(named:"dev.thermo.disk.run"))
        XCTAssertTrue(off.entries.isEmpty)
    }
    func testGlobalPathConflictsAreReportedEvenForAnOffModule() throws {
        XCTAssertThrowsError(try ModuleCommandCatalog([manifest(),manifest("dev.other.disk")],enabled:{$0.id == "dev.thermo.disk"})) { error in
            XCTAssertTrue(String(describing:error).contains("used by more than one module"))
        }
    }
    func testSchemaAndValidationUseTheSameRepeatingTypes() throws {
        let entry=try XCTUnwrap(ModuleCommandCatalog([manifest()],enabled:{_ in true}).tool(named:"dev.thermo.disk.run"))
        let tool=entry.tool
        XCTAssertEqual(tool.inputSchema.properties["ids"]?.type,"array")
        XCTAssertEqual(tool.inputSchema.properties["ids"]?.items?.type,"string")
        XCTAssertEqual(tool.inputSchema.properties["ids"]?.minItems,1)
        XCTAssertFalse(tool.annotations.readOnlyHint)
        XCTAssertTrue(tool.annotations.destructiveHint)
        XCTAssertNoThrow(try entry.validate(["ids":.array([.string("safe")]),"budget":.integer(30),"exact":.boolean(true)]))
        for args: [String:ModuleArgument] in [[:],["ids":.array([])],["ids":.string("safe")],["ids":.array([.integer(1)])],
            ["ids":.array([.string("safe")]),"budget":.boolean(true)],["ids":.array([.string("safe")]),"undeclared":.string("x")]] {
            XCTAssertThrowsError(try entry.validate(args))
        }
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(tool)) as? [String:Any])
        XCTAssertEqual((json["inputSchema"] as? [String:Any])?["additionalProperties"] as? Bool,false)
    }
    func testJSONDoesNotCoerceBooleansNumbersNullsOrObjects() throws {
        let decode={ (text:String) in try JSONDecoder().decode([String:ModuleArgument].self,from:Data(text.utf8)) }
        XCTAssertEqual(try decode("{\"n\":1,\"b\":true,\"a\":[\"x\"]}"),["n":.integer(1),"b":.boolean(true),"a":.array([.string("x")])])
        XCTAssertThrowsError(try decode("{\"n\":1.5}"))
        XCTAssertThrowsError(try decode("{\"n\":null}"))
        XCTAssertThrowsError(try decode("{\"n\":{}}"))
    }
}
