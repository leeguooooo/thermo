import XCTest
@testable import ModuleKit

final class ModuleCommandArgumentsTests: XCTestCase {
    func entry() throws -> ModuleCommandCatalog.Entry {
        let m=ModuleManifest(id:"dev.thermo.disk",name:"Disk",summary:"Disk",symbol:"disk",version:"1.0.0",commands:[
            .init(id:"run",title:"Clean",summary:"Clean",parameters:[.init(name:"ids",kind:.string,required:true,summary:"IDs",repeats:true),
                .init(name:"budget",kind:.integer,summary:"Budget"),.init(name:"exact",kind:.boolean,summary:"Exact")],cli:["clean","run"])])
        return try XCTUnwrap(ModuleCommandCatalog([m],enabled:{_ in true}).entries.first)
    }
    func testNamedAndTrailingRepeatsKeepTheirTypes() throws {
        let e=try entry(),values=try e.parseCLI(["safe","--ids","with spaces","--budget=30","--exact=false"])
        XCTAssertEqual(values,["ids":.array([.string("safe"),.string("with spaces")]),"budget":.integer(30),"exact":.boolean(false)])
        XCTAssertNoThrow(try e.validate(values))
        XCTAssertTrue(e.cliUsage.hasPrefix("clean run --ids STRING"))
    }
    func testOptionLookingValuesCannotBecomeHostConfirmation() throws {
        let e=try entry(),controls=[ModuleManifest.Command.Parameter(name:"yes",kind:.boolean,summary:"Confirm")]
        XCTAssertEqual(try e.parseCLI(["--ids","--yes"],controls:controls),["ids":.array([.string("--yes")])])
        XCTAssertEqual(try e.parseCLI(["--","--yes"],controls:controls),["ids":.array([.string("--yes")])])
        XCTAssertEqual(try e.parseCLI(["safe","--yes"],controls:controls)["yes"],.boolean(true))
    }
    func testUnknownDuplicateAndMissingArgumentsAreRejected() throws {
        let e=try entry()
        for input in [[],["safe","--unknown"],["safe","--budget"],["safe","--budget","x"],["safe","--budget=1","--budget=2"],["safe","--exact=maybe"]] {
            XCTAssertThrowsError(try e.parseCLI(input),"\(input)")
        }
        XCTAssertThrowsError(try e.parseCLI(["safe"],controls:[.init(name:"ids",kind:.string,summary:"Conflict")]))
    }
}
