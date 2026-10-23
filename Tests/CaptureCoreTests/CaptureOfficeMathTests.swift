import Foundation
import XCTest
@testable import CaptureCore

final class CaptureOfficeMathTests:XCTestCase {
    @MainActor func testFractionsRootsScriptsAndMatricesRemainStructured() throws {
        for (source,tags) in [("\\frac{1}{\\sqrt{x}}",["m:f","m:rad"]),("x_1^2+\\sqrt[3]{y}",["m:sSubSup","m:deg"]),("\\begin{pmatrix}a&b\\\\c&d\\end{pmatrix}",["m:d","m:m","m:mr"]),("\\hat{x}+\\overline{y}",["m:acc","m:bar"])] {
            let formula=CaptureLaTeX(source:source),result=try CaptureOfficeMath.convert(formula.render().mathml,formula:formula)
            for tag in tags { XCTAssertTrue(result.contains("<"+tag+">"),source+" missing "+tag) }
            XCTAssertFalse(result.contains("drawing"));XCTAssertFalse(result.contains("<pic:"));XCTAssertTrue(XMLParser(data:Data(result.utf8)).parse())
        }
    }
    @MainActor func testNaryConsumesEditableBodyAndRetainsLimits() throws {
        let formula=CaptureLaTeX(source:"\\int_0^1 x^2\\,dx"),result=try CaptureOfficeMath.convert(formula.render().mathml,formula:formula)
        XCTAssertTrue(result.contains("<m:nary>"));XCTAssertTrue(result.contains("<m:sub>"));XCTAssertTrue(result.contains("<m:sup>"));XCTAssertTrue(result.contains("<m:e><m:sSup>"))
        XCTAssertTrue(result.contains("∫"));XCTAssertTrue(result.contains("<m:t xml:space=\"preserve\">x</m:t>"))
    }
    func testInvalidAndUnsupportedMathDoesNotSilentlyFlatten() throws {
        let formula=CaptureLaTeX(source:"x")
        for value in ["<!DOCTYPE math [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><math>&x;</math>","<math xmlns='http://www.w3.org/1998/Math/MathML'><unknown>x</unknown></math>","<math xmlns='http://www.w3.org/1998/Math/MathML'><mfrac><mi>x</mi></mfrac></math>","<math xmlns='http://www.w3.org/1998/Math/MathML'><menclose notation='circle'><mi>x</mi></menclose></math>"] { XCTAssertThrowsError(try CaptureOfficeMath.convert(value,formula:formula)) }
    }
    @MainActor func testStyleColorAndLiteralCharactersAreEscapedAndPreserved() throws {
        var formula=CaptureLaTeX(source:"\\text{a < b \\& c}");formula.foreground="#2244AA";formula.fontSize=40
        let output=try CaptureOfficeMath.convert(formula.render().mathml,formula:formula)
        XCTAssertTrue(output.contains("w:color w:val=\"2244AA\""));XCTAssertTrue(output.contains("w:sz w:val=\"80\""));XCTAssertTrue(output.contains("&lt;"));XCTAssertTrue(output.contains("&amp;"))
    }
    @MainActor func testDocxContainsNativeMathAndNoImageFallback() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:directory) }
        let file=directory.appendingPathComponent("formula.docx");try CaptureWordDocument.save(.init(source:"\\frac{x^2}{y}"),to:file)
        let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");process.arguments=["-p",file.path,"word/document.xml"];process.standardOutput=pipe;try process.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0);let xml=try XCTUnwrap(String(data:data,encoding:.utf8));XCTAssertTrue(xml.contains("<m:f>"));XCTAssertTrue(xml.contains("<m:sSup>"));XCTAssertFalse(xml.contains("THERMO_MATH_SLOT"));XCTAssertFalse(xml.contains("<w:drawing"));XCTAssertTrue(XMLParser(data:data).parse())
        let existing=Data("existing".utf8);try existing.write(to:file)
        XCTAssertThrowsError(try CaptureWordDocument.save(.init(source:"\\notACommand"),to:file));XCTAssertEqual(try Data(contentsOf:file),existing)
    }
    @MainActor func testChemistryMetricPhantomsDoNotHideVisibleSubscripts() throws {
        let formula=CaptureLaTeX(source:"\\ce{H2O}"),result=try CaptureOfficeMath.convert(formula.render().mathml,formula:formula)
        XCTAssertTrue(result.contains("<m:sSub>"));XCTAssertTrue(result.contains(">H</m:t>"));XCTAssertTrue(result.contains(">2</m:t>"));XCTAssertTrue(result.contains(">O</m:t>"));XCTAssertFalse(result.contains("<m:phant>"))
    }
    @MainActor func testAlignedEquationsUseAlignmentArray() throws {
        let formula=CaptureLaTeX(source:"\\begin{aligned}a&=b+c\\\\d&=e\\end{aligned}"),result=try CaptureOfficeMath.convert(formula.render().mathml,formula:formula)
        XCTAssertTrue(result.contains("<m:eqArr>"));XCTAssertFalse(result.contains("<m:m>"));XCTAssertTrue(result.contains("<m:aln"));XCTAssertFalse(result.contains("&amp;"))
        let xml=try XMLDocument(data:Data(result.utf8));let markers=try xml.nodes(forXPath:"//*[local-name()='r'][*[local-name()='rPr']/*[local-name()='aln']]/*[local-name()='t']");XCTAssertEqual(markers.map { $0.stringValue ?? "" },["=","="])
    }

    @MainActor func testChemicalIsotopeUsesPrescriptsAndVisibleAtomicNumbers() throws {
        let formula=CaptureLaTeX(source:"\\ce{^{14}_{6}C}"),result=try CaptureOfficeMath.convert(formula.render().mathml,formula:formula)
        XCTAssertTrue(result.contains("<m:sPre>"));XCTAssertTrue(result.contains(">14</m:t>"));XCTAssertTrue(result.contains(">6</m:t>"));XCTAssertFalse(result.contains("<m:phant>"))
    }

}
